import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';
import 'offline_vault.dart';
import 'sync_engine.dart';

/// Offline-first repository for the admin access-members list. Reads always
/// hit SQLite; mutations write-local + enqueue a sync operation that is
/// picked up by [NocodbSyncService] when connectivity is available.
class AccessMembersRepository {
  AccessMembersRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<AdminAccessMember>> fetchAll() async {
    final db = await _database.database;
    final rows = await db.query(
      'access_members',
      where: 'pending_delete = 0',
      orderBy: 'display_name ASC',
    );
    final out = <AdminAccessMember>[];
    for (final row in rows) {
      out.add(await _mapRow(row));
    }
    return out;
  }

  /// Overwrites the local cache with [remoteMembers]. Rows whose
  /// `sync_state` is not `synced` are preserved so we never clobber a
  /// local pending mutation. Rows missing from [remoteMembers] whose local
  /// sync_state is `synced` are deleted (the server considers them gone).
  Future<void> mergeRemoteMembers(List<AdminAccessMember> remoteMembers) async {
    final db = await _database.database;
    final remoteByEmail = {for (final m in remoteMembers) m.email: m};
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'access_members',
        columns: ['email', 'sync_state', 'pending_delete'],
      );
      final existingByEmail = {
        for (final r in existingRows) r['email'] as String: r,
      };

      // Insert/update remote members.
      //
      // NOTE 2026-05-07 : ce repo skip aveuglément si `pendingSync`,
      // contrairement à note/document/wiki/retirement_funds qui font du
      // LWW (parité fix 2026-05-07). On garde le skip aveugle ICI car
      // le modèle `AdminAccessMember` n'expose pas d'`updatedAt`
      // authoritatif côté serveur — sans timestamp, impossible de
      // décider qui gagne. Impact perçu : faible (la table
      // `access_members` est administrée par 1 admin, peu de races
      // possibles). Si on a un bug « membre ajouté côté NocoDB n'arrive
      // pas sur l'app », ajouter `updatedAt` au model + LWW comme
      // ailleurs.
      for (final m in remoteMembers) {
        final existing = existingByEmail[m.email];
        if (existing != null) {
          final syncState = existing['sync_state'] as String?;
          final pendingDelete = (existing['pending_delete'] as int?) ?? 0;
          if ((syncState != null && syncState != SyncState.synced.name) ||
              pendingDelete == 1) {
            continue; // local mutation in flight
          }
        }
        // Audit sécu 2026-05-15 (P0 #3) : depuis le fix, le serveur
        // renvoie TOUJOURS `generatedPassword: ''` dans /api/admin/
        // access-members (le password n'est plus persisté en RAM côté
        // serveur). Si on faisait un `replace` aveugle, le password
        // qu'un admin vient de générer côté Flutter (capturé localement
        // dans `generated_password` ou `pending_password`) serait
        // écrasé à `''` à chaque pull. On préserve donc la valeur
        // locale quand le remote envoie vide.
        String? incomingPassword = m.generatedPassword;
        if (incomingPassword.isEmpty) {
          // Lookup pour conserver l'éventuel password déjà stocké local.
          final localRow = await txn.query(
            'access_members',
            columns: ['generated_password'],
            where: 'email = ?',
            whereArgs: [m.email],
            limit: 1,
          );
          if (localRow.isNotEmpty) {
            incomingPassword = await OfflineVault.instance.openString(
              (localRow.first['generated_password'] as String?) ?? '',
            );
          }
        }
        await txn.insert('access_members', {
          'email': m.email,
          'display_name': m.displayName,
          'role': m.role.name,
          'selectable': m.selectable ? 1 : 0,
          'establishment_label': m.establishmentLabel,
          'ergo_label': m.ergoLabel,
          'has_password': m.hasPassword ? 1 : 0,
          'generated_password': await OfflineVault.instance.sealString(
            incomingPassword,
          ),
          'created_at': m.createdAt,
          'updated_at': now,
          'last_synced_at': now,
          'sync_state': SyncState.synced.name,
          'pending_delete': 0,
          'pending_password': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // Delete local rows that the server says are gone, unless we have
      // a local mutation in flight for them.
      for (final entry in existingByEmail.entries) {
        final email = entry.key;
        if (remoteByEmail.containsKey(email)) continue;
        final syncState = entry.value['sync_state'] as String?;
        final pendingDelete = (entry.value['pending_delete'] as int?) ?? 0;
        if ((syncState != null && syncState != SyncState.synced.name) ||
            pendingDelete == 1) {
          continue;
        }
        await txn.delete(
          'access_members',
          where: 'email = ?',
          whereArgs: [email],
        );
      }
    });
  }

