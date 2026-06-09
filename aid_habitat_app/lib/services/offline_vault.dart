import 'dart:typed_data';

import 'offline_vault_stub.dart'
    if (dart.library.html) 'offline_vault_web.dart'
    as impl;

/// Chiffrement applicatif pour les valeurs sensibles stockées offline.
///
/// Sur iOS/macOS/Android la base SQLite est déjà protégée par SQLCipher :
/// l'implémentation native est donc un no-op. Sur Flutter Web, SQLite WASM
/// n'expose pas SQLCipher ; cette couche chiffre les gros contenus et notes
/// avant écriture dans IndexedDB/SQLite web, sans retirer le mode offline.
class OfflineVault {
  OfflineVault._();

  static final OfflineVault instance = OfflineVault._();

  Future<String> sealString(String value) => impl.sealString(value);

  Future<String?> sealNullableString(String? value) async {
    if (value == null || value.isEmpty) return value;
    return sealString(value);
  }

  Future<String> openString(String value) => impl.openString(value);

  Future<String?> openNullableString(String? value) async {
    if (value == null || value.isEmpty) return value;
    return openString(value);
  }

  Future<Uint8List> sealBytes(List<int> value) => impl.sealBytes(value);

  Future<Uint8List> openBytes(Object? value) => impl.openBytes(value);
}
