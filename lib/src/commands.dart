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

/// How evcc is installed on the Pi.
enum InstallKind { apt, docker, unknown }

/// Reads the installed version of the `evcc` package (no sudo needed).
const String versionQuery = r"dpkg-query -W -f='${Version}' evcc";

/// Lists running containers as `name|image` lines (no sudo).
const String dockerListCommand = "docker ps --format '{{.Names}}|{{.Image}}'";

/// Same, but via sudo for hosts where the user isn't in the `docker` group.
const String dockerListSudoCommand =
    "sudo -S docker ps --format '{{.Names}}|{{.Image}}'";

/// A running evcc Docker container (its name + image).
class EvccDocker {
  final String name;
  final String image;
  const EvccDocker({required this.name, required this.image});
}

/// docker-compose project metadata read off a container's labels.
class DockerComposeInfo {
  final String workingDir;
  final String configFile;
  final String service;
  const DockerComposeInfo({
    required this.workingDir,
    required this.configFile,
    required this.service,
  });
}

/// Decides how evcc is installed from a `dpkg-query` result and a `docker ps`
/// listing. apt takes precedence (it's the supported install); a running evcc
/// container is the Docker case; otherwise unknown.
InstallKind classifyInstall({
  required String dpkgOutput,
  required String dockerPs,
}) {
  if (dpkgOutput.trim().isNotEmpty) return InstallKind.apt;
  if (parseEvccDocker(dockerPs) != null) return InstallKind.docker;
  return InstallKind.unknown;
}

/// Finds the evcc container in a `name|image`-per-line listing, matching on
/// either the image or the container name. Returns null when none is present.
EvccDocker? parseEvccDocker(String dockerPs) {
  for (final line in dockerPs.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split('|');
    if (parts.length < 2) continue;
    final name = parts[0].trim();
    final image = parts[1].trim();
    if (image.toLowerCase().contains('evcc') ||
        name.toLowerCase().contains('evcc')) {
      return EvccDocker(name: name, image: image);
    }
  }
  return null;
}

/// Whether docker output indicates the user lacks daemon access (so the command
/// should be retried via sudo). Distinct from "docker not installed".
bool isDockerPermissionError(String output) {
  final o = output.toLowerCase();
  return o.contains('permission denied') &&
          (o.contains('docker daemon') || o.contains('docker.sock')) ||
      o.contains('cannot connect to the docker daemon');
}

/// `docker inspect` that prints `workingDir|configFile|service` from the
/// compose labels (or `<no value>` for each missing label).
String dockerInspectCommand(String container) =>
    "docker inspect '$container' --format "
    '\'{{ index .Config.Labels "com.docker.compose.project.working_dir"}}|'
    '{{ index .Config.Labels "com.docker.compose.project.config_files"}}|'
    '{{ index .Config.Labels "com.docker.compose.service"}}\'';

/// sudo variant of [dockerInspectCommand].
String dockerInspectSudoCommand(String container) =>
    'sudo -S ${dockerInspectCommand(container)}';

/// Parses the `workingDir|configFile|service` line from [dockerInspectCommand].
/// Returns null unless both a working dir and a service name are present (i.e.
/// the container really is docker-compose-managed).
DockerComposeInfo? parseComposeInfo(String inspectOutput) {
  final line = inspectOutput
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  if (line.isEmpty) return null;
  final parts = line.split('|');
  String at(int i) {
    if (i >= parts.length) return '';
    final v = parts[i].trim();
    return v == '<no value>' ? '' : v;
  }

  final workingDir = at(0);
  final service = at(2);
  if (workingDir.isEmpty || service.isEmpty) return null;
  return DockerComposeInfo(
    workingDir: workingDir,
    configFile: at(1),
    service: service,
  );
}

/// The root/bash script that updates a compose-managed evcc: pull the image,
/// then recreate only the evcc service in its project directory.
String dockerComposeUpdateScript(DockerComposeInfo info) {
  return '''
set -e
cd '${info.workingDir}'
docker compose pull '${info.service}'
docker compose up -d '${info.service}'
''';
}

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
///
/// [channel] selects the apt repo: 'stable' (default) or 'unstable' (nightly).
String buildInstallScript({String channel = 'stable'}) {
  final repo = channel == 'unstable' ? 'unstable' : 'stable';
  return '''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.evcc.io/public/evcc/$repo/setup.deb.sh' -o /tmp/evcc-setup.sh
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
