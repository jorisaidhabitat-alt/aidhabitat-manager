import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';

class SyncRepository {
  SyncRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<SyncOperation>> fetchRunnableOperations() async {
    final db = await _database.database;
    // Exclude 'conflict' and 'completed' operations — conflicts require manual
    // resolution and completed operations are done.
    final rows = await db.query(
      'sync_operations',
      where: 'status IN (?, ?)',
      whereArgs: [
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
      orderBy: 'created_at ASC',
    );

    final now = DateTime.now();
    final out = <SyncOperation>[];
    for (final row in rows) {
      final attempts = row['attempt_count'] as int? ?? 0;
      final updatedAt = DateTime.tryParse(row['updated_at'] as String? ?? '');
      // Backoff par op : au-delà de 3 tentatives, on attend de plus en
      // plus longtemps avant de retenter (30s × attempts, capé à 5 min).
      // Évite de marteler le serveur sur une op qui échoue en boucle,
      // tout en laissant les premières tentatives rapides.
      if (attempts >= 3 && updatedAt != null) {
        final backoffSeconds = (attempts * 30).clamp(30, 300);
        if (now.difference(updatedAt).inSeconds < backoffSeconds) {
          continue;
        }
      }
      out.add(SyncOperation(
        id: row['id'] as String,
        entityType: row['entity_type'] as String,
        entityLocalId: row['entity_local_id'] as String,
        operationType: row['operation_type'] as String,
        payloadJson: row['payload_json'] as String,
        status: SyncOperationStatus.values.byName(row['status'] as String),
        attemptCount: attempts,
        lastError: row['last_error'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      ));
    }
    return out;
  }

  Future<void> markRunning(String operationId) async {
    await _updateOperation(
      operationId: operationId,
      status: SyncOperationStatus.running,
      clearError: true,
    );
  }

  Future<void> markCompleted({
    required String operationId,
    required String entityType,
    required String entityLocalId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    await _updateOperation(
      operationId: operationId,
      status: SyncOperationStatus.completed,
      clearError: true,
    );
    await _updateEntitySyncState(
      db: db,
      entityType: entityType,
      entityLocalId: entityLocalId,
      syncState: SyncState.synced,
    );
    await db.update(
      'sync_operations',
      {'updated_at': now},
      where: 'id = ?',
      whereArgs: [operationId],
    );
  }

  Future<void> markFailed({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    required String error,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_operations',
      columns: ['attempt_count'],
      where: 'id = ?',
      whereArgs: [operationId],
      limit: 1,
    );
    final attempts = rows.isEmpty
        ? 0
        : (rows.first['attempt_count'] as int? ?? 0);

    await db.update(
      'sync_operations',
      {
        'status': SyncOperationStatus.failed.name,
        'attempt_count': attempts + 1,
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [operationId],
    );

    await _updateEntitySyncState(
      db: db,
      entityType: entityType,
      entityLocalId: entityLocalId,
      syncState: SyncState.syncError,
    );
  }

  /// Erreur transitoire (timeout, déconnexion, 5xx serveur). L'opération
  /// reste en statut `pending` pour être repêchée au prochain cycle de
  /// sync — PAS de bandeau rouge côté UI, PAS de statut `failed`. On
  /// bump juste `attempt_count` et on trace `last_error` pour le debug.
  Future<void> markTransientFailure({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    required String error,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_operations',
      columns: ['attempt_count'],
      where: 'id = ?',
      whereArgs: [operationId],
      limit: 1,
    );
    final attempts = rows.isEmpty
        ? 0
        : (rows.first['attempt_count'] as int? ?? 0);

    await db.update(
      'sync_operations',
      {
        'status': SyncOperationStatus.pending.name,
        'attempt_count': attempts + 1,
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [operationId],
    );

    // On laisse sync_state sur `pendingSync` (c'est le statut "en cours
    // de sync" normal) plutôt que `syncError` pour ne pas alarmer l'UI.
    await _updateEntitySyncState(
      db: db,
      entityType: entityType,
      entityLocalId: entityLocalId,
      syncState: SyncState.pendingSync,
    );
  }

  Future<void> markConflict({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    required String error,
  }) async {
    final db = await _database.database;
    await db.update(
      'sync_operations',
      {
        'status': 'conflict',
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [operationId],
    );

    await _updateEntitySyncState(
      db: db,
      entityType: entityType,
      entityLocalId: entityLocalId,
      syncState: SyncState.conflict,
    );
  }

  Future<void> storeDocumentRemoteData({
    required String documentLocalId,
    required String remotePath,
    required String publicUrl,
  }) async {
    final db = await _database.database;
    await db.update(
      'documents',
      {
        'remote_file_path': remotePath,
        'remote_public_url': publicUrl,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [documentLocalId],
    );
  }

  Future<void> storeNotePageRemoteData({
    required String noteLocalId,
    required String remotePath,
    required String remoteUrl,
  }) async {
    final db = await _database.database;
    await db.update(
      'note_pages',
      {
        'drawing_remote_path': remotePath,
        'drawing_remote_url': remoteUrl,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [noteLocalId],
    );
  }

  /// After a successful remote creation, store the remote IDs in the local
  /// database so subsequent updates can reference them.
  Future<void> storeRemoteIds({
    required String patientLocalId,
    required String remotePatientId,
    required String dossierLocalId,
    String? remoteDossierId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    await db.update(
      'patients',
      {
        'remote_patient_id': remotePatientId,
        'sync_state': SyncState.synced.name,
        'remote_updated_at': now,
        'updated_at': now,
      },
      where: 'local_id = ?',
      whereArgs: [patientLocalId],
    );

    if (dossierLocalId.isNotEmpty && remoteDossierId != null) {
      await db.update(
        'dossiers',
        {
          'remote_dossier_id': remoteDossierId,
          'sync_state': SyncState.synced.name,
          'remote_updated_at': now,
          'updated_at': now,
        },
        where: 'local_id = ?',
        whereArgs: [dossierLocalId],
      );
    }
  }

  /// Look up the remote patient ID for a given local patient ID.
  Future<String?> resolveRemotePatientId(String patientLocalId) async {
    final db = await _database.database;
    final rows = await db.query(
      'patients',
      columns: ['remote_patient_id'],
      where: 'local_id = ?',
      whereArgs: [patientLocalId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['remote_patient_id'] as String?;
  }

  /// Delete completed sync operations older than [maxAge] to prevent
  /// unbounded SQLite growth. Safe to call periodically.
  Future<int> purgeCompleted({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final db = await _database.database;
    final cutoff = DateTime.now().subtract(maxAge).toIso8601String();
    return db.delete(
      'sync_operations',
      where: 'status = ? AND updated_at < ?',
      whereArgs: [SyncOperationStatus.completed.name, cutoff],
    );
  }

  /// Purge stale sync operations that are almost certainly obsolete and
  /// would otherwise be replayed every time the app starts, overwriting
  /// fresh remote data with values captured by a previous app version.
  ///
  ///  - any operation in `failed` state (retries exhausted → payload
  ///    rejected by the current backend schema, not worth pushing again),
  ///  - `pending` operations whose `created_at` is older than
  ///    [maxPendingAge] (default 72 h — a comfortable offline window),
  ///  - `running` operations whose `updated_at` is older than
  ///    [maxPendingAge] (they should have completed long ago).
  ///
  /// Returns the number of rows removed. Safe to call on app boot.
  /// Purge les `sync_operations` obsolètes. On ne touche JAMAIS aux
  /// `pending` — quelle que soit leur ancienneté, elles doivent être
  /// poussées au prochain retour de connexion. Seuls les `failed`
  /// (erreur définitive, typiquement rejet serveur 400/403/409 avec
  /// attempt_count ≥ max retries) et les `running` bloqués > 72h (orphelins
  /// si l'app a crashé en plein milieu d'un push) sont purgés.
  Future<int> purgeStalePendingOperations({
    Duration maxRunningAge = const Duration(hours: 72),
  }) async {
    final db = await _database.database;
    final cutoff = DateTime.now().subtract(maxRunningAge).toIso8601String();
    return db.delete(
      'sync_operations',
      where: '''
        status = ?
        OR (status = ? AND updated_at < ?)
      ''',
      whereArgs: [
        SyncOperationStatus.failed.name,
        SyncOperationStatus.running.name,
        cutoff,
      ],
    );
  }

  Future<void> setEntitySyncState({
    required String entityType,
    required String entityLocalId,
    required SyncState syncState,
  }) async {
    final db = await _database.database;
    await _updateEntitySyncState(
      db: db,
      entityType: entityType,
      entityLocalId: entityLocalId,
      syncState: syncState,
    );
  }

  /// Renvoie un résumé court de la première opération en échec — utilisée
  /// par le bandeau UI pour expliquer à l'utilisateur ce qui bloque.
  /// Renvoie null si aucune op n'est en `failed`.
  Future<Map<String, String?>?> fetchTopFailingOperation() async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_operations',
      columns: [
        'id',
        'entity_type',
        'operation_type',
        'entity_local_id',
        'last_error',
        'attempt_count',
      ],
      where: 'status = ?',
      whereArgs: [SyncOperationStatus.failed.name],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'id': r['id'] as String?,
      'entityType': r['entity_type'] as String?,
      'operationType': r['operation_type'] as String?,
      'entityLocalId': r['entity_local_id'] as String?,
      'lastError': r['last_error'] as String?,
      'attemptCount': '${r['attempt_count'] ?? 0}',
    };
  }

  /// Supprime TOUTES les opérations en `failed` — permet à l'utilisateur de
  /// débloquer le bandeau rouge quand une modification ne pourra jamais
  /// aboutir (ex: ressource supprimée côté serveur).
  Future<int> discardFailedOperations() async {
    final db = await _database.database;
    return db.delete(
      'sync_operations',
      where: 'status = ?',
      whereArgs: [SyncOperationStatus.failed.name],
    );
  }

  Future<void> clearPendingOperationsForEntity(String entityLocalId) async {
    final db = await _database.database;
    await db.delete(
      'sync_operations',
      where: 'entity_local_id = ? AND status IN (?, ?)',
      whereArgs: [
        entityLocalId,
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
    );
  }

  Future<void> _updateOperation({
    required String operationId,
    required SyncOperationStatus status,
    required bool clearError,
  }) async {
    final db = await _database.database;
    await db.update(
      'sync_operations',
      {
        'status': status.name,
        'last_error': clearError ? null : undefined,
        'updated_at': DateTime.now().toIso8601String(),
      }..removeWhere((key, value) => value == undefined),
      where: 'id = ?',
      whereArgs: [operationId],
    );
  }

  Future<void> _updateEntitySyncState({
    required Database db,
    required String entityType,
    required String entityLocalId,
    required SyncState syncState,
  }) async {
    final binding = switch (entityType) {
      'dossier' => const _EntityBinding('dossiers', 'local_id'),
      'document' => const _EntityBinding('documents', 'local_id'),
      'note_page' => const _EntityBinding('note_pages', 'local_id'),
      'wiki_item' => const _EntityBinding('wiki_items', 'id'),
      'retirement_fund' => const _EntityBinding('retirement_funds', 'id'),
      'access_member' => const _EntityBinding('access_members', 'email'),
      'profile_photo' => const _EntityBinding('app_users', 'local_id'),
      _ => null,
    };
    if (binding == null) return;

    await db.update(
      binding.table,
      {'sync_state': syncState.name},
      where: '${binding.idColumn} = ?',
      whereArgs: [entityLocalId],
    );
  }
}

const undefined = Object();

class _EntityBinding {
  final String table;
  final String idColumn;
  const _EntityBinding(this.table, this.idColumn);
}
