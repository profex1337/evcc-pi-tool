import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:flutter_test/flutter_test.dart';

// Exact command strings the updater is expected to run (see commands.dart).
const _vQuery = r"dpkg-query -W -f='${Version}' evcc";
const _aptUpdate = 'sudo -S apt-get update -qq';
const _aptUpgrade = 'sudo -S apt-get install --only-upgrade -y evcc';
const _aptDryRun = 'sudo -S apt-get install --only-upgrade --dry-run evcc';
const _svc = 'systemctl is-active evcc';

const _config = SshConfig(
  host: '192.168.178.64',
  port: 22,
  username: 'pi',
  password: 'sekret',
  timeout: Duration(seconds: 10),
);

CommandResult _r(String stdout, {String stderr = '', int exitCode = 0}) =>
    CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr);

/// In-memory [SshRunner] that returns scripted output per command. A command
/// listed with several results yields them in order on successive calls (the
/// version query runs twice: before and after).
class FakeSshRunner implements SshRunner {
  final Map<String, List<CommandResult>> responses;
  final Object? connectError;

  final List<String> commandsRun = [];
  final Map<String, String?> stdinByCommand = {};
  bool closed = false;
  bool connected = false;

  FakeSshRunner(this.responses, {this.connectError});

  @override
  Future<void> connect() async {
    if (connectError != null) throw connectError!;
    connected = true;
  }

  @override
  Future<CommandResult> run(String command,
      {String? stdin, void Function(String chunk)? onOutput}) async {
    commandsRun.add(command);
    stdinByCommand[command] = stdin;

    final queue = responses[command];
    final CommandResult result;
    if (queue == null || queue.isEmpty) {
      result = _r('');
    } else {
      result = queue.length > 1 ? queue.removeAt(0) : queue.first;
    }

    if (onOutput != null) {
      if (result.stdout.isNotEmpty) onOutput(result.stdout);
      if (result.stderr.isNotEmpty) onOutput(result.stderr);
    }
    return result;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

EvccUpdater _updaterWith(FakeSshRunner runner) =>
    EvccUpdater(runnerFactory: (_) => runner);

FakeSshRunner _happyRunner() => FakeSshRunner({
      _vQuery: [_r('0.310.0\n'), _r('0.311.0\n')],
      _aptUpdate: [_r('')],
      _aptUpgrade: [
        _r('Setting up evcc (0.311.0) ...\n'
            '1 upgraded, 0 newly installed, 0 to remove and 27 not upgraded.')
      ],
      _svc: [_r('active\n')],
    });

void main() {
  group('EvccUpdater happy paths', () {
    test('real run upgrades evcc and reports the version change', () async {
      final runner = _happyRunner();
      final log = <String>[];

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: log.add,
      );

      expect(result.status, UpdateStatus.updated);
      expect(result.before, '0.310.0');
      expect(result.after, '0.311.0');
      expect(result.message, 'evcc 0.310.0 → 0.311.0 aktualisiert.');
      expect(runner.closed, isTrue);
    });

    test('real run without a newer version reports already current', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n'), _r('0.310.0\n')],
        _aptUpdate: [_r('')],
        _aptUpgrade: [
          _r('evcc is already the newest version (0.310.0).\n'
              '0 upgraded, 0 newly installed, 0 to remove and 28 not upgraded.')
        ],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: (_) {},
      );

      expect(result.status, UpdateStatus.alreadyCurrent);
    });

    test('full system upgrade: evcc unchanged, system packages upgraded',
        () async {
      const fullCmd = 'sudo -S apt-get full-upgrade -y';
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n'), _r('0.310.0\n')],
        _aptUpdate: [_r('')],
        fullCmd: [
          _r('The following packages will be upgraded:\n  libfoo libbar\n'
              '12 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.')
        ],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: true,
        dryRun: false,
        onLog: (_) {},
      );

      expect(runner.commandsRun, contains(fullCmd));
      expect(result.status, UpdateStatus.alreadyCurrent);
      expect(result.message, contains('System-Pakete'));
    });

    test('dry-run uses the --dry-run command and reports a probe', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n')],
        _aptUpdate: [_r('')],
        _aptDryRun: [
          _r('Inst evcc [0.310.0] (0.311.0 ...)\n'
              '1 upgraded, 0 newly installed, 0 to remove.')
        ],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: true,
        onLog: (_) {},
      );

