import 'dart:convert';

/// One entry in the action history (a past update/install/restart/…).
class HistoryEntry {
  final String when; // 'yyyy-MM-dd HH:mm'
  final String text;

  const HistoryEntry({required this.when, required this.text});

  Map<String, dynamic> toJson() => {'when': when, 'text': text};

  static HistoryEntry fromJson(Map<String, dynamic> j) => HistoryEntry(
        when: (j['when'] ?? '').toString(),
        text: (j['text'] ?? '').toString(),
      );
}

/// Keep at most [max] entries, dropping the oldest.
List<HistoryEntry> capHistory(List<HistoryEntry> entries, [int max = 30]) {
  if (entries.length <= max) return entries;
  return entries.sublist(entries.length - max);
}

/// Decodes the stored JSON array (tolerant: returns [] on anything unexpected).
List<HistoryEntry> parseHistory(String json) {
  if (json.trim().isEmpty) return [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((m) => HistoryEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  } catch (_) {
    return [];
  }
}

String encodeHistory(List<HistoryEntry> entries) =>
    jsonEncode(entries.map((e) => e.toJson()).toList());

/// Formats [dt] as 'yyyy-MM-dd HH:mm' without an intl dependency.
String formatTimestamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}
