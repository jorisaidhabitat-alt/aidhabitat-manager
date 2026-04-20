import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';
import 'sync_engine.dart';

class NoteRepository {
  NoteRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<String?> fetchDrawingJson({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'note_pages',
      columns: ['drawing_json'],
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, tabKey, pageNumber],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['drawing_json'] as String?;
  }

  Future<void> saveDrawingJson({
    required String patientId,
    required String tabKey,
    required String drawingJson,
    int pageNumber = 0,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final noteId = 'note_${patientId}_${tabKey}_$pageNumber';
    final operationId = 'sync_$noteId';

    await db.insert('note_pages', {
      'local_id': noteId,
      'patient_local_id': patientId,
      'tab_key': tabKey,
      'page_number': pageNumber,
      'text_content': '',
      'drawing_json': drawingJson,
      'drawing_local_path': null,
      'drawing_remote_path': null,
      'drawing_remote_url': null,
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await db.insert('sync_operations', {
      'id': operationId,
      'entity_type': 'note_page',
      'entity_local_id': noteId,
      'operation_type': 'upsert',
      'payload_json': jsonEncode({
        'patientLocalId': patientId,
        'tabKey': tabKey,
        'pageNumber': pageNumber,
        'drawingJson': drawingJson,
      }),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    SyncEngine().notify();
  }

  Future<bool> mergeRemoteNotePage({
    required String patientId,
    required String tabKey,
    required int pageNumber,
    required String drawingJson,
    String? remotePath,
    String? remoteUrl,
    String? updatedAt,
  }) async {
    final db = await _database.database;
    final existingRows = await db.query(
      'note_pages',
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, tabKey, pageNumber],
      limit: 1,
    );
    final existing = existingRows.isNotEmpty ? existingRows.first : null;
    final existingSyncState = existing?['sync_state'] as String?;

    if (existing != null && existingSyncState != SyncState.synced.name) {
      return false;
    }

    await db.insert('note_pages', {
      'local_id':
          existing?['local_id'] as String? ??
          'remote_note_${patientId}_${tabKey}_$pageNumber',
      'patient_local_id': patientId,
      'tab_key': tabKey,
      'page_number': pageNumber,
      'text_content': existing?['text_content'] as String? ?? '',
      'drawing_json': drawingJson,
      'drawing_local_path': existing?['drawing_local_path'],
      'drawing_remote_path': remotePath,
      'drawing_remote_url': remoteUrl,
      'updated_at': updatedAt ?? DateTime.now().toIso8601String(),
      'sync_state': SyncState.synced.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    return true;
  }
}
