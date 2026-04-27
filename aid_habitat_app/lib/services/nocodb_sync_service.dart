import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'app_config.dart';
import 'connectivity_service.dart';
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

  /// Lit la valeur `remote_updated_at` de la ligne locale identifiée
  /// par [idColumn] = [idValue] dans [table]. Renvoie `null` si la
  /// ligne n'existe pas ou si la colonne est vide.
  ///
  /// Utilisé pour câbler le contrôle d'optimistic concurrency au push :
  /// la valeur retournée est passée au serveur dans
  /// `expectedUpdatedAt`, et `sendConflictIfStale()` (server/index.mjs)
  /// renvoie 409 si le serveur a une version plus récente.
  Future<String?> _readRemoteUpdatedAt({
    required String table,
    required String idColumn,
    required String idValue,
  }) async {
    final db = await LocalDatabase.instance.database;
    final rows = await db.query(
      table,
      columns: ['remote_updated_at'],
      where: '$idColumn = ?',
      whereArgs: [idValue],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final v = rows.first['remote_updated_at'];
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  Future<SyncRunResult> pushPendingChanges() async {
    // Auto-guérison : réhabilite toute opération précédemment marquée
    // `failed` dont l'erreur ressemble à un 5xx / timeout / déconnexion,
    // pour qu'elle soit retentée silencieusement à ce cycle. Évite que
    // de vieux 500 serveur restent bloqués en "failed" côté iPad après
    // un correctif serveur (et empêche le bandeau rouge de persister
    // sur des ops que la prochaine tentative ferait réussir).
    try {
      final rehabCount =
          await _syncRepository.rehabilitateTransientFailures();
      if (rehabCount > 0) {
        // ignore: avoid_print
        print('[sync] $rehabCount opération(s) réhabilitée(s) depuis failed');
      }
    } catch (_) {
      // La réhabilitation est best-effort : une erreur ne doit pas
      // empêcher la suite du cycle.
    }

    final operations = await _syncRepository.fetchRunnableOperations();
    if (operations.isEmpty) {
      return const SyncRunResult(
        pushedOperations: 0,
        failedOperations: 0,
        message: 'Aucune opération à synchroniser',
      );
    }

    // Si on est offline, on ne lance AUCUN appel réseau — les opérations
    // restent en `pending` et repartiront quand la connectivité revient
    // (ConnectivityService appelle `onConnectivityBack` qui re-trigger
    // le sync). Sans ce guard, chaque op essaye un fetch → échoue en
    // TimeoutException ou SocketException → `markFailed` → bandeau
    // rouge "Synchronisation en échec" alors que c'est juste "en
    // attente de réseau".
    if (ConnectivityService().isOffline) {
      return SyncRunResult(
        pushedOperations: 0,
        failedOperations: 0,
        message:
            'Hors ligne — ${operations.length} '
            'opération${operations.length > 1 ? 's' : ''} en attente',
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
      } on TransientRemoteException catch (e) {
        // 5xx / timeout / déconnexion : l'op reste en pending pour être
        // rejouée silencieusement au prochain cycle. On ne remonte rien
        // à l'UI (pas de bandeau rouge) — c'est un hoquet réseau, pas
        // une vraie erreur métier.
        // ignore: avoid_print
        print('[sync] transient ${operation.entityType}:'
            '${operation.operationType} id=${operation.entityLocalId} '
            'err=$e — retry au prochain cycle');
        await _syncRepository.markTransientFailure(
          operationId: operation.id,
          entityType: operation.entityType,
          entityLocalId: operation.entityLocalId,
          error: e.toString(),
        );
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
      } on ConflictException catch (e) {
        // 409 serveur (optimistic concurrency) — l'op et l'entity row
        // sont marquées `conflict`. Pas de retry : c'est l'écran de
        // résolution qui prendra la main quand l'utilisateur ré-ouvre
        // le dossier.
        await _syncRepository.markConflict(
          operationId: operation.id,
          entityType: operation.entityType,
          entityLocalId: operation.entityLocalId,
          error: e.message,
        );
        failures.add('${operation.entityType}:conflit');
        // Stop le groupe : pas la peine de continuer à pousser des
        // ops sur la même entity quand on sait qu'il y a divergence.
        break;
      } on TransientRemoteException catch (e) {
        // ignore: avoid_print
        print('[sync] transient ${operation.entityType}:'
            '${operation.operationType} id=${operation.entityLocalId} '
            'err=$e — retry au prochain cycle');
        await _syncRepository.markTransientFailure(
          operationId: operation.id,
          entityType: operation.entityType,
          entityLocalId: operation.entityLocalId,
          error: e.toString(),
        );
        // Pas de break : les ops transitoires n'invalident pas la suite
        // (le serveur peut avoir juste un hoquet éphémère).
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
      case 'wiki_item':
        await _processWikiItemOperation(operation, payload);
        return;
      case 'retirement_fund':
        await _processRetirementFundOperation(operation, payload);
        return;
      case 'access_member':
        await _processAccessMemberOperation(operation, payload);
        return;
      case 'profile_photo':
        await _processProfilePhotoOperation(operation, payload);
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
    // Optimistic concurrency : on transmet le timestamp serveur connu
    // localement. Le serveur (sendConflictIfStale) renvoie 409 si la
    // ligne a été modifiée depuis — l'op est alors marquée `conflict`
    // et l'écran de résolution est proposé à l'utilisateur.
    final expected = await _readRemoteUpdatedAt(
      table: 'dossiers',
      idColumn: 'local_id',
      idValue: dossierId,
    );
    final updatesWithGuard = <String, dynamic>{
      ...updates,
      if (expected != null) 'expectedUpdatedAt': expected,
    };
    // ignore: avoid_print
    print('[sync] PATCH /api/dossiers/$dossierId (contexte) '
        'keys=${updates.keys.toList()} '
        'expectedUpdatedAt=${expected ?? "null"}');
    await _apiClient.updateDossier(
      dossierId: dossierId,
      updates: updatesWithGuard,
    );
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
    // Optimistic concurrency (cf. _processContexteDeVieOperation).
    final expected = await _readRemoteUpdatedAt(
      table: 'patients',
      idColumn: 'local_id',
      idValue: localId,
    );
    final updatesWithGuard = <String, dynamic>{
      ...updates,
      if (expected != null) 'expectedUpdatedAt': expected,
    };
    // ignore: avoid_print
    print('[sync] PATCH /api/beneficiaires/$remoteId '
        'updates=${updates.keys.toList()} '
        'expectedUpdatedAt=${expected ?? "null"}');
    await _apiClient.updateBeneficiary(
      patientId: remoteId,
      updates: updatesWithGuard,
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
    // Optimistic concurrency : on s'appuie sur la `housing_local_id`
    // référencée par le dossier pour récupérer le timestamp serveur du
    // logement (le `local_id` du logement est `housing_<dossierId>`).
    final db = await LocalDatabase.instance.database;
    final dRows = await db.query(
      'dossiers',
      columns: ['housing_local_id'],
      where: 'local_id = ?',
      whereArgs: [dossierLocalId],
      limit: 1,
    );
    final housingLocalId = dRows.isEmpty
        ? null
        : dRows.first['housing_local_id'] as String?;
    final expected = housingLocalId == null
        ? null
        : await _readRemoteUpdatedAt(
            table: 'housings',
            idColumn: 'local_id',
            idValue: housingLocalId,
          );
    final updatesWithGuard = <String, dynamic>{
      ...updates,
      if (expected != null) 'expectedUpdatedAt': expected,
    };
    // ignore: avoid_print
    print('[sync] PATCH /api/logements/by-beneficiary/$remoteId '
        'updates=${updates.keys.toList()} '
        'expectedUpdatedAt=${expected ?? "null"}');
    await _apiClient.updateLogement(
      beneficiaryId: remoteId,
      updates: updatesWithGuard,
    );
    if (housingLocalId != null) {
      await db.update(
        'housings',
        {'sync_state': SyncState.synced.name},
        where: 'local_id = ?',
        whereArgs: [housingLocalId],
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
    final dataUrl = payload['dataUrl']?.toString();
    final title = payload['title']?.toString() ?? 'Document';
    final fileName = payload['fileName']?.toString() ?? 'document.bin';
    final mimeType =
        payload['mimeType']?.toString() ?? 'application/octet-stream';
    final tags =
        (payload['tags'] as List?)?.map((tag) => '$tag').toList() ?? [];

    if (patientId == null ||
        documentLocalId == null ||
        patientId.isEmpty ||
        documentLocalId.isEmpty) {
      throw Exception('Payload document incomplet');
    }

    File? file;
    List<int>? bytes;

    if (localPath != null && localPath.isNotEmpty) {
      file = File(localPath);
      if (!await file.exists()) {
        throw Exception('Fichier local introuvable: $localPath');
      }
    } else if (dataUrl != null && dataUrl.isNotEmpty) {
      // Web path: bytes stored as a data URL in SQLite. Decode and upload.
      final comma = dataUrl.indexOf(',');
      if (comma < 0) {
        throw Exception('dataUrl malformé (pas de séparateur)');
      }
      bytes = base64Decode(dataUrl.substring(comma + 1));
    } else {
      throw Exception(
        'Payload document: ni localPath ni dataUrl fourni',
      );
    }

    final uploaded = await _apiClient.uploadDocument(
      patientId: patientId,
      documentLocalId: documentLocalId,
      title: title,
      fileName: fileName,
      mimeType: mimeType,
      tags: tags,
      file: file,
      bytes: bytes,
    );

    await _syncRepository.storeDocumentRemoteData(
      documentLocalId: operation.entityLocalId,
      remotePath: uploaded['remotePath']?.toString() ?? '',
      publicUrl: uploaded['publicUrl']?.toString() ?? '',
    );
  }

  /// Pushes a wiki item create/update. For `create`, the local row was
  /// inserted with a temporary `local_draft_*` id — after the remote call
  /// returns, we swap the local id for the server-assigned one so future
  /// edits go through `update` instead of `create`. The pending image data
  /// URL column is cleared on success so it's not re-uploaded.
  Future<void> _processWikiItemOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    final db = await LocalDatabase.instance.database;
    final imageDataUrl = payload['imageDataUrl']?.toString() ?? '';

    if (operation.operationType == 'create') {
      final title = payload['title']?.toString() ?? '';
      final description = payload['description']?.toString() ?? '';
      final category = payload['category']?.toString() ?? '';
      final tags = (payload['tags'] as List?)
              ?.map((t) => t.toString())
              .toList() ??
          const <String>[];
      final localId = operation.entityLocalId;

      if (title.isEmpty) throw Exception('Titre wiki obligatoire');

      final saved = await _apiClient.createWikiItem(
        title: title,
        description: description,
        category: category,
        tags: tags,
        imageDataUrl: imageDataUrl,
      );
      // Replace the local draft row (id = localId) with the remote one.
      await db.transaction((txn) async {
        await txn.delete(
          'wiki_items',
          where: 'id = ?',
          whereArgs: [localId],
        );
        final now = DateTime.now().toIso8601String();
        await txn.insert('wiki_items', {
          'id': saved.id,
          'title': saved.title,
          'description': saved.description,
          'image_url': saved.imageUrl,
          'tags_json': jsonEncode(saved.tags),
          'category': saved.category,
          'created_at': saved.createdAt,
          'updated_at': saved.updatedAt,
          'last_synced_at': now,
          'pending_image_data_url': null,
          'sync_state': SyncState.synced.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
      return;
    }

    if (operation.operationType == 'update') {
      final itemId = payload['itemId']?.toString() ?? operation.entityLocalId;
      final title = payload['title']?.toString() ?? '';
      final description = payload['description']?.toString() ?? '';
      final category = payload['category']?.toString() ?? '';
      final tags = (payload['tags'] as List?)
              ?.map((t) => t.toString())
              .toList() ??
          const <String>[];

      final saved = await _apiClient.updateWikiItem(
        itemId: itemId,
        item: WikiItem(
          id: itemId,
          title: title,
          description: description,
          imageUrl: payload['imageUrl']?.toString() ?? '',
          tags: tags,
          category: category,
          createdAt: payload['createdAt']?.toString() ?? '',
          updatedAt: payload['updatedAt']?.toString() ?? '',
        ),
        imageDataUrl: imageDataUrl.isEmpty ? null : imageDataUrl,
      );
      final now = DateTime.now().toIso8601String();
      await db.update(
        'wiki_items',
        {
          'title': saved.title,
          'description': saved.description,
          'image_url': saved.imageUrl,
          'tags_json': jsonEncode(saved.tags),
          'category': saved.category,
          'updated_at': saved.updatedAt,
          'last_synced_at': now,
          'pending_image_data_url': null,
          'sync_state': SyncState.synced.name,
        },
        where: 'id = ?',
        whereArgs: [itemId],
      );
      return;
    }

    throw Exception('Opération wiki_item non supportée: ${operation.operationType}');
  }

  /// Pushes a retirement fund update. The fund payload comes fully serialized
  /// from the repository.
  Future<void> _processRetirementFundOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'update') {
      throw Exception(
        'Opération retirement_fund non supportée: ${operation.operationType}',
      );
    }
    final fundId = payload['fundId']?.toString() ?? operation.entityLocalId;
    final fundMap = (payload['fund'] as Map?)?.cast<String, dynamic>();
    if (fundMap == null) throw Exception('Payload retirement_fund incomplet');

    final fund = RetirementFund(
      id: fundId,
      name: fundMap['name']?.toString() ?? '',
      phone: fundMap['phone']?.toString() ?? '',
      audience: fundMap['audience']?.toString() ?? '',
      requestMethod: fundMap['requestMethod']?.toString() ?? '',
      requestDelay: fundMap['requestDelay']?.toString() ?? '',
      aidAmount: fundMap['aidAmount']?.toString() ?? '',
      therapistNote: fundMap['therapistNote']?.toString() ?? '',
      website: fundMap['website']?.toString() ?? '',
      logoUrl: fundMap['logoUrl']?.toString() ?? '',
    );

    final saved = await _apiClient.updateRetirementFund(
      fundId: fundId,
      fund: fund,
    );

    final db = await LocalDatabase.instance.database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'retirement_funds',
      {
        'name': saved.name,
        'phone': saved.phone,
        'audience': saved.audience,
        'request_method': saved.requestMethod,
        'request_delay': saved.requestDelay,
        'aid_amount': saved.aidAmount,
        'therapist_note': saved.therapistNote,
        'website': saved.website,
        'logo_url': saved.logoUrl,
        'last_edited_at': saved.lastEditedAt,
        'last_synced_at': now,
        'pending_logo_data_url': null,
        'sync_state': SyncState.synced.name,
      },
      where: 'id = ?',
      whereArgs: [fundId],
    );
  }

  /// Admin access mutations are no longer generated by the app (the page
  /// was removed — everything is managed directly on NocoDB to avoid sync
  /// conflicts). Any leftover `access_member` operation in the queue from
  /// a previous app version is silently marked complete so the engine
  /// doesn't retry it forever.
  Future<void> _processAccessMemberOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    // Intentionally empty — treated as a successful no-op.
    return;
  }

  /// Pushes a profile photo upload. The local row keeps its SQLite-encoded
  /// data URL until the server returns the resolved public URL.
  Future<void> _processProfilePhotoOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'upload') {
      throw Exception(
        'Opération profile_photo non supportée: ${operation.operationType}',
      );
    }
    final userLocalId = payload['userLocalId']?.toString() ??
        operation.entityLocalId;
    final dataUrl = payload['imageDataUrl']?.toString() ?? '';
    if (dataUrl.isEmpty) throw Exception('Payload profile_photo incomplet');

    final photoUrl = await _apiClient.uploadProfilePhoto(dataUrl);

    final db = await LocalDatabase.instance.database;
    await db.update(
      'app_users',
      {
        'profile_photo_url': photoUrl,
        'pending_photo_data_url': null,
        'sync_state': SyncState.synced.name,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [userLocalId],
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
