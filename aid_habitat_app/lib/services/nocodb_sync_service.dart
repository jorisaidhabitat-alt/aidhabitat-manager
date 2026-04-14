import 'dart:convert';
import 'dart:io';

import '../models/types.dart';
import 'app_config.dart';
import 'nocodb_api_client.dart';
import 'sync_repository.dart';

class NocodbSyncService {
  NocodbSyncService({
    NocodbApiClient? apiClient,
    SyncRepository? syncRepository,
  }) : _apiClient = apiClient ?? NocodbApiClient(),
       _syncRepository = syncRepository ?? SyncRepository();

  final NocodbApiClient _apiClient;
  final SyncRepository _syncRepository;

  Future<SyncRunResult> pushPendingChanges() async {
    final operations = await _syncRepository.fetchRunnableOperations();
    if (operations.isEmpty) {
      return const SyncRunResult(
        pushedOperations: 0,
        failedOperations: 0,
        message: 'Aucune opération à synchroniser',
      );
    }

    if (!AppConfig.hasRemoteConfig) {
      for (final operation in operations) {
        await _syncRepository.markFailed(
          operationId: operation.id,
          entityType: operation.entityType,
          entityLocalId: operation.entityLocalId,
          error: 'Configuration NocoDB absente',
        );
      }
      return SyncRunResult(
        pushedOperations: 0,
        failedOperations: operations.length,
        message: 'Configuration NocoDB absente',
      );
    }

    var pushed = 0;
    var failed = 0;
    final failures = <String>[];

    for (final operation in operations) {
      await _syncRepository.markRunning(operation.id);
      try {
        await _processOperation(operation);
        await _syncRepository.markCompleted(
          operationId: operation.id,
          entityType: operation.entityType,
          entityLocalId: operation.entityLocalId,
        );
        pushed += 1;
      } catch (error) {
        final message = error.toString();
        await _syncRepository.markFailed(
          operationId: operation.id,
          entityType: operation.entityType,
          entityLocalId: operation.entityLocalId,
          error: message,
        );
        failed += 1;
        failures.add('${operation.entityType}:${operation.operationType}');
      }
    }

    final message = failed == 0
        ? 'Synchronisation terminée'
        : 'Synchronisation partielle. Échecs: ${failures.join(', ')}';

    return SyncRunResult(
      pushedOperations: pushed,
      failedOperations: failed,
      message: message,
    );
  }

  Future<void> _processOperation(SyncOperation operation) async {
    final payload = jsonDecode(operation.payloadJson) as Map<String, dynamic>;

    switch (operation.entityType) {
      case 'dossier':
        await _processDossierOperation(operation, payload);
        return;
      case 'document':
        await _processDocumentOperation(operation, payload);
        return;
      case 'note_page':
        await _processNotePageOperation(operation, payload);
        return;
      default:
        throw Exception(
          'Type d’opération non supporté: ${operation.entityType}',
        );
    }
  }

  Future<void> _processDossierOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType == 'update') {
      final dossierId = payload['dossierId']?.toString();
      final updates = (payload['updates'] as Map?)?.cast<String, dynamic>();
      if (dossierId == null || dossierId.isEmpty || updates == null) {
        throw Exception('Payload dossier incomplet');
      }
      await _apiClient.updateDossier(dossierId: dossierId, updates: updates);
      return;
    }

    if (operation.operationType == 'seed_sync') {
      return;
    }

    throw Exception(
      'Opération dossier non supportée: ${operation.operationType}',
    );
  }

  Future<void> _processDocumentOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'upload_file') {
      throw Exception(
        'Opération document non supportée: ${operation.operationType}',
      );
    }

    final patientId = payload['patientLocalId']?.toString();
    final documentLocalId = payload['documentLocalId']?.toString();
    final localPath = payload['localPath']?.toString();
    final title = payload['title']?.toString() ?? 'Document';
    final fileName = payload['fileName']?.toString() ?? 'document.bin';
    final mimeType =
        payload['mimeType']?.toString() ?? 'application/octet-stream';
    final tags =
        (payload['tags'] as List?)?.map((tag) => '$tag').toList() ?? [];

    if (patientId == null ||
        documentLocalId == null ||
        localPath == null ||
        patientId.isEmpty ||
        documentLocalId.isEmpty ||
        localPath.isEmpty) {
      throw Exception('Payload document incomplet');
    }

    final file = File(localPath);
    if (!await file.exists()) {
      throw Exception('Fichier local introuvable: $localPath');
    }

    final uploaded = await _apiClient.uploadDocument(
      patientId: patientId,
      documentLocalId: documentLocalId,
      title: title,
      fileName: fileName,
      mimeType: mimeType,
      tags: tags,
      contentBase64: base64Encode(await file.readAsBytes()),
    );

    await _syncRepository.storeDocumentRemoteData(
      documentLocalId: operation.entityLocalId,
      remotePath: uploaded['remotePath']?.toString() ?? '',
      publicUrl: uploaded['publicUrl']?.toString() ?? '',
    );
  }

  Future<void> _processNotePageOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'upsert') {
      throw Exception(
        'Opération note non supportée: ${operation.operationType}',
      );
    }

    final patientId = payload['patientLocalId']?.toString();
    final tabKey = payload['tabKey']?.toString();
    final drawingJson = payload['drawingJson']?.toString();
    final pageNumberRaw = payload['pageNumber'];
    final pageNumber = pageNumberRaw is num
        ? pageNumberRaw.toInt()
        : int.tryParse('$pageNumberRaw');

    if (patientId == null ||
        tabKey == null ||
        drawingJson == null ||
        patientId.isEmpty ||
        tabKey.isEmpty ||
        pageNumber == null) {
      throw Exception('Payload note incomplet');
    }

    final notePage = await _apiClient.upsertNotePage(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: pageNumber,
      drawingJson: drawingJson,
    );

    await _syncRepository.storeNotePageRemoteData(
      noteLocalId: operation.entityLocalId,
      remotePath: notePage['remotePath']?.toString() ?? '',
      remoteUrl: notePage['remoteUrl']?.toString() ?? '',
    );
  }
}

class SyncRunResult {
  final int pushedOperations;
  final int failedOperations;
  final String message;

  const SyncRunResult({
    required this.pushedOperations,
    required this.failedOperations,
    required this.message,
  });
}
