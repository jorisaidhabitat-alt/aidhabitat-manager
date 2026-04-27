import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import '../models/visit_report_categories.dart';
import 'local_database.dart';
import 'sync_engine.dart';

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
    return rows.first['drawing_json'] as String?;
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
      'plan_phase': preservedPhase,
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
        if (preservedPhase != null) 'planPhase': preservedPhase,
        // `previewDataUrl` rasterisé côté Flutter (PNG base64). Stocké
        // uniquement dans le payload de la sync_op (pas en SQLite
        // local — gros volume) : le serveur le persiste dans
        // mobile_note_pages.preview_data_url, et le générateur PDF y
        // pioche pour les pages 9/10 (plans avant/après).
        if (previewDataUrl != null && previewDataUrl.isNotEmpty)
          'previewDataUrl': previewDataUrl,
      }),
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
    final drawingJson =
        row.isNotEmpty ? (row.first['drawing_json'] as String? ?? '') : '';

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
        'planPhase': planPhaseToDb(phase),
      }),
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
      textContent: rows.first['text_content'] as String? ?? '',
      drawingJson: rows.first['drawing_json'] as String?,
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
        ? (existing.first['drawing_json'] as String? ?? '')
        : '';
    final preservedPhase =
        existing.isNotEmpty ? existing.first['plan_phase'] as String? : null;
    await db.insert(
      'note_pages',
      {
        'local_id': noteId,
        'patient_local_id': patientId,
        'tab_key': tabKey,
        'page_number': pageNumber,
        'text_content': textContent,
        'drawing_json': drawingJson,
        'drawing_local_path': null,
        'drawing_remote_path': null,
        'drawing_remote_url': null,
        'plan_phase': preservedPhase,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

    if (existing != null && existingSyncState != SyncState.synced.name) {
      return false;
    }

    // Si le serveur ne nous renvoie pas explicitement de planPhase
    // (clé absente du payload), on garde celle qui était en local —
    // évite de perdre la catégorisation lors d'un sync passif.
    final mergedPlanPhase = planPhase ??
        (existing?['plan_phase'] as String?);

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
      'plan_phase': mergedPlanPhase,
      'updated_at': updatedAt ?? DateTime.now().toIso8601String(),
      'sync_state': SyncState.synced.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    return true;
  }
}
