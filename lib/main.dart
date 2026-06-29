import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/authenticator.dart';
import 'src/evcc_updater.dart';
import 'src/parsing.dart';
import 'src/settings_store.dart';
import 'src/ssh_runner.dart';
import 'src/update_check.dart';

void main() {
  runApp(const EvccPiToolApp());
}

/// Clean minimal dark: near-black canvas, a single vivid green accent.
const kGreen = Color(0xFF1FD65F);
const kBlack = Color(0xFF0B0E0C);
const kCard = Color(0xFF161A17);

const kEvccPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=io.evcc.android';
const kPrivacyUrl = 'https://profex1337.github.io/evcc-pi-tool/privacy.html';
const kReleasesUrl = 'https://github.com/profex1337/evcc-pi-tool/releases';

class EvccPiToolApp extends StatelessWidget {
  const EvccPiToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: kGreen,
      brightness: Brightness.dark,
    ).copyWith(primary: kGreen, onPrimary: Colors.black, surface: kBlack);

    return MaterialApp(
      title: 'evcc Pi-Tool',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: kBlack,
        appBarTheme: const AppBarTheme(
          backgroundColor: kBlack,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const UpdaterPage(),
    );
  }
}

class UpdaterPage extends StatefulWidget {
  /// All collaborators are injectable so widget tests avoid real platform
  /// channels, SSH, network and biometrics.
  const UpdaterPage({
    super.key,
    this.store,
    this.updater,
    this.updateChecker,
    this.authenticator,
  });

  final SettingsStore? store;
  final EvccUpdater? updater;
  final UpdateChecker? updateChecker;
  final Authenticator? authenticator;

  @override
  State<UpdaterPage> createState() => _UpdaterPageState();
}

