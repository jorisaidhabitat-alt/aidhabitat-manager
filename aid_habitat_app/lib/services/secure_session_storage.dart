import 'dart:convert';
import 'dart:math';

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

  /// Clé sous laquelle on stocke la **master key SQLCipher** (32 bytes
  /// random en base64) qui chiffre toute la base SQLite locale sur
  /// iOS/macOS natif. Audit sécurité 2026-05-15 P0 #4 Layer 2 : la clé
  /// est générée UNE FOIS à la première ouverture de DB sur un device
  /// donné, jamais retransmise au serveur, jamais loggée. Si le
  /// Keychain est purgé (uninstall app, reset device), la base devient
  /// irrécouvrable — l'utilisateur devra se re-loguer et les données
  /// se re-tireront depuis NocoDB.
  static const String _masterKeyKey = 'aidhabitat.db_master_key';

  /// Options par plateforme — durci `accessibility` sur iOS/macOS pour
  /// que le Keychain n'expose le token que lorsque l'appareil est
  /// effectivement déverrouillé, et sans migration iCloud vers un autre
  /// device (cf. `KeychainAccessibility.unlocked_this_device`).
  /// Sur web : pas d'options additionnelles (flutter_secure_storage
  /// utilise WebCrypto+IndexedDB par défaut).
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
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
  /// Ne touche PAS à la master key SQLCipher (cf. `clearMasterKey`) —
  /// signOut doit préserver le chiffrement de la base, sinon les
  /// re-syncs depuis NocoDB après login échoueraient sur la couche
  /// SQLCipher.
  Future<void> clear() async {
    try {
      await _storage.delete(key: _sessionTokenKey);
    } catch (_) {
      // Silent — pareil que `write` : si la suppression échoue, le
      // token en RAM est de toute façon clearé par AppConfig.
    }
  }

  // ---------------------------------------------------------------------------
  // SQLCipher master key (P0 #4 Layer 2).
  // ---------------------------------------------------------------------------

  /// Récupère la master key SQLCipher si elle existe déjà sur ce device,
  /// sinon retourne `null`. NE GÉNÈRE PAS une nouvelle clé — c'est
  /// `ensureMasterKey()` qui s'en charge à la première ouverture de
  /// base. On distingue read pur de generate+store pour éviter de
  /// créer accidentellement une nouvelle clé (qui rendrait la base
  /// existante irrécouvrable).
  Future<String?> readMasterKey() async {
    try {
      final value = await _storage.read(key: _masterKeyKey);
      if (value == null || value.isEmpty) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  /// Garantit qu'une master key est disponible :
  ///   - si une clé existe déjà → retourne celle-ci (réutilise donc le
  ///     chiffrement de la base existante)
  ///   - sinon → en génère une nouvelle (32 bytes cryptographiquement
  ///     aléatoires, encodés base64url), la stocke, et la retourne
  ///
  /// **Idempotente** : appeler plusieurs fois retourne toujours la même
  /// clé tant que le Keychain n'a pas été purgé. C'est cette propriété
  /// qui garantit que SQLCipher peut rouvrir la base aux démarrages
  /// suivants.
  Future<String> ensureMasterKey() async {
    final existing = await readMasterKey();
    if (existing != null && existing.isNotEmpty) return existing;
    // 32 bytes = 256 bits, taille standard pour SQLCipher AES-256.
    // `Random.secure()` utilise CSPRNG (SecureRandom sur iOS/macOS,
    // /dev/urandom sur Linux, RtlGenRandom sur Windows, WebCrypto sur
    // web). Sortie encodée en base64url pour la passer comme `password`
    // texte à SQLCipher.
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final key = base64UrlEncode(bytes);
    try {
      await _storage.write(key: _masterKeyKey, value: key);
    } catch (e) {
      // Si le secure storage refuse l'écriture (cas web très rare,
      // quota épuisé), on rethrow pour éviter d'ouvrir une base
      // chiffrée avec une clé que personne ne pourra restaurer au
      // prochain démarrage → base devient irrécouvrable.
      throw StateError(
        'Impossible de stocker la master key SQLCipher dans le secure '
        'storage : $e. La base ne peut pas être chiffrée sur ce device.',
      );
    }
    return key;
  }

  /// Supprime la master key SQLCipher. **À utiliser avec une extrême
  /// prudence** : toute donnée chiffrée avec cette clé devient
  /// irrécouvrable. Réservé aux cas exceptionnels (reset device-side,
  /// re-bootstrap encryption après corruption détectée). Le flux
  /// `signOut` standard NE l'appelle pas.
  Future<void> clearMasterKey() async {
    try {
      await _storage.delete(key: _masterKeyKey);
    } catch (_) {
      // silent
    }
  }
}
