import 'package:evcc_updater/src/history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round-trips entries through encode/parse', () {
    final list = [
      const HistoryEntry(when: '2026-06-29 14:00', text: 'evcc 0.1 → 0.2'),
    ];
    final back = parseHistory(encodeHistory(list));
    expect(back.single.when, '2026-06-29 14:00');
    expect(back.single.text, 'evcc 0.1 → 0.2');
  });

  test('parseHistory tolerates empty/garbage input', () {
    expect(parseHistory(''), isEmpty);
    expect(parseHistory('not json'), isEmpty);
    expect(parseHistory('{}'), isEmpty);
  });

  test('capHistory keeps the newest N', () {
    final many =
        List.generate(40, (i) => HistoryEntry(when: 't$i', text: 'e$i'));
    final capped = capHistory(many, 30);
    expect(capped.length, 30);
    expect(capped.first.text, 'e10');
    expect(capped.last.text, 'e39');
  });

  test('formatTimestamp pads to yyyy-MM-dd HH:mm', () {
    expect(formatTimestamp(DateTime(2026, 6, 29, 9, 5)), '2026-06-29 09:05');
  });
}
