/// Best-effort "Pi finden": a bounded TCP-connect sweep of the phone's local
/// /24 looking for hosts with an open SSH port (22).
///
/// This is deliberately a plain port-22 scan rather than mDNS — it needs no
/// extra plugin, no Android multicast lock, and behaves the same on every
/// device. The pure orchestration (subnet maths + bounded concurrency) is
/// unit-tested with a fake probe; only the socket probe and interface lookup
/// touch real I/O.
library;

import 'dart:async';
import 'dart:io';

/// Returns the `a.b.c.` prefix of a dotted IPv4 address, or null if [ip] is not
/// a well-formed IPv4 (four 0–255 octets).
String? subnetBase(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
  }
  return '${parts[0]}.${parts[1]}.${parts[2]}.';
}

/// All host addresses (.1–.254) in [localIp]'s /24, excluding [localIp] itself.
/// Empty when [localIp] is not a valid IPv4.
List<String> subnetHosts(String localIp) {
  final base = subnetBase(localIp);
  if (base == null) return const [];
  final hosts = <String>[];
  for (var i = 1; i <= 254; i++) {
    final ip = '$base$i';
    if (ip != localIp) hosts.add(ip);
  }
  return hosts;
}

/// Probes whether [ip] should be reported as a candidate. Injected for tests.
typedef HostProbe = Future<bool> Function(String ip);

/// Runs [probe] over [ips] with at most [concurrency] in flight and returns the
/// reachable ones in input order. A throwing probe counts as unreachable.
Future<List<String>> scanHosts(
  List<String> ips,
  HostProbe probe, {
  int concurrency = 32,
}) async {
  final reachable = List<bool>.filled(ips.length, false);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= ips.length) return;
      try {
        reachable[i] = await probe(ips[i]);
      } catch (_) {
        reachable[i] = false;
      }
    }
  }

  final workers = <Future<void>>[];
  for (var i = 0; i < concurrency && i < ips.length; i++) {
    workers.add(worker());
  }
  await Future.wait(workers);

  return [
    for (var i = 0; i < ips.length; i++)
      if (reachable[i]) ips[i],
  ];
}

/// The phone's non-loopback IPv4 addresses (e.g. its Wi-Fi address).
Future<List<String>> localIPv4s() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return [
      for (final iface in interfaces)
        for (final addr in iface.addresses) addr.address,
    ];
  } catch (_) {
    return const [];
  }
}

/// TCP-connects to [ip]:[port] within [timeout]; true if the port accepts.
Future<bool> probeSshPort(
  String ip, {
  int port = 22,
  Duration timeout = const Duration(milliseconds: 400),
}) async {
  Socket? socket;
  try {
    socket = await Socket.connect(ip, port, timeout: timeout);
    return true;
  } catch (_) {
    return false;
  } finally {
    socket?.destroy();
  }
}

/// Discovers reachable SSH hosts across every local /24 the phone sits on.
/// Best-effort and fail-soft: returns an empty list when offline or on Wi-Fi
/// without peers. [probe] is injectable for tests.
Future<List<String>> findSshHosts({
  HostProbe? probe,
  int concurrency = 48,
}) async {
  final locals = await localIPv4s();
  final candidates = <String>{};
  for (final ip in locals) {
    candidates.addAll(subnetHosts(ip));
  }
  if (candidates.isEmpty) return const [];
  return scanHosts(
    candidates.toList(),
    probe ?? (ip) => probeSshPort(ip),
    concurrency: concurrency,
  );
}
