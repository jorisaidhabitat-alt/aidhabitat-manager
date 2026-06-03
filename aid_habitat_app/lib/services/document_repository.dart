import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';
import 'media_cache_service.dart';
import 'sync_engine.dart';

class DocumentRepositoryChange {
  const DocumentRepositoryChange({
    required this.patientId,
    this.dossierId,
    required this.reason,
  });

  final String patientId;
  final String? dossierId;
  final String reason;
}

class DocumentRepository {
  DocumentRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  static final StreamController<DocumentRepositoryChange> _changesController =
      StreamController<DocumentRepositoryChange>.broadcast();

  static Stream<DocumentRepositoryChange> get changes =>
      _changesController.stream;

  final LocalDatabase _database;

  void _notifyChanged({
    required String patientId,
    String? dossierId,
    required String reason,
  }) {
    _changesController.add(
      DocumentRepositoryChange(
        patientId: patientId,
        dossierId: dossierId,
        reason: reason,
      ),
    );
  }

  Future<List<DocItem>> fetchDocuments(String patientId) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      where: 'patient_local_id = ? AND pending_delete = 0',
      whereArgs: [patientId],
      orderBy: 'updated_at DESC, created_at DESC',
    );

    return rows.map(_mapRow).toList();
  }

  /// Charge les bytes locaux des documents VAD (tags `Visite - …`) pour
  /// un patient, en vue de les embarquer **inline** dans la requête de
  /// génération PDF. Permet au serveur de générer le rapport même si la
  /// sync NocoDB est en retard ou a échoué partiellement (cf. edge case
  /// "réseau intermittent" : 8 photos prises offline, certaines sont
  /// montées avant la coupure, d'autres pas — sans inline, le PDF
  /// arrive incomplet ou la génération est différée).
  ///
  /// Filtre :
  ///   - tag matche un préfixe `Visite - ` (logement / acces / sani)
  ///   - `pending_delete = 0`
  ///   - bytes disponibles localement (`local_file_data_url` web ou
  ///     `local_file_path` natif)
  ///   - `sync_state != synced` — les docs déjà sur NocoDB n'ont pas
  ///     besoin d'être renvoyés (le serveur les fetche en parallèle)
  ///
  /// Renvoie une liste de `InlineDocumentBytes`, prête à être convertie
  /// en `MultipartFile` par [NocodbApiClient.downloadVisitReport].
  Future<List<InlineDocumentBytes>> fetchVisitReportInlineBytes(
    String patientId,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      where:
          'patient_local_id = ? AND pending_delete = 0 '
          "AND sync_state != ? "
          "AND mime_type LIKE 'image/%' "
          "AND tags_json LIKE '%Visite - %'",
      whereArgs: [patientId, SyncState.synced.name],
      orderBy: 'created_at DESC',
    );

    final result = <InlineDocumentBytes>[];
    for (final row in rows) {
      final tagsRaw = row['tags_json'] as String? ?? '[]';
      final tags = (jsonDecode(tagsRaw) as List<dynamic>).cast<String>();
      // Double-filtre côté Dart (le LIKE SQL ci-dessus est approximatif).
      final hasVisitTag = tags.any((t) => t.startsWith('Visite - '));
      if (!hasVisitTag) continue;

      Uint8List? bytes;

      // 1) Web/PWA : bytes encodés en base64 dans `local_file_data_url`.
      final dataUrl = row['local_file_data_url'] as String?;
      if (dataUrl != null && dataUrl.isNotEmpty) {
        final match = RegExp(r'^data:[^;]+;base64,(.+)$').firstMatch(dataUrl);
        if (match != null) {
          try {
            bytes = base64Decode(match.group(1)!);
          } catch (_) {
            // dataUrl corrompu : on tente la fallback file path.
          }
        }
      }

      // 2) Natif : fichier copié dans le sandbox app via `local_file_path`.
      if (bytes == null && !kIsWeb) {
        final filePath = row['local_file_path'] as String?;
        if (filePath != null && filePath.isNotEmpty) {
          try {
            final file = File(filePath);
            if (await file.exists()) {
              bytes = await file.readAsBytes();
            }
          } catch (_) {
            // I/O error : on skip ce doc, le serveur retombera sur NocoDB.
          }
        }
      }

      if (bytes == null || bytes.isEmpty) continue;

      result.add(
        InlineDocumentBytes(
          localId: row['local_id'] as String,
          fileName: row['file_name'] as String,
          mimeType: row['mime_type'] as String,
          tags: tags,
          title: row['title'] as String? ?? '',
          dossierId: row['dossier_local_id'] as String?,
          bytes: bytes,
        ),
      );
    }
    return result;
  }

  /// Web-friendly import that takes bytes + metadata directly (no
  /// [File]) since PWAs don't have a filesystem. The bytes are stored as
  /// a `data:<mime>;base64,…` URL in `documents.local_file_data_url` and
  /// the sync processor decodes them when pushing to NocoDB.
  /// Insert un document SANS queuer d'upload — pour le cas où le
  /// serveur a déjà sauvegardé le PDF en NocoDB (cf. génération de
  /// rapport, demande utilisateur 2026-04-29). Le doc local est
  /// directement marqué `synced` avec son `remote_file_path` pointant
  /// sur l'UUID NocoDB, donc le polling `mergeRemoteDocuments` le
  /// reconnaît au prochain refresh sans créer de doublon.
  ///
  /// Évite la boucle 413 Content Too Large quand le PDF dépasse la
  /// limite ~4.5 MB de Vercel Hobby.
  Future<DocItem> importDocumentRemoteOnly({
    required String patientId,
    required List<int> bytes,
    required String fileName,
    required String remoteUuid,
    List<String> tags = const ['Autre'],
    String? title,
    int? categoryOrder,
    String? dossierId,

    /// Identifiant déterministe assigné par le client (Flutter) — DOIT
    /// correspondre au `client_document_id` que le serveur a stocké
    /// dans NocoDB. Utilisé comme `local_id` pour que `mergeRemoteDocuments`
    /// puisse retrouver cette ligne au prochain polling et éviter de
    /// créer un doublon.
    ///
    /// Si null → fallback sur `remoteUuid` (comportement legacy, à
    /// éviter pour les rapports : crée un doublon au prochain pull
    /// car le serveur renvoie `clientDocumentId = doc_report_<dossierId>`
    /// qui ne matche aucun `local_id` existant). Bug reporté
    /// 2026-05-05.
    String? clientDocumentId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now();
    final extension = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : p.basenameWithoutExtension(fileName);
    // Priorité au clientDocumentId pour que le merge polling matche
    // par `local_id == clientDocumentId`. Fallback sur remoteUuid si
    // l'appelant ne le connaît pas (cas legacy).
    final localId = (clientDocumentId != null && clientDocumentId.isNotEmpty)
        ? clientDocumentId
        : remoteUuid;
    final mimeType = _mimeTypeFor(extension);
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';

    // Native (macOS/iOS/iPad) : on persiste les bytes sur disque pour
    // que le PDF annotator puisse les ouvrir. Sans ça, `localPath`
    // restait null → la condition de preview au l.3482 du
    // documents_screen tombait sur `_unsupportedPanel` (« Prévisualisation
    // non disponible pour ce format ») — bug reporté 2026-04-30 sur
    // les rapports générés.
    //
    // Web : pas de fichier (path_provider indispo), on garde
    // uniquement le data URL.
    String? localFilePath;
    if (!kIsWeb) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final docsDir = Directory(
          p.join(appDir.path, 'offline_documents', patientId),
        );
        await docsDir.create(recursive: true);
        // Nom déterministe basé sur le remoteUuid → idempotent : un
        // 2ème appel pour le même rapport overwrite le fichier sans
        // créer de doublon. Préserve l'extension d'origine pour
        // qu'`OpenFilex.open` ouvre dans la bonne app native.
        final storedPath = p.join(docsDir.path, '$remoteUuid.$extension');
        await File(storedPath).writeAsBytes(bytes, flush: true);
        localFilePath = storedPath;
      } catch (_) {
        // Si la persistance disque échoue (permissions, disque plein),
        // on retombe sur le data URL — la preview ne marchera pas mais
        // le doc reste utilisable (download via "Ouvrir dans une autre
        // app", upload, etc).
        localFilePath = null;
      }
    }

    final row = {
      'local_id': localId,
      'patient_local_id': patientId,
      'dossier_local_id': dossierId,
      'title': resolvedTitle,
      'file_name': fileName,
      'file_ext': extension,
      'mime_type': mimeType,
      'local_file_path': localFilePath,
      // Bytes en local pour vignette immédiate, sans avoir à pull
      // depuis NocoDB le binaire (qui passerait par /api/mobile-documents/.../content).
      'local_file_data_url': dataUrl,
      // remote_file_path = UUID NocoDB → permet à mergeRemoteDocuments
      // de matcher au prochain pull sans dupliquer.
      'remote_file_path': remoteUuid,
      'remote_public_url': null,
      'tags_json': jsonEncode(tags),
      'category_order': categoryOrder,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'sync_state': SyncState.synced.name,
      'pending_delete': 0,
    };

    await db.insert(
      'documents',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // PAS de sync_operations — le doc est déjà côté serveur.
    _notifyChanged(
      patientId: patientId,
      dossierId: dossierId,
      reason: 'import_remote_only',
    );
    return _mapRow(row);
  }

  Future<DocItem> importDocumentBytes({
    required String patientId,
    required List<int> bytes,
    required String fileName,
    List<String> tags = const ['Autre'],
    String? title,
    int? categoryOrder,
    String? dossierId,

    /// Optionnel : id déterministe pour permettre la dédup. Quand
    /// fourni et qu'une ligne existe déjà, on REPLACE (ConflictAlgorithm.
    /// replace). Cas d'usage : le rapport PDF d'un dossier (« Rapport »
    /// tag) qui doit toujours être 1 doc unique par dossier — sans ça,
    /// chaque retry de la sync_op `report_generation` créait un nouveau
    /// doc avec un id timestamp, finissant par 15 copies dans NocoDB
    /// (bug reporté 2026-04-30). Quand non fourni (cas normal), on
    /// génère un id timestamp pour un nouveau doc.
    String? localId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now();
    final extension = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : p.basenameWithoutExtension(fileName);
    final resolvedLocalId = localId ?? 'doc_${now.microsecondsSinceEpoch}';
    final mimeType = _mimeTypeFor(extension);
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';

    // Native : persiste les bytes sur disque pour que le PDF annotator
    // puisse les ouvrir (cf. importDocumentRemoteOnly pour le rationale
    // détaillé — bug « Prévisualisation non disponible » 2026-04-30).
    String? localFilePath;
    if (!kIsWeb) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final docsDir = Directory(
          p.join(appDir.path, 'offline_documents', patientId),
        );
        await docsDir.create(recursive: true);
        final storedPath = p.join(docsDir.path, '$resolvedLocalId.$extension');
        await File(storedPath).writeAsBytes(bytes, flush: true);
        localFilePath = storedPath;
      } catch (_) {
        localFilePath = null;
      }
    }

    // Si on REPLACE un doc déterministe (ex. le rapport PDF), on
    // préserve les éventuelles annotations existantes (l'ergo a peut-
    // être dessiné/écrit sur l'ancien rapport — re-générer ne doit
    // pas wiper son travail).
    Map<String, Object?>? preservedFields;
    if (localId != null) {
      final existing = await db.query(
        'documents',
        columns: ['annotations_json', 'created_at'],
        where: 'local_id = ?',
        whereArgs: [resolvedLocalId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        preservedFields = {
          'annotations_json': existing.first['annotations_json'],
          // Les rapports doivent afficher la date de dernière
          // génération. Les autres documents déterministes gardent leur
          // date de création initiale.
          if (!tags.any((tag) => tag.trim().toLowerCase() == 'rapport'))
            'created_at': existing.first['created_at'],
        };
      }
    }

    final row = {
      'local_id': resolvedLocalId,
      'patient_local_id': patientId,
      // Optionnel mais conseillé : permet le scoping par dossier dans
      // les futures requêtes (ex. liste docs d'une visite spécifique).
      // Le filtre Documents primaire reste `patient_local_id`.
      'dossier_local_id': dossierId,
      'title': resolvedTitle,
      'file_name': fileName,
      'file_ext': extension,
      'mime_type': mimeType,
      'local_file_path': localFilePath,
      'local_file_data_url': dataUrl,
      'remote_file_path': null,
      'remote_public_url': null,
      'tags_json': jsonEncode(tags),
      'category_order': categoryOrder,
      'created_at': preservedFields?['created_at'] ?? now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'sync_state': SyncState.pendingSync.name,
      'pending_delete': 0,
      if (preservedFields?['annotations_json'] != null)
        'annotations_json': preservedFields!['annotations_json'],
    };

    // ConflictAlgorithm.replace pour le path déterministe (regénération
    // de rapport) ; insert simple sinon (nouveau doc).
    await db.insert(
      'documents',
      row,
      conflictAlgorithm: localId != null
          ? ConflictAlgorithm.replace
          : ConflictAlgorithm.abort,
    );
    await db.insert(
      'sync_operations',
      {
        'id': 'sync_$resolvedLocalId',
        'entity_type': 'document',
        'entity_local_id': resolvedLocalId,
        'operation_type': 'upload_file',
        'payload_json': jsonEncode({
          'patientLocalId': patientId,
          // IMPORTANT : on envoie `resolvedLocalId` (et pas `localId`)
          // pour que le serveur dedupe correctement via
          // `client_document_id`. Sans ça, un retry de regénération
          // de rapport créait une 2e ligne NocoDB malgré le replace
          // local — bug reporté 2026-04-30 (« 15 documents dans le
          // dossier alors que j'en vois seulement un »).
          'documentLocalId': resolvedLocalId,
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
      },
      // Replace si on retry une regénération avec le même localId
      // (sinon UNIQUE constraint sur 'id'='sync_<localId>' fait
      // échouer le 2ème appel).
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    SyncEngine().notify();
    _notifyChanged(
      patientId: patientId,
      dossierId: dossierId,
      reason: 'import_bytes',
    );
    return _mapRow(row);
  }

  Future<DocItem> importDocument({
    required String patientId,
    required File sourceFile,
    List<String> tags = const ['Autre'],
    String? title,
    int? categoryOrder,
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
      'category_order': categoryOrder,
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
    _notifyChanged(patientId: patientId, reason: 'import_file');

    return _mapRow(row);
  }

  /// Variante **web** : prend les bytes flattened directement (pas de
  /// filesystem dans le navigateur). Encode en data URL et enqueue une
  /// op d'upload qui sera ré-hydratée par `_processDocumentOperation`
  /// via le champ `dataUrl` du payload. Le `documentLocalId` reste le
  /// même, donc côté NocoDB on remplace l'asset existant (parité avec
  /// la variante natif `enqueueAnnotatedReupload`).
  /// Enregistre l'aplat (PDF page + traits ergo) d'UNE SEULE PAGE
  /// d'un PDF dans la map `annotations_json` du document, sans
  /// toucher au PDF original. Le PDF reste navigable, et la preview
  /// affiche l'aplat PNG sur les pages qui ont une entrée dans la map.
  ///
  /// Format du JSON stocké : `{"1": "data:image/png;base64,...", "3": "..."}`
  /// (clé = numéro de page 1-indexé, valeur = data URL PNG).
  ///
  /// Symptôme avant ce mécanisme :
  /// `enqueueAnnotatedReuploadBytes` remplaçait le PDF entier par le
  /// PNG d'une seule page → perte des autres pages, plus de
  /// navigation, le `file_ext` passait à 'png' et la preview ne savait
  /// plus distinguer un vrai PDF d'un image annotée.
  ///
  /// Cette méthode est utilisée pour les annotations PDF par page.
  /// Les annotations sur images "simples" (jpg/png originaux)
  /// continuent d'utiliser `enqueueAnnotatedReuploadBytes` qui flatten
  /// directement le fichier source (puisqu'il n'y a qu'une "page").
  ///
  /// Note : le sync NocoDB n'est pas câblé pour les overlays par page
  /// en v1 — les annotations restent local-only. Voir TODO dans le
  /// sync engine pour pousser une op `update_annotations`.
  Future<void> enqueueAnnotatedPageBytes({
    required String documentId,
    required int pageNumber,
    required Uint8List bytes,
  }) async {
    if (pageNumber < 1) return;
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      columns: ['annotations_json'],
      where: 'local_id = ?',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) return;

    // Lit la map existante, ajoute/écrase l'entrée de la page courante.
    final existingJson = rows.first['annotations_json'] as String? ?? '';
    Map<String, dynamic> map = {};
    if (existingJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(existingJson);
        if (decoded is Map<String, dynamic>) map = decoded;
      } catch (_) {
        // JSON corrompu → on repart d'une map vide. La page de l'ergo
        // sera la 1re entrée. Les anciennes annotations sont perdues
        // mais c'était déjà cassé.
      }
    }
    final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
    map['$pageNumber'] = dataUrl;

    final now = DateTime.now().toIso8601String();
    await db.update(
      'documents',
      {
        'annotations_json': jsonEncode(map),
        'updated_at': now,
        // Pas de `sync_state = pendingSync` — les annotations restent
        // local-only en v1, pas de push NocoDB. Le doc PDF original
        // garde son sync_state existant (synced typiquement).
      },
      where: 'local_id = ?',
      whereArgs: [documentId],
    );
  }

  Future<void> enqueueAnnotatedReuploadBytes({
    required String documentId,
    required Uint8List bytes,
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
    final flatName = '${p.basenameWithoutExtension(originalName)}-annoté.png';
    final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
    final now = DateTime.now().toIso8601String();
    final tagsJson = row['tags_json'] as String? ?? '[]';
    final tags = (jsonDecode(tagsJson) as List<dynamic>).cast<String>();

    // Annule toute upload en attente pour ce doc — on remplace par la
    // version annotée.
    await db.delete(
      'sync_operations',
      where: 'entity_local_id = ? AND entity_type = ? AND status IN (?, ?)',
      whereArgs: [
        documentId,
        'document',
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
    );

    // Persiste le data URL côté SQLite local pour que la vignette du
    // doc reflète immédiatement la version annotée même avant que la
    // sync remote ne s'achève.
    //
    // CRITIQUE : on met aussi à jour `file_ext`, `mime_type` et
    // `file_name` pour que le doc bascule de "pdf" à "image" côté
    // app. Sans ça, la preview à la réouverture essayait de
    // décoder les bytes PNG comme un PDF (`PdfDocument.openData`)
    // → erreur dans le viewer + impossible de re-voir le rapport
    // annoté. L'aplatissage produit un PNG (limitation actuelle :
    // pas de lib d'écriture PDF en Flutter), donc on aligne les
    // métadonnées sur ce qui est vraiment stocké.
    await db.update(
      'documents',
      {
        'local_file_data_url': dataUrl,
        'file_ext': 'png',
        'mime_type': 'image/png',
        'file_name': flatName,
        'sync_state': SyncState.pendingSync.name,
        'updated_at': now,
      },
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
        'dataUrl': dataUrl,
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
    final flatName = '${p.basenameWithoutExtension(originalName)}-annoté.png';
    final now = DateTime.now().toIso8601String();
    final tagsJson = row['tags_json'] as String? ?? '[]';
    final tags = (jsonDecode(tagsJson) as List<dynamic>).cast<String>();

    // Supprime toute opération d'upload en attente pour ce doc — on ne veut
    // pas pousser successivement deux versions.
    await db.delete(
      'sync_operations',
      where: 'entity_local_id = ? AND entity_type = ? AND status IN (?, ?)',
      whereArgs: [
        documentId,
        'document',
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
    );

    // Marque le doc comme pendingSync + bascule les métadonnées sur
    // PNG. Sans cette bascule, le doc restait classé `pdf` côté
    // SQLite alors que le contenu local devient un PNG (le flatten
    // produit un PNG, limitation Flutter PDF write). À la réouverture,
    // la preview essayait `PdfDocument.openData` sur des bytes PNG →
    // erreur du décodeur, plus de preview visible. On aligne les
    // métadonnées sur ce qui est réellement stocké : `file_ext='png'`,
    // `mime_type='image/png'`, et on adopte aussi le `file_name`
    // suffixé "-annoté.png" pour que la cohérence remontée serveur
    // soit propre.
    await db.update(
      'documents',
      {
        'sync_state': SyncState.pendingSync.name,
        'updated_at': now,
        'local_file_path': flattenedPath,
        'file_ext': 'png',
        'mime_type': 'image/png',
        'file_name': flatName,
      },
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

  /// Persiste le chemin local d'un fichier distant téléchargé en cache.
  ///
  /// Local-only : on ne marque pas le document comme modifié et on ne crée
  /// aucune opération de sync. Le but est uniquement de permettre aux aperçus
  /// natifs (notamment PDF) de s'ouvrir instantanément aux prochains clics.
  Future<void> storeLocalDocumentPath({
    required String documentId,
    required String localFilePath,
  }) async {
    final trimmedPath = localFilePath.trim();
    if (trimmedPath.isEmpty) return;
    final db = await _database.database;
    await db.update(
      'documents',
      {'local_file_path': trimmedPath},
      where:
          'local_id = ? AND (local_file_path IS NULL OR local_file_path = "")',
      whereArgs: [documentId],
    );
  }

  /// Met à jour la catégorisation visite d'un document — utilisé
  /// exclusivement par l'onglet Photos du relevé de visite.
  ///
  /// - [tags] : la liste cible (le caller a déjà calculé ce que la
  ///   nouvelle catégorie implique — ajout du tag visite, retrait des
  ///   éventuels autres tags visite, conservation des tags non-visite).
  /// - [categoryOrder] : position dans la catégorie. `null` quand le
  ///   document est retiré d'une catégorie visite (passe à « À classer »).
  ///
  /// `category_order` est purement local en v1 (pas d'envoi au serveur).
  /// La mise à jour des tags par contre est synchronisée à NocoDB via
  /// le sync engine pour qu'on retrouve le tag à la prochaine connexion.
  Future<void> setVisitCategorization({
    required String documentId,
    required List<String> tags,
    int? categoryOrder,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'documents',
      {
        'tags_json': jsonEncode(tags),
        'category_order': categoryOrder,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      },
      where: 'local_id = ?',
      whereArgs: [documentId],
    );
    SyncEngine().notify();
  }

  /// Réordonne plusieurs documents d'une catégorie en une seule
  /// transaction. Appelé après un drag-to-reorder côté UI : le caller
  /// fournit la liste des `documentId` dans le NOUVEL ordre voulu et
  /// chacun reçoit son index comme `category_order`.
  Future<void> reorderVisitCategory({
    required List<String> orderedDocumentIds,
  }) async {
    if (orderedDocumentIds.isEmpty) return;
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final batch = db.batch();
    for (var i = 0; i < orderedDocumentIds.length; i++) {
      batch.update(
        'documents',
        {
          'category_order': i,
          'updated_at': now,
          'sync_state': SyncState.pendingSync.name,
        },
        where: 'local_id = ?',
        whereArgs: [orderedDocumentIds[i]],
      );
    }
    await batch.commit(noResult: true);
    // Pas de notification au sync engine : `category_order` est local-only
    // pour l'instant. Si un autre champ change, c'est un autre code-path.
  }

  Future<void> hideObsoleteReportDocuments({
    required String patientId,
    required String dossierId,
    String keepLocalId = '',
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      columns: const [
        'local_id',
        'dossier_local_id',
        'tags_json',
        'sync_state',
        'remote_file_path',
        'remote_public_url',
      ],
      where: 'patient_local_id = ? AND pending_delete = 0',
      whereArgs: [patientId],
    );

    final now = DateTime.now().toIso8601String();
    var changed = false;

    await db.transaction((txn) async {
      for (final row in rows) {
        final localId = (row['local_id'] as String?) ?? '';
        if (localId.isEmpty || localId == keepLocalId) continue;
        if (!_documentRowHasTag(row, 'Rapport')) continue;

        final rowDossierId = (row['dossier_local_id'] as String?) ?? '';
        if (rowDossierId.isNotEmpty && rowDossierId != dossierId) continue;

        changed = true;
        final wasSynced =
            (row['sync_state'] as String?) == SyncState.synced.name;
        final remoteId = _extractRemoteIdFromRow(row, localId);

        await txn.update(
          'documents',
          {
            'pending_delete': 1,
            'updated_at': now,
            'sync_state': SyncState.pendingSync.name,
          },
          where: 'local_id = ?',
          whereArgs: [localId],
        );

        await txn.delete(
          'sync_operations',
          where:
              'entity_local_id = ? AND operation_type = ? AND status IN (?, ?)',
          whereArgs: [
            localId,
            'upload_file',
            SyncOperationStatus.pending.name,
            SyncOperationStatus.failed.name,
          ],
        );

        if (wasSynced && remoteId.isNotEmpty) {
          await txn.insert('sync_operations', {
            'id': 'sync_delete_$localId',
            'entity_type': 'document',
            'entity_local_id': localId,
            'operation_type': 'delete_document',
            'payload_json': jsonEncode({'remoteDocumentId': remoteId}),
            'status': SyncOperationStatus.pending.name,
            'attempt_count': 0,
            'last_error': null,
            'created_at': now,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        } else {
          await txn.delete(
            'documents',
            where: 'local_id = ?',
            whereArgs: [localId],
          );
        }
      }
    });

    if (changed) SyncEngine().notify();
    if (changed) {
      _notifyChanged(
        patientId: patientId,
        dossierId: dossierId,
        reason: 'hide_obsolete_reports',
      );
    }
  }

  Future<void> deleteDocument(String documentId) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    // Snapshot l'état actuel : si le doc avait déjà été poussé sur
    // NocoDB (sync_state == synced) il faut envoyer un DELETE remote.
    // Sinon on peut juste annuler la pending upload et purger.
    final rows = await db.query(
      'documents',
      columns: const [
        'patient_local_id',
        'sync_state',
        'remote_file_path',
        'remote_public_url',
      ],
      where: 'local_id = ?',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final patientId = rows.first['patient_local_id'] as String? ?? '';

    final wasSynced =
        (rows.first['sync_state'] as String?) == SyncState.synced.name;
    final remoteId = _extractRemoteIdFromRow(rows.first, documentId);

    // Marque pending_delete pour cacher immédiatement le doc côté UI
    // (filtrage SQL `pending_delete = 0` dans `fetchDocuments`).
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

    // Annule toute upload encore pending/failed pour ce doc — l'upload
    // est moot (le doc est en train d'être supprimé).
    await db.delete(
      'sync_operations',
      where: 'entity_local_id = ? AND operation_type = ? AND status IN (?, ?)',
      whereArgs: [
        documentId,
        'upload_file',
        SyncOperationStatus.pending.name,
        SyncOperationStatus.failed.name,
      ],
    );

    if (wasSynced && remoteId.isNotEmpty) {
      // Enqueue un DELETE qui sera traité par `_processDocumentOperation`
      // côté sync engine. Sans cette op, la suppression locale n'était
      // JAMAIS propagée au serveur — au prochain pull NocoDB, le doc
      // était ressuscité (cf. audit critique #4).
      await db.insert(
        'sync_operations',
        {
          'id': 'sync_delete_$documentId',
          'entity_type': 'document',
          'entity_local_id': documentId,
          'operation_type': 'delete_document',
          'payload_json': jsonEncode({'remoteDocumentId': remoteId}),
          'status': SyncOperationStatus.pending.name,
          'attempt_count': 0,
          'last_error': null,
          'created_at': now,
          'updated_at': now,
        },
        // Idempotent : si l'utilisateur clique deux fois, on remplace
        // l'op précédente plutôt que de dupliquer.
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      // Doc jamais poussé — on peut purger directement le local.
      await db.delete(
        'documents',
        where: 'local_id = ?',
        whereArgs: [documentId],
      );
    }

    SyncEngine().notify();
    _notifyChanged(
      patientId: patientId,
      reason: 'delete',
    );
  }

  bool _documentRowHasTag(Map<String, Object?> row, String tag) {
    final raw = row['tags_json'] as String? ?? '[]';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final expected = tag.trim().toLowerCase();
        return decoded.any(
          (value) => value.toString().trim().toLowerCase() == expected,
        );
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// Pour les documents synced, retrouve l'ID utilisé côté NocoDB pour
  /// les supprimer via `DELETE /api/documents/<id>`. Trois sources, dans
  /// l'ordre :
  ///   1. `local_id` direct (cas standard : Flutter a uploadé le doc, le
  ///      serveur a réutilisé `clientDocumentId` comme `uuid_source`).
  ///   2. Préfixe `remote_doc_<id>` retiré (cas où le doc venait du
  ///      remote sans avoir été uploadé localement).
  ///   3. Extraction depuis `remote_file_path` ou `remote_public_url`
  ///      (URL `/api/mobile-documents/<id>/content`) — fallback dur.
  String _extractRemoteIdFromRow(Map<String, Object?> row, String localId) {
    if (!localId.startsWith('remote_doc_')) {
      return localId;
    }
    final stripped = localId.substring('remote_doc_'.length);
    if (stripped.isNotEmpty) return stripped;

    // Fallback : parse l'URL.
    final candidates = [
      (row['remote_file_path'] as String?) ?? '',
      (row['remote_public_url'] as String?) ?? '',
    ];
    for (final raw in candidates) {
      final match = RegExp(
        r'/mobile-documents/([^/]+)/content',
      ).firstMatch(raw);
      if (match != null) {
        return Uri.decodeComponent(match.group(1) ?? '');
      }
    }
    return '';
  }

  Future<void> mergeRemoteDocuments(
    String patientId,
    List<Map<String, dynamic>> remoteDocuments,
  ) async {
    final db = await _database.database;

    // Set canonique des `local_id` qui existent côté NocoDB pour ce
    // patient — alimenté pendant la boucle pour réconcilier ensuite
    // les suppressions remote (chantier sync #1).
    final remoteLocalIds = <String>{};

    await db.transaction((txn) async {
      for (final remote in remoteDocuments) {
        final remotePath = remote['remotePath']?.toString();
        final publicUrl = remote['publicUrl']?.toString();
        // Server echoes the Flutter-assigned local id as `clientDocumentId`
        // → used here as the primary match key. Prevents duplicates when
        // the sync push lands before `storeDocumentRemoteData` populates
        // the remote_file_path/remote_public_url columns.
        final clientDocumentId = remote['clientDocumentId']?.toString() ?? '';

        final existingRows = await txn.query(
          'documents',
          where: clientDocumentId.isNotEmpty
              ? 'patient_local_id = ? AND '
                    '(local_id = ? OR remote_file_path = ? OR remote_public_url = ?)'
              : 'patient_local_id = ? AND '
                    '(remote_file_path = ? OR remote_public_url = ?)',
          whereArgs: clientDocumentId.isNotEmpty
              ? [patientId, clientDocumentId, remotePath, publicUrl]
              : [patientId, remotePath, publicUrl],
          limit: 1,
        );

        final existing = existingRows.isNotEmpty ? existingRows.first : null;
        final existingSyncState = existing?['sync_state'] as String?;
        // Stratégie LWW (last-writer-wins) — même fix que pour
        // `mergeRemoteNotePage` (note_repository.dart 2026-05-07).
        //
        // Avant : on skippait aveuglément dès que la row locale était
        // `pendingSync`. Conséquence : si une ancienne op de cette row
        // était bloquée en `failed`/`pendingSync` côté Mac, toutes les
        // versions remote suivantes (notamment les photos importées
        // depuis iPad) étaient ignorées. Symptôme reporté 2026-05-07 :
        // « nouvelle photo Accessibilité importée sur iPad mais ne se
        // met pas sur Mac, default de synchronisation toujours présent ».
        //
        // Désormais :
        //  1. Si row locale `synced` → merge directement (pas de risque)
        //  2. Sinon, comparer `remote.updatedAt` vs `local.updated_at` :
        //     - remote plus récent → merge (la version distante gagne,
        //       on rattrape un local stale)
        //     - remote plus ancien → skip (préserve un push en cours)
        //  3. Timestamps absents/invalides → skip safely (ancien
        //     comportement)
        if (existing != null && existingSyncState != SyncState.synced.name) {
          final localUpdatedAt = existing['updated_at'] as String?;
          final remoteUpdatedAt = remote['updatedAt']?.toString();
          final remoteIsNewer = _isRemoteUpdatedAtNewer(
            remoteUpdatedAt: remoteUpdatedAt,
            localUpdatedAt: localUpdatedAt,
          );
          if (!remoteIsNewer) {
            continue;
          }
          // Sinon on tombe en bas pour faire le merge.
        }
        // Anti-resurrection : si l'utilisateur a supprimé le doc localement
        // (pending_delete=1) et que le DELETE remote n'a pas encore été
        // traité par le sync engine, on évite de l'écraser en `synced`
        // (sinon il réapparaît dans l'UI). On laisse la `sync_operations`
        // (delete_document) faire le DELETE distant + purger le local.
        if (existing != null &&
            (existing['pending_delete'] as int? ?? 0) == 1) {
          continue;
        }

        final fileName = remote['fileName']?.toString() ?? 'document';
        final extension = p
            .extension(fileName)
            .replaceFirst('.', '')
            .toLowerCase();
        final localId =
            existing?['local_id'] as String? ??
            'remote_doc_${remote['id'] ?? DateTime.now().microsecondsSinceEpoch}';
        remoteLocalIds.add(localId);
        final row = {
          'local_id': localId,
          'patient_local_id': patientId,
          'title': remote['title']?.toString() ?? fileName,
          'file_name': fileName,
          'file_ext': extension,
          'mime_type':
              remote['mimeType']?.toString() ?? _mimeTypeFor(extension),
          'local_file_path': existing?['local_file_path'],
          // CRITICAL : preserve the local bytes (web PWA "offline upload").
          // Without this, `conflictAlgorithm: replace` nulls the column and
          // the thumbnail loses its source → the picture would disappear
          // right after the sync pushes it to NocoDB.
          'local_file_data_url': existing?['local_file_data_url'],
          'remote_file_path': remotePath,
          'remote_public_url': publicUrl,
          'tags_json': jsonEncode(
            (remote['tags'] as List?)?.map((tag) => '$tag').toList() ??
                const <String>[],
          ),
          // CRITICAL aussi : `category_order` (ordre de la photo dans
          // sa catégorie de l'onglet Photos du relevé) est local-only
          // — le serveur ne le connaît pas. Sans cette préservation,
          // le polling silencieux de `_loadDocuments` (toutes les 10 s)
          // remet TOUTES les photos visite à `category_order = NULL` →
          // le tri perd son sens.
          'category_order':
              existing?['category_order'] ?? remote['category_order'],
          // CRITICAL aussi : `annotations_json` (overlays par page d'un
          // PDF annoté côté ergo) est local-only en v1. Sans cette
          // préservation, à chaque polling remote (10 s) la colonne
          // était réécrite à NULL → les annotations disparaissaient.
          // Symptôme reporté : "j'écris sur le PDF, je clique
          // enregistrer, je quitte, la note se voit pas, je rouvre
          // elle est là, je requitte/rouvre elle a disparu".
          'annotations_json': existing?['annotations_json'],
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

      // ----------------------------------------------------------------
      // Réconciliation des suppressions NocoDB scopée à ce patient.
      // Toute ligne `synced` (donc déjà connue du serveur) qui n'est
      // PAS dans le set canonique remote est purgée. Les drafts
      // (sync_state != synced) et les soft-deletes (pending_delete=1)
      // sont préservés.
      //
      // Filtre temporel : on ne purge que les docs créés il y a plus
      // de 5 minutes. Protection contre la consistance éventuelle de
      // NocoDB — un doc uploadé < 5 min plus tôt peut ne pas encore
      // figurer dans la pull list. Au prochain pull (≥ 5 min plus
      // tard), si le doc reste absent, on purge.
      //
      // Cas spécial 2026-05-06 (bug fix) : si `remoteLocalIds` est
      // VIDE (= NocoDB n'a aucun doc pour ce patient), on purge quand
      // même les rows synced antérieurs au seuil. Avant : on skippait
      // par sécurité, mais ça empêchait la propagation de la dernière
      // suppression d'un patient (l'ergo supprimait la seule photo
      // sur iPad → le Mac ne purgeait jamais la sienne).
      // ----------------------------------------------------------------
      final ageThreshold = DateTime.now().subtract(const Duration(minutes: 5));
      final args = <Object?>[
        patientId,
        SyncState.synced.name,
        ageThreshold.toIso8601String(),
      ];
      String whereClause =
          'patient_local_id = ? AND sync_state = ? '
          'AND pending_delete = 0 '
          'AND created_at < ?';
      if (remoteLocalIds.isNotEmpty) {
        final placeholders = List.filled(remoteLocalIds.length, '?').join(',');
        whereClause += ' AND local_id NOT IN ($placeholders)';
        args.addAll(remoteLocalIds);
      }
      // Si `remoteLocalIds` est vide, le where ne contient pas
      // `NOT IN (…)` → on purge TOUT ce qui est synced + > 5min,
      // ce qui correspond à « l'autre device a tout supprimé ».
      final deleted = await txn.delete(
        'documents',
        where: whereClause,
        whereArgs: args,
      );
      if (deleted > 0) {
        // ignore: avoid_print
        print(
          '[reconcile] documents (patient=$patientId) : '
          '$deleted ligne(s) purgée(s) (suppression remote, âge > 5min)',
        );
      }
    });

    // Warm the media cache so document previews (PDFs, images) work offline
    // after the first sync of this dossier.
    unawaited(_prefetchDocumentAssets(patientId, remoteDocuments));
  }

  Future<void> _prefetchDocumentAssets(
    String patientId,
    List<Map<String, dynamic>> remoteDocuments,
  ) async {
    final urls = <String>{};
    for (final doc in remoteDocuments) {
      final url = doc['publicUrl']?.toString().trim() ?? '';
      if (url.isNotEmpty) urls.add(url);
    }
    if (urls.isEmpty) return;

    try {
      // Étape 1 — warm cache générique (sha1-keyed sur disk en native, blob
      // SQLite sur web). Mêmes headers d'auth web ET native : les URLs
      // patient passent par `requireAuth` côté serveur dans le mode
      // `nocodb`. Sans le header, le fetch renvoyait 401 et le cache
      // restait vide → réinstallation iPad sans réseau = aucun aperçu.
      await MediaCacheService.instance.prefetchAll(
        urls,
        headers: MediaCacheService.authHeaders(),
      );
    } catch (e) {
      // Best effort — log mais ne bloque pas le reste du sync.
      // ignore: avoid_print
      print('[docs prefetch] warm cache failed: $e');
    }

    // Étape 2 (native uniquement) — pour chaque document remote, on copie
    // les bytes vers un emplacement stable
    // `<docs>/cached_remote_documents/<patientId>/<localId>.<ext>` puis
    // on met à jour `documents.local_file_path` si vide. Permet à
    // `_PreviewScreen._buildPreviewBody` (qui exige `File(localPath)
    // .existsSync()`) d'ouvrir les PDFs distants après une réinstallation
    // — sans ça, sur iPad réinstallé, aucun PDF synchronisé n'était
    // consultable.
    //
    // Sur web, les PDFs sont déjà dans `web_media_cache` SQLite ; un
    // chemin natif n'aurait aucun sens.
    if (kIsWeb) return;
    try {
      await _persistRemoteDocumentsLocally(patientId, remoteDocuments);
    } catch (e) {
      // ignore: avoid_print
      print('[docs prefetch] persist-to-disk failed: $e');
    }
  }

  /// Pour chaque document remote sans `local_file_path` côté DB, télécharge
  /// (via le cache MediaCacheService déjà chaud) puis copie le fichier vers
  /// un chemin stable et persistent et met à jour la table `documents`.
  /// L'existant est préservé : si l'utilisateur a uploadé le doc en local
  /// (donc `local_file_path` non-vide), on ne touche à rien.
  Future<void> _persistRemoteDocumentsLocally(
    String patientId,
    List<Map<String, dynamic>> remoteDocuments,
  ) async {
    if (remoteDocuments.isEmpty) return;
    final db = await _database.database;

    // Lit toutes les lignes de ce patient pour résoudre `local_id` à partir
    // de l'URL remote. C'est `mergeRemoteDocuments` qui décide du
    // `local_id` final (souvent un id pré-existant si le doc avait
    // d'abord été uploadé offline).
    final rows = await db.query(
      'documents',
      columns: const [
        'local_id',
        'file_ext',
        'remote_file_path',
        'remote_public_url',
        'local_file_path',
      ],
      where: 'patient_local_id = ?',
      whereArgs: [patientId],
    );
    if (rows.isEmpty) return;

    // Mappe l'URL remote (publicUrl OU remote_file_path) → ligne DB pour
    // retrouver le `local_id`.
    final byKey = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final url = (row['remote_public_url'] as String?)?.trim() ?? '';
      final path = (row['remote_file_path'] as String?)?.trim() ?? '';
      if (url.isNotEmpty) byKey[url] = row;
      if (path.isNotEmpty) byKey[path] = row;
    }

    final docsDir = await getApplicationDocumentsDirectory();
    for (final remote in remoteDocuments) {
      final url = remote['publicUrl']?.toString().trim() ?? '';
      if (url.isEmpty) continue;
      final row =
          byKey[url] ?? byKey[remote['remotePath']?.toString().trim() ?? ''];
      if (row == null) continue;

      // Skip si l'utilisateur a déjà des bytes locaux (upload offline,
      // ou ré-upload après annotation).
      final existingPath = (row['local_file_path'] as String?)?.trim() ?? '';
      if (existingPath.isNotEmpty && await File(existingPath).exists()) {
        continue;
      }

      // Récupère via MediaCacheService (auth-aware, déjà chauffé par
      // l'étape 1).
      final cached = await MediaCacheService.instance.fetch(
        url,
        headers: MediaCacheService.authHeaders(),
      );
      if (cached == null) continue;

      final localId = row['local_id'] as String;
      final ext = (row['file_ext'] as String? ?? '').trim();
      final extSuffix = ext.isEmpty ? '' : '.$ext';

      try {
        final targetDir = Directory(
          p.join(docsDir.path, 'cached_remote_documents', patientId),
        );
        if (!await targetDir.exists()) {
          await targetDir.create(recursive: true);
        }
        final target = File(p.join(targetDir.path, '$localId$extSuffix'));
        if (!await target.exists()) {
          await cached.copy(target.path);
        }
        await db.update(
          'documents',
          {'local_file_path': target.path},
          // Re-vérifie côté SQL : entre l'instant où on a lu la row et
          // maintenant un autre flux a pu écrire un chemin (ex. user
          // qui ré-importe le doc localement). On n'écrase que si
          // toujours vide.
          where:
              'local_id = ? AND (local_file_path IS NULL OR local_file_path = "")',
          whereArgs: [localId],
        );
      } catch (e) {
        // ignore: avoid_print
        print('[docs persist] copy/update failed for $localId: $e');
      }
    }
  }

  DocItem _mapRow(Map<String, Object?> row) {
    final ext = (row['file_ext'] as String? ?? '').toLowerCase();
    final type = _typeForExtension(ext);
    final rawTags = row['tags_json'] as String? ?? '[]';
    final decodedTags = (jsonDecode(rawTags) as List<dynamic>).cast<String>();
    final isReport = decodedTags.any(
      (tag) => tag.trim().toLowerCase() == 'rapport',
    );
    final createdAt = row['created_at'] as String;
    final updatedAt = row['updated_at'] as String? ?? createdAt;

    return DocItem(
      id: row['local_id'] as String,
      type: type,
      name: row['file_name'] as String,
      title: row['title'] as String,
      url: row['remote_public_url'] as String?,
      date: isReport ? updatedAt : createdAt,
      localPath: row['local_file_path'] as String?,
      // Web-only: the freshly captured bytes as a data URL. Populated by
      // `importDocumentBytes` on web and cleared once the sync processor
      // uploads them.
      dataUrl: row['local_file_data_url'] as String?,
      tags: decodedTags,
      syncState: SyncState.values.byName(row['sync_state'] as String),
      categoryOrder: (row['category_order'] as num?)?.toInt(),
      annotationsJson: row['annotations_json'] as String?,
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

  /// Compare deux timestamps ISO-8601 (ex. `2026-05-07T14:30:00Z`)
  /// pour décider si la version remote est strictement plus récente
  /// que la version locale. Utilisé par `mergeRemoteDocuments` pour
  /// décider si on rattrape une row locale `pendingSync` orpheline.
  /// En cas de timestamp manquant ou invalide, renvoie `false` (= refuse
  /// le merge) pour rester safe.
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
}

/// Container plat pour un document à embarquer **inline** dans la
/// requête HTTP de génération PDF. Construit par
/// [DocumentRepository.fetchVisitReportInlineBytes].
///
/// Les champs `tags`, `title`, `dossierId`, `mimeType` sont sérialisés
/// dans un champ multipart `inline_doc_<localId>_meta` (JSON). Les
/// `bytes` sont attachés comme `MultipartFile` avec le fieldname
/// `inline_doc_<localId>`. Côté serveur, cf.
/// `parseInlineReportAssets()` dans `server/index.mjs`.
class InlineDocumentBytes {
  InlineDocumentBytes({
    required this.localId,
    required this.fileName,
    required this.mimeType,
    required this.tags,
    required this.bytes,
    this.title = '',
    this.dossierId,
  });

  final String localId;
  final String fileName;
  final String mimeType;
  final List<String> tags;
  final String title;
  final String? dossierId;
  final Uint8List bytes;
}
