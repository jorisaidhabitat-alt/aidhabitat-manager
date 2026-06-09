import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import '../models/visit_report_categories.dart';
import 'local_database.dart';
import 'offline_vault.dart';
import 'sync_engine.dart';

/// Container plat pour un plan (page de l'onglet Plans) à embarquer
/// **inline** dans la requête HTTP de génération PDF. Construit par
/// [NoteRepository.fetchPlanReportInlineBytes].
///
/// Les bytes proviennent du `previewDataUrl` rasterisé au moment de la
/// dernière sauvegarde par `plan_canvas.dart`. Comme cette data URL
/// n'est PAS persistée dans la table `note_pages` locale (trop gros),
/// on la lit depuis le payload de la `sync_op` en attente — qui la
/// contient justement pour l'envoyer au serveur. Élégant : la queue de
/// sync devient aussi notre cache d'images inline pour le report.
class InlinePlanBytes {
  InlinePlanBytes({
    required this.localId,
    required this.planPhase,
    required this.pageNumber,
    required this.bytes,
    this.scopeId,
    this.mimeType = 'image/png',
  });

  final String localId;
  final String planPhase;
  final int pageNumber;
  final String? scopeId;
  final String mimeType;
  final Uint8List bytes;
}

class NoteRow {
  final String textContent;
  final String? drawingJson;

  /// Phase du plan (avant / après travaux) — utilisée uniquement par
  /// les pages de l'onglet Plans pour décider dans quel emplacement
  /// du PDF (page 9 ou page 10 du rapport) le dessin sera injecté.
  /// `null` pour les notes hors onglet Plans, ou pour les plans pas
  /// encore catégorisés par l'ergo.
  final PlanPhase? planPhase;

