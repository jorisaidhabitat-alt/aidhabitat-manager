import 'dart:convert';
import 'dart:io';

import '../models/types.dart';
import 'app_config.dart';
import 'local_database.dart';
import 'nocodb_api_client.dart';
import 'sync_repository.dart';

/// Indicates that a sync operation was rejected due to a conflict (HTTP 409).
/// The engine should NOT retry these -- they require user resolution.
class SyncConflictException implements Exception {
  final String message;
  final Map<String, dynamic>? remoteData;

  SyncConflictException(this.message, {this.remoteData});

  @override
  String toString() => 'SyncConflictException: $message';
}

class NocodbSyncService {
  NocodbSyncService({
    NocodbApiClient? apiClient,
    SyncRepository? syncRepository,
  }) : _apiClient = apiClient ?? NocodbApiClient(),
       _syncRepository = syncRepository ?? SyncRepository();

  final NocodbApiClient _apiClient;
  final SyncRepository _syncRepository;

  /// Maximum number of entities processed in parallel. Operations on the
  /// same entity (same entity_type + entity_local_id) always run sequentially
  /// to preserve ordering, but different entities can sync concurrently.
  static const int _maxConcurrency = 4;

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

    // Group operations by entity key so same-entity ops stay sequential
    // while different entities can proceed in parallel.
    final groups = <String, List<SyncOperation>>{};
    for (final op in operations) {
      final key = '${op.entityType}:${op.entityLocalId}';
      groups.putIfAbsent(key, () => []).add(op);
    }

