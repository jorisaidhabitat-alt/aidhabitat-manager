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
    //
    // ⚠️ On EXCLUT `payload_json` du SELECT initial pour éviter les
    // OOM (out-of-memory) sur iPad. Quand l'utilisateur a accumulé
    // plusieurs ops `upload_file` stuck (chacune avec un dataUrl base64
    // de plusieurs MB dans payload_json), un SELECT * chargeait tout
    // en RAM → SqliteException(7) : out of memory. Reporté
    // 2026-04-29 : « SqfliteFfiException(sqlite_error: 7, out of
    // memory) … SELECT * FROM sync_operations WHERE status IN (?, ?) ».
    // payload_json est lu lazily PAR OP via `fetchPayloadJson` quand
    // `_processOperation` le réclame.
    final rows = await db.query(
      'sync_operations',
      columns: const [
        'id',
        'entity_type',
        'entity_local_id',
        'operation_type',
        'status',
        'attempt_count',
        'last_error',
        'created_at',
        'updated_at',
      ],
      where: 'status IN (?, ?)',
      whereArgs: [
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
      orderBy: 'created_at ASC',
    );

    final now = DateTime.now();
    final eligibleRows = <Map<String, Object?>>[];
    for (final row in rows) {
      final attempts = row['attempt_count'] as int? ?? 0;
      final updatedAt = DateTime.tryParse(row['updated_at'] as String? ?? '');
      // Backoff par op dès la 1ère tentative échouée. Evite la boucle
      // tight "échec transitoire → retry immédiat → échec → …" sur les
      // ops qui cassent le sync cycle. Progression : attempts=1→10s,
      // attempts=2→30s, attempts=3→60s, attempts=4→120s, capé à 5 min.
      if (attempts >= 1 && updatedAt != null) {
        final backoffSeconds = _computeOpBackoffSeconds(attempts);
        if (now.difference(updatedAt).inSeconds < backoffSeconds) {
          continue;
        }
      }
      eligibleRows.add(row);
    }

    // Lit le `payload_json` UN PAR UN pour les ops éligibles → max 1
    // payload en RAM à la fois côté ce loader (le sync engine va de
    // toute façon les itérer en série après).
    final out = <SyncOperation>[];
    for (final row in eligibleRows) {
      final id = row['id'] as String;
      final payloadRows = await db.query(
        'sync_operations',
        columns: const ['payload_json'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (payloadRows.isEmpty) continue;
      out.add(SyncOperation(
        id: id,
        entityType: row['entity_type'] as String,
        entityLocalId: row['entity_local_id'] as String,
        operationType: row['operation_type'] as String,
        payloadJson: payloadRows.first['payload_json'] as String,
        status:
            SyncOperationStatus.values.byName(row['status'] as String),
        attemptCount: row['attempt_count'] as int? ?? 0,
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

  /// Marque une op comme `completed` UNIQUEMENT si elle est encore
  /// `running`. Si entre temps l'utilisateur a tapé d'autres caractères
  /// (donc `dossier_repository.updatePatient` a fait `INSERT(replace)`
  /// sur la même `id`, ce qui repasse le row à `pending` avec un
  /// nouveau payload), la transition est rejetée → le row reste
  /// `pending` avec sa payload fraîche, le SyncEngine la repushera au
  /// prochain cycle, et l'utilisateur ne perd PAS sa frappe. C'est le
  /// fix de la race « Bro → B » (avril 2026).
  Future<void> markCompleted({
    required String operationId,
    required String entityType,
    required String entityLocalId,
  }) async {
    final updated = await _updateOperation(
      operationId: operationId,
      status: SyncOperationStatus.completed,
      clearError: true,
      expectedStatus: SyncOperationStatus.running,
    );
    if (updated == 0) {
      // L'op a été remplacée par une nouvelle version `pending` pendant
      // le PATCH en vol. Ne PAS marquer l'entité `synced` — il y a une
      // mutation locale plus récente à pousser. On laisse la nouvelle
      // op `pending` faire son travail au prochain cycle.
      return;
    }
    final db = await _database.database;
    await _updateEntitySyncState(
      db: db,
      entityType: entityType,
      entityLocalId: entityLocalId,
      syncState: SyncState.synced,
    );
  }

  /// Marque une op comme `failed` UNIQUEMENT si elle est encore
  /// `running` (cf. `markCompleted` pour le rationale du verrou). Si
  /// l'op a été remplacée par une version `pending` pendant le PATCH en
  /// vol, la transition est rejetée → le row reste `pending` avec sa
  /// payload fraîche, et n'est PAS marqué `failed` (sinon on
  /// déclencherait un bandeau rouge UI alors que la mutation suivante
  /// va potentiellement réussir).
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
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, SyncOperationStatus.running.name],
      limit: 1,
    );
    if (rows.isEmpty) {
      // L'op a été remplacée pendant le PATCH — laisser le row `pending`
      // tel quel, il sera retenté au prochain cycle.
      return;
    }
    final attempts = rows.first['attempt_count'] as int? ?? 0;

    final updated = await db.update(
      'sync_operations',
      {
        'status': SyncOperationStatus.failed.name,
        'attempt_count': attempts + 1,
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, SyncOperationStatus.running.name],
    );
    if (updated == 0) {
      // Race : la transition pending→running a été annulée juste avant
      // notre UPDATE. Identique au cas `rows.isEmpty` ci-dessus.
      return;
    }

    await _updateEntitySyncState(
      db: db,
      entityType: entityType,
      entityLocalId: entityLocalId,
      syncState: SyncState.syncError,
    );
  }

  /// Backoff par opération après échec transitoire. Progression :
  /// attempts=1→10s, 2→30s, 3→60s, 4→120s, 5+→300s (capé à 5 min).
  /// Appelé uniquement par [fetchRunnableOperations] pour filtrer les
  /// ops qu'il faut laisser reposer.
  static int _computeOpBackoffSeconds(int attempts) {
    if (attempts <= 0) return 0;
    const schedule = [10, 30, 60, 120, 300];
    return schedule[(attempts - 1).clamp(0, schedule.length - 1)];
  }

  /// Total des opérations "en attente" pour affichage UI (bandeau,
  /// compteur) : inclut aussi bien les ops retentables immédiatement
  /// que celles en cours de backoff — l'utilisateur doit voir qu'il y
  /// a encore du travail en file même si rien n'est exécuté tout de
  /// suite. Ne compte pas les ops `completed` ni `conflict`.
  Future<int> countPendingOperations() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM sync_operations '
      'WHERE status IN (?, ?)',
      [
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
    );
    if (rows.isEmpty) return 0;
    final v = rows.first['cnt'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// Réhabilite les opérations `failed` dont le message d'erreur ressemble
  /// à un problème transitoire (5xx serveur, timeout, déconnexion…) en
  /// les repassant à `pending` pour qu'elles soient retentées. Laisse les
  /// vraies erreurs fonctionnelles (4xx, payload invalide…) en `failed`.
  ///
  /// Appelé au début de chaque cycle de sync pour auto-guérir les
  /// opérations qui se sont accumulées en `failed` à cause d'un hoquet
  /// serveur (notamment les ops de note_page qui ont fait planter la
  /// prod avec des 500 dans le passé).
  ///
  /// **Limite d'âge** : on ne réhabilite QUE les ops créées dans les
  /// 24 dernières heures. Sinon une vieille op `failed` (genre saisie
  /// d'il y a 3 semaines en mode offline qui n'a jamais réussi à
  /// passer) finissait par être repêchée et écrasait NocoDB avec un
  /// payload obsolète — symptôme « le nom revient à une version
  /// antérieure tout seul » signalé le 2026-04-28. Au-delà de 24h, le
  /// payload est considéré comme dépassé : l'utilisateur peut soit
  /// vider la file via `discardFailedOperations` (UI : bouton « Vider
  /// les échecs »), soit refaire la modif manuellement.
  /// Réhabilite les `upload_file` ops `failed` — AGGRESSIVELY (même
  /// pour des erreurs non-transient). Pourquoi ce traitement spécial :
  /// le serveur déduplique les uploads via `documentLocalId` (cf.
  /// `/api/documents` POST côté server/index.mjs), donc un retry est
  /// idempotent — au pire on perd 1 round-trip réseau, jamais de
  /// double-création.
  ///
  /// Cas couverts par ce rehab (vs `rehabilitateTransientFailures`
  /// qui ne match que les patterns d'erreur transient) :
  ///   - 4xx persistants (ex. session expirée, CORS, etc.)
  ///   - SyntaxError, RangeError, parse errors (la 1ère tentative a pu
  ///     se faire avant un fix de schéma)
  ///   - Erreurs non-classifiées
  ///
  /// Limite d'âge : 7 jours (vs 24 h pour le rehab générique). Les
  /// uploads sont du contenu user (photos, rapports) qu'on ne veut
  /// surtout pas perdre par "oubli de retry".
  ///
  /// Appelé automatiquement à chaque ouverture de l'écran Documents
  /// (cf. `data_service.refreshDocumentsFromRemote`) → l'utilisateur
  /// n'a plus jamais à clear le cache pour débloquer un upload bloqué.
  Future<int> rehabFailedDocumentUploads() async {
    final db = await _database.database;
    final ageCutoff = DateTime.now()
        .subtract(const Duration(days: 7))
        .toIso8601String();
    final n = await db.rawUpdate(
      '''
      UPDATE sync_operations
      SET status = ?, updated_at = ?, attempt_count = 0, last_error = NULL
      WHERE status = ?
        AND operation_type = 'upload_file'
        AND created_at > ?
      ''',
      [
        SyncOperationStatus.pending.name,
        DateTime.now().toIso8601String(),
        SyncOperationStatus.failed.name,
        ageCutoff,
      ],
    );
    if (n > 0) {
      // ignore: avoid_print
      print('[sync] rehabFailedDocumentUploads : $n op(s) repassée(s) en pending');
    }
    return n;
  }

  Future<int> rehabilitateTransientFailures() async {
    final db = await _database.database;
    final ageCutoff = DateTime.now()
        .subtract(const Duration(hours: 24))
        .toIso8601String();
    // On reset `attempt_count` à 0 en plus du status. Sinon, après un
    // épisode CORS/Vercel-SSO qui a fait échouer 5+ fois la même op,
    // le backoff (`_computeOpBackoffSeconds`) la maintient en attente
    // pendant 5 minutes — l'utilisateur voit l'op « En attente » sans
    // comprendre qu'elle ne sera pas tentée tout de suite. Réhabiliter
    // c'est admettre que la cause de l'échec est passée, donc un budget
    // de tentatives frais est légitime. Si l'op échoue à nouveau, elle
    // re-démarre le cycle de backoff normal à attempt_count=1.
    final rehabilitated = await db.rawUpdate(
      '''
      UPDATE sync_operations
      SET status = ?, updated_at = ?, attempt_count = 0
      WHERE status = ?
        AND created_at > ?
        AND (
          last_error LIKE '%500%'
          OR last_error LIKE '%502%'
          OR last_error LIKE '%503%'
          OR last_error LIKE '%504%'
          OR last_error LIKE '%timeout%' COLLATE NOCASE
          OR last_error LIKE '%SocketException%'
          OR last_error LIKE '%ClientException%'
          OR last_error LIKE '%HttpException%'
          OR last_error LIKE '%TransientRemoteException%'
          OR last_error LIKE '%Remote note sync failed%'
          OR last_error LIKE '%Remote document upload failed%'
          OR last_error LIKE '%Document upload network error%'
          OR last_error LIKE '%network error%' COLLATE NOCASE
          OR last_error LIKE '%XMLHttpRequest error%' COLLATE NOCASE
          OR last_error LIKE '%Failed to fetch%' COLLATE NOCASE
          OR last_error LIKE '%CORS%' COLLATE NOCASE
          OR last_error LIKE '%(401)%'
          OR last_error LIKE '%(403)%'
        )
      ''',
      [
        SyncOperationStatus.pending.name,
        DateTime.now().toIso8601String(),
        SyncOperationStatus.failed.name,
        ageCutoff,
      ],
    );
    return rehabilitated;
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
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, SyncOperationStatus.running.name],
      limit: 1,
    );
    if (rows.isEmpty) {
      // L'op a été remplacée par une version `pending` plus récente
      // pendant le PATCH en vol — ne pas écraser. La nouvelle version
      // contient déjà la donnée la plus récente et sera retentée.
      return;
    }
    final attempts = rows.first['attempt_count'] as int? ?? 0;

    final updated = await db.update(
      'sync_operations',
      {
        'status': SyncOperationStatus.pending.name,
        'attempt_count': attempts + 1,
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, SyncOperationStatus.running.name],
    );
    if (updated == 0) {
      return;
    }

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
    final updated = await db.update(
      'sync_operations',
      {
        'status': 'conflict',
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, SyncOperationStatus.running.name],
    );
    if (updated == 0) {
      // L'op a été remplacée pendant le PATCH par une version `pending`
      // plus récente — la nouvelle version va re-PATCHer avec la
      // dernière donnée locale et résoudra (ou pas) le conflit serveur
      // de son côté. Ne pas marquer l'entité en `conflict` ici : on
      // ferait clignoter l'UI à tort.
      return;
    }

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
    final n1 = await db.delete(
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

    // Purge d'URGENCE des ops dont le `payload_json` est énorme (>500KB,
    // typiquement un dataUrl base64 d'un fichier de plusieurs MB) ET
    // qui ont déjà raté ≥ 3 fois. Ces ops sont la cause des OOM
    // (out-of-memory) sur SQLite reportés 2026-04-29 :
    //   « SqfliteFfiException(sqlite_error: 7, out of memory)
    //    while selecting from sync_operations ».
    //
    // Une op bloated qui a échoué 3+ fois est presque certainement
    // doomed (limite serveur, erreur permanente). On la drop pour
    // libérer la RAM. L'utilisateur peut re-uploader si besoin via l'UI.
    //
    // Note : les ops avec petit payload_json restent en place quelle
    // que soit leur attempt_count (le rehab les retentera).
    final n2 = await db.rawDelete(
      'DELETE FROM sync_operations WHERE '
      'status IN (?, ?) AND '
      'attempt_count >= 3 AND '
      'length(payload_json) > 500000',
      [
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
    );
    if (n2 > 0) {
      // ignore: avoid_print
      print(
        '[sync] purge URGENCE OOM : $n2 op(s) avec payload >500KB et '
        'attempt_count ≥ 3 supprimée(s) → libère la RAM',
      );
    }
    return n1 + n2;
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

  /// Débloque les entités historiquement marquées `conflict` dans les
  /// tables `dossiers` / `patients` / `housings` / `documents` /
  /// `note_pages`. Pour chacune :
  ///   1. Reset son `sync_state` à `synced` (le prochain pull NocoDB
  ///      pourra alors appliquer le merge sans skipper la ligne).
  ///   2. Purge les ops `sync_operations` pending/failed/conflict qui
  ///      la concernent.
  ///
  /// Renvoie le nombre TOTAL de lignes débloquées (somme des updates
  /// sur les 5 tables — utile pour le log de boot).
  ///
  /// Demande utilisateur 2026-04-30 : « il ne faut aucun bouton ni
  /// intervention tout doit se faire tout seul en backend » →
  /// l'écran de résolution de conflit n'est plus nécessaire, on
  /// applique systématiquement la version serveur.
  Future<int> unstickConflictedEntities() async {
    final db = await _database.database;
    var total = 0;
    const tables = [
      'dossiers',
      'patients',
      'housings',
      'documents',
      'note_pages',
    ];
    for (final table in tables) {
      final updated = await db.update(
        table,
        {'sync_state': SyncState.synced.name},
        where: 'sync_state = ?',
        whereArgs: [SyncState.conflict.name],
      );
      total += updated;
    }
    // Purge des ops `conflict` (le `purgeStalePendingOperations` ne
    // touche que les `failed` / `running` ; les `conflict` restaient
    // en queue pour toujours). Au passage on prend aussi les `failed`
    // au cas où — `discardFailedOperations` existe mais purge tout
    // sans cibler les entités unstuck-ées, ce qu'on veut justement.
    await db.delete(
      'sync_operations',
      where: 'status = ?',
      whereArgs: ['conflict'],
    );
    return total;
  }

  /// Met à jour le statut d'une `sync_operation`. Si [expectedStatus] est
  /// fourni, la transition n'a lieu QUE si le row est actuellement dans
  /// cet état — sinon `0` est renvoyé (no-op). Crucial pour le verrou
  /// par status="running" qui empêche un `markCompleted` de squasher
  /// un row qui a été remplacé par une nouvelle version pending pendant
  /// que le PATCH HTTP était en vol (cf. fix race « Bro → B »).
  ///
  /// Renvoie le nombre de lignes effectivement mises à jour (0 ou 1).
  Future<int> _updateOperation({
    required String operationId,
    required SyncOperationStatus status,
    required bool clearError,
    SyncOperationStatus? expectedStatus,
  }) async {
    final db = await _database.database;
    final values = <String, Object?>{
      'status': status.name,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (clearError) {
      values['last_error'] = null;
    }
    if (expectedStatus == null) {
      return db.update(
        'sync_operations',
        values,
        where: 'id = ?',
        whereArgs: [operationId],
      );
    }
    return db.update(
      'sync_operations',
      values,
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, expectedStatus.name],
    );
  }

  Future<void> _updateEntitySyncState({
    required Database db,
    required String entityType,
    required String entityLocalId,
    required SyncState syncState,
  }) async {
    // Bindings entity_type → table:colonne. Avant ce mapping complet,
    // les types `patient` / `housing` / `contexte_de_vie` /
    // `diagnostic_sanitaires` / `visit_recommendations` n'avaient PAS
    // de binding → leur sync_state restait à `pendingSync` indéfiniment
    // après un push réussi. Conséquence : `mergeRemoteDossierPayloads`
    // ne pouvait pas détecter qu'un patient avait une op en cours et
    // l'écrasait avec les données du serveur (qui pouvaient encore
    // refléter l'ancienne valeur en cas de eventual consistency NocoDB)
    // → flash visuel "le nom a disparu pendant quelques secondes".
    final binding = switch (entityType) {
      'dossier' => const _EntityBinding('dossiers', 'local_id'),
      'patient' => const _EntityBinding('patients', 'local_id'),
      'housing' => const _EntityBinding('housings', 'local_id'),
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
