import 'package:evcc_updater/src/network_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('subnetBase', () {
    test('returns the /24 prefix of a valid IPv4', () {
      expect(subnetBase('192.168.178.64'), '192.168.178.');
      expect(subnetBase('10.0.0.5'), '10.0.0.');
    });
    test('rejects non-IPv4 / malformed input', () {
      expect(subnetBase('not-an-ip'), isNull);
      expect(subnetBase('192.168.1'), isNull);
      expect(subnetBase('192.168.1.1.1'), isNull);
      expect(subnetBase('192.168.1.999'), isNull);
      expect(subnetBase(''), isNull);
    });
  });

  group('subnetHosts', () {
    test('enumerates .1–.254 and omits the device itself', () {
      final hosts = subnetHosts('192.168.178.64');
      expect(hosts, hasLength(253)); // 254 candidates minus self
      expect(hosts, contains('192.168.178.1'));
      expect(hosts, contains('192.168.178.254'));
      expect(hosts, isNot(contains('192.168.178.64'))); // self excluded
      expect(hosts, isNot(contains('192.168.178.0'))); // network address
      expect(hosts, isNot(contains('192.168.178.255'))); // broadcast
    });
    test('returns nothing for an invalid address', () {
      expect(subnetHosts('garbage'), isEmpty);
    });
  });

  group('scanHosts', () {
    test('returns only reachable hosts, in input order', () async {
      final reachable = {'10.0.0.2', '10.0.0.5'};
      final found = await scanHosts(
        ['10.0.0.1', '10.0.0.2', '10.0.0.3', '10.0.0.5'],
        (ip) async => reachable.contains(ip),
        concurrency: 2,
      );
      expect(found, ['10.0.0.2', '10.0.0.5']);
    });

    test('never exceeds the concurrency limit', () async {
      var active = 0;
      var peak = 0;
      Future<bool> probe(String ip) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return false;
      }

      await scanHosts(
        List.generate(20, (i) => '10.0.0.$i'),
        probe,
        concurrency: 4,
      );
      expect(peak, lessThanOrEqualTo(4));
    });

    test('a probe that throws is treated as unreachable, not fatal', () async {
      final found = await scanHosts(
        ['10.0.0.1', '10.0.0.2'],
        (ip) async => ip == '10.0.0.2' ? throw 'boom' : true,
        concurrency: 2,
      );
      expect(found, ['10.0.0.1']);
    });
  });
}
