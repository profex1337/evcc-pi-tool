import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'history.dart';
import 'host_key.dart';

/// How to authenticate the SSH connection.
enum AuthMode { password, key }

/// User-entered connection settings, persisted between launches.
class Settings {
  final String host;
  final String port;
  final String username;

  /// In password mode: the SSH+sudo password. In key mode: the sudo password.
  final String password;
  final bool fullUpgrade;

  final AuthMode authMode;

  /// PEM-encoded private key (key mode only).
  final String privateKey;
  final String keyPassphrase;

  /// Scheme + port for the "open evcc web UI" link.
  final String uiScheme; // 'http' | 'https'
  final String uiPort;

  /// Whether the app requires biometric/PIN unlock on launch + resume.
  final bool lockEnabled;

  /// 'system' | 'dark' | 'light'.
  final String themeMode;

  /// evcc apt channel for fresh installs: 'stable' | 'unstable' (nightly).
  final String channel;

  /// Run a read-only status check automatically on launch.
  final bool autoCheck;

  const Settings({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.fullUpgrade,
    this.authMode = AuthMode.password,
    this.privateKey = '',
    this.keyPassphrase = '',
    this.uiScheme = 'http',
    this.uiPort = '7070',
    this.lockEnabled = false,
    this.themeMode = 'system',
    this.channel = 'stable',
    this.autoCheck = false,
  });

  static const empty = Settings(
    host: '',
    port: '22',
    username: 'pi',
    password: '',
    fullUpgrade: false,
  );
}

/// Persists [Settings] in the platform secure storage (Android Keystore-backed).
///
/// The password lives only here, encrypted at rest — never in plain prefs.
/// Tests subclass this and override [load]/[save] to avoid platform channels.
class SettingsStore {
  static const _kHost = 'host';
  static const _kPort = 'port';
  static const _kUser = 'user';
  static const _kPassword = 'password';
  static const _kFullUpgrade = 'fullUpgrade';
  static const _kAuthMode = 'authMode';
  static const _kPrivateKey = 'privateKey';
  static const _kKeyPassphrase = 'keyPassphrase';
  static const _kUiScheme = 'uiScheme';
  static const _kUiPort = 'uiPort';
  static const _kLockEnabled = 'lockEnabled';
  static const _kThemeMode = 'themeMode';
  static const _kChannel = 'channel';
  static const _kAutoCheck = 'autoCheck';

  final FlutterSecureStorage _storage;

  SettingsStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<Settings> load() async {
    final all = await _storage.readAll();
    return Settings(
      host: all[_kHost] ?? Settings.empty.host,
      port: all[_kPort] ?? Settings.empty.port,
      username: all[_kUser] ?? Settings.empty.username,
      password: all[_kPassword] ?? Settings.empty.password,
      fullUpgrade: all[_kFullUpgrade] == 'true',
      authMode:
          all[_kAuthMode] == 'key' ? AuthMode.key : AuthMode.password,
      privateKey: all[_kPrivateKey] ?? '',
      keyPassphrase: all[_kKeyPassphrase] ?? '',
      uiScheme: all[_kUiScheme] ?? Settings.empty.uiScheme,
      uiPort: all[_kUiPort] ?? Settings.empty.uiPort,
      lockEnabled: all[_kLockEnabled] == 'true',
      themeMode: all[_kThemeMode] ?? Settings.empty.themeMode,
      channel: all[_kChannel] ?? Settings.empty.channel,
      autoCheck: all[_kAutoCheck] == 'true',
    );
  }

  Future<void> save(Settings s) async {
    await _storage.write(key: _kHost, value: s.host);
    await _storage.write(key: _kPort, value: s.port);
    await _storage.write(key: _kUser, value: s.username);
    await _storage.write(key: _kPassword, value: s.password);
    await _storage.write(key: _kFullUpgrade, value: s.fullUpgrade.toString());
    await _storage.write(key: _kAuthMode, value: s.authMode.name);
    await _storage.write(key: _kPrivateKey, value: s.privateKey);
    await _storage.write(key: _kKeyPassphrase, value: s.keyPassphrase);
    await _storage.write(key: _kUiScheme, value: s.uiScheme);
    await _storage.write(key: _kUiPort, value: s.uiPort);
    await _storage.write(key: _kLockEnabled, value: s.lockEnabled.toString());
    await _storage.write(key: _kThemeMode, value: s.themeMode);
    await _storage.write(key: _kChannel, value: s.channel);
    await _storage.write(key: _kAutoCheck, value: s.autoCheck.toString());
  }
}

/// Persists the action history (JSON array) in secure storage.
class HistoryStore {
  static const _key = 'history_v1';
  final FlutterSecureStorage _storage;

  HistoryStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<List<HistoryEntry>> load() async =>
      parseHistory(await _storage.read(key: _key) ?? '');

  Future<void> add(HistoryEntry entry) async {
    final list = capHistory([...await load(), entry]);
    await _storage.write(key: _key, value: encodeHistory(list));
  }

  Future<void> clear() => _storage.delete(key: _key);
}

/// [HostKeyStore] backed by the platform secure storage.
class SecureHostKeyStore implements HostKeyStore {
  final FlutterSecureStorage _storage;

  SecureHostKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> get(String id) => _storage.read(key: id);

  @override
  Future<void> set(String id, String fingerprint) =>
      _storage.write(key: id, value: fingerprint);

  @override
  Future<void> remove(String id) => _storage.delete(key: id);
}
