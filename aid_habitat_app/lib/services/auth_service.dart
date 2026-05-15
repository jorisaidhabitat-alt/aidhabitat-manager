import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'app_config.dart';
import 'local_database.dart';
import 'nocodb_api_client.dart';

class AuthService {
  AuthService._internal();

  static final AuthService _instance = AuthService._internal();

  factory AuthService() => _instance;

  final LocalDatabase _database = LocalDatabase.instance;

  static const String bootstrapPassword = 'AidHabitat!Local';

  /// Build a fallback session token for a locally-authenticated user. The
  /// server accepts tokens prefixed with `local-auth:` followed by a
  /// base64 email (see `shared/localAuthProfiles.js`). This lets us keep
  /// NocoDB sync working when the remote password hash has drifted from
  /// the local one — the user only ever needs their local password.
  static String _buildLocalAuthToken(String email) {
    return 'local-auth:${base64.encode(utf8.encode(email.trim().toLowerCase()))}';
  }

  static const List<_SeedUser> _seedUsers = [
    _SeedUser(
      id: 'user_admin',
      email: 'contact@aidhabitat.fr',
      displayName: 'Renan',
      role: LocalUserRole.admin,
    ),
    _SeedUser(
      id: 'user_ergo_1',
      email: 'joris.aidhabitat@gmail.com',
      displayName: 'Coralie',
      role: LocalUserRole.ergo,
      establishmentId: '2',
      ergoLabel: 'Coralie',
      dossierErgoScope: 'ergo1',
    ),
    _SeedUser(
      id: 'user_ergo_2',
      email: 'joris.balluais@gmail.com',
      displayName: 'Christelle',
      role: LocalUserRole.ergo,
      establishmentId: '2',
      ergoLabel: 'Christelle',
      dossierErgoScope: 'christelle',
    ),
  ];

  Future<void> initialize() async {
    final db = await _database.database;
    await _ensureSeedUsers(db);
    await _ensureSeedScopes(db);
  }

