/// Pure construction of the SSH command sequence that updates evcc on a Pi.
///
/// No I/O happens here so the exact commands can be unit-tested without a real
/// SSH connection. The sequence mirrors the facts validated against the real
/// evcc-Pi on 2026-06-28.
library;

/// A single command in the update sequence.
class SshStep {
  /// Short human-readable label shown in the live log.
  final String label;

  /// The exact shell command to run on the Pi.
  final String command;

  /// Whether the sudo password must be fed to this command via stdin.
  ///
  /// The password is written to the command's stdin (for `sudo -S`) instead of
  /// being embedded in [command], so it can never end up in the command string
  /// or the visible log.
  final bool needsSudoPassword;

  const SshStep({
    required this.label,
    required this.command,
    required this.needsSudoPassword,
  });
}

/// Reads the installed version of the `evcc` package (no sudo needed).
const String versionQuery = r"dpkg-query -W -f='${Version}' evcc";

/// Queries whether the evcc service is running (no sudo needed).
const String serviceStatus = 'systemctl is-active evcc';

/// Restarts the evcc service (needs sudo).
const String serviceRestartCommand = 'sudo -S systemctl restart evcc';

/// Reboots the Pi (needs sudo). The SSH connection drops as a result.
const String rebootCommand = 'sudo -S reboot';

/// evcc service status incl. the last log lines (no sudo needed).
const String statusCommand = 'systemctl status evcc --no-pager';

/// Builds the ordered update sequence.
///
/// - [fullUpgrade] `false` upgrades only evcc; `true` upgrades the whole system.
/// - [dryRun] `true` makes apt simulate the upgrade without changing anything.
List<SshStep> buildUpdateSteps({
  required bool fullUpgrade,
  required bool dryRun,
}) {
  return [
    const SshStep(
      label: 'Version vorher',
      command: versionQuery,
      needsSudoPassword: false,
    ),
    const SshStep(
      label: 'Paketliste aktualisieren',
      command: 'sudo -S apt-get update -qq',
      needsSudoPassword: true,
    ),
    SshStep(
      label: fullUpgrade ? 'System-Upgrade' : 'evcc aktualisieren',
      command: _upgradeCommand(fullUpgrade: fullUpgrade, dryRun: dryRun),
      needsSudoPassword: true,
    ),
    const SshStep(
      label: 'Dienststatus',
      command: serviceStatus,
      needsSudoPassword: false,
    ),
    const SshStep(
      label: 'Version nachher',
      command: versionQuery,
      needsSudoPassword: false,
    ),
  ];
}

/// The remote command that runs the install script as root: `sudo -S bash -s`.
///
/// The caller feeds `<password>\n<script>` to stdin — `sudo -S` consumes the
/// first line as the password, then `bash -s` executes the rest as root. This
/// keeps the password out of the command line entirely.
const String installShellCommand = 'sudo -S bash -s';

/// The root install script: official evcc apt-repo setup + package install +
/// service enable. Mirrors https://docs.evcc.io/en/installation/linux.
/// Runs as root (via [installShellCommand]), so it uses no inner `sudo`.
String buildInstallScript() {
  return '''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.evcc.io/public/evcc/stable/setup.deb.sh' -o /tmp/evcc-setup.sh
bash /tmp/evcc-setup.sh
rm -f /tmp/evcc-setup.sh
apt-get update
apt-get install -y evcc
systemctl enable --now evcc
''';
}

String _upgradeCommand({required bool fullUpgrade, required bool dryRun}) {
  if (fullUpgrade) {
    return dryRun
        ? 'sudo -S apt-get full-upgrade --dry-run'
        : 'sudo -S apt-get full-upgrade -y';
  }
  return dryRun
      ? 'sudo -S apt-get install --only-upgrade --dry-run evcc'
      : 'sudo -S apt-get install --only-upgrade -y evcc';
}
