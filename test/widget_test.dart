import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/authenticator.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory config store so the widget test never touches platform channels.
class _FakeStore extends AppConfigStore {
  _FakeStore([this._initial = AppConfig.initial]);

  final AppConfig _initial;
  AppConfig saved = AppConfig.initial;

  @override
  Future<AppConfig> load() async => _initial;

  @override
  Future<void> save(AppConfig c) async => saved = c;
}

/// Authenticator that is available but always denies — keeps the app locked.
class _DenyAuth implements Authenticator {
  @override
  Future<bool> canAuthenticate() async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// Update checker that never hits the network in tests.
final _noUpdateChecker =
    UpdateChecker(getJson: (_) async => <String, dynamic>{});

Widget _page() => MaterialApp(
    home: UpdaterPage(store: _FakeStore(), updateChecker: _noUpdateChecker));

void main() {
  // A tall phone-sized surface so the whole single screen fits (the ListView
  // builds lazily, so off-screen widgets wouldn't exist on the default surface).
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('renders the single-screen updater UI', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.text('Pi-Tool'), findsOneWidget); // app bar wordmark
    expect(find.text('evcc aktualisieren'), findsOneWidget);
    expect(find.text('Verbindung testen'), findsOneWidget);
    expect(find.text('Probelauf (ändert nichts)'), findsOneWidget);
    expect(find.text('evcc installieren'), findsOneWidget);
    expect(find.text('Komplettes System-Upgrade'), findsOneWidget);
    expect(find.text('Live-Log'), findsOneWidget);
    // Host/IP, Benutzer, Port, Passwort.
    expect(find.byType(TextField), findsNWidgets(4));
  });

  testWidgets('blocks the update and warns when the host is empty',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'evcc aktualisieren'));
    await tester.pump(); // surface the SnackBar

    expect(find.text('Bitte Host/IP eintragen.'), findsOneWidget);
  });

  testWidgets('auto-saves the active profile shortly after a field is edited',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore();
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Host / IP'), '192.168.1.50');
    await tester.pump(const Duration(seconds: 1)); // past the 800ms debounce

    expect(store.saved.active.host, '192.168.1.50');
  });

  testWidgets('adds a profile from the default config without crashing',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(); // AppConfig.initial → const profiles list
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Neues Profil'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Eltern');
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(store.saved.profiles.length, 2);
    expect(store.saved.profiles.last.name, 'Eltern');
  });

  testWidgets('shows the lock screen when app-lock is on and not unlocked',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'Standard')],
      activeIndex: 0,
      lockEnabled: true,
    ));
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        authenticator: _DenyAuth(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Gesperrt'), findsOneWidget);
    expect(find.text('Entsperren'), findsOneWidget);
    // Main UI must be hidden behind the lock.
    expect(find.text('evcc aktualisieren'), findsNothing);
  });
}