    var pushed = 0;
    var failed = 0;
    var conflicts = 0;
    final failures = <String>[];
    final groupList = groups.values.toList();

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
      } on ConflictException catch (e) {
        // Server returned 409 — mark as conflict, do not retry automatically.
        await _syncRepository.markConflict(
          operationId: operation.id,
          entityType: operation.entityType,
          entityLocalId: operation.entityLocalId,
          error: e.message,
        );
        conflicts += 1;
        failures.add('${operation.entityType}:conflit');
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

    final message = (failed == 0 && conflicts == 0)
        ? 'Synchronisation terminée'
        : conflicts > 0
            ? 'Synchronisation : $conflicts conflit${conflicts > 1 ? 's' : ''} à résoudre'
            : 'Synchronisation partielle. Échecs: ${failures.join(', ')}';

    return SyncRunResult(
      pushedOperations: pushed,
      failedOperations: failed,
      conflictCount: conflicts,
      message: message,
    );
  }

  Future<_GroupResult> _processGroup(List<SyncOperation> group) async {
    var pushed = 0;
    var failed = 0;
    final failures = <String>[];

    for (final operation in group) {
      await _syncRepository.markRunning(operation.id);
      try {
        await _processOperation(operation);
        await _syncRepository.markCompleted(
          operationId: operation.id,
          entityType: operation.entityType,
          entityLocalId: operation.entityLocalId,
        );
        pushed += 1;
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          '[sync] ÉCHEC ${operation.entityType}:${operation.operationType} '
          'id=${operation.entityLocalId} err=$error',
        );
        // ignore: avoid_print
        print(stack);
        await _syncRepository.markFailed(
          operationId: operation.id,
          entityType: operation.entityType,
          entityLocalId: operation.entityLocalId,
          error: error.toString(),
        );
        failed += 1;
        failures.add('${operation.entityType}:${operation.operationType}');
        // Don't keep pushing ops for an entity that just failed — stop this
        // group so we don't clobber remote state with stale follow-ups.
        break;
      }
    }

    return _GroupResult(pushed: pushed, failed: failed, failures: failures);
  }

  Future<void> _processOperation(SyncOperation operation) async {
    final payload = jsonDecode(operation.payloadJson) as Map<String, dynamic>;

    switch (operation.entityType) {
      case 'dossier':
        await _processDossierOperation(operation, payload);
        return;
      case 'patient':
        await _processPatientOperation(operation, payload);
        return;
      case 'housing':
        await _processHousingOperation(operation, payload);
        return;
      case 'document':
        await _processDocumentOperation(operation, payload);
        return;
      case 'note_page':
        await _processNotePageOperation(operation, payload);
        return;
      case 'contexte_de_vie':
        await _processContexteDeVieOperation(operation, payload);
        return;
      case 'diagnostic_sanitaires':
        await _processDiagnosticSanitairesOperation(operation, payload);
        return;
      case 'visit_recommendations':
        await _processVisitRecommendationsOperation(operation, payload);
        return;
      default:
        throw Exception(
          'Type d\'operation non supporte: ${operation.entityType}',
        );
    }
  }

  /// Pushes a Contexte de vie update (medical context + autonomy
  /// checklists) via `PATCH /api/dossiers/:dossierId`. The server's
  /// `upsertContexte` reads `medicalContext` + `autonomy` from the body
  /// and writes them into the NocoDB context table.
  Future<void> _processContexteDeVieOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'update') {
      throw Exception(
        'Opération contexte de vie non supportée: ${operation.operationType}',
      );
    }
    final dossierId = payload['dossierId']?.toString();
    final updates = (payload['updates'] as Map?)?.cast<String, dynamic>();
    if (dossierId == null || dossierId.isEmpty || updates == null) {
      throw Exception('Payload contexte de vie incomplet');
    }
    // ignore: avoid_print
    print('[sync] PATCH /api/dossiers/$dossierId (contexte) '
        'keys=${updates.keys.toList()}');
    await _apiClient.updateDossier(dossierId: dossierId, updates: updates);
    // Mark the local contexte_de_vie row as synced.
    final db = await LocalDatabase.instance.database;
    await db.update(
      'contexte_de_vie',
      {'sync_state': SyncState.synced.name},
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
    );
  }

  /// Pushes a Diagnostic sanitaires update (salle de bain + WC instances)
  /// via `PUT /api/diagnostic-sanitaires/:dossierId`.
  Future<void> _processDiagnosticSanitairesOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'update') {
      throw Exception(
        'Opération diagnostic sanitaires non supportée: ${operation.operationType}',
      );
    }
    final dossierId = payload['dossierId']?.toString();
    if (dossierId == null || dossierId.isEmpty) {
      throw Exception('Payload diagnostic sanitaires incomplet');
    }
    final sdb = (payload['sdbInstances'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    final wc = (payload['wcInstances'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    // ignore: avoid_print
    print(
      '[sync] PUT /api/diagnostic-sanitaires/$dossierId '
      'sdb=${sdb.length} wc=${wc.length}',
    );
    await _apiClient.updateDiagnosticSanitaires(
      dossierId: dossierId,
      sdbInstances: sdb,
      wcInstances: wc,
    );
    final db = await LocalDatabase.instance.database;
    await db.update(
      'diagnostic_sanitaires',
      {'sync_state': SyncState.synced.name},
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
    );
  }

  /// Pushes the visit recommendations list (wiki-linked items + notes) via
  /// `PUT /api/visit-recommendations/:dossierId`.
  Future<void> _processVisitRecommendationsOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'update') {
      throw Exception(
        'Opération visit recommendations non supportée: ${operation.operationType}',
      );
    }
    final dossierId = payload['dossierId']?.toString();
    if (dossierId == null || dossierId.isEmpty) {
      throw Exception('Payload visit recommendations incomplet');
    }
    final items = (payload['items'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    // ignore: avoid_print
    print('[sync] PUT /api/visit-recommendations/$dossierId '
        'count=${items.length}');
    await _apiClient.updateVisitRecommendations(
      dossierId: dossierId,
      items: items,
    );
    final db = await LocalDatabase.instance.database;
    await db.update(
      'visit_recommendations',
      {'sync_state': SyncState.synced.name},
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
    );
  }

  /// Pushes a patient update (beneficiary) to NocoDB via the Express API.
  /// The [payload]'s `patientLocalId` is used to look up the remote ID in
  /// the local `patients` table — if missing, we fall back to the local id
  /// itself since the server accepts either a synthetic id like
  /// `nocodb-beneficiaire-123` or a free-form appBeneficiaryId resolved
  /// via linked records.
  Future<void> _processPatientOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'update') {
      throw Exception(
        'Opération patient non supportée: ${operation.operationType}',
      );
    }
    final localId = payload['patientLocalId']?.toString();
    final updates = (payload['updates'] as Map?)?.cast<String, dynamic>();
    if (localId == null || localId.isEmpty || updates == null) {
      throw Exception('Payload patient incomplet');
    }
    final remoteId = await _resolveRemotePatientId(localId) ?? localId;
    // ignore: avoid_print
    print('[sync] PATCH /api/beneficiaires/$remoteId  updates=${updates.keys.toList()}');
    await _apiClient.updateBeneficiary(
      patientId: remoteId,
      updates: updates,
    );
    // Mark as synced locally once the push succeeds.
    final db = await LocalDatabase.instance.database;
    await db.update(
      'patients',
      {'sync_state': SyncState.synced.name},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Pushes a housing update to NocoDB. The housing row is resolved to a
  /// beneficiary remote ID by joining `dossiers` and `patients`.
  Future<void> _processHousingOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'update') {
      throw Exception(
        'Opération housing non supportée: ${operation.operationType}',
      );
    }
    final dossierLocalId = payload['dossierLocalId']?.toString();
    final updates = (payload['updates'] as Map?)?.cast<String, dynamic>();
    if (dossierLocalId == null ||
        dossierLocalId.isEmpty ||
        updates == null) {
      throw Exception('Payload housing incomplet');
    }
    final remoteId =
        await _resolveRemoteBeneficiaryIdFromDossier(dossierLocalId) ??
            dossierLocalId;
    // ignore: avoid_print
    print('[sync] PATCH /api/logements/by-beneficiary/$remoteId  updates=${updates.keys.toList()}');
    await _apiClient.updateLogement(
      beneficiaryId: remoteId,
      updates: updates,
    );
    final db = await LocalDatabase.instance.database;
    final rows = await db.query('dossiers',
        columns: ['housing_local_id'],
        where: 'local_id = ?',
        whereArgs: [dossierLocalId],
        limit: 1);
    if (rows.isNotEmpty) {
      final housingId = rows.first['housing_local_id'] as String;
      await db.update(
        'housings',
        {'sync_state': SyncState.synced.name},
        where: 'local_id = ?',
        whereArgs: [housingId],
      );
    }
  }

  Future<String?> _resolveRemotePatientId(String localId) async {
    final db = await LocalDatabase.instance.database;
    final rows = await db.query(
      'patients',
      columns: ['remote_patient_id'],
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final remote = rows.first['remote_patient_id'] as String?;
    if (remote == null || remote.isEmpty) return null;
    return remote;
  }

  Future<String?> _resolveRemoteBeneficiaryIdFromDossier(
      String dossierLocalId) async {
    final db = await LocalDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT p.remote_patient_id
      FROM dossiers d
      INNER JOIN patients p ON p.local_id = d.patient_local_id
      WHERE d.local_id = ?
      LIMIT 1
    ''', [dossierLocalId]);
    if (rows.isEmpty) return null;
    final remote = rows.first['remote_patient_id'] as String?;
    if (remote == null || remote.isEmpty) return null;
    return remote;
  }

  Future<void> _processDossierOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType == 'create') {
      final firstName = payload['firstName']?.toString() ?? '';
      final lastName = payload['lastName']?.toString() ?? '';
      final ergoId = payload['ergoId']?.toString() ?? '';
      final dossierLocalId = payload['dossierLocalId']?.toString() ?? '';
      final patientLocalId = payload['patientLocalId']?.toString() ?? '';

      if (lastName.isEmpty) {
        throw Exception('Nom du bénéficiaire obligatoire');
      }

      final result = await _apiClient.createBeneficiary(fields: {
        'firstName': firstName,
        'lastName': lastName,
        'ergoId': ergoId,
      });

      // Store the remote IDs locally so future updates reference them.
      final remotePatientId = result['id']?.toString();
      final remoteDossierId = result['dossierId']?.toString();
      if (remotePatientId != null && remotePatientId.isNotEmpty) {
        await _syncRepository.storeRemoteIds(
          patientLocalId: patientLocalId,
          remotePatientId: remotePatientId,
          dossierLocalId: dossierLocalId,
          remoteDossierId: remoteDossierId,
        );
      }
      return;
    }

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
      file: file,
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

    // Déduire scopeType depuis tabKey (parité React) :
    //  - tabs du relevé de visite → 'visit_report'
    //  - onglet Plans → 'visit_grid'
    //  - tout le reste (notes rapides du dossier, etc.) → 'dossier_detail'
    const visitReportTabs = {
      'Bénéficiaire', 'Contexte de vie', 'Mesures',
      'Accessibilité', 'Salle de bain', 'WC', 'Préconisations',
    };
    final scopeTypeFromPayload = payload['scopeType']?.toString();
    final scopeIdFromPayload = payload['scopeId']?.toString();
    final scopeType = scopeTypeFromPayload?.isNotEmpty == true
        ? scopeTypeFromPayload!
        : (tabKey == 'Plans'
            ? 'visit_grid'
            : visitReportTabs.contains(tabKey)
                ? 'visit_report'
                : 'dossier_detail');
    final scopeId = scopeIdFromPayload?.isNotEmpty == true
        ? scopeIdFromPayload
        : (payload['dossierId']?.toString() ?? patientId);

    // Les bénéficiaires de seed local (mock) n'existent pas côté NocoDB —
    // on saute la sync pour éviter une boucle d'échecs 404 stériles. Les
    // patients remote ont un id de la forme "nocodb-beneficiaire-<n>" ou un
    // UUID ; les mocks locaux ont des id courts comme "p1", "p2", etc.
    final looksRemote = patientId.startsWith('nocodb-') ||
        patientId.contains('-') && patientId.length > 20;
    if (!looksRemote) {
      // On ne fait rien — l'opération est considérée comme traitée.
      return;
    }

    final notePage = await _apiClient.upsertNotePage(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: pageNumber,
      drawingJson: drawingJson,
      scopeType: scopeType,
      scopeId: scopeId,
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
  final int conflictCount;
  final String message;

  const SyncRunResult({
    required this.pushedOperations,
    required this.failedOperations,
    this.conflictCount = 0,
    required this.message,
  });
}

class _GroupResult {
  final int pushed;
  final int failed;
  final List<String> failures;

  const _GroupResult({
    required this.pushed,
    required this.failed,
    required this.failures,
  });
}
