import 'package:local_auth/local_auth.dart';

/// Device authentication (biometrics or device PIN/pattern). Behind an
/// interface so the UI can be tested without platform channels.
abstract class Authenticator {
  /// Whether the device can authenticate (has biometrics or a secure lock set).
  Future<bool> canAuthenticate();

  /// Prompts the user; returns true on success.
  Future<bool> authenticate(String reason);
}

/// Real [Authenticator] backed by the `local_auth` plugin.
class LocalAuthenticator implements Authenticator {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<bool> canAuthenticate() async {
    try {
      // isDeviceSupported() is true when a biometric OR device credential
      // (PIN/pattern/password) is available — which is what we allow below.
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false, // allow device PIN/pattern fallback
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
