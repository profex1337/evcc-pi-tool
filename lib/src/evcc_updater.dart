import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'commands.dart';
import 'dartssh2_runner.dart';
import 'parsing.dart';
import 'ssh_runner.dart';

/// Categories of failure surfaced to the user with a clear message.
enum UpdateErrorKind {
  connection,
  auth,
  sudo,
  serviceInactive,
  packageMissing,
  unknown,
}

/// A failure during the update, carrying a user-facing German [message].
class EvccUpdateException implements Exception {
  final UpdateErrorKind kind;
  final String message;

  const EvccUpdateException(this.kind, this.message);

  @override
  String toString() => 'EvccUpdateException($kind): $message';
}

/// Result of a successful connection test.
class ConnectionInfo {
  final String version;
  final bool serviceActive;

  const ConnectionInfo({required this.version, required this.serviceActive});
}

/// Result of a successful evcc installation.
class InstallResult {
  final String version;
  final bool serviceActive;

  const InstallResult({required this.version, required this.serviceActive});
}

/// Builds the [SshRunner] for a given config (injected so tests can fake SSH).
typedef SshRunnerFactory = SshRunner Function(SshConfig config);

/// Orchestrates the validated evcc update sequence over SSH.
class EvccUpdater {
  final SshRunnerFactory runnerFactory;

  const EvccUpdater({required this.runnerFactory});

  /// Production updater backed by the real dartssh2 adapter.
  factory EvccUpdater.real() =>
      EvccUpdater(runnerFactory: (config) => Dartssh2Runner(config));

