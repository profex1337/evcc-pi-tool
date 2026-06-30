import 'package:evcc_updater/src/services/pihole_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsePiholeVersion', () {
    test('reads the v5 "Pi-hole version is" line', () {
      const out = 'Pi-hole version is v5.18.2 (Latest: v5.18.2)\n'
          'AdminLTE version is v5.21 (Latest: v5.21)\n'
          'FTL version is v5.25.2 (Latest: v5.25.2)';
      final v = parsePiholeVersion(out);
      expect(v, isNotNull);
      expect(v!.version, 'v5.18.2');
      expect(v.updateAvailable, isFalse);
    });

    test('reads the v6 "Core version is" line', () {
      const out = 'Core version is v6.0.4 (Latest: v6.0.4)\n'
          'Web version is v6.0.1 (Latest: v6.0.1)\n'
          'FTL version is v6.0.4 (Latest: v6.0.4)';
      expect(parsePiholeVersion(out)!.version, 'v6.0.4');
    });

    test('flags an available update when current != latest', () {
      const out = 'Core version is v6.0.4 (Latest: v6.1.0)';
      final v = parsePiholeVersion(out);
      expect(v!.updateAvailable, isTrue);
    });

    test('null when Pi-hole is not installed (no version line)', () {
      expect(parsePiholeVersion(''), isNull);
      expect(parsePiholeVersion('bash: pihole: command not found'), isNull);
    });
  });

  group('isPiholeBlocking', () {
    test('true when blocking is enabled', () {
      expect(isPiholeBlocking('[✓] Pi-hole blocking is enabled'), isTrue);
      expect(isPiholeBlocking('Pi-hole blocking is enabled'), isTrue);
    });
    test('false when disabled / unknown', () {
      expect(isPiholeBlocking('[✗] Pi-hole blocking is disabled'), isFalse);
      expect(isPiholeBlocking(''), isFalse);
    });
  });
}