  /// Creates a member locally (sync_state = pendingSync) and enqueues a
  /// `create` op. Returns the local member so the UI can render it
  /// immediately — the caller should treat the generated password as "not
  /// yet available" until sync completes.
  Future<AdminAccessMember> createLocalMember({
    required String email,
    required String displayName,
    required LocalUserRole role,
    String? establishmentId,
    String? password,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    final draft = AdminAccessMember(
      email: email,
      displayName: displayName,
      role: role,
      selectable: true,
      establishmentLabel: establishmentId ?? '',
      ergoLabel: '',
      hasPassword: password != null && password.isNotEmpty,
      generatedPassword: password ?? '',
      createdAt: now,
    );

    await db.transaction((txn) async {
      await txn.insert('access_members', {
        'email': email,
        'display_name': displayName,
        'role': role.name,
        'selectable': 1,
        'establishment_label': establishmentId ?? '',
        'ergo_label': '',
        'has_password': (password != null && password.isNotEmpty) ? 1 : 0,
        'generated_password': await OfflineVault.instance.sealString(
          password ?? '',
        ),
        'created_at': now,
        'updated_at': now,
        'last_synced_at': now,
        'sync_state': SyncState.pendingSync.name,
        'pending_delete': 0,
        'pending_password': await OfflineVault.instance.sealNullableString(
          password,
        ),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await _enqueueOperation(txn, {
        'id': 'access_create_${_sanitize(email)}',
        'entity_type': 'access_member',
        'entity_local_id': email,
        'operation_type': 'create',
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode({
            'email': email,
            'displayName': displayName,
            'role': role == LocalUserRole.admin ? 'ADMIN' : 'ERGO',
            if (establishmentId != null && establishmentId.isNotEmpty)
              'establishmentId': establishmentId,
            if (password != null && password.isNotEmpty) 'password': password,
          }),
        ),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
    });

    SyncEngine().notify();
    return draft;
  }

  /// Updates a member locally + enqueues `update`. Mirrors the server API
  /// which accepts optional `displayName` and `establishmentId`.
  Future<AdminAccessMember> updateLocalMember({
    required String email,
    String? displayName,
    String? establishmentId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      final updates = <String, Object?>{
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      };
      if (displayName != null) updates['display_name'] = displayName;
      if (establishmentId != null) {
        updates['establishment_label'] = establishmentId;
      }
      await txn.update(
        'access_members',
        updates,
        where: 'email = ?',
        whereArgs: [email],
      );

      await _enqueueOperation(txn, {
        'id':
            'access_update_${_sanitize(email)}_'
            '${DateTime.now().microsecondsSinceEpoch}',
        'entity_type': 'access_member',
        'entity_local_id': email,
        'operation_type': 'update',
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode({
            'email': email,
            if (displayName != null) 'displayName': displayName,
            if (establishmentId != null) 'establishmentId': establishmentId,
          }),
        ),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
    });

    SyncEngine().notify();
    final rows = await db.query(
      'access_members',
      where: 'email = ?',
      whereArgs: [email],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw Exception('Membre introuvable après mise à jour locale');
    }
    return await _mapRow(rows.first);
  }

  /// Marks the row as `pending_delete` (so [fetchAll] hides it), then
  /// enqueues a `delete` op. Physical deletion happens in the sync
  /// processor once the server confirms.
  Future<void> deleteLocalMember(String email) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await txn.update(
        'access_members',
        {
          'pending_delete': 1,
          'sync_state': SyncState.pendingSync.name,
          'updated_at': now,
        },
        where: 'email = ?',
        whereArgs: [email],
      );

      await _enqueueOperation(txn, {
        'id': 'access_delete_${_sanitize(email)}',
        'entity_type': 'access_member',
        'entity_local_id': email,
        'operation_type': 'delete',
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode({'email': email}),
        ),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
    });

    SyncEngine().notify();
  }

  /// Queues a password change. If [password] is null/empty, the server
  /// regenerates one on next sync. Locally, [password] (when provided) is
  /// cached in `pending_password` so the UI can still display it offline.
  Future<void> setLocalPassword({
    required String email,
    String? password,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await txn.update(
        'access_members',
        {
          'pending_password': await OfflineVault.instance.sealNullableString(
            password,
          ),
          'sync_state': SyncState.pendingSync.name,
          'updated_at': now,
          // When the caller explicitly sets a password, reflect it locally
          // so it shows up in the admin UI before the sync completes.
          if (password != null && password.isNotEmpty)
            'generated_password': await OfflineVault.instance.sealString(
              password,
            ),
          if (password != null && password.isNotEmpty) 'has_password': 1,
        },
        where: 'email = ?',
        whereArgs: [email],
      );

      await _enqueueOperation(txn, {
        'id':
            'access_password_${_sanitize(email)}_'
            '${DateTime.now().microsecondsSinceEpoch}',
        'entity_type': 'access_member',
        'entity_local_id': email,
        'operation_type': 'set_password',
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode({
            'email': email,
            if (password != null && password.isNotEmpty) 'password': password,
          }),
        ),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
    });

    SyncEngine().notify();
  }

  /// Returns the password currently visible for [email], preferring the
  /// locally-pending one. Used by the admin UI so a just-set password shows
  /// up even before the sync completes.
  Future<String?> fetchEffectivePassword(String email) async {
    final db = await _database.database;
    final rows = await db.query(
      'access_members',
      columns: ['generated_password', 'pending_password'],
      where: 'email = ?',
      whereArgs: [email],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final pending = await OfflineVault.instance.openNullableString(
      rows.first['pending_password'] as String?,
    );
    if (pending != null && pending.isNotEmpty) return pending;
    final generated = await OfflineVault.instance.openNullableString(
      rows.first['generated_password'] as String?,
    );
    return (generated == null || generated.isEmpty) ? null : generated;
  }

  Future<void> _enqueueOperation(
    Transaction txn,
    Map<String, Object?> row,
  ) async {
    final rowAtRest = Map<String, Object?>.from(row);
    final payload = rowAtRest['payload_json'];
    if (payload is String && payload.isNotEmpty) {
      rowAtRest['payload_json'] = await OfflineVault.instance.sealString(
        payload,
      );
    }
    await txn.insert(
      'sync_operations',
      rowAtRest,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  String _sanitize(String email) =>
      email.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  Future<AdminAccessMember> _mapRow(Map<String, Object?> row) async {
    return AdminAccessMember(
      email: row['email'] as String,
      displayName: row['display_name'] as String,
      role: LocalUserRole.values.byName(row['role'] as String),
      selectable: (row['selectable'] as int? ?? 1) == 1,
      establishmentLabel: (row['establishment_label'] as String?) ?? '',
      ergoLabel: (row['ergo_label'] as String?) ?? '',
      hasPassword: (row['has_password'] as int? ?? 0) == 1,
      generatedPassword: await OfflineVault.instance.openString(
        (row['generated_password'] as String?) ?? '',
      ),
      createdAt: row['created_at'] as String?,
    );
  }
}