  /// Runs the update (or a dry-run probe) and returns a result summary.
  ///
  /// Streams every command and its output to [onLog] (with the password
  /// redacted). Throws [EvccUpdateException] on any failure.
  Future<UpdateSummary> run({
    required SshConfig config,
    required bool fullUpgrade,
    required bool dryRun,
    required void Function(String line) onLog,
  }) {
    return _withConnection<UpdateSummary>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Verbunden. Starte ${dryRun ? 'Probelauf' : 'Update'} …');

        final steps = buildUpdateSteps(fullUpgrade: fullUpgrade, dryRun: dryRun);
        String? before;
        String? after;
        var upgradeOutput = '';

        for (var i = 0; i < steps.length; i++) {
          final step = steps[i];
          log('\$ ${step.command}');

          final result = await runner.run(
            step.command,
            stdin: step.needsSudoPassword ? '${config.password}\n' : null,
            onOutput: (chunk) {
              final trimmed = chunk.trimRight();
              if (trimmed.isNotEmpty) log(trimmed);
            },
          );
          final combined = '${result.stdout}\n${result.stderr}';

          if (step.needsSudoPassword && isSudoPasswordFailure(combined)) {
            throw const EvccUpdateException(
              UpdateErrorKind.sudo,
              'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
            );
          }

          switch (i) {
            case 0:
              before = parseInstalledVersion(result.stdout);
              if (before == null) {
                throw const EvccUpdateException(
                  UpdateErrorKind.packageMissing,
                  'evcc ist auf dem Pi nicht installiert (apt-Paket fehlt).',
                );
              }
            case 2:
              upgradeOutput = combined;
            case 3:
              if (!dryRun && !isServiceActive(result.stdout)) {
                throw const EvccUpdateException(
                  UpdateErrorKind.serviceInactive,
                  'evcc-Dienst ist nach dem Update nicht aktiv '
                  '(systemctl is-active ≠ active).',
                );
              }
            case 4:
              after = parseInstalledVersion(result.stdout);
          }
        }

        final summary = summarize(
          before: before,
          after: after,
          dryRun: dryRun,
          fullUpgrade: fullUpgrade,
          alreadyNewest: isAlreadyNewest(upgradeOutput),
        );
        log(summary.message);
        return summary;
      },
    );
  }

  /// Quick reachability/auth check: connects, reads the evcc version and the
  /// service state. Uses no sudo and changes nothing. Throws
  /// [EvccUpdateException] when the host is unreachable, auth fails, or evcc is
  /// not installed.
  Future<ConnectionInfo> testConnection({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<ConnectionInfo>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Verbunden. Prüfe evcc …');

        log('\$ $versionQuery');
        final versionResult = await runner.run(versionQuery);
        final version = parseInstalledVersion(versionResult.stdout);
        if (version == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.packageMissing,
            'Verbindung steht, aber evcc ist auf dem Pi nicht installiert.',
          );
        }

        log('\$ $serviceStatus');
        final serviceResult = await runner.run(serviceStatus);
        final active = isServiceActive(serviceResult.stdout);

        log('OK: evcc $version, Dienst ${active ? 'aktiv' : 'inaktiv'}.');
        return ConnectionInfo(version: version, serviceActive: active);
      },
    );
  }

  /// Installs evcc on a freshly-configured Pi: adds the official apt repo,
  /// installs the package and enables the service — all as root via one
  /// `sudo -S bash -s` call (password fed as the first stdin line, never on the
  /// command line). Then verifies the installed version and service state.
  ///
  /// Experimental: built from evcc's official docs but not validated against a
  /// fresh Pi end-to-end. Throws [EvccUpdateException] on failure.
  Future<InstallResult> install({
    required SshConfig config,
    required void Function(String line) onLog,
  }) {
    return _withConnection<InstallResult>(
      config: config,
      onLog: onLog,
      body: (runner, log) async {
        log('Installiere evcc … (Repo einrichten + Paket installieren, '
            'das dauert ein paar Minuten)');

        final result = await runner.run(
          installShellCommand,
          stdin: '${config.password}\n${buildInstallScript()}\n',
          onOutput: (chunk) {
            final trimmed = chunk.trimRight();
            if (trimmed.isNotEmpty) log(trimmed);
          },
        );
        final combined = '${result.stdout}\n${result.stderr}';

        if (isSudoPasswordFailure(combined)) {
          throw const EvccUpdateException(
            UpdateErrorKind.sudo,
            'sudo hat das Passwort abgelehnt – stimmt das Pi-Passwort?',
          );
        }
        if (result.exitCode != null && result.exitCode != 0) {
          throw EvccUpdateException(
            UpdateErrorKind.unknown,
            'Installation fehlgeschlagen (Exit ${result.exitCode}). '
            'Details im Log.',
          );
        }

        final versionResult = await runner.run(versionQuery);
        final version = parseInstalledVersion(versionResult.stdout);
        if (version == null) {
          throw const EvccUpdateException(
            UpdateErrorKind.packageMissing,
            'Installation lief durch, aber evcc ist nicht auffindbar.',
          );
        }

        final serviceResult = await runner.run(serviceStatus);
        final active = isServiceActive(serviceResult.stdout);

        log('evcc $version installiert, Dienst ${active ? 'aktiv' : 'inaktiv'}.');
        return InstallResult(version: version, serviceActive: active);
      },
    );
  }

  /// Opens the connection, runs [body], and maps any SSH/IO failure to an
  /// [EvccUpdateException]. The runner is always closed afterwards.
  Future<T> _withConnection<T>({
    required SshConfig config,
    required void Function(String line) onLog,
    required Future<T> Function(SshRunner runner, void Function(String) log)
        body,
  }) async {
    final runner = runnerFactory(config);
    void log(String s) => onLog(redactPassword(s, config.password));

    try {
      log('Verbinde mit ${config.username}@${config.host}:${config.port} …');
      await runner.connect();
      return await body(runner, log);
    } on EvccUpdateException {
      rethrow;
    } on SSHAuthError {
      throw const EvccUpdateException(
        UpdateErrorKind.auth,
        'Anmeldung fehlgeschlagen – Benutzer/Passwort prüfen.',
      );
    } on SocketException {
      throw const EvccUpdateException(
        UpdateErrorKind.connection,
        'Verbindung fehlgeschlagen – IP/Port korrekt, Pi online im Netz?',
      );
    } on TimeoutException {
      throw const EvccUpdateException(
        UpdateErrorKind.connection,
        'Zeitüberschreitung – Pi nicht erreichbar.',
      );
    } on SSHError catch (e) {
      throw EvccUpdateException(UpdateErrorKind.unknown, 'SSH-Fehler: $e');
    } catch (e) {
      throw EvccUpdateException(
          UpdateErrorKind.unknown, 'Unerwarteter Fehler: $e');
    } finally {
      await runner.close();
    }
  }
}
