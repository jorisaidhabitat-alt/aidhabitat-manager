import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'app_config.dart';
import 'connectivity_service.dart';
import 'document_repository.dart';
import 'dossier_repository.dart';
import 'local_database.dart';
import 'nocodb_api_client.dart';
import 'report_generation_service.dart';
import 'sync_repository.dart';

/// Vrai si l'erreur attrapée par le catch générique du sync engine est
/// en réalité un hoquet réseau (à rejouer silencieusement) plutôt qu'une
/// vraie erreur métier (à remonter à l'UI).
///
/// On capture :
///   - `http.ClientException` → "Load failed" sur Safari iOS / iPad PWA
///     quand la connexion est cancelée par le navigateur (mise en
///     veille, scroll qui interrompt le fetch, cellulaire qui flap…)
///   - `TimeoutException` → la requête a dépassé son `.timeout(...)`
///   - `SocketException` / `HttpException` → erreurs bas niveau Dart
///   - le pattern textuel "Load failed" / "fetch failed" / "Failed to
///     fetch" en fallback (au cas où une de ces exceptions remonterait
///     wrappée dans une `Exception` générique).
///
/// Demande utilisateur 2026-05-05 : « tout fonctionnait bien jusqu'à
/// la partie Accessibilité du VAD » — le PATCH /api/logements échouait
/// en "Load failed" sur iPad et le bandeau rouge bloquait l'ergo.
/// Avec ce reclassement, l'op est rejouée au cycle suivant sans aucune
/// alerte UI.
bool _isTransientErrorLike(Object error) {
  if (error is TimeoutException) return true;
  if (error is SocketException) return true;
  if (error is HttpException) return true;
  if (error is http.ClientException) return true;
  final s = error.toString().toLowerCase();
  return s.contains('load failed') ||
      s.contains('fetch failed') ||
      s.contains('failed to fetch') ||
      s.contains('clientexception');
}

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
    //
    // Demande utilisateur 2026-05-06 : « la synchronisation des
    // documents est trop longue à la connexion ». Avant ce changement,
    // le for-loop itérait `operations` strictement en SÉRIE — chaque
    // upload de photo (1-3 Mo, 5-15s) attendait le précédent.
    // 10 photos en queue = ~1 minute de bandeau « sync ». Maintenant
    // on traite les groupes (= entités) en parallèle, avec un pool
    // de [_maxConcurrency] workers (constante déjà existante sur la
    // classe). Chaque groupe reste séquentiel en interne (préserve
    // l'ordre upload→merge sur la même entité, contrat conservé pour
    // `mergeRemoteDocuments`).
    final groups = <String, List<SyncOperation>>{};
    for (final op in operations) {
      final key = '${op.entityType}:${op.entityLocalId}';
      groups.putIfAbsent(key, () => []).add(op);
    }
    final groupList = groups.values.toList();

    // Pool de workers : chaque worker tire un groupe de la queue
    // partagée, le traite via `_processGroup` (qui gère markRunning /
    // markCompleted / markFailed pour chaque op), et passe au suivant.
    // Dart étant single-threaded, `removeAt(0)` est atomique entre
    // deux awaits — pas besoin de lock.
    final queue = List<List<SyncOperation>>.from(groupList);
    final results = <_GroupResult>[];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final group = queue.removeAt(0);
        final r = await _processGroup(group);
        results.add(r);
      }
    }

    final workerCount = groupList.length < _maxConcurrency
        ? groupList.length
        : _maxConcurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));

    // Agrégation finale des résultats par groupe.
    var pushed = 0;
    var failed = 0;
    final failures = <String>[];
    for (final r in results) {
      pushed += r.pushed;
      failed += r.failed;
      failures.addAll(r.failures);
    }
    // Le compteur `conflicts` était déjà toujours 0 dans l'ancien
    // for-loop (les conflits sont auto-résolus et comptés comme
    // `pushed`). On le garde à 0 pour préserver la sémantique
    // observée par les callers + le banner UI.
    const conflicts = 0;

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
        // Auto-résolution « remote wins » (cf. commentaire identique
        // dans le for-loop principal). On résout puis on continue à
        // pousser les ops suivantes du groupe — utile si l'op
        // suivante est sur un champ différent qui ne conflictera pas.
        await _autoResolveConflictTakingRemote(operation, e);
        pushed += 1;
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
        // Filet de sécurité : reclasse toute erreur réseau bas niveau
        // (incluant `http.ClientException: Load failed` côté iPad PWA)
        // en transitoire — l'op reste en queue et est rejouée au
        // prochain cycle, pas de bandeau rouge. Sans ce reclassement,
        // n'importe quel endpoint d'écriture qui n'est pas wrappé dans
        // `_runWithTransientGuard` produisait un failed définitif au
        // moindre hoquet Safari iOS (rapporté 2026-05-05 sur
        // housing:update / Accessibilité). Préservé lors du passage
        // en pool de workers parallèles 2026-05-06.
        if (_isTransientErrorLike(error)) {
          // ignore: avoid_print
          print('[sync] reclassed-as-transient ${operation.entityType}:'
              '${operation.operationType} id=${operation.entityLocalId} '
              'err=$error — retry au prochain cycle');
          await _syncRepository.markTransientFailure(
            operationId: operation.id,
            entityType: operation.entityType,
            entityLocalId: operation.entityLocalId,
            error: error.toString(),
          );
          // Ne casse PAS le groupe sur transient — les ops suivantes
          // peuvent passer (le serveur a peut-être juste un hoquet
          // éphémère).
          continue;
        }
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

  /// Résout automatiquement un conflit 409 en abandonnant la modif
  /// locale et en faisant gagner la version serveur. Étapes :
  ///
  ///   1. Marque l'op courante comme `completed` (sort de la queue).
  ///   2. Purge TOUTES les ops `pending`/`failed` pour cette entité —
  ///      sans ce wipe, une 2e op du même genre re-tenterait le push
  ///      au cycle suivant et re-déclencherait un 409 → boucle.
  ///   3. Reset le `sync_state` de l'entité à `synced` pour que le
  ///      `mergeRemoteDossierPayloads` du prochain pull NocoDB ne
  ///      skip plus cette ligne (le merge guard `sync_state != synced`
  ///      sautait ces lignes pour ne pas écraser des saisies en
  ///      cours — mais ici on a JUSTEMENT décidé d'abandonner les
  ///      saisies en cours).
  ///   4. Déclenche un pull workspace immédiat (`refreshWorkspaceFromRemote`)
  ///      pour appliquer la version serveur SANS attendre le prochain
  ///      tick périodique du SyncEngine. Best-effort : si le pull
  ///      échoue (offline transitoire), le tick suivant rattrapera.
  ///
  /// Demande utilisateur 2026-04-30 : « il ne faut aucun bouton ni
  /// intervention tout doit se faire tout seul en backend ».
  Future<void> _autoResolveConflictTakingRemote(
    SyncOperation operation,
    ConflictException exception,
  ) async {
    // ignore: avoid_print
    print(
      '[sync] auto-resolve conflict ${operation.entityType}:'
      '${operation.entityLocalId} → take remote (op="${operation.id}", '
      'err="${exception.message}")',
    );
    // 1) L'op courante est résolue de notre point de vue
    await _syncRepository.markCompleted(
      operationId: operation.id,
      entityType: operation.entityType,
      entityLocalId: operation.entityLocalId,
    );
    // 2) Purge des autres ops pour la même entité (évite la boucle
    //    de re-conflict).
    await _syncRepository
        .clearPendingOperationsForEntity(operation.entityLocalId);
    // 3) Reset sync_state pour que le pull suivant fasse son merge
    //    sans skipper l'entité.
    await _syncRepository.setEntitySyncState(
      entityType: operation.entityType,
      entityLocalId: operation.entityLocalId,
      syncState: SyncState.synced,
    );
    // 4) Pull immédiat via le callback injecté par DataService au
    //    démarrage. Évite le cycle d'imports (DataService importe ce
    //    service → on ne peut pas l'importer dans l'autre sens). Si
    //    le callback n'est pas câblé (tests isolés), on tombe sur le
    //    pull périodique du SyncEngine — ~5-30s plus tard.
    final pull = onConflictAutoResolved;
    if (pull != null) {
      try {
        // ignore: avoid_print
        print('[sync] auto-resolve : déclenche pull workspace immédiat');
        await pull();
      } catch (_) {
        // Best-effort — le pull périodique rattrapera.
      }
    }
  }

  /// Callback optionnel câblé par `DataService` au boot pour que ce
  /// service puisse déclencher un pull workspace après une
  /// auto-résolution de conflit, SANS importer DataService directement
  /// (ce qui créerait un cycle d'imports). Cf. `DataService.initialize`.
  Future<void> Function()? onConflictAutoResolved;

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
      case 'mesures_anthropometriques':
        await _processMesuresOperation(operation, payload);
        return;
      case 'observations_synthese':
        await _processObservationsOperation(operation, payload);
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
      case 'report_generation':
        await _processReportGenerationOperation(operation, payload);
        return;
      default:
        throw Exception(
          'Type d\'operation non supporte: ${operation.entityType}',
        );
    }
  }

  /// Génération différée du rapport de visite. Enqueued par
  /// `_generateReport` côté UI quand l'ergo clique « Générer » offline
  /// (ou que la requête réseau échoue). Au tour de sync suivant — quand
  /// la connexion est de retour — le sync engine appelle cette fonction
  /// qui :
  ///   1. Demande au serveur Express le PDF du dossier
  ///      (`POST /api/reports/visit/:dossierId`).
  ///   2. Insère le résultat comme document local taggé « Rapport »
  ///      via `DocumentRepository.importDocumentBytes` — cette fonction
  ///      enqueue à son tour un `upload_file` op qui pousse le PDF vers
  ///      l'espace Documents NocoDB du dossier au cycle suivant.
  ///
  /// Idempotence : l'op est de type 'generate' avec un id unique
  /// `report_gen_<dossierId>` (ConflictAlgorithm.replace côté
  /// `enqueueReportGeneration`) — donc deux clics « Générer » offline
  /// d'affilée ne produisent qu'un seul rapport.
  ///
  /// Retry : si la requête échoue (serveur down, 5xx), le sync engine
  /// la marque transient et la retentera au cycle suivant. Si elle
  /// échoue avec une 4xx définitive (dossier hors scope), elle passe
  /// en `failed` et l'utilisateur voit l'erreur dans la pastille de
  /// sync de la sidebar.
  Future<void> _processReportGenerationOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'generate') {
      throw Exception(
        'Opération report_generation non supportée: ${operation.operationType}',
      );
    }
    final dossierId = payload['dossierId']?.toString() ?? '';
    final patientId = payload['patientId']?.toString() ?? '';
    if (dossierId.isEmpty || patientId.isEmpty) {
      throw Exception('Payload report_generation incomplet '
          '(dossierId="$dossierId", patientId="$patientId")');
    }
    // ignore: avoid_print
    print('[sync] POST /api/reports/visit/$dossierId (generation différée)');
    final result = await _apiClient.downloadVisitReport(dossierId: dossierId);
    // ignore: avoid_print
    print('[sync] PDF reçu (${result.bytes.length} bytes), import local…');
    final fileName = result.fileName;
    final title = fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');

    // DEUX CHEMINS selon que le serveur a sauvegardé le PDF directement
    // dans NocoDB (header X-Saved-Doc-Uuid) ou non. Bug fix 2026-05-11 :
    // avant ce changement, le path différé utilisait TOUJOURS
    // `importDocumentBytes` (qui queue un upload_file op). Pour un PDF
    // de 9 MB, cet upload échouait avec 413 Vercel (body limit 4.5 MB)
    // → le doc restait stuck "en attente" indéfiniment côté iPad. Avec
    // le savedDocUuid, on bypass le ré-upload et on insère direct comme
    // `synced` (le serveur a déjà tout sauvegardé).
    if (result.savedDocUuid != null && result.savedDocUuid!.isNotEmpty) {
      // ignore: avoid_print
      print('[sync] doc déjà en NocoDB (uuid=${result.savedDocUuid}) '
          '→ import remote-only synced (pas de re-upload)');
      await DocumentRepository().importDocumentRemoteOnly(
        patientId: patientId,
        dossierId: dossierId,
        bytes: result.bytes,
        fileName: fileName,
        title: title.isEmpty ? 'Rapport de visite' : title,
        tags: const ['Rapport'],
        remoteUuid: result.savedDocUuid!,
        clientDocumentId: 'doc_report_$dossierId',
      );
    } else {
      // Fallback compat (rare — server-side save échoué) : ancien chemin.
      // localId déterministe par dossier → REPLACE plutôt que créer un
      // nouveau doc à chaque retry de l'op `report_generation`. Sans
      // ça, un retry créait une nouvelle ligne `documents` à chaque
      // fois (15 documents observés pour 1 click — bug reporté
      // 2026-04-30). Cf. `importDocumentBytes` qui gère le replace +
      // la préservation des annotations.
      await DocumentRepository().importDocumentBytes(
        patientId: patientId,
        dossierId: dossierId,
        bytes: result.bytes,
        fileName: fileName,
        title: title.isEmpty ? 'Rapport de visite' : title,
        tags: const ['Rapport'],
        localId: 'doc_report_$dossierId',
      );
    }
    // ignore: avoid_print
    print('[sync] document "Rapport" inséré localement (id=doc_report_$dossierId)');
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

  /// Push des mesures anthropométriques via `PUT /api/mesures/:dossierId`.
  /// Avant cette méthode, les saisies (taille debout, hauteur d'assise,
  /// profondeur genoux, hauteur coudes) ne quittaient JAMAIS l'iPad —
  /// `upsertMesures` n'enqueueait pas de sync_op.
  Future<void> _processMesuresOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'update') {
      throw Exception(
        'Opération mesures non supportée: ${operation.operationType}',
      );
    }
    final dossierId = payload['dossierId']?.toString();
    final updates = (payload['updates'] as Map?)?.cast<String, dynamic>();
    if (dossierId == null || dossierId.isEmpty || updates == null) {
      throw Exception('Payload mesures incomplet');
    }
    // ignore: avoid_print
    print('[sync] PUT /api/mesures/$dossierId '
        'keys=${updates.keys.toList()}');
    await _apiClient.updateMesures(
      dossierId: dossierId,
      updates: updates,
    );
    final db = await LocalDatabase.instance.database;
    await db.update(
      'mesures_anthropometriques',
      {'sync_state': SyncState.synced.name},
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
    );
  }

  /// Push des observations de synthèse via
  /// `PUT /api/observations/:dossierId`. Alimente les pages 6 et 7 du
  /// rapport PDF (« Projet ou souhait de l'usager », « Résumé des
  /// préconisations », « Observation sur les équipements »).
  Future<void> _processObservationsOperation(
    SyncOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation.operationType != 'update') {
      throw Exception(
        'Opération observations non supportée: ${operation.operationType}',
      );
    }
    final dossierId = payload['dossierId']?.toString();
    final updates = (payload['updates'] as Map?)?.cast<String, dynamic>();
    if (dossierId == null || dossierId.isEmpty || updates == null) {
      throw Exception('Payload observations incomplet');
    }
    // ignore: avoid_print
    print('[sync] PUT /api/observations/$dossierId '
        'keys=${updates.keys.toList()}');
    await _apiClient.updateObservations(
      dossierId: dossierId,
      updates: updates,
    );
    final db = await LocalDatabase.instance.database;
    await db.update(
      'observations_synthese',
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

      // GARDE D'IDEMPOTENCE — si la création a déjà abouti côté serveur
      // lors d'un cycle précédent (POST réussi mais réponse perdue : Wi-Fi
      // coupé entre l'écriture NocoDB et la réception côté Flutter →
      // l'op est marquée failed/transient → réhabilitation automatique
      // → re-POST → DUPLICATE), `patients.remote_patient_id` est déjà
      // populé localement. Dans ce cas on saute le POST pour éviter de
      // créer un doublon. C'est la cause racine du bug rapporté
      // « JORIS Try → JORIS BALS enregistré 2× en JORIS ESS » :
      // l'op create rejouait, créait une 2e ligne orpheline, et l'update
      // tapait sur la 2e (la 1ère gardait l'ancien nom).
      if (patientLocalId.isNotEmpty) {
        final existingRemoteId =
            await _syncRepository.resolveRemotePatientId(patientLocalId);
        if (existingRemoteId != null && existingRemoteId.isNotEmpty) {
          // ignore: avoid_print
          print('[sync] dossier:create skip — déjà créé côté serveur '
              '(patientLocalId=$patientLocalId remoteId=$existingRemoteId)');
          return;
        }
      }

      // Champs admin demandés à la création (CreateBeneficiaryScreen
      // depuis 2026-04-30). Tous optionnels pour rester compat avec
      // les sync_operations héritées d'avant cette date — qui ont
      // juste firstName/lastName/ergoId.
      final natureAccompagnement = payload['natureAccompagnement']?.toString() ?? '';
      final numberPeopleRaw = payload['numberPeople'];
      final numberPeople = numberPeopleRaw is num
          ? numberPeopleRaw.toInt()
          : (numberPeopleRaw is String ? int.tryParse(numberPeopleRaw) : null);
      final fiscalRevenueRaw = payload['fiscalRevenue'];
      final fiscalRevenue = fiscalRevenueRaw is num
          ? fiscalRevenueRaw.toDouble()
          : (fiscalRevenueRaw is String ? double.tryParse(fiscalRevenueRaw) : null);
      final address = payload['address']?.toString() ?? '';
      final city = payload['city']?.toString() ?? '';
      final zipCode = payload['zipCode']?.toString() ?? '';

      final result = await _apiClient.createBeneficiary(fields: {
        'firstName': firstName,
        'lastName': lastName,
        'ergoId': ergoId,
        // Clé d'idempotence — le serveur l'utilise pour retrouver une
        // création précédente partiellement aboutie (cf. patch serveur
        // associé dans `server/index.mjs`). Sans cette clé, le serveur
        // n'a aucun moyen de distinguer un retry d'un vrai nouveau dossier.
        if (patientLocalId.isNotEmpty) 'clientLocalId': patientLocalId,
        if (natureAccompagnement.isNotEmpty)
          'natureAccompagnement': natureAccompagnement,
        if (numberPeople != null && numberPeople > 0)
          'numberPeople': numberPeople,
        if (fiscalRevenue != null) 'fiscalRevenue': fiscalRevenue,
        if (address.isNotEmpty) 'address': address,
        if (city.isNotEmpty) 'city': city,
        if (zipCode.isNotEmpty) 'zipCode': zipCode,
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
      // Si le `dossierId` est un local_* (= dossier créé offline et
      // pas encore poussé côté serveur), on tente de résoudre le
      // remote_dossier_id (`uuid_source` NocoDB) depuis SQLite. Sans
      // ça, le serveur reçoit `local_…` qu'il ne reconnaît pas et
      // renvoie 404 → "Load failed" côté iPad. Si la résolution
      // échoue (= la création n'a vraiment jamais abouti), on lève
      // une exception transitoire pour que l'op soit retry au
      // prochain cycle (la création a probablement réussi entre-temps).
      String urlDossierId = dossierId;
      if (dossierId.startsWith('local_')) {
        final remote = await _syncRepository.resolveRemoteDossierId(dossierId);
        if (remote != null && remote.isNotEmpty) {
          urlDossierId = remote;
        } else {
          throw TransientRemoteException(
            'Dossier $dossierId pas encore synchronisé — retry au prochain cycle',
          );
        }
      }
      await _apiClient.updateDossier(dossierId: urlDossierId, updates: updates);
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
    // Branche `delete_document` : enqueued par
    // `DocumentRepository.deleteDocument` quand le doc avait déjà été
    // poussé sur NocoDB. On envoie un DELETE puis on supprime
    // définitivement la ligne locale (sinon `mergeRemoteDocuments` la
    // laissait avec `pending_delete=1` indéfiniment).
    if (operation.operationType == 'delete_document') {
      final remoteId = payload['remoteDocumentId']?.toString() ?? '';
      if (remoteId.isEmpty) {
        // Pas de remote id → le doc n'a jamais été poussé, on purge
        // simplement le local.
        await _purgeLocalDocument(operation.entityLocalId);
        return;
      }
      await _apiClient.deleteDocument(remoteId);
      await _purgeLocalDocument(operation.entityLocalId);
      return;
    }
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

  /// Supprime définitivement la ligne `documents` locale après que
  /// `DELETE /api/documents/<id>` a réussi côté serveur. Avant ce helper,
  /// `pending_delete=1` restait indéfiniment dans la DB et au prochain
  /// `mergeRemoteDocuments` le doc pouvait soit être ressuscité (si
  /// encore présent côté serveur faute de DELETE), soit rester en
  /// purgatoire local.
  Future<void> _purgeLocalDocument(String localId) async {
    if (localId.isEmpty) return;
    final db = await LocalDatabase.instance.database;
    await db.delete(
      'documents',
      where: 'local_id = ?',
      whereArgs: [localId],
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

    // Phase d'un dessin Plans (avant / apres / null) — saveDrawingJson
    // et setPlanPhase la propagent dans le payload de la sync_op.
    final planPhase = payload['planPhase']?.toString();
    // Aperçu PNG rasterisé du canvas (data URL). Renseigné par
    // `_persistForKey` dans plan_canvas.dart pour alimenter les pages
    // 9/10 du rapport PDF. Optionnel — si absent, le serveur garde la
    // dernière valeur connue.
    final previewDataUrl = payload['previewDataUrl']?.toString();
    final notePage = await _apiClient.upsertNotePage(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: pageNumber,
      drawingJson: drawingJson,
      scopeType: scopeType,
      scopeId: scopeId,
      planPhase: (planPhase == 'avant' || planPhase == 'apres')
          ? planPhase
          : null,
      previewDataUrl: previewDataUrl,
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
