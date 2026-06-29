/// Read-only client for evcc's local Web-API (`GET /api/state`).
///
/// Pure parsing + formatting are unit-tested; the HTTP fetch is a thin
/// injectable adapter. Everything is defensive: evcc dropped the legacy
/// `{"result": …}` wrapper in a later version, field casing has drifted
/// (`batterySoc` vs `batterySoC`), and any field may be missing — so the parser
/// never throws on shape and the UI degrades to em dashes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One loadpoint (charge point) from evcc's state.
class EvccLoadpoint {
  final String title;
  final bool charging;
  final bool connected;
  final num? chargePower;
  final num? vehicleSoc;
  final String? mode;

  const EvccLoadpoint({
    required this.title,
    required this.charging,
    required this.connected,
    required this.chargePower,
    required this.vehicleSoc,
    required this.mode,
  });
}

/// A defensive snapshot of evcc's site state. Every field is optional.
class EvccState {
  final String? version;
  final String? siteTitle;
  final num? gridPower;
  final num? homePower;
  final num? pvPower;
  final bool batteryConfigured;
  final num? batterySoc;
  final num? batteryPower;
  final List<EvccLoadpoint> loadpoints;

  const EvccState({
    required this.version,
    required this.siteTitle,
    required this.gridPower,
    required this.homePower,
    required this.pvPower,
    required this.batteryConfigured,
    required this.batterySoc,
    required this.batteryPower,
    required this.loadpoints,
  });
}

/// Parses evcc's `/api/state` JSON, unwrapping the legacy `result` envelope if
/// present and tolerating missing fields / casing drift / string numbers.
EvccState parseEvccState(Map<String, dynamic> json) {
  final root = (json['result'] is Map)
      ? Map<String, dynamic>.from(json['result'] as Map)
      : json;

  final lps = <EvccLoadpoint>[];
  final rawLps = root['loadpoints'];
  if (rawLps is List) {
    for (final e in rawLps) {
      if (e is Map) {
        final m = Map<String, dynamic>.from(e);
        lps.add(EvccLoadpoint(
          title: (m['title'] ?? 'Ladepunkt').toString(),
          charging: m['charging'] == true,
          connected: m['connected'] == true,
          chargePower: _num(m['chargePower']),
          vehicleSoc: _num(m['vehicleSoc'] ?? m['vehicleSoC']),
          mode: m['mode']?.toString(),
        ));
      }
    }
  }

  return EvccState(
    version: _str(root['version']),
    siteTitle: _str(root['siteTitle']),
    gridPower: _num(root['gridPower']),
    homePower: _num(root['homePower']),
    pvPower: _num(root['pvPower']),
    batteryConfigured: root['batteryConfigured'] == true,
    batterySoc: _num(root['batterySoc'] ?? root['batterySoC']),
    batteryPower: _num(root['batteryPower']),
    loadpoints: lps,
  );
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

num? _num(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  return null;
}

/// Formats a power value in W into a compact German string: whole watts below
/// 1 kW, otherwise kW with one decimal and a decimal comma. Keeps the sign.
String formatPower(num? watts) {
  if (watts == null) return '—';
  if (watts.abs() < 1000) return '${watts.round()} W';
  final kw = (watts / 1000).toStringAsFixed(1).replaceAll('.', ',');
  return '$kw kW';
}

/// Raised when the live status can't be read; carries a German [message].
class EvccApiException implements Exception {
  final String message;
  const EvccApiException(this.message);
  @override
  String toString() => 'EvccApiException: $message';
}

/// Fetches JSON from [url]. Injected so the client can be unit-tested.
typedef JsonGetter = Future<Map<String, dynamic>> Function(Uri url);

/// Reads evcc's live state over plain HTTP. Read-only; never sends sudo/creds.
class EvccApiClient {
  final JsonGetter _get;

  EvccApiClient({JsonGetter? getJson}) : _get = getJson ?? _defaultGet;

  /// Fetches and parses `/api/state`. Throws [EvccApiException] with a
  /// user-facing German message on any failure.
  Future<EvccState> fetchState({
    required String scheme,
    required String host,
    required String port,
  }) async {
    final url = Uri.parse('$scheme://$host:$port/api/state');
    final json = await _get(url);
    return parseEvccState(json);
  }
}

Future<Map<String, dynamic>> _defaultGet(Uri url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6);
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response =
        await request.close().timeout(const Duration(seconds: 6));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const EvccApiException(
          'evcc verlangt eine Anmeldung – Live-Status nicht abrufbar.');
    }
    if (response.statusCode != 200) {
      throw EvccApiException('evcc-API antwortete mit '
          'HTTP ${response.statusCode}.');
    }
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const EvccApiException('Unerwartete Antwort der evcc-API.');
    }
    return Map<String, dynamic>.from(decoded);
  } on EvccApiException {
    rethrow;
  } on SocketException {
    throw const EvccApiException(
        'evcc nicht erreichbar – läuft die Oberfläche auf diesem Host/Port?');
  } on TimeoutException {
    throw const EvccApiException('Zeitüberschreitung beim evcc-Status.');
  } catch (e) {
    throw EvccApiException('Live-Status fehlgeschlagen: $e');
  } finally {
    client.close(force: true);
  }
}