      expect(runner.commandsRun, contains(_aptDryRun));
      expect(result.status, UpdateStatus.dryRunWouldUpdate);
    });
  });

  group('EvccUpdater password handling', () {
    test('feeds the sudo password via stdin only for the apt-get steps',
        () async {
      final runner = _happyRunner();

      await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: (_) {},
      );

      expect(runner.stdinByCommand[_aptUpdate], 'sekret\n');
      expect(runner.stdinByCommand[_aptUpgrade], 'sekret\n');
      expect(runner.stdinByCommand[_vQuery], isNull);
      expect(runner.stdinByCommand[_svc], isNull);
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('redacts the password if it ever surfaces in command output',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n'), _r('0.310.0\n')],
        _aptUpdate: [_r('', stderr: 'oops leaked sekret here')],
        _aptUpgrade: [
          _r('evcc is already the newest version (0.310.0).\n'
              '0 upgraded, 0 newly installed, 0 to remove and 28 not upgraded.')
        ],
        _svc: [_r('active\n')],
      });
      final log = <String>[];

      await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: log.add,
      );

      expect(log.any((l) => l.contains('sekret')), isFalse);
      expect(log.any((l) => l.contains(passwordMask)), isTrue);
    });
  });

  group('EvccUpdater.testConnection', () {
    test('reports evcc version and service state without using sudo', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n')],
        _svc: [_r('active\n')],
      });

      final info = await _updaterWith(runner)
          .testConnection(config: _config, onLog: (_) {});

      expect(info.version, '0.310.0');
      expect(info.serviceActive, isTrue);
      expect(runner.commandsRun, isNot(contains(_aptUpdate)));
      expect(runner.commandsRun, isNot(contains(_aptUpgrade)));
      expect(runner.stdinByCommand[_vQuery], isNull);
      expect(runner.stdinByCommand[_svc], isNull);
      expect(runner.closed, isTrue);
    });

    test('an inactive service is reported, not treated as an error', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n')],
        _svc: [_r('inactive\n')],
      });

      final info = await _updaterWith(runner)
          .testConnection(config: _config, onLog: (_) {});

      expect(info.version, '0.310.0');
      expect(info.serviceActive, isFalse);
    });

    test('maps an auth failure to an auth error', () async {
      final runner =
          FakeSshRunner({}, connectError: SSHAuthFailError('no auth'));

      await expectLater(
        _updaterWith(runner).testConnection(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.auth)),
      );
    });

    test('fails clearly when evcc is not installed', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('', stderr: 'no packages found', exitCode: 1)],
      });

      await expectLater(
        _updaterWith(runner).testConnection(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.packageMissing)),
      );
    });
  });

  group('EvccUpdater.install', () {
    const installCmd = 'sudo -S bash -s';

    test('runs the install script as root, then verifies version + service',
        () async {
      final runner = FakeSshRunner({
        installCmd: [_r('Setting up evcc ...', exitCode: 0)],
        _vQuery: [_r('0.310.0\n')],
        _svc: [_r('active\n')],
      });

      final res =
          await _updaterWith(runner).install(config: _config, onLog: (_) {});

      expect(res.version, '0.310.0');
      expect(res.serviceActive, isTrue);
      // Password is the FIRST stdin line (for sudo -S), not in the command.
      expect(runner.stdinByCommand[installCmd], startsWith('sekret\n'));
      expect(runner.stdinByCommand[installCmd], contains('apt-get install -y evcc'));
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('detects a rejected sudo password', () async {
      final runner = FakeSshRunner({
        installCmd: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).install(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('fails when the install script exits non-zero', () async {
      final runner = FakeSshRunner({
        installCmd: [_r('E: Unable to locate package evcc', exitCode: 100)],
      });

      await expectLater(
        _updaterWith(runner).install(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater error handling', () {
    test('maps a socket failure to a connection error', () async {
      final runner = FakeSshRunner({}, connectError: SocketException('refused'));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.connection)),
      );
    });

    test('maps an SSH auth failure to an auth error', () async {
      final runner =
          FakeSshRunner({}, connectError: SSHAuthFailError('no auth methods'));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.auth)),
      );
    });

    test('detects a rejected sudo password and still cleans up', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n')],
        _aptUpdate: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
      expect(runner.closed, isTrue);
    });

    test('fails when the service is not active after a real upgrade', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('0.310.0\n'), _r('0.311.0\n')],
        _aptUpdate: [_r('')],
        _aptUpgrade: [_r('1 upgraded, 0 newly installed')],
        _svc: [_r('inactive\n', exitCode: 3)],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.serviceInactive)),
      );
    });

    test('fails clearly when evcc is not installed', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('', stderr: 'no packages found matching evcc', exitCode: 1)],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.packageMissing)),
      );
    });
  });
}
