import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';

class DocumentRepository {
  DocumentRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<DocItem>> fetchDocuments(String patientId) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      where: 'patient_local_id = ? AND pending_delete = 0',
      whereArgs: [patientId],
      orderBy: 'created_at DESC',
    );

    return rows.map(_mapRow).toList();
  }

  Future<DocItem> importDocument({
    required String patientId,
    required File sourceFile,
    List<String> tags = const ['Autre'],
  }) async {
    final db = await _database.database;
    final now = DateTime.now();
    final extension = p
        .extension(sourceFile.path)
        .replaceFirst('.', '')
        .toLowerCase();
    final baseName = p.basename(sourceFile.path);
    final title = p.basenameWithoutExtension(sourceFile.path);
    final localId = 'doc_${now.microsecondsSinceEpoch}';
    final appDir = await getApplicationDocumentsDirectory();
    final docsDir = Directory(
      p.join(appDir.path, 'offline_documents', patientId),
    );
    await docsDir.create(recursive: true);
    final storedPath = p.join(
      docsDir.path,
      '${now.millisecondsSinceEpoch}_$baseName',
    );
    await sourceFile.copy(storedPath);

    final row = {
      'local_id': localId,
      'patient_local_id': patientId,
      'title': title,
      'file_name': baseName,
      'file_ext': extension,
      'mime_type': _mimeTypeFor(extension),
      'local_file_path': storedPath,
      'remote_file_path': null,
      'remote_public_url': null,
      'tags_json': jsonEncode(tags),
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'sync_state': SyncState.pendingSync.name,
      'pending_delete': 0,
    };

    await db.insert('documents', row);
    await db.insert('sync_operations', {
      'id': 'sync_$localId',
      'entity_type': 'document',
      'entity_local_id': localId,
      'operation_type': 'upload_file',
      'payload_json': jsonEncode({
        'patientLocalId': patientId,
        'documentLocalId': localId,
        'localPath': storedPath,
        'title': title,
        'fileName': baseName,
        'mimeType': row['mime_type'],
        'tags': tags,
      }),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });

    return _mapRow(row);
  }

  Future<void> mergeRemoteDocuments(
    String patientId,
    List<Map<String, dynamic>> remoteDocuments,
  ) async {
    final db = await _database.database;

    await db.transaction((txn) async {
      for (final remote in remoteDocuments) {
        final remotePath = remote['remotePath']?.toString();
        final publicUrl = remote['publicUrl']?.toString();
        final existingRows = await txn.query(
          'documents',
          where:
              'patient_local_id = ? AND (remote_file_path = ? OR remote_public_url = ?)',
          whereArgs: [patientId, remotePath, publicUrl],
          limit: 1,
        );

        final existing = existingRows.isNotEmpty ? existingRows.first : null;
        final existingSyncState = existing?['sync_state'] as String?;
        if (existing != null && existingSyncState != SyncState.synced.name) {
          continue;
        }

        final fileName = remote['fileName']?.toString() ?? 'document';
        final extension = p
            .extension(fileName)
            .replaceFirst('.', '')
            .toLowerCase();
        final row = {
          'local_id':
              existing?['local_id'] as String? ??
              'remote_doc_${remote['id'] ?? DateTime.now().microsecondsSinceEpoch}',
          'patient_local_id': patientId,
          'title': remote['title']?.toString() ?? fileName,
          'file_name': fileName,
          'file_ext': extension,
          'mime_type':
              remote['mimeType']?.toString() ?? _mimeTypeFor(extension),
          'local_file_path': existing?['local_file_path'],
          'remote_file_path': remotePath,
          'remote_public_url': publicUrl,
          'tags_json': jsonEncode(
            (remote['tags'] as List?)?.map((tag) => '$tag').toList() ??
                const <String>[],
          ),
          'created_at':
              remote['createdAt']?.toString() ??
              existing?['created_at'] as String? ??
              DateTime.now().toIso8601String(),
          'updated_at':
              remote['updatedAt']?.toString() ??
              DateTime.now().toIso8601String(),
          'sync_state': SyncState.synced.name,
          'pending_delete': existing?['pending_delete'] ?? 0,
        };

        await txn.insert(
          'documents',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  DocItem _mapRow(Map<String, Object?> row) {
    final ext = (row['file_ext'] as String? ?? '').toLowerCase();
    final type = _typeForExtension(ext);
    final rawTags = row['tags_json'] as String? ?? '[]';
    final decodedTags = (jsonDecode(rawTags) as List<dynamic>).cast<String>();

    return DocItem(
      id: row['local_id'] as String,
      type: type,
      name: row['file_name'] as String,
      title: row['title'] as String,
      url: row['remote_public_url'] as String?,
      date: row['created_at'] as String,
      localPath: row['local_file_path'] as String?,
      tags: decodedTags,
      syncState: SyncState.values.byName(row['sync_state'] as String),
    );
  }

  String _typeForExtension(String extension) {
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'].contains(extension)) {
      return 'image';
    }
    if (extension == 'pdf') return 'pdf';
    return 'doc';
  }

  String _mimeTypeFor(String extension) {
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }
}
