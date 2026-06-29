import 'package:evcc_updater/src/evcc_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseEvccState', () {
    test('reads the legacy result-wrapped shape', () {
      final state = parseEvccState({
        'result': {
          'version': '0.123.1',
          'siteTitle': 'Zuhause',
          'gridPower': 1234.0,
          'homePower': 800,
          'pvPower': 2500.5,
          'batteryConfigured': true,
          'batterySoc': 87,
          'batteryPower': -300,
          'loadpoints': [
            {
              'title': 'Garage',
              'charging': true,
              'chargePower': 11000,
              'vehicleSoc': 62,
              'connected': true,
              'mode': 'pv',
            },
          ],
        },
      });

      expect(state.version, '0.123.1');
      expect(state.siteTitle, 'Zuhause');
      expect(state.gridPower, 1234.0);
      expect(state.homePower, 800);
      expect(state.pvPower, 2500.5);
      expect(state.batteryConfigured, true);
      expect(state.batterySoc, 87);
      expect(state.batteryPower, -300);
      expect(state.loadpoints, hasLength(1));
      expect(state.loadpoints.first.title, 'Garage');
      expect(state.loadpoints.first.charging, true);
      expect(state.loadpoints.first.chargePower, 11000);
      expect(state.loadpoints.first.vehicleSoc, 62);
      expect(state.loadpoints.first.mode, 'pv');
    });

    test('reads the new unwrapped shape (no result key)', () {
      final state = parseEvccState({
        'version': '0.200.0',
        'siteTitle': 'Haus',
        'gridPower': 50,
        'loadpoints': [],
      });
      expect(state.version, '0.200.0');
      expect(state.siteTitle, 'Haus');
      expect(state.gridPower, 50);
      expect(state.loadpoints, isEmpty);
    });

    test('tolerates the alternate batterySoC / vehicleSoC casing', () {
      final state = parseEvccState({
        'batterySoC': 41,
        'loadpoints': [
          {'title': 'LP1', 'vehicleSoC': 33},
        ],
      });
      expect(state.batterySoc, 41);
      expect(state.loadpoints.first.vehicleSoc, 33);
    });

    test('is fully defensive about missing / wrong-typed fields', () {
      final state = parseEvccState({'loadpoints': 'not-a-list'});
      expect(state.version, isNull);
      expect(state.siteTitle, isNull);
      expect(state.gridPower, isNull);
      expect(state.batteryConfigured, false);
      expect(state.batterySoc, isNull);
      expect(state.loadpoints, isEmpty);
    });

    test('coerces numbers given as strings', () {
      final state = parseEvccState({'gridPower': '1500'});
      expect(state.gridPower, 1500);
    });
  });

  group('formatPower', () {
    test('null is an em dash', () => expect(formatPower(null), '—'));
    test('below 1 kW shows whole watts', () {
      expect(formatPower(0), '0 W');
      expect(formatPower(350), '350 W');
      expect(formatPower(999), '999 W');
    });
    test('1 kW and above shows kW with a German decimal comma', () {
      expect(formatPower(1000), '1,0 kW');
      expect(formatPower(1500), '1,5 kW');
      expect(formatPower(11000), '11,0 kW');
    });
    test('keeps the sign for feed-in / battery discharge', () {
      expect(formatPower(-2300), '-2,3 kW');
      expect(formatPower(-250), '-250 W');
    });
    test('a value that rounds up to 1000 W is shown as kW, not "1000 W"', () {
      expect(formatPower(999.6), '1,0 kW');
      expect(formatPower(-999.6), '-1,0 kW');
    });
  });
}
