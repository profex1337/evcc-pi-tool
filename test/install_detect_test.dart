import 'package:evcc_updater/src/commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyInstall', () {
    test('apt wins when dpkg reports a version', () {
      expect(
        classifyInstall(dpkgOutput: '0.123.1', dockerPs: 'evcc|evcc/evcc'),
        InstallKind.apt,
      );
    });
    test('docker when no apt package but an evcc container runs', () {
      expect(
        classifyInstall(
          dpkgOutput: '',
          dockerPs: 'db|postgres:16\nevcc|evcc/evcc:latest',
        ),
        InstallKind.docker,
      );
    });
    test('unknown when neither is present', () {
      expect(
        classifyInstall(dpkgOutput: '   ', dockerPs: 'db|postgres:16'),
        InstallKind.unknown,
      );
    });
  });

  group('parseEvccDocker', () {
    test('finds the evcc container by image among others', () {
      final d = parseEvccDocker('db|postgres:16\nmy-evcc|evcc/evcc:0.123');
      expect(d, isNotNull);
      expect(d!.name, 'my-evcc');
      expect(d.image, 'evcc/evcc:0.123');
    });
    test('matches on the container name too', () {
      final d = parseEvccDocker('evcc|ghcr.io/foo/bar:1');
      expect(d!.name, 'evcc');
    });
    test('returns null when no evcc container is present', () {
      expect(parseEvccDocker('db|postgres:16\nweb|nginx'), isNull);
      expect(parseEvccDocker(''), isNull);
    });
  });

  group('isDockerPermissionError', () {
    test('detects the daemon permission / socket errors', () {
      expect(
        isDockerPermissionError(
            'permission denied while trying to connect to the Docker daemon socket'),
        isTrue,
      );
      expect(
        isDockerPermissionError(
            'Cannot connect to the Docker daemon at unix:///var/run/docker.sock'),
        isTrue,
      );
    });
    test('a normal listing is not a permission error', () {
      expect(isDockerPermissionError('evcc|evcc/evcc:latest'), isFalse);
      expect(isDockerPermissionError('bash: docker: command not found'), isFalse);
    });
  });

  group('parseComposeInfo', () {
    test('parses working dir + config file + service', () {
      final c = parseComposeInfo(
          '/home/pi/evcc|/home/pi/evcc/docker-compose.yml|evcc');
      expect(c, isNotNull);
      expect(c!.workingDir, '/home/pi/evcc');
      expect(c.configFile, '/home/pi/evcc/docker-compose.yml');
      expect(c.service, 'evcc');
    });
    test('returns null for a non-compose container (<no value> labels)', () {
      expect(parseComposeInfo('<no value>|<no value>|<no value>'), isNull);
      expect(parseComposeInfo('||'), isNull);
      expect(parseComposeInfo(''), isNull);
    });
    test('requires both working dir and service', () {
      expect(parseComposeInfo('/home/pi/evcc|<no value>|<no value>'), isNull);
    });
  });

  group('dockerComposeUpdateScript', () {
    test('pulls then recreates only the evcc service in the project dir', () {
      final script = dockerComposeUpdateScript(const DockerComposeInfo(
        workingDir: '/home/pi/evcc',
        configFile: '/home/pi/evcc/docker-compose.yml',
        service: 'evcc',
      ));
      expect(script, contains("cd '/home/pi/evcc'"));
      expect(script, contains("docker compose pull 'evcc'"));
      expect(script, contains("docker compose up -d 'evcc'"));
      expect(script, contains('set -e'));
    });
  });
}
