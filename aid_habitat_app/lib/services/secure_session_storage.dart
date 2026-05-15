import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wrapper minimal autour de `flutter_secure_storage` pour stocker le
/// token de session de l'utilisateur connecté.
///
/// Audit sécurité 2026-05-15 (P0 #4) : avant cette refonte, le token de
/// session était stocké en clair dans `SQLite app_session.remote_token`.
/// Conséquence : la perte/le vol d'un iPad ou Mac déverrouillé exposait
/// le token (= bypass auth complet vers NocoDB côté serveur). Désormais
/// le token est stocké dans :
///   - iOS / macOS : Keychain (clé chiffrée par le secure enclave du
///     device, accessible uniquement après déverrouillage)
///   - Android : EncryptedSharedPreferences (Keystore Android)
///   - Web : IndexedDB chiffré (WebCrypto AES-GCM, clé dérivée par le
///     navigateur — requiert HTTPS, OK sur Vercel)
///
/// Le wrapper conserve une API trivialement migrable : 3 méthodes
/// publiques (`read`, `write`, `clear`).
class SecureSessionStorage {
  SecureSessionStorage._();
  static final SecureSessionStorage instance = SecureSessionStorage._();

  /// Clé sous laquelle on stocke le token de session courant.
  /// Distinct de `user_local_id` (qui est public et reste dans SQLite).
  static const String _sessionTokenKey = 'aidhabitat.session_token';

  /// Options par plateforme — durci `accessibility` sur iOS/macOS pour
  /// que le Keychain n'expose le token qu'APRÈS le premier déverrouillage
  /// post-boot (cf. `KeychainAccessibility.first_unlock_this_device`).
  /// Sur web : pas d'options additionnelles (flutter_secure_storage
  /// utilise WebCrypto+IndexedDB par défaut).
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// Récupère le token stocké, ou `null` si rien n'est persisté.
  /// Une exception du provider sous-jacent (ex. Keychain locked, web
  /// IndexedDB indisponible) est interceptée et retourne `null` —
  /// l'app retombera proprement sur le flow login.
  Future<String?> read() async {
    try {
      final value = await _storage.read(key: _sessionTokenKey);
      if (value == null || value.isEmpty) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  /// Persiste [token] dans le secure storage. Une chaîne vide est
  /// traitée comme `clear()` pour éviter de stocker un placeholder.
  Future<void> write(String token) async {
    if (token.isEmpty) {
      await clear();
      return;
    }
    try {
      await _storage.write(key: _sessionTokenKey, value: token);
    } catch (_) {
      // Best-effort : si le write échoue (ex. quota web), l'app continue
      // avec le token en RAM. La session sera perdue au prochain cold
      // restart — l'utilisateur devra se re-loguer, ce qui est le
      // comportement correct.
    }
  }

  /// Supprime le token (logout ou révocation).
  Future<void> clear() async {
    try {
      await _storage.delete(key: _sessionTokenKey);
    } catch (_) {
      // Silent — pareil que `write` : si la suppression échoue, le
      // token en RAM est de toute façon clearé par AppConfig.
    }
  }
}
