import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';
import 'media_cache_service.dart';
import 'sync_engine.dart';

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

  /// Web-friendly import that takes bytes + metadata directly (no
  /// [File]) since PWAs don't have a filesystem. The bytes are stored as
  /// a `data:<mime>;base64,…` URL in `documents.local_file_data_url` and
  /// the sync processor decodes them when pushing to NocoDB.
  Future<DocItem> importDocumentBytes({
    required String patientId,
    required List<int> bytes,
    required String fileName,
    List<String> tags = const ['Autre'],
    String? title,
  }) async {
    final db = await _database.database;
    final now = DateTime.now();
    final extension = p
        .extension(fileName)
        .replaceFirst('.', '')
        .toLowerCase();
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : p.basenameWithoutExtension(fileName);
    final localId = 'doc_${now.microsecondsSinceEpoch}';
    final mimeType = _mimeTypeFor(extension);
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';

    final row = {
      'local_id': localId,
      'patient_local_id': patientId,
      'title': resolvedTitle,
      'file_name': fileName,
      'file_ext': extension,
      'mime_type': mimeType,
      'local_file_path': null,
      'local_file_data_url': dataUrl,
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
        'dataUrl': dataUrl,
        'title': resolvedTitle,
        'fileName': fileName,
        'mimeType': mimeType,
        'tags': tags,
      }),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });

    SyncEngine().notify();
    return _mapRow(row);
  }

  Future<DocItem> importDocument({
    required String patientId,
    required File sourceFile,
    List<String> tags = const ['Autre'],
    String? title,
  }) async {
    final db = await _database.database;
    final now = DateTime.now();
    final extension = p
        .extension(sourceFile.path)
        .replaceFirst('.', '')
        .toLowerCase();
    final baseName = p.basename(sourceFile.path);
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : p.basenameWithoutExtension(sourceFile.path);
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
      'title': resolvedTitle,
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
        'title': resolvedTitle,
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

    SyncEngine().notify();

    return _mapRow(row);
  }

  /// Re-upload d'un document existant avec le même `documentLocalId` et un
  /// fichier "flattened" (image + annotations aplaties). Le serveur remplace
  /// l'asset existant sur dedup par `documentLocalId`. Appelé après un save
  /// d'annotation image/PDF — les annotations deviennent ainsi visibles sur
  /// l'exemplaire NocoDB téléchargé depuis l'app React ou un tiers.
  Future<void> enqueueAnnotatedReupload({
    required String documentId,
    required String flattenedPath,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      where: 'local_id = ?',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final patientId = row['patient_local_id'] as String;
    final title = row['title'] as String? ?? 'Document';
    final originalName = row['file_name'] as String? ?? 'document.bin';
    // Nom de fichier côté serveur : on force l'extension .png puisque le
    // flatten produit un PNG (valable aussi pour les PDFs annotés aplatis
    // à une page).
    final flatName =
        '${p.basenameWithoutExtension(originalName)}-annoté.png';
    final now = DateTime.now().toIso8601String();
    final tagsJson = row['tags_json'] as String? ?? '[]';
    final tags = (jsonDecode(tagsJson) as List<dynamic>).cast<String>();

    // Supprime toute opération d'upload en attente pour ce doc — on ne veut
    // pas pousser successivement deux versions.
    await db.delete(
      'sync_operations',
      where:
          'entity_local_id = ? AND entity_type = ? AND status IN (?, ?)',
      whereArgs: [
        documentId,
        'document',
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
    );

    // Marque le doc comme pendingSync pour que l'UI (pastille, compteur)
    // reflète l'attente.
    await db.update(
      'documents',
      {'sync_state': SyncState.pendingSync.name, 'updated_at': now},
      where: 'local_id = ?',
      whereArgs: [documentId],
    );

    await db.insert('sync_operations', {
      'id': 'sync_${documentId}_${DateTime.now().microsecondsSinceEpoch}',
      'entity_type': 'document',
      'entity_local_id': documentId,
      'operation_type': 'upload_file',
      'payload_json': jsonEncode({
        'patientLocalId': patientId,
        'documentLocalId': documentId,
        'localPath': flattenedPath,
        'title': title,
        'fileName': flatName,
        'mimeType': 'image/png',
        'tags': tags,
      }),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    });

    SyncEngine().notify();
  }

  Future<void> updateDocumentMetadata({
    required String documentId,
    required String title,
    required List<String> tags,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'documents',
      {
        'title': title,
        'tags_json': jsonEncode(tags),
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      },
      where: 'local_id = ?',
      whereArgs: [documentId],
    );
    SyncEngine().notify();
  }

  Future<void> deleteDocument(String documentId) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'documents',
      {
        'pending_delete': 1,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      },
      where: 'local_id = ?',
      whereArgs: [documentId],
    );
    // Cancel any pending upload operation — the document is being removed
    // before it ever reached the remote, so the upload is moot.
    await db.delete(
      'sync_operations',
      where: 'entity_local_id = ? AND status IN (?, ?)',
      whereArgs: [
        documentId,
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
    );
    SyncEngine().notify();
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

    // Warm the media cache so document previews (PDFs, images) work offline
    // after the first sync of this dossier.
    unawaited(_prefetchDocumentAssets(remoteDocuments));
  }

  Future<void> _prefetchDocumentAssets(
    List<Map<String, dynamic>> remoteDocuments,
  ) async {
    final urls = <String>{};
    for (final doc in remoteDocuments) {
      final url = doc['publicUrl']?.toString().trim() ?? '';
      if (url.isNotEmpty) urls.add(url);
    }
    if (urls.isEmpty) return;
    try {
      await MediaCacheService.instance.prefetchAll(urls);
    } catch (_) {
      // Best effort — one failed doc shouldn't block others.
    }
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
      // Web-only: the freshly captured bytes as a data URL. Populated by
      // `importDocumentBytes` on web and cleared once the sync processor
      // uploads them.
      dataUrl: row['local_file_data_url'] as String?,
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
