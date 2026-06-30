/// Pi-hole service: command strings + pure parsers (v5 and v6). SSH
/// orchestration is wired in evcc_updater.dart. See
/// design/2026-06-30-multi-service.md.
library;

/// Prints Pi-hole/Core/FTL versions if installed; empty/error if not (no sudo).
const String piholeVersionCommand = 'pihole -v 2>/dev/null';

/// Blocking status (no sudo).
const String piholeStatusCommand = 'pihole status 2>/dev/null';

/// Update Pi-hole core/web/FTL (needs sudo).
const String piholeUpdateCommand = 'LC_ALL=C sudo -S pihole -up';

/// Rebuild the blocklists / gravity database (needs sudo).
const String piholeGravityCommand = 'LC_ALL=C sudo -S pihole -g';

/// Restart the DNS resolver (needs sudo).
const String piholeRestartCommand = 'LC_ALL=C sudo -S pihole restartdns';

/// The detected current version + whether a newer one is available.
class PiholeVersion {
  final String version;
  final bool updateAvailable;
  const PiholeVersion({required this.version, required this.updateAvailable});
}

// Matches both v5 ("Pi-hole version is v5.x (Latest: v5.y)") and
// v6 ("Core version is v6.x (Latest: v6.y)").
final _verLine = RegExp(
    r'(?:Pi-hole|Core) version is (v[\d.]+)(?:\s*\(Latest:\s*(v[\d.]+)\))?',
    caseSensitive: false);

/// Parses `pihole -v`. Returns null when Pi-hole isn't installed.
PiholeVersion? parsePiholeVersion(String output) {
  final m = _verLine.firstMatch(output);
  if (m == null) return null;
  final current = m.group(1)!;
  final latest = m.group(2);
  return PiholeVersion(
    version: current,
    updateAvailable: latest != null && latest != current,
  );
}

/// Whether `pihole status` reports blocking as enabled.
bool isPiholeBlocking(String statusOutput) =>
    statusOutput.toLowerCase().contains('blocking is enabled');

/// Root/bash script for an UNATTENDED Pi-hole install (run via the sudo shell).
/// Pre-seeds a minimal setupVars.conf (auto-detected interface, Quad9 upstream)
/// so the official installer runs without a TTY. Experimental — not validated
/// against a fresh Pi; the user finishes setup in the web UI.
String buildPiholeInstallScript() {
  return r'''
set -e
export DEBIAN_FRONTEND=noninteractive
export PIHOLE_SKIP_OS_CHECK=true
mkdir -p /etc/pihole
if [ ! -f /etc/pihole/setupVars.conf ]; then
  IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
  {
    echo "PIHOLE_INTERFACE=${IFACE:-eth0}"
    echo "PIHOLE_DNS_1=9.9.9.9"
    echo "PIHOLE_DNS_2=149.112.112.112"
    echo "QUERY_LOGGING=true"
    echo "INSTALL_WEB_SERVER=true"
    echo "INSTALL_WEB_INTERFACE=true"
    echo "LIGHTTPD_ENABLED=true"
    echo "DNSMASQ_LISTENING=local"
    echo "BLOCKING_ENABLED=true"
  } > /etc/pihole/setupVars.conf
fi
setup=$(mktemp)
curl -sSL https://install.pi-hole.net -o "$setup"
bash "$setup" --unattended
rm -f "$setup"
''';
}