  Future<void> _ensureSeedUsers(Database db) async {
    final now = DateTime.now().toIso8601String();
    final existingRows = await db.query('app_users', columns: ['local_id']);
    final existingIds = existingRows
        .map((row) => row['local_id'] as String)
        .toSet();

    final batch = db.batch();
    for (final seed in _seedUsers) {
      if (existingIds.contains(seed.id)) continue;
      final salt = _generateSalt();
      batch.insert('app_users', {
        'local_id': seed.id,
        'email': seed.email,
        'display_name': seed.displayName,
        'role': seed.role.name,
        'password_salt': salt,
        'password_hash': _hashPassword(bootstrapPassword, salt),
        'establishment_id': seed.establishmentId,
        'ergo_label': seed.ergoLabel,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> _ensureSeedScopes(Database db) async {
    final now = DateTime.now().toIso8601String();
    final existingRows = await db.query(
      'user_access_scopes',
      columns: ['local_id'],
    );
    final existingIds = existingRows
        .map((row) => row['local_id'] as String)
        .toSet();

    final seedScopes = <_SeedAccessScope>[
      const _SeedAccessScope(
        id: 'scope_admin_all',
        userId: 'user_admin',
        type: 'dossier_access',
        value: '*',
      ),
      for (final seed in _seedUsers) ...[
        if (seed.establishmentId != null)
          _SeedAccessScope(
            id: '${seed.id}_establishment',
            userId: seed.id,
            type: 'establishment_id',
            value: seed.establishmentId!,
          ),
        if (seed.ergoLabel != null)
          _SeedAccessScope(
            id: '${seed.id}_ergo_label',
            userId: seed.id,
            type: 'ergo_label',
            value: seed.ergoLabel!,
          ),
        if (seed.dossierErgoScope != null)
          _SeedAccessScope(
            id: '${seed.id}_dossier_ergo',
            userId: seed.id,
            type: 'dossier_ergo',
            value: seed.dossierErgoScope!,
          ),
      ],
    ];

    final batch = db.batch();
    for (final scope in seedScopes) {
      if (existingIds.contains(scope.id)) continue;
      batch.insert('user_access_scopes', {
        'local_id': scope.id,
        'user_local_id': scope.userId,
        'scope_type': scope.type,
        'scope_value': scope.value,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<LocalAppUser>> fetchAvailableUsers() async {
    final db = await _database.database;
    final rows = await db.query(
      'app_users',
      where: 'is_active = 1',
      orderBy: 'display_name ASC',
    );
    final scopes = await _fetchScopesByUserId(db);
    return rows
        .map((row) => _mapUser(row, scopes[row['local_id']] ?? []))
        .toList();
  }

  /// Persists [photoUrl] as the current user's profile photo in SQLite
  /// so it survives full-cold restarts even when offline. No-op when no
  /// user is signed in.
  Future<void> updateCurrentUserProfilePhoto(String photoUrl) async {
    final db = await _database.database;
    final sessionRows = await db.query('app_session', limit: 1);
    if (sessionRows.isEmpty) return;
    final userLocalId = sessionRows.first['user_local_id'] as String;
    await db.update(
      'app_users',
      {
        'profile_photo_url': photoUrl,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [userLocalId],
    );
  }

  /// Writes a base64 data URL to `pending_photo_data_url` for the currently
  /// signed-in user and enqueues a `profile_photo` sync operation. The UI
  /// can render [dataUrl] immediately through [CachedRemoteImage]'s
  /// `pendingDataUrl` parameter; the sync processor will replace it with
  /// the server-resolved URL on success.
  Future<void> persistPendingProfilePhoto(String dataUrl) async {
    final db = await _database.database;
    final sessionRows = await db.query('app_session', limit: 1);
    if (sessionRows.isEmpty) return;
    final userLocalId = sessionRows.first['user_local_id'] as String;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await txn.update(
        'app_users',
        {
          'pending_photo_data_url': dataUrl,
          'sync_state': SyncState.pendingSync.name,
          'updated_at': now,
        },
        where: 'local_id = ?',
        whereArgs: [userLocalId],
      );
      await txn.insert('sync_operations', {
        'id': 'profile_photo_${userLocalId}_'
            '${DateTime.now().microsecondsSinceEpoch}',
        'entity_type': 'profile_photo',
        'entity_local_id': userLocalId,
        'operation_type': 'upload',
        'payload_json': jsonEncode({
          'userLocalId': userLocalId,
          'imageDataUrl': dataUrl,
        }),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<LocalAppUser?> getCurrentUser() async {
    final db = await _database.database;
    final sessionRows = await db.query('app_session', limit: 1);
    if (sessionRows.isEmpty) return null;

    final session = sessionRows.first;
    final userRows = await db.query(
      'app_users',
      where: 'local_id = ? AND is_active = 1',
      whereArgs: [session['user_local_id']],
      limit: 1,
    );
    if (userRows.isEmpty) return null;
    final scopes = await _fetchScopesByUserId(db);
    final row = userRows.first;
    return _mapUser(row, scopes[row['local_id']] ?? []);
  }

  Future<LocalSignInResult> signIn({
    required String email,
    required String password,
  }) async {
    final db = await _database.database;
    final normalizedEmail = email.trim().toLowerCase();
    final rows = await db.query(
      'app_users',
      where: 'email = ? AND is_active = 1',
      whereArgs: [normalizedEmail],
      limit: 1,
    );

    if (rows.isEmpty) {
      return const LocalSignInResult(
        success: false,
        error: 'Compte local introuvable',
      );
    }

    final row = rows.first;
    final salt = row['password_salt'] as String? ?? '';
    final expectedHash = row['password_hash'] as String? ?? '';
    final providedHash = _hashPassword(password, salt);
    final localPasswordMatches = providedHash == expectedHash;

    // Try the Express API in parallel with the same password. If the server
    // accepts it, the user gets both a local and a remote session.
    final remoteResult = await NocodbApiClient().loginToRemote(
      email: normalizedEmail,
      password: password,
    );
    final remoteToken = remoteResult.token;

    // Fix audit 2026-05-06 : si le serveur a EXPLICITEMENT rejeté (401),
    // on N'accepte JAMAIS le fallback local. Sinon un changement de
    // mot de passe côté admin ne pouvait jamais invalider l'ancien hash
    // local — l'utilisateur continuait à pouvoir se connecter avec son
    // ancien mot de passe pour toujours, et le nouveau ne marchait pas.
    // Le fallback local reste actif uniquement quand le serveur est
    // INATTEIGNABLE (mode offline) — auquel cas on suppose que l'auth
    // n'a pas changé.
    if (remoteResult.rejected) {
      // Sync local hash si l'utilisateur a tapé le bon nouveau password
      // (qui matche pas le hash local) — non, attends : si le serveur
      // rejette, c'est qu'il n'accepte pas non plus. Donc on échoue net.
      return const LocalSignInResult(
        success: false,
        error: 'Mot de passe invalide',
      );
    }

    if (!localPasswordMatches && remoteToken == null) {
      // Serveur inatteignable ET local KO → vrai échec.
      return const LocalSignInResult(
        success: false,
        error: 'Mot de passe invalide',
      );
    }

    // If the server accepted the password but the local hash doesn't match,
    // the user has rotated their password on the admin panel without updating
    // their device. Sync the local password to match the server one so the
    // user only ever types a single password.
    if (!localPasswordMatches && remoteToken != null) {
      final nextSalt = _generateSalt();
      await _database.database.then((db) => db.update(
            'app_users',
            {
              'password_salt': nextSalt,
              'password_hash': _hashPassword(password, nextSalt),
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'local_id = ?',
            whereArgs: [row['local_id']],
          ));
    }

    final now = DateTime.now().toIso8601String();

    // When the server rejects our remote login (password drift between
    // local and server hashes), fall back to a `local-auth:<base64-email>`
    // token that the server accepts for members known in the registry.
    // This keeps NocoDB sync working without forcing a manual password
    // reset every time the hashes diverge.
    final effectiveToken = remoteToken ?? _buildLocalAuthToken(normalizedEmail);

    await db.insert('app_session', {
      'id': 1,
      'user_local_id': row['local_id'],
      'remote_token': effectiveToken,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    AppConfig.setAppSessionToken(effectiveToken);

    final scopes = await _fetchScopesByUserId(db);
    return LocalSignInResult(
      success: true,
      user: _mapUser(row, scopes[row['local_id']] ?? []),
      hasRemoteSession: remoteToken != null,
    );
  }

  /// Attempt a remote login with a given password (can differ from the local
  /// one). Stores the token in SQLite and AppConfig if successful.
  Future<bool> linkRemoteSession({
    required String email,
    required String password,
  }) async {
    final result = await NocodbApiClient().loginToRemote(
      email: email.trim().toLowerCase(),
      password: password,
    );
    final token = result.token;
    if (token == null) return false;

    final db = await _database.database;
    await db.update(
      'app_session',
      {
        'remote_token': token,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = 1',
    );
    AppConfig.setAppSessionToken(token);
    return true;
  }

  /// Restore any remote session token persisted from a previous login.
  /// If the stored token is missing/empty but we still have an active
  /// local user, synthesize a `local-auth:` fallback token so NocoDB
  /// sync works without forcing a re-login.
  ///
  /// **Garde-fou 2026-05-15 (audit P0 #1)** : si le token chargé est de
  /// type `local-auth:` et que le serveur est joignable, on le valide
  /// via `/api/auth/session`. Si le serveur le rejette (401/403), c'est
  /// le signal que le fix `c2140d4` (qui rejette les tokens non signés
  /// HMAC) est déployé → on efface la ligne `app_session` pour forcer
  /// une re-login propre côté UI **sans perdre les données locales**
  /// (les tables data sont préservées, contrairement à `signOut`).
  /// Sans ce garde-fou, l'iPad spammerait le bandeau rouge "erreur de
  /// sync" indéfiniment puisque chaque PATCH/PUT renvoie 401 et que le
  /// 401 est rejoué toutes les ~24 h par `rehabilitateTransientFailures`.
  Future<void> restoreRemoteSession() async {
    final db = await _database.database;
    try {
      final rows = await db.query(
        'app_session',
        columns: ['remote_token', 'user_local_id'],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final token = rows.first['remote_token'] as String?;
      if (token != null && token.isNotEmpty) {
        AppConfig.setAppSessionToken(token);
        await _maybeInvalidateStaleLocalAuthToken(db, token);
        return;
      }
      final userLocalId = rows.first['user_local_id'] as String?;
      if (userLocalId == null || userLocalId.isEmpty) return;
      final userRows = await db.query(
        'app_users',
        columns: ['email'],
        where: 'local_id = ?',
        whereArgs: [userLocalId],
        limit: 1,
      );
      if (userRows.isEmpty) return;
      final email = (userRows.first['email'] as String?)?.trim();
      if (email == null || email.isEmpty) return;
      final fallback = _buildLocalAuthToken(email);
      await db.update(
        'app_session',
        {
          'remote_token': fallback,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = 1',
      );
      AppConfig.setAppSessionToken(fallback);
      await _maybeInvalidateStaleLocalAuthToken(db, fallback);
    } catch (_) {
      // Column may not exist yet on older schemas — ignore.
    }
  }

  /// Si [token] est un token `local-auth:`, teste-le contre le serveur.
  /// Quand il est rejeté (401/403), on efface la ligne `app_session`
  /// pour forcer un re-login. Les autres cas (valide ou injoignable)
  /// laissent l'état inchangé. Idempotent : pas d'effet si le token
  /// n'est pas `local-auth:` ou si le serveur n'est pas joignable.
  Future<void> _maybeInvalidateStaleLocalAuthToken(
    Database db,
    String token,
  ) async {
    if (!token.startsWith('local-auth:')) return;
    try {
      final status = await NocodbApiClient().validateSessionToken();
      if (status == SessionTokenStatus.rejected) {
        // ignore: avoid_print
        print('[auth-root] local-auth token rejected by server — '
            'clearing session to force re-login (data preserved)');
        await _clearSessionRowOnly(db);
        // Plus de token côté AppConfig non plus, sinon les call API
        // jusqu'au rebuild UI seraient encore signés avec le token mort.
        AppConfig.clearAppSessionToken();
      }
    } catch (_) {
      // Best-effort : si la validation explose pour une raison
      // imprévue, on laisse l'utilisateur dans son état actuel plutôt
      // que de lui faire perdre sa session sur un faux positif.
    }
  }

  /// Efface uniquement la ligne `app_session` (token de session). À la
  /// différence de `signOut()`, ne touche PAS aux tables de données
  /// (dossiers, patients, sync_operations, etc.) — utilisé pour forcer
  /// un re-login sans perdre le travail local en cours.
  Future<void> _clearSessionRowOnly(Database db) async {
    await db.delete('app_session');
  }

  Future<void> signOut() async {
    final db = await _database.database;
    await db.delete('app_session');
    // Purge complète des données locales — convention « logout = état
    // propre » (demande utilisateur 2026-05-06). Évite les divergences
    // après re-login : le prochain login ré-tire toutes les données
    // depuis NocoDB sans les bloquer derrière des `pending_sync` flags
    // hérités de la session précédente. Les tables d'auth (app_users,
    // user_access_scopes, access_members) sont préservées pour que le
    // re-login offline marche.
    //
    // Tables wipées (alignées avec `DataService.wipeLocalDataForResync`) :
    const dataTables = <String>[
      'dossiers',
      'patients',
      'housings',
      'documents',
      'note_pages',
      'sync_operations',
      'contexte_de_vie',
      'diagnostic_sanitaires',
      'mesures_anthropometriques',
      'observations_synthese',
      'visit_recommendations',
      'wiki_items',
      'retirement_funds',
      'reference_sync_meta',
      'web_media_cache',
    ];
    for (final table in dataTables) {
      try {
        await db.delete(table);
      } catch (_) {
        // Table inexistante (migration partielle) — ignore.
      }
    }
  }

  Future<bool> isUsingBootstrapPassword(String userId) async {
    final db = await _database.database;
    final rows = await db.query(
      'app_users',
      columns: ['password_salt', 'password_hash'],
      where: 'local_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final row = rows.first;
    final salt = row['password_salt'] as String? ?? '';
    final currentHash = row['password_hash'] as String? ?? '';
    return currentHash == _hashPassword(bootstrapPassword, salt);
  }

  Future<bool> isBootstrapPasswordActiveForEmail(String email) async {
    final db = await _database.database;
    final rows = await db.query(
      'app_users',
      columns: ['local_id'],
      where: 'email = ? AND is_active = 1',
      whereArgs: [email.trim().toLowerCase()],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return isUsingBootstrapPassword(rows.first['local_id'] as String);
  }

  Future<PasswordChangeResult> changePassword({
    required String userId,
    required String currentPassword,
    required String nextPassword,
  }) async {
    if (nextPassword.trim().length < 8) {
      return const PasswordChangeResult(
        success: false,
        error: 'Le nouveau mot de passe doit contenir au moins 8 caractères',
      );
    }

    final db = await _database.database;
    final rows = await db.query(
      'app_users',
      columns: ['password_salt', 'password_hash'],
      where: 'local_id = ? AND is_active = 1',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return const PasswordChangeResult(
        success: false,
        error: 'Compte local introuvable',
      );
    }

    final row = rows.first;
    final salt = row['password_salt'] as String? ?? '';
    final expectedHash = row['password_hash'] as String? ?? '';
    final currentHash = _hashPassword(currentPassword, salt);
    if (currentHash != expectedHash) {
      return const PasswordChangeResult(
        success: false,
        error: 'Mot de passe actuel invalide',
      );
    }

    final nextSalt = _generateSalt();
    await db.update(
      'app_users',
      {
        'password_salt': nextSalt,
        'password_hash': _hashPassword(nextPassword, nextSalt),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [userId],
    );

    return const PasswordChangeResult(success: true);
  }

  Future<bool> mergeRemoteUsers(List<Map<String, dynamic>> remoteUsers) async {
    if (remoteUsers.isEmpty) return false;

    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    for (final remoteUser in remoteUsers) {
      final email = (remoteUser['email']?.toString() ?? '')
          .trim()
          .toLowerCase();
      if (email.isEmpty) continue;

      final existingRows = await db.query(
        'app_users',
        columns: ['local_id'],
        where: 'email = ?',
        whereArgs: [email],
        limit: 1,
      );

      final localUserId = existingRows.isNotEmpty
          ? existingRows.first['local_id'] as String
          : 'remote_${email.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

      if (existingRows.isEmpty) {
        final salt = _generateSalt();
        await db.insert('app_users', {
          'local_id': localUserId,
          'email': email,
          'display_name': remoteUser['displayName']?.toString() ?? email,
          'role': _mapRemoteRole(remoteUser['role']?.toString()).name,
          'password_salt': salt,
          'password_hash': _hashPassword(bootstrapPassword, salt),
          'establishment_id': _nullableValue(remoteUser['establishmentId']),
          'ergo_label': _nullableValue(remoteUser['ergoLabel']),
          'is_active': _remoteIsActive(remoteUser) ? 1 : 0,
          'profile_photo_url':
              remoteUser['profilePhotoUrl']?.toString() ?? '',
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        final updates = <String, Object?>{
          'display_name': remoteUser['displayName']?.toString() ?? email,
          'role': _mapRemoteRole(remoteUser['role']?.toString()).name,
          'establishment_id': _nullableValue(remoteUser['establishmentId']),
          'ergo_label': _nullableValue(remoteUser['ergoLabel']),
          'is_active': _remoteIsActive(remoteUser) ? 1 : 0,
          'updated_at': now,
        };
        // Only overwrite the local photo when the server actually sent
        // one — avoids clobbering a just-uploaded photo whose URL hasn't
        // propagated back through `fetchLocalAuthState` yet.
        final remotePhoto = remoteUser['profilePhotoUrl']?.toString() ?? '';
        if (remotePhoto.isNotEmpty) {
          updates['profile_photo_url'] = remotePhoto;
        }
        await db.update(
          'app_users',
          updates,
          where: 'local_id = ?',
          whereArgs: [localUserId],
        );
      }

      await db.delete(
        'user_access_scopes',
        where: 'user_local_id = ?',
        whereArgs: [localUserId],
      );

      final remoteScopes = (remoteUser['scopes'] as List?) ?? const [];
      for (var index = 0; index < remoteScopes.length; index += 1) {
        final scope = remoteScopes[index];
        if (scope is! Map) continue;
        final type = scope['type']?.toString().trim() ?? '';
        final value = scope['value']?.toString().trim() ?? '';
        if (type.isEmpty || value.isEmpty) continue;
        await db.insert('user_access_scopes', {
          'local_id': '${localUserId}_scope_$index',
          'user_local_id': localUserId,
          'scope_type': type,
          'scope_value': value,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }

    return true;
  }

  List<Dossier> filterDossiersForUser(
    List<Dossier> dossiers,
    LocalAppUser user,
  ) {
    if (user.role == LocalUserRole.admin || _hasWildcardAccess(user.scopes)) {
      return dossiers;
    }

    final dossierIds = user.scopes
        .where((scope) => scope.type == 'dossier_id')
        .map((scope) => scope.value.trim().toLowerCase())
        .toSet();
    final dossierErgos = user.scopes
        .where((scope) => scope.type == 'dossier_ergo')
        .map((scope) => scope.value.trim().toLowerCase())
        .toSet();
    final expectedErgo = (user.ergoLabel ?? '').trim().toLowerCase();
    return dossiers.where((dossier) {
      final dossierId = dossier.id.trim().toLowerCase();
      final ergoId = dossier.ergoId.trim().toLowerCase();
      if (dossierIds.contains(dossierId) || dossierErgos.contains(ergoId)) {
        return true;
      }
      if (dossierIds.isEmpty &&
          dossierErgos.isEmpty &&
          expectedErgo.isNotEmpty) {
        return ergoId == expectedErgo;
      }
      return false;
    }).toList();
  }

  Future<Map<String, List<LocalAccessScope>>> _fetchScopesByUserId(
    Database db,
  ) async {
    final rows = await db.query(
      'user_access_scopes',
      columns: ['user_local_id', 'scope_type', 'scope_value'],
    );
    final scopesByUserId = <String, List<LocalAccessScope>>{};
    for (final row in rows) {
      final userId = row['user_local_id'] as String;
      scopesByUserId.putIfAbsent(userId, () => []);
      scopesByUserId[userId]!.add(
        LocalAccessScope(
          type: row['scope_type'] as String,
          value: row['scope_value'] as String,
        ),
      );
    }
    return scopesByUserId;
  }

  bool _hasWildcardAccess(List<LocalAccessScope> scopes) {
    return scopes.any(
      (scope) => scope.type == 'dossier_access' && scope.value.trim() == '*',
    );
  }

  LocalAppUser _mapUser(
    Map<String, Object?> row,
    List<LocalAccessScope> scopes,
  ) {
    return LocalAppUser(
      id: row['local_id'] as String,
      email: row['email'] as String,
      displayName: row['display_name'] as String,
      role: LocalUserRole.values.byName(row['role'] as String),
      establishmentId: row['establishment_id'] as String?,
      ergoLabel: row['ergo_label'] as String?,
      profilePhotoUrl: (row['profile_photo_url'] as String?) ?? '',
      pendingProfilePhotoDataUrl:
          (row['pending_photo_data_url'] as String?) ?? '',
      scopes: scopes,
    );
  }

  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  String _hashPassword(String password, String salt) {
    return sha256.convert(utf8.encode('$salt::$password')).toString();
  }

  LocalUserRole _mapRemoteRole(String? role) {
    switch ((role ?? '').trim().toUpperCase()) {
      case 'ADMIN':
        return LocalUserRole.admin;
      case 'ERGO':
      default:
        return LocalUserRole.ergo;
    }
  }

  bool _remoteIsActive(Map<String, dynamic> remoteUser) {
    final value = remoteUser['isActive'];
    if (value is bool) return value;
    return value?.toString() != 'false';
  }

  String? _nullableValue(Object? value) {
    final normalized = value?.toString().trim() ?? '';
    return normalized.isEmpty ? null : normalized;
  }
}

class LocalSignInResult {
  final bool success;
  final String? error;
  final LocalAppUser? user;
  final bool hasRemoteSession;

  const LocalSignInResult({
    required this.success,
    this.error,
    this.user,
    this.hasRemoteSession = false,
  });
}

class PasswordChangeResult {
  final bool success;
  final String? error;

  const PasswordChangeResult({required this.success, this.error});
}

class _SeedUser {
  final String id;
  final String email;
  final String displayName;
  final LocalUserRole role;
  final String? establishmentId;
  final String? ergoLabel;
  final String? dossierErgoScope;

  const _SeedUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.role,
    this.establishmentId,
    this.ergoLabel,
    this.dossierErgoScope,
  });
}

class _SeedAccessScope {
  final String id;
  final String userId;
  final String type;
  final String value;

  const _SeedAccessScope({
    required this.id,
    required this.userId,
    required this.type,
    required this.value,
  });
}
