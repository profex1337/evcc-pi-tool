import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'host_key.dart';
import 'settings_store.dart';
import 'ssh_runner.dart';

/// Real [SshRunner] backed by dartssh2 (pure-Dart SSH, password auth).
///
/// Thin I/O adapter: no parsing or business logic lives here (that is in the
/// unit-tested pure layer). Exercised end-to-end by the manual dry-run against
/// the real Pi (see README).
class Dartssh2Runner implements SshRunner {
  final SshConfig config;
  final HostKeyStore _hostKeyStore;
  SSHClient? _client;
  String? _changedFingerprint;
  String? _storedAtCheck;

  Dartssh2Runner(this.config, {HostKeyStore? hostKeyStore})
      : _hostKeyStore = hostKeyStore ?? SecureHostKeyStore();

  @override
  Future<void> connect() async {
    // SSHSocket.connect's timeout only bounds the TCP handshake, so bound the
    // auth handshake separately — otherwise a host that accepts TCP but stalls
    // during key-exchange/auth would hang forever.
    // Parse the private key before opening the socket so a bad key/passphrase
    // fails fast (and surfaces as a clear auth error) without leaking a socket.
    // fromPem throws SSHKeyDecryptError for passphrase issues but plain
    // FormatException/UnsupportedError/ArgumentError for malformed/unsupported
    // keys — normalise them all to SSHKeyDecodeError so the UI shows one clear
    // "key invalid" message instead of a raw error.
    List<SSHKeyPair>? identities;
    if (config.usesKeyAuth) {
      try {
        identities = SSHKeyPair.fromPem(
          config.privateKey,
          config.keyPassphrase.isEmpty ? null : config.keyPassphrase,
        );
      } on SSHKeyDecodeError {
        rethrow;
      } catch (e) {
        throw SSHKeyDecodeError('Privater SSH-Key konnte nicht gelesen werden', e);
      }
    }

    final socket = await SSHSocket.connect(
      config.host,
      config.port,
      timeout: config.timeout,
    );
    final client = SSHClient(
      socket,
      username: config.username,
      // Key auth when a private key is provided; otherwise password auth.
      identities: identities,
      onPasswordRequest: config.usesKeyAuth ? null : () => config.password,
      // TOFU host-key check. dartssh2 hands us the OpenSSH `SHA256:<base64>`
      // fingerprint (UTF-8 bytes). Returning false aborts the handshake before
      // any password is sent.
      onVerifyHostKey: (type, fingerprint) async {
        final presented = utf8.decode(fingerprint);
        final id = hostKeyId(config.host, config.port);
        final stored = await _hostKeyStore.get(id);
        switch (verifyHostKey(stored: stored, presented: presented)) {
          case HostKeyVerdict.firstUse:
            await _hostKeyStore.set(id, presented);
            return true;
          case HostKeyVerdict.match:
            return true;
          case HostKeyVerdict.changed:
            _changedFingerprint = presented;
            _storedAtCheck = stored;
            return false;
        }
      },
    );
    try {
      // Force authentication now so wrong-password errors surface here.
      await client.authenticated.timeout(config.timeout);
    } catch (e) {
      client.close();
      // A rejected host key surfaces as an SSHHostkeyError here; translate it
      // to a typed domain error carrying the new fingerprint.
      if (_changedFingerprint != null) {
        throw HostKeyChangedException(
          host: config.host,
          port: config.port,
          presented: _changedFingerprint!,
          stored: _storedAtCheck,
        );
      }
      rethrow;
    }
    _client = client;
  }

  @override
  Future<CommandResult> run(
    String command, {
    String? stdin,
    void Function(String chunk)? onOutput,
  }) async {
    final client = _client;
    if (client == null) {
      throw StateError('connect() must be called before run()');
    }

    final session = await client.execute(command);

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();

    // Drain both streams to completion. asFuture() resolves on the stream's
    // onDone, which dartssh2 fires only after all channel data is delivered —
    // so no trailing chunk (e.g. a short version string) can be lost. Awaiting
    // the streams (rather than session.done + cancel) is what guarantees this.
    final outDone = session.stdout.listen((data) {
      final s = utf8.decode(data, allowMalformed: true);
      stdoutBuf.write(s);
      onOutput?.call(s);
    }).asFuture<void>();
    final errDone = session.stderr.listen((data) {
      final s = utf8.decode(data, allowMalformed: true);
      stderrBuf.write(s);
      onOutput?.call(s);
    }).asFuture<void>();

    if (stdin != null) {
      session.stdin.add(Uint8List.fromList(utf8.encode(stdin)));
    }
    await session.stdin.close();

    try {
      await Future.wait([outDone, errDone]).timeout(config.commandTimeout);
    } on TimeoutException {
      session.close();
      rethrow;
    }

    return CommandResult(
      exitCode: session.exitCode,
      stdout: stdoutBuf.toString(),
      stderr: stderrBuf.toString(),
    );
  }

  @override
  Future<void> close() async {
    _client?.close();
    _client = null;
  }
}