class _UpdaterPageState extends State<UpdaterPage>
    with WidgetsBindingObserver {
  late final SettingsStore _store = widget.store ?? SettingsStore();
  late final EvccUpdater _updater = widget.updater ?? EvccUpdater.real();
  late final UpdateChecker _updateChecker =
      widget.updateChecker ?? UpdateChecker();
  late final Authenticator _authenticator =
      widget.authenticator ?? LocalAuthenticator();

  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'pi');
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _keyPassphrase = TextEditingController();
  final _uiPort = TextEditingController(text: '7070');
  final _logScroll = ScrollController();

  bool _fullUpgrade = false;
  bool _obscure = true;
  bool _busy = false;
  AuthMode _authMode = AuthMode.password;
  String _uiScheme = 'http';
  bool _lockEnabled = false;
  bool _locked = false;
  bool _unlocking = false;

  final List<String> _log = [];
  String? _versionBefore;
  String? _versionAfter;
  String? _statusMessage;
  bool _statusOk = true;
  ReleaseInfo? _update;
  String? _setupUrl;
  Timer? _saveDebounce;
  bool _hostKeyIssue = false;
  SshConfig? _lastConfig;
  Future<void> Function()? _lastAction;

  List<TextEditingController> get _savedControllers =>
      [_host, _port, _user, _password, _privateKey, _keyPassphrase, _uiPort];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _checkForUpdate();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _persistSettings(); // reads controllers synchronously before disposal
    for (final c in _savedControllers) {
      c.dispose();
    }
    _logScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist on any background-ish transition (cheap, safe).
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _saveDebounce?.cancel();
      _persistSettings();
    }
    // Lock only on REAL backgrounding (paused/hidden), not on transient
    // `inactive` (notification shade, system dialogs, the auth prompt itself),
    // and not while an unlock is already in progress.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_lockEnabled && !_unlocking && mounted) {
        setState(() => _locked = true);
      }
    } else if (state == AppLifecycleState.resumed && _locked && !_unlocking) {
      _tryUnlock();
    }
  }

  Future<void> _loadSettings() async {
    final s = await _store.load();
    if (!mounted) return;
    setState(() {
      _host.text = s.host;
      _port.text = s.port;
      _user.text = s.username;
      _password.text = s.password;
      _fullUpgrade = s.fullUpgrade;
      _authMode = s.authMode;
      _privateKey.text = s.privateKey;
      _keyPassphrase.text = s.keyPassphrase;
      _uiScheme = s.uiScheme;
      _uiPort.text = s.uiPort;
      _lockEnabled = s.lockEnabled;
      if (_lockEnabled) _locked = true;
    });
    // Attach auto-save listeners after initial values are set.
    for (final c in _savedControllers) {
      c.addListener(_scheduleSave);
    }
    if (_locked) _tryUnlock();
  }

  /// Debounced auto-save: persists ~0.8s after the last edit.
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _persistSettings);
  }

  Future<void> _persistSettings() => _store.save(_currentSettings());

  Settings _currentSettings() => Settings(
        host: _host.text.trim(),
        port: _port.text.trim().isEmpty ? '22' : _port.text.trim(),
        username: _user.text.trim().isEmpty ? 'pi' : _user.text.trim(),
        password: _password.text,
        fullUpgrade: _fullUpgrade,
        authMode: _authMode,
        privateKey: _privateKey.text,
        keyPassphrase: _keyPassphrase.text,
        uiScheme: _uiScheme,
        uiPort: _uiPort.text.trim().isEmpty ? '7070' : _uiPort.text.trim(),
        lockEnabled: _lockEnabled,
      );

  Future<void> _checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final release = await _updateChecker.checkForUpdate(info.version);
      if (release != null && mounted) setState(() => _update = release);
    } catch (_) {
      // never let the update check disrupt the app
    }
  }

  Future<void> _tryUnlock() async {
    if (!_lockEnabled) {
      if (mounted) setState(() => _locked = false);
      return;
    }
    if (_unlocking) return; // re-entrancy guard: avoid overlapping prompts
    _unlocking = true;
    try {
      final ok = await _authenticator.authenticate('evcc Pi-Tool entsperren');
      if (ok && mounted) setState(() => _locked = false);
    } finally {
      _unlocking = false;
    }
  }

  // ---- actions -------------------------------------------------------------

  int? _validatedPort() {
    if (_host.text.trim().isEmpty) {
      _snack('Bitte Host/IP eintragen.');
      return null;
    }
    if (_authMode == AuthMode.password && _password.text.isEmpty) {
      _snack('Bitte Pi-Passwort eintragen.');
      return null;
    }
    if (_authMode == AuthMode.key && _privateKey.text.trim().isEmpty) {
      _snack('Bitte privaten SSH-Key einfügen.');
      return null;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      _snack('Port ist ungültig (1–65535).');
      return null;
    }
    return port;
  }

  SshConfig _configFor(int port) => SshConfig(
        host: _host.text.trim(),
        port: port,
        username: _user.text.trim().isEmpty ? 'pi' : _user.text.trim(),
        password: _password.text,
        privateKey: _authMode == AuthMode.key ? _privateKey.text : '',
        keyPassphrase: _authMode == AuthMode.key ? _keyPassphrase.text : '',
        timeout: const Duration(seconds: 15),
      );

  /// Validates, builds the config, remembers it, saves settings and enters the
  /// busy state. Returns the config, or null when validation failed.
  SshConfig? _prepare() {
    final port = _validatedPort();
    if (port == null) return null;
    final config = _configFor(port);
    _lastConfig = config;
    _persistSettings();
    _beginBusy();
    return config;
  }

  void _beginBusy() {
    setState(() {
      _busy = true;
      _log.clear();
      _statusMessage = null;
      _versionAfter = null;
      _setupUrl = null;
      _hostKeyIssue = false;
    });
  }

  /// Shared error handling + busy-reset for every action.
  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } on EvccUpdateException catch (e) {
      _appendLog('FEHLER: ${e.message}');
      if (!mounted) return;
      setState(() {
        _statusMessage = e.message;
        _statusOk = false;
        _hostKeyIssue = e.kind == UpdateErrorKind.hostKeyChanged;
      });
    } catch (e) {
      _appendLog('FEHLER: $e');
      if (!mounted) return;
      setState(() {
        _statusMessage =
            redactPassword('Unerwarteter Fehler: $e', _password.text);
        _statusOk = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run({required bool dryRun}) async {
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _run(dryRun: dryRun);
    await _guard(() async {
      final summary = await _updater.run(
        config: config,
        fullUpgrade: _fullUpgrade,
        dryRun: dryRun,
        onLog: _appendLog,
      );
      if (!mounted) return;
      setState(() {
        _versionBefore = summary.before;
        _versionAfter = summary.after;
        _statusMessage = summary.message;
        _statusOk = true;
      });
    });
  }

  Future<void> _testConnection() async {
    final config = _prepare();
    if (config == null) return;
    _lastAction = _testConnection;
    await _guard(() async {
      final info = await _updater.testConnection(
        config: config,
        onLog: _appendLog,
      );
      if (!mounted) return;
      setState(() {
        _versionBefore = info.version;
        _versionAfter = null;
        _statusMessage = 'Verbindung OK – evcc ${info.version}, '
            'Dienst ${info.serviceActive ? 'aktiv' : 'inaktiv'}.';
        _statusOk = true;
      });
    });
  }

  Future<void> _install() async {
    if (!await _confirm(
      'evcc installieren?',
      'Installiert evcc auf ${_host.text.trim()}: fügt das offizielle '
          'evcc-Repo hinzu, installiert das Paket und startet den Dienst.\n\n'
          'Experimentell — nach offizieller evcc-Doku gebaut, aber noch nicht '
          'gegen einen frischen Pi getestet.',
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _install;
    await _guard(() async {
      final res = await _updater.install(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _versionBefore = res.version;
        _versionAfter = null;
        _statusMessage = 'evcc ${res.version} installiert, '
            'Dienst ${res.serviceActive ? 'aktiv' : 'inaktiv'}. '
            'Jetzt im Browser einrichten.';
        _statusOk = true;
        _setupUrl = _evccUiUrl();
      });
    });
  }

  Future<void> _restartService() async {
    final config = _prepare();
    if (config == null) return;
    _lastAction = _restartService;
    await _guard(() async {
      await _updater.restartService(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = 'evcc-Dienst neu gestartet.';
        _statusOk = true;
      });
    });
  }

  Future<void> _reboot() async {
    if (!await _confirm(
      'Pi neustarten?',
      'Startet den Raspberry Pi neu. Die Verbindung bricht dabei kurz ab.',
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _reboot;
    await _guard(() async {
      await _updater.reboot(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Neustart ausgelöst – der Pi ist gleich kurz offline.';
        _statusOk = true;
      });
    });
  }

  Future<void> _showStatus() async {
    final config = _prepare();
    if (config == null) return;
    _lastAction = _showStatus;
    await _guard(() async {
      await _updater.fetchStatus(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Status abgerufen (siehe Live-Log).';
        _statusOk = true;
      });
    });
  }

  /// Re-trust a changed host key, then retry the action that hit it.
  Future<void> _trustAndRetry() async {
    final config = _lastConfig;
    final action = _lastAction;
    if (config == null || action == null) return;
    await _updater.forgetHostKey(config);
    await action();
  }

  void _shareLog() {
    if (_log.isEmpty) {
      _snack('Das Log ist leer.');
      return;
    }
    SharePlus.instance.share(ShareParams(text: _log.join('\n')));
  }

  // ---- helpers -------------------------------------------------------------

  void _appendLog(String line) {
    if (!mounted) return;
    // Defense in depth: redact the live password from anything we log.
    setState(() => _log.add(redactPassword(line, _password.text)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  String _evccUiUrl() {
    final port = _uiPort.text.trim().isEmpty ? '7070' : _uiPort.text.trim();
    return '$_uiScheme://${_host.text.trim()}:$port';
  }

  void _openEvccUi() {
    if (_host.text.trim().isEmpty) {
      _snack('Bitte zuerst Host/IP eintragen.');
      return;
    }
    _openUrl(_evccUiUrl());
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) _snack('Konnte den Link nicht öffnen.');
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Weiter'),
          ),
        ],
      ),
    );
    return r == true && mounted;
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Einstellungen',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('App mit Biometrie/PIN sperren'),
                  subtitle: const Text('Beim Öffnen & nach dem Wechsel'),
                  value: _lockEnabled,
                  onChanged: (v) async {
                    if (v && !await _authenticator.canAuthenticate()) {
                      _snack('Keine Biometrie/PIN auf dem Gerät eingerichtet.');
                      return;
                    }
                    setState(() => _lockEnabled = v);
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('evcc-Oberfläche über HTTPS'),
                  subtitle: Text(_uiScheme == 'https'
                      ? 'https://…'
                      : 'http://… (Standard)'),
                  value: _uiScheme == 'https',
                  onChanged: (v) {
                    setState(() => _uiScheme = v ? 'https' : 'http');
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _uiPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'evcc-Oberfläche: Port',
                    helperText: 'Standard 7070',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_locked) return _LockScreen(onUnlock: _tryUnlock);

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('evcc ',
                style: TextStyle(
                    fontWeight: FontWeight.w800, letterSpacing: 0.3)),
            Text('Pi-Tool',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: kGreen)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (v) {
              switch (v) {
                case 'restart':
                  _restartService();
                case 'reboot':
                  _reboot();
                case 'status':
                  _showStatus();
                case 'share':
                  _shareLog();
                case 'settings':
                  _openSettings();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'restart', child: Text('evcc-Dienst neustarten')),
              PopupMenuItem(value: 'reboot', child: Text('Pi neustarten')),
              PopupMenuItem(
                  value: 'status', child: Text('Status / Logs anzeigen')),
              PopupMenuItem(value: 'share', child: Text('Log teilen')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'settings', child: Text('Einstellungen')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_update != null) ...[
              _UpdateBanner(
                release: _update!,
                onDownload: () => _openUrl(_update!.downloadUrl),
                onDismiss: () => setState(() => _update = null),
              ),
              const SizedBox(height: 8),
            ],
            _ConnectionCard(
              host: _host,
              port: _port,
              user: _user,
              password: _password,
              privateKey: _privateKey,
              keyPassphrase: _keyPassphrase,
              authMode: _authMode,
              obscure: _obscure,
              enabled: !_busy,
              onToggleObscure: () => setState(() => _obscure = !_obscure),
              onAuthMode: (m) {
                setState(() => _authMode = m);
                _scheduleSave();
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _fullUpgrade,
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() => _fullUpgrade = v);
                      _scheduleSave();
                    },
              title: const Text('Komplettes System-Upgrade'),
              subtitle: Text(_fullUpgrade
                  ? 'apt-get full-upgrade (alle Pakete)'
                  : 'Aus → nur evcc wird aktualisiert'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            const SizedBox(height: 8),
            if (_versionBefore != null)
              _VersionBadge(before: _versionBefore, after: _versionAfter),
            if (_versionBefore != null) const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : () => _run(dryRun: false),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt),
              label: Text(_busy ? 'Läuft …' : 'evcc aktualisieren'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _testConnection,
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Verbindung testen'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(dryRun: true),
              icon: const Icon(Icons.science_outlined),
              label: const Text('Probelauf (ändert nichts)'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44)),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Expanded(child: Divider(color: Colors.white12)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text('Erstinstallation auf neuem Pi',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: Colors.white54)),
                ),
                const Expanded(child: Divider(color: Colors.white12)),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _install,
              icon: const Icon(Icons.install_mobile),
              label: const Text('evcc installieren (experimentell)'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              _StatusBanner(message: _statusMessage!, ok: _statusOk),
            ],
            if (_hostKeyIssue) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _trustAndRetry,
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text('Pi neu aufgesetzt → neuen Key vertrauen'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
            ],
            if (_setupUrl != null) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => _openUrl(_setupUrl!),
                icon: const Icon(Icons.open_in_new),
                label: const Text('evcc-Einrichtung öffnen'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
            ],
            const SizedBox(height: 12),
            Text('Live-Log', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            _LogView(lines: _log, controller: _logScroll),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _openEvccUi,
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('evcc-Oberfläche öffnen'),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(kEvccPlayStoreUrl),
                  icon: const Icon(Icons.shop_outlined, size: 18),
                  label: const Text('Offizielle evcc-App'),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(kReleasesUrl),
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('Changelog'),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(kPrivacyUrl),
                  icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                  label: const Text('Datenschutz'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Nutzung auf eigene Gefahr – keine Haftung für Schäden am '
              'System. Inoffizielles Tool, nicht mit evcc verbunden.',
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.privateKey,
    required this.keyPassphrase,
    required this.authMode,
    required this.obscure,
    required this.enabled,
    required this.onToggleObscure,
    required this.onAuthMode,
  });

  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController user;
  final TextEditingController password;
  final TextEditingController privateKey;
  final TextEditingController keyPassphrase;
  final AuthMode authMode;
  final bool obscure;
  final bool enabled;
  final VoidCallback onToggleObscure;
  final ValueChanged<AuthMode> onAuthMode;

  @override
  Widget build(BuildContext context) {
    final keyMode = authMode == AuthMode.key;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: kCard,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Colors.white10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          children: [
            TextField(
              controller: host,
              enabled: enabled,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Host / IP',
                hintText: 'z. B. 192.168.178.64 oder Tailscale-IP',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: user,
                    enabled: enabled,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Benutzer',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: port,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<AuthMode>(
              segments: const [
                ButtonSegment(
                    value: AuthMode.password,
                    label: Text('Passwort'),
                    icon: Icon(Icons.password)),
                ButtonSegment(
                    value: AuthMode.key,
                    label: Text('SSH-Key'),
                    icon: Icon(Icons.vpn_key_outlined)),
              ],
              selected: {authMode},
              onSelectionChanged:
                  enabled ? (s) => onAuthMode(s.first) : null,
            ),
            if (keyMode) ...[
              TextField(
                controller: privateKey,
                enabled: enabled,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'Privater SSH-Key (PEM)',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY----- …',
                  alignLabelWithHint: true,
                ),
              ),
              TextField(
                controller: keyPassphrase,
                enabled: enabled,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Key-Passphrase (optional)',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
              ),
            ],
            TextField(
              controller: password,
              enabled: enabled,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: keyMode ? 'sudo-Passwort' : 'Passwort',
                helperText: keyMode
                    ? 'für sudo auf dem Pi (leer lassen bei NOPASSWD-sudo)'
                    : null,
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: onToggleObscure,
                  icon: Icon(
                      obscure ? Icons.visibility : Icons.visibility_off),
                  tooltip: obscure ? 'Anzeigen' : 'Verbergen',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBlack,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bolt, color: kGreen, size: 56),
            const SizedBox(height: 12),
            const Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: 'evcc ',
                    style: TextStyle(
                        fontWeight: FontWeight.w800, color: Colors.white)),
                TextSpan(
                    text: 'Pi-Tool',
                    style: TextStyle(
                        fontWeight: FontWeight.w800, color: kGreen)),
              ]),
              style: TextStyle(fontSize: 22),
            ),
            const SizedBox(height: 6),
            const Text('Gesperrt', style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: const Icon(Icons.lock_open),
              label: const Text('Entsperren'),
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionBadge extends StatelessWidget {
  const _VersionBadge({required this.before, required this.after});

  final String? before;
  final String? after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changed = after != null && before != after;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.bolt, size: 18),
          const SizedBox(width: 8),
          Text('evcc ', style: theme.textTheme.bodyMedium),
          Text(before ?? '—',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          if (changed) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.arrow_forward, size: 16),
            ),
            Text(after!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                )),
          ],
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.ok});

  final String message;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = ok ? scheme.primaryContainer : scheme.errorContainer;
    final fg = ok ? scheme.onPrimaryContainer : scheme.onErrorContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              color: fg),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: fg))),
        ],
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({
    required this.release,
    required this.onDownload,
    required this.onDismiss,
  });

  final ReleaseInfo release;
  final VoidCallback onDownload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.system_update, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Update ${release.version} verfügbar',
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
          TextButton(onPressed: onDownload, child: const Text('Laden')),
          IconButton(
            onPressed: onDismiss,
            icon: Icon(Icons.close, color: scheme.onTertiaryContainer),
            tooltip: 'Ausblenden',
          ),
        ],
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.lines, required this.controller});

  final List<String> lines;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 240,
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF11140F),
        borderRadius: BorderRadius.circular(10),
      ),
      child: lines.isEmpty
          ? const Text(
              'Noch keine Ausgabe. Tippe „evcc aktualisieren" oder „Probelauf".',
              style: TextStyle(color: Color(0xFF8A8F84), fontSize: 13),
            )
          : SingleChildScrollView(
              controller: controller,
              child: SelectableText(
                lines.join('\n'),
                style: const TextStyle(
                  color: Color(0xFFB8F2C9),
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
    );
  }
}
