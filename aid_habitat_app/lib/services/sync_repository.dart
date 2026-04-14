import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';

class SyncRepository {
  SyncRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<SyncOperation>> fetchRunnableOperations() async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_operations',
      where: 'status IN (?, ?)',
      whereArgs: [
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
      orderBy: 'created_at ASC',
    );

    return rows.map((row) {
      return SyncOperation(
        id: row['id'] as String,
        entityType: row['entity_type'] as String,
        entityLocalId: row['entity_local_id'] as String,
        operationType: row['operation_type'] as String,
        payloadJson: row['payload_json'] as String,
        status: SyncOperationStatus.values.byName(row['status'] as String),
        attemptCount: row['attempt_count'] as int? ?? 0,
        lastError: row['last_error'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
    }).toList();
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
    final table = switch (entityType) {
      'dossier' => 'dossiers',
      'document' => 'documents',
      'note_page' => 'note_pages',
      _ => null,
    };
    if (table == null) return;

    await db.update(
      table,
      {'sync_state': syncState.name},
      where: 'local_id = ?',
      whereArgs: [entityLocalId],
    );
  }
}

const undefined = Object();