  const NoteRow({
    required this.textContent,
    required this.drawingJson,
    this.planPhase,
  });
}

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
    return OfflineVault.instance.openNullableString(
      rows.first['drawing_json'] as String?,
    );
  }

  /// Charge les bytes PNG des plans VAD (onglet Plans, phase non-null)
  /// pour un patient/dossier, en vue de les embarquer **inline** dans
  /// la requête de génération PDF. Cf. [InlinePlanBytes] pour la
  /// motivation.
  ///
  /// Stratégie : on join `note_pages` (filtre tab_key='Plans' + phase
  /// non-null + sync_state != synced) avec `sync_operations` (latest
  /// pending op pour cette note) et on pioche `previewDataUrl` dans le
  /// payload JSON. Les plans déjà synchronisés vers NocoDB ne sont
  /// **pas** retournés (le serveur les a déjà via
  /// `mobile_note_pages.preview_data_url`).
  Future<List<InlinePlanBytes>> fetchPlanReportInlineBytes(
    String patientId, {
    String? dossierId,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'note_pages',
      columns: const [
        'local_id',
        'tab_key',
        'page_number',
        'plan_phase',
        'dossier_local_id',
        'sync_state',
      ],
      where:
          'patient_local_id = ? AND tab_key = ? '
          'AND plan_phase IS NOT NULL '
          'AND sync_state != ?',
      whereArgs: [patientId, 'Plans', SyncState.synced.name],
    );

    final result = <InlinePlanBytes>[];
    for (final row in rows) {
      final localId = row['local_id'] as String;
      final phase = row['plan_phase'] as String?;
      if (phase == null || phase.isEmpty) continue;

      // Optionnel : restreindre au scope du dossier passé.
      final rowDossier = row['dossier_local_id'] as String?;
      if (dossierId != null && rowDossier != null && rowDossier != dossierId) {
        continue;
      }

      // Lit `previewDataUrl` dans la sync_op en attente pour ce plan.
      final opRows = await db.query(
        'sync_operations',
        columns: const ['payload_json'],
        where: 'entity_type = ? AND entity_local_id = ?',
        whereArgs: ['note_page', localId],
        orderBy: 'updated_at DESC',
        limit: 1,
      );
      if (opRows.isEmpty) continue;
      final payloadRaw = await OfflineVault.instance.openString(
        opRows.first['payload_json'] as String? ?? '{}',
      );
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(payloadRaw) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final previewDataUrl = payload['previewDataUrl']?.toString();
      if (previewDataUrl == null || previewDataUrl.isEmpty) continue;

      final match = RegExp(
        r'^data:([^;]+);base64,(.+)$',
      ).firstMatch(previewDataUrl);
      if (match == null) continue;
      Uint8List bytes;
      try {
        bytes = base64Decode(match.group(2)!);
      } catch (_) {
        continue;
      }
      if (bytes.isEmpty) continue;

      result.add(
        InlinePlanBytes(
          localId: localId,
          planPhase: phase,
          pageNumber: (row['page_number'] as num?)?.toInt() ?? 0,
          scopeId: rowDossier,
          mimeType: match.group(1) ?? 'image/png',
          bytes: bytes,
        ),
      );
    }
    return result;
  }

  Future<void> saveDrawingJson({
    required String patientId,
    required String tabKey,
    required String drawingJson,
    int pageNumber = 0,
    String? previewDataUrl,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final noteId = 'note_${patientId}_${tabKey}_$pageNumber';
    final operationId = 'sync_$noteId';

    // Préserve `plan_phase` à travers un save : on n'écrase pas la
    // catégorie avant/après travaux quand l'ergo continue de dessiner.
    // (ConflictAlgorithm.replace remet la colonne à NULL par défaut.)
    final existing = await db.query(
      'note_pages',
      columns: ['plan_phase'],
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, tabKey, pageNumber],
      limit: 1,
    );
    final preservedPhase = existing.isNotEmpty
        ? existing.first['plan_phase'] as String?
        : null;

    final drawingJsonAtRest = await OfflineVault.instance.sealString(
      drawingJson,
    );

    await db.insert('note_pages', {
      'local_id': noteId,
      'patient_local_id': patientId,
      'tab_key': tabKey,
      'page_number': pageNumber,
      'text_content': '',
      'drawing_json': drawingJsonAtRest,
      'drawing_local_path': null,
      'drawing_remote_path': null,
      'drawing_remote_url': null,
      'plan_phase': preservedPhase,
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await db.insert('sync_operations', {
      'id': operationId,
      'entity_type': 'note_page',
      'entity_local_id': noteId,
      'operation_type': 'upsert',
      'payload_json': await OfflineVault.instance.sealString(
        jsonEncode({
          'patientLocalId': patientId,
          'tabKey': tabKey,
          'pageNumber': pageNumber,
          'drawingJson': drawingJson,
          if (preservedPhase != null) 'planPhase': preservedPhase,
          // `previewDataUrl` rasterisé côté Flutter (PNG base64). Stocké
          // uniquement dans le payload de la sync_op (pas en SQLite
          // local — gros volume) : le serveur le persiste dans
          // mobile_note_pages.preview_data_url, et le générateur PDF y
          // pioche pour les pages 9/10 (plans avant/après).
          if (previewDataUrl != null && previewDataUrl.isNotEmpty)
            'previewDataUrl': previewDataUrl,
        }),
      ),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    SyncEngine().notify();
  }

  /// Met à jour la phase (avant / après / non classé) d'un dessin de
  /// l'onglet Plans sans toucher à son contenu. Enqueue une sync_op
  /// pour propager la valeur côté NocoDB.
  ///
  /// Si la ligne `note_pages` n'existe pas encore (page créée mais
  /// pas encore enregistrée), on no-op : la phase sera persistée à
  /// la prochaine sauvegarde du dessin via [saveDrawingJson].
  Future<void> setPlanPhase({
    required String patientId,
    required String tabKey,
    required int pageNumber,
    required PlanPhase? phase,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final noteId = 'note_${patientId}_${tabKey}_$pageNumber';
    final operationId = 'sync_$noteId';

    final updated = await db.update(
      'note_pages',
      {
        'plan_phase': planPhaseToDb(phase),
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      },
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, tabKey, pageNumber],
    );
    if (updated == 0) return;

    // Enqueue un upsert qui transporte aussi le drawingJson actuel —
    // évite que le serveur "reset" le dessin parce que la sync_op ne
    // lui parle que de la phase.
    final row = await db.query(
      'note_pages',
      columns: ['drawing_json'],
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, tabKey, pageNumber],
      limit: 1,
    );
    final drawingJson = row.isNotEmpty
        ? await OfflineVault.instance.openString(
            row.first['drawing_json'] as String? ?? '',
          )
        : '';

    await db.insert('sync_operations', {
      'id': operationId,
      'entity_type': 'note_page',
      'entity_local_id': noteId,
      'operation_type': 'upsert',
      'payload_json': await OfflineVault.instance.sealString(
        jsonEncode({
          'patientLocalId': patientId,
          'tabKey': tabKey,
          'pageNumber': pageNumber,
          'drawingJson': drawingJson,
          'planPhase': planPhaseToDb(phase),
        }),
      ),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    SyncEngine().notify();
  }

  /// Lit la phase courante d'un dessin Plans (null = non classé).
  Future<PlanPhase?> fetchPlanPhase({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'note_pages',
      columns: ['plan_phase'],
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, tabKey, pageNumber],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return planPhaseFromDb(rows.first['plan_phase'] as String?);
  }

  /// Fetches the note row for (patientId, tabKey, pageNumber). Returns a
  /// lightweight record with `textContent` + `drawingJson`. Used by the
  /// detached note OS window to load its initial content.
  Future<NoteRow?> fetchNote({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'note_pages',
      columns: ['text_content', 'drawing_json', 'plan_phase'],
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, tabKey, pageNumber],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return NoteRow(
      textContent: await OfflineVault.instance.openString(
        rows.first['text_content'] as String? ?? '',
      ),
      drawingJson: await OfflineVault.instance.openNullableString(
        rows.first['drawing_json'] as String?,
      ),
      planPhase: planPhaseFromDb(rows.first['plan_phase'] as String?),
    );
  }

  /// Updates only the `text_content` of a note, preserving its drawing.
  /// Used by the detached OS note window.
  Future<void> upsertNoteText({
    required String patientId,
    required String tabKey,
    required String textContent,
    int pageNumber = 0,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final noteId = 'note_${patientId}_${tabKey}_$pageNumber';
    final existing = await db.query(
      'note_pages',
      columns: ['drawing_json', 'plan_phase'],
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, tabKey, pageNumber],
      limit: 1,
    );
    final drawingJson = existing.isNotEmpty
        ? await OfflineVault.instance.openString(
            existing.first['drawing_json'] as String? ?? '',
          )
        : '';
    final preservedPhase = existing.isNotEmpty
        ? existing.first['plan_phase'] as String?
        : null;
    await db.insert('note_pages', {
      'local_id': noteId,
      'patient_local_id': patientId,
      'tab_key': tabKey,
      'page_number': pageNumber,
      'text_content': await OfflineVault.instance.sealString(textContent),
      'drawing_json': await OfflineVault.instance.sealString(drawingJson),
      'drawing_local_path': null,
      'drawing_remote_path': null,
      'drawing_remote_url': null,
      'plan_phase': preservedPhase,
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> mergeRemoteNotePage({
    required String patientId,
    required String tabKey,
    required int pageNumber,
    required String drawingJson,
    String? remotePath,
    String? remoteUrl,
    String? updatedAt,
    String? planPhase,
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

    // Stratégie LWW (last-writer-wins) basée sur les timestamps.
    //
    // Avant 2026-05-07 : on skippait simplement si `existingSyncState !=
    // synced`, ce qui bloquait définitivement la propagation cross-
    // device dès qu'une row locale était orpheline en `pendingSync`
    // (ex. push échoué silencieusement, op `failed` non rejouée…).
    // Symptôme reporté : « j'ai modifié la note médicale Contexte de
    // vie de BALS Joris sur iPad, sur Mac ça ne se change pas ».
    //
    // Désormais :
    //  1. Si `remote.updatedAt > local.updated_at` → merge (le serveur
    //     a une version plus récente, on prend, même si la row locale
    //     est `pendingSync`).
    //  2. Si `remote.updatedAt <= local.updated_at` → skip (notre
    //     version locale est plus fraîche, le push en attente la
    //     propagera bientôt).
    //  3. Cas dégradés (timestamps absents / non-parsables) → fallback
    //     sur l'ancien comportement (skip si !synced) pour préserver
    //     le travail local en cours.
    //
    // Le NotesWidget protège déjà la frappe en cours via `_isDirty` →
    // pas de risque d'écraser ce que l'utilisateur tape MAINTENANT,
    // c'est seulement les modifs anciennes orphelines qui peuvent
    // être ratrapées.
    if (existing != null && existingSyncState != SyncState.synced.name) {
      final localUpdatedAt = existing['updated_at'] as String?;
      final remoteIsNewer = _isRemoteUpdatedAtNewer(
        remoteUpdatedAt: updatedAt,
        localUpdatedAt: localUpdatedAt,
      );
      if (!remoteIsNewer) {
        return false;
      }
      // Sinon on tombe en bas pour faire le merge.
    }

    // Si le serveur ne nous renvoie pas explicitement de planPhase
    // (clé absente du payload), on garde celle qui était en local —
    // évite de perdre la catégorisation lors d'un sync passif.
    final mergedPlanPhase = planPhase ?? (existing?['plan_phase'] as String?);

    final preservedTextContent = existing?['text_content'] as String? ?? '';
    final textContentAtRest = await OfflineVault.instance.sealString(
      await OfflineVault.instance.openString(preservedTextContent),
    );
    final drawingJsonAtRest = await OfflineVault.instance.sealString(
      drawingJson,
    );

    await db.insert('note_pages', {
      'local_id':
          existing?['local_id'] as String? ??
          'remote_note_${patientId}_${tabKey}_$pageNumber',
      'patient_local_id': patientId,
      'tab_key': tabKey,
      'page_number': pageNumber,
      'text_content': textContentAtRest,
      'drawing_json': drawingJsonAtRest,
      'drawing_local_path': existing?['drawing_local_path'],
      'drawing_remote_path': remotePath,
      'drawing_remote_url': remoteUrl,
      'plan_phase': mergedPlanPhase,
      'updated_at': updatedAt ?? DateTime.now().toIso8601String(),
      'sync_state': SyncState.synced.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    return true;
  }

  /// Compare deux timestamps ISO-8601 (ex. `2026-05-07T14:30:00Z`)
  /// pour décider si la version remote est strictement plus récente
  /// que la version locale. En cas de timestamp manquant ou invalide,
  /// renvoie `false` (= refuse le merge) pour rester safe.
  bool _isRemoteUpdatedAtNewer({
    required String? remoteUpdatedAt,
    required String? localUpdatedAt,
  }) {
    if (remoteUpdatedAt == null || remoteUpdatedAt.isEmpty) return false;
    if (localUpdatedAt == null || localUpdatedAt.isEmpty) return true;
    final remote = DateTime.tryParse(remoteUpdatedAt);
    final local = DateTime.tryParse(localUpdatedAt);
    if (remote == null || local == null) return false;
    return remote.isAfter(local);
  }

  /// Migration locale (demande utilisateur 2026-04-29, option « 3 ») :
  /// supprime les notes saisies sous les anciens tabKeys « Salle de
  /// bain-Équipements » et « WC-Config. & équipements ». La nouvelle
  /// note unique partagée vit désormais sous le tabKey
  /// `Sanitaires-Notes` (cf. `_kSharedSanitairesNotesTabKey` dans
  /// `visit_report_screen.dart`).
  ///
  /// Idempotent : appelé une fois à chaque ouverture de dossier — la
  /// requête DELETE est un no-op après la 1ère exécution. Coût
  /// négligeable (~µs) donc pas besoin de gate via flag persistant.
  ///
  /// Limite connue : ne touche QUE le SQLite local. Les anciennes
  /// lignes restent dans NocoDB (le note repository n'expose pas
  /// d'opération de delete server-side). C'est OK puisque l'app ne
  /// requête plus jamais ces tabKeys → les orphelins serveurs sont
  /// invisibles. Si un nettoyage NocoDB est souhaité, faire passer
  /// un script admin.
  ///
  /// Renvoie le nombre de lignes supprimées (utile pour log debug).
  Future<int> purgeLegacySanitairesNotes(String patientId) async {
    final db = await _database.database;
    return db.delete(
      'note_pages',
      where: 'patient_local_id = ? AND tab_key IN (?, ?)',
      whereArgs: [
        patientId,
        'Salle de bain-Équipements',
        'WC-Config. & équipements',
      ],
    );
  }
}
