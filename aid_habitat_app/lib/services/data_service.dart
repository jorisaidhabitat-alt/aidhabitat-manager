import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/types.dart';
import '../models/visit_report_categories.dart';
import 'access_members_repository.dart';
import 'auth_service.dart';
import 'dossier_repository.dart';
import 'document_repository.dart';
import 'note_repository.dart';
import 'nocodb_api_client.dart';
import 'nocodb_sync_service.dart';
import 'retirement_funds_repository.dart';
import 'sync_engine.dart';
import 'sync_repository.dart';
import 'wiki_repository.dart';

class DataService {
  DataService._internal();

  static final DataService _instance = DataService._internal();

  factory DataService() => _instance;

  final DossierRepository _dossierRepository = DossierRepository();
  final DocumentRepository _documentRepository = DocumentRepository();
  final NoteRepository _noteRepository = NoteRepository();
  final NocodbApiClient _nocodbApiClient = NocodbApiClient();
  final SyncRepository _syncRepository = SyncRepository();
  final NocodbSyncService _nocodbSyncService = NocodbSyncService();
  final AuthService _authService = AuthService();
  final WikiRepository _wikiRepository = WikiRepository();
  final RetirementFundsRepository _retirementFundsRepository =
      RetirementFundsRepository();
  final AccessMembersRepository _accessMembersRepository =
      AccessMembersRepository();

  Future<void> initialize() async {
    await _dossierRepository.initialize();
  }

  /// One-shot cleanup run at app boot: drops sync operations that are
  /// almost certainly obsolete (failed retries or very old pending ops
  /// captured by a previous app version). Prevents stale payloads from
  /// overwriting fresh remote data on startup. Errors are swallowed so
  /// a corrupted sync_operations table never blocks the app from
  /// launching.
  Future<void> purgeStaleSyncOperations() async {
    try {
      await _syncRepository.purgeStalePendingOperations();
    } catch (_) {
      // ignore — cleanup is best-effort
    }
  }

  Future<bool> refreshLocalAuthStateFromRemote() async {
    try {
      final remoteUsers = await _nocodbApiClient.fetchLocalAuthState();
      if (remoteUsers.isEmpty) return false;
      return _authService.mergeRemoteUsers(remoteUsers);
    } catch (_) {
      return false;
    }
  }

  Future<List<Dossier>> fetchDossiers() async {
    return _dossierRepository.fetchAllDossiers();
  }

  /// Fetches a single dossier by its local id. Used when returning from
  /// the visit report to refresh the dossier screen's prop with the
  /// fresh patient / housing data.
  Future<Dossier?> fetchDossierById(String dossierLocalId) {
    return _dossierRepository.fetchDossierById(dossierLocalId);
  }

  /// Create a new beneficiary + dossier locally (works offline).
  /// A sync operation is automatically enqueued.
  Future<Dossier> createDossierOffline({
    required String firstName,
    required String lastName,
    String ergoId = '',
  }) async {
    return _dossierRepository.createDossierOffline(
      firstName: firstName,
      lastName: lastName,
      ergoId: ergoId,
    );
  }

  Future<List<WikiItem>> fetchWikiItems() async {
    return _wikiRepository.fetchAllItems();
  }

  Future<bool> refreshWikiItemsFromRemote() async {
    try {
      final remoteItems = await _nocodbApiClient.fetchWikiItems();
      if (remoteItems.isEmpty) return false;
      await _wikiRepository.mergeRemoteItems(remoteItems);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Update patient fields locally and enqueue a sync operation.
  Future<void> updatePatientLocal({
    required String patientLocalId,
    required Map<String, dynamic> updates,
  }) async {
    return _dossierRepository.updatePatientLocal(
      patientLocalId: patientLocalId,
      updates: updates,
    );
  }

  /// Creates a wiki item with an offline-first flow: the record is written
  /// to SQLite immediately (with a `local_draft_*` id) and a sync operation
  /// is enqueued. Works without network — the row is picked up by the sync
  /// engine as soon as connectivity returns.
  Future<WikiItem> createWikiItem({
    required String title,
    required String description,
    required String category,
    required List<String> tags,
    String imageDataUrl = '',
  }) async {
    return _wikiRepository.createLocalDraft(
      title: title,
      description: description,
      category: category,
      tags: tags,
      imageDataUrl: imageDataUrl,
    );
  }

  /// Offline-first profile photo upload: encodes the file as a base64 data
  /// URL, stashes it in SQLite (`app_users.pending_photo_data_url`) so the
  /// UI can render it immediately, and enqueues a `profile_photo` sync op.
  /// Returns the data URL so the caller can display it optimistically —
  /// when the sync completes, the server-resolved URL replaces it in the
  /// `profile_photo_url` column.
  Future<String> uploadProfilePhoto(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final extension = imageFile.path.split('.').last.toLowerCase();
    final mimeType = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
    final base64Data = base64Encode(bytes);
    final dataUrl = 'data:$mimeType;base64,$base64Data';
    await _authService.persistPendingProfilePhoto(dataUrl);
    SyncEngine().notify();
    return dataUrl;
  }

  /// Variante cross-platform : prend un data URL pré-encodé (Web-safe)
  /// et le persiste localement + enqueue le sync. Utilisée par
  /// `account_dialog._pickAndUploadPhoto` qui lit les bytes via
  /// `XFile.readAsBytes()` (fonctionne sur web où `dart:io.File` ne
  /// peut pas ouvrir un blob URL).
  Future<String> uploadProfilePhotoBytes(String dataUrl) async {
    await _authService.persistPendingProfilePhoto(dataUrl);
    SyncEngine().notify();
    return dataUrl;
  }

  Future<Map<String, dynamic>> fetchAnahStatus() async {
    return _nocodbApiClient.fetchAnahStatus();
  }

  /// Directly fetch raw reference data from the backend. Most callers
  /// should use `ReferencesService()` which caches this in memory.
  Future<ReferencesPayload> fetchReferences() async {
    return _nocodbApiClient.fetchReferences();
  }

  Future<List<RetirementFund>> fetchRetirementFunds() async {
    return _retirementFundsRepository.fetchAllFunds();
  }

  /// Liste des noms de **caisses principales** pour le dropdown
  /// « Caisse princ. » de l'onglet Bénéficiaire > Admin.
  ///
  /// Source NocoDB : table `caisses_de_retraite` (principales),
  /// distincte de `caisses_de_retraite_complementaires`. On passe par
  /// l'endpoint serveur `/api/retirement-funds-principal` qui lit la
  /// bonne table — pas le repository local `retirement_funds` qui ne
  /// cache QUE les complémentaires (cf. `/api/retirement-funds`).
  ///
  /// Bug avant 2026-04-28 : ce getter renvoyait
  /// `_retirementFundsRepository.fetchAllNames()`, soit la liste des
  /// **complémentaires** par méprise — du coup le dropdown « Caisse
  /// princ. » et le dropdown « Caisse complém. » proposaient les
  /// mêmes options.
  ///
  /// Pas de cache local pour l'instant (pas de table SQLite dédiée
  /// aux principales). Si l'app est offline, on retombe sur une
  /// liste vide — l'ergo verra le dropdown « Sélectionner... » sans
  /// choix tant que le réseau ne revient pas.
  Future<List<String>> fetchPrincipalRetirementFundNames() async {
    try {
      return await _nocodbApiClient.fetchPrincipalRetirementFundNames();
    } catch (_) {
      return const [];
    }
  }

  Future<bool> refreshRetirementFundsFromRemote() async {
    try {
      final remoteFunds = await _nocodbApiClient.fetchRetirementFunds();
      if (remoteFunds.isEmpty) return false;
      await _retirementFundsRepository.mergeRemoteFunds(remoteFunds);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Offline-first retirement fund update: writes to SQLite immediately
  /// and enqueues a sync operation. The fund is pushed to the server when
  /// connectivity returns.
  Future<RetirementFund> updateRetirementFund(RetirementFund fund) async {
    return _retirementFundsRepository.updateLocalFund(fund);
  }

  /// Pulls the latest admin access list from the server and merges into
  /// SQLite + propagates to `app_users`. Used only for offline login
  /// support — the app no longer exposes any admin UI; all member
  /// management happens on NocoDB. Errors swallowed.
  Future<bool> refreshAdminAccessMembersFromRemote() async {
    try {
      final remote = await _nocodbApiClient.fetchAdminAccessMembers();
      if (remote.isEmpty) return false;
      await _accessMembersRepository.mergeRemoteMembers(remote);
      // Propagate to app_users so ergos provisioned on NocoDB can log in
      // offline after the first successful sync.
      await _authService.mergeRemoteUsers(
        remote.map(_accessMemberToAuthUserMap).toList(),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Converts an [AdminAccessMember] into the shape [AuthService.mergeRemoteUsers]
  /// expects so new ergos provisioned on the server can log in offline.
  Map<String, dynamic> _accessMemberToAuthUserMap(AdminAccessMember m) {
    return {
      'email': m.email,
      'displayName': m.displayName,
      'role': m.role == LocalUserRole.admin ? 'ADMIN' : 'ERGO',
      'establishmentId': m.establishmentLabel,
      'ergoLabel': m.ergoLabel,
      'isActive': m.selectable,
      'scopes': const <Map<String, dynamic>>[],
    };
  }

  /// Updates a wiki item offline-first: edits are persisted to SQLite and a
  /// sync operation is enqueued. If [newImageDataUrl] is provided, it is
  /// stored in `pending_image_data_url` and uploaded on next sync.
  Future<WikiItem> updateWikiItem(
    WikiItem item, {
    String? newImageDataUrl,
  }) async {
    return _wikiRepository.updateLocalItem(
      item,
      imageDataUrl: newImageDataUrl,
    );
  }

  Future<List<DocItem>> fetchDocuments(String patientId) async {
    return _documentRepository.fetchDocuments(patientId);
  }

  Future<bool> refreshDocumentsFromRemote(String patientId) async {
    // 1. Auto-débloquage : avant tout fetch, on réhabilite les
    //    `upload_file` ops bloquées en `failed` → le SyncEngine va
    //    les retenter au prochain cycle. Idempotent côté serveur (dédup
    //    par `documentLocalId`), donc retry safe.
    //
    //    Demande utilisateur 2026-04-29 : « je ne dois pas avoir à
    //    faire ces reload à chaque fois. Tu dois pouvoir anticiper
    //    cela ». Sans ce hook, un upload échoué une fois avec une
    //    erreur non-transient (4xx, parse, etc.) restait stuck à vie
    //    en local — l'utilisateur voyait son doc localement mais pas
    //    sur les autres devices.
    try {
      final rehabbed = await _syncRepository.rehabFailedDocumentUploads();
      if (rehabbed > 0) {
        // Notifie le SyncEngine pour qu'il pousse sans attendre les
        // 60 s du timer périodique → le doc apparaît côté serveur
        // dans les secondes qui suivent.
        SyncEngine().notify();
      }
    } catch (_) {
      // Best-effort : un échec de rehab ne doit pas bloquer le fetch.
    }

    // 2. Fetch remote.
    try {
      final remoteDocuments = await _nocodbApiClient.fetchDocuments(patientId);
      // BUG fix 2026-04-29 : avant, `if (remoteDocuments.isEmpty) return false;`
      // empêchait le merge même quand l'API renvoyait correctement une
      // liste vide. Conséquence : le local cache stale n'était jamais
      // purgé. Maintenant on merge TOUJOURS, l'empty list est un état
      // valide qui doit purger les docs locaux `synced` orphelins.
      await _documentRepository.mergeRemoteDocuments(
        patientId,
        remoteDocuments,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<DocItem> importDocument({
    required String patientId,
    required String filePath,
    List<String> tags = const ['Autre'],
    int? categoryOrder,
  }) async {
    return _documentRepository.importDocument(
      patientId: patientId,
      sourceFile: File(filePath),
      tags: tags,
      categoryOrder: categoryOrder,
    );
  }

  /// Variante web : importe directement les bytes d'une photo
  /// (compressée) sans passer par un File. Utilisé par l'onglet
  /// Photos du relevé de visite quand on tourne en PWA, et par le
  /// bouton « Générer le rapport » pour pousser le PDF dans
  /// l'espace Documents du dossier.
  Future<DocItem> importDocumentBytes({
    required String patientId,
    required List<int> bytes,
    required String fileName,
    List<String> tags = const ['Autre'],
    String? title,
    int? categoryOrder,
    String? dossierId,
  }) async {
    return _documentRepository.importDocumentBytes(
      patientId: patientId,
      bytes: bytes,
      fileName: fileName,
      tags: tags,
      title: title,
      categoryOrder: categoryOrder,
      dossierId: dossierId,
    );
  }

  /// Insère un doc déjà sauvegardé côté serveur — skip la queue
  /// upload (évite le 413 Vercel sur les PDFs > 4.5 MB).
  Future<DocItem> importDocumentRemoteOnly({
    required String patientId,
    required List<int> bytes,
    required String fileName,
    required String remoteUuid,
    List<String> tags = const ['Autre'],
    String? title,
    int? categoryOrder,
    String? dossierId,
  }) async {
    return _documentRepository.importDocumentRemoteOnly(
      patientId: patientId,
      bytes: bytes,
      fileName: fileName,
      remoteUuid: remoteUuid,
      tags: tags,
      title: title,
      categoryOrder: categoryOrder,
      dossierId: dossierId,
    );
  }

  /// Met à jour les tags + l'ordre dans la catégorie visite d'un
  /// document (Logement / Accessibilité / Sanitaires / À classer).
  /// Utilisé par l'onglet Photos pour déplacer une photo entre
  /// catégories ou la sortir d'une catégorie. Voir
  /// [DocumentRepository.setVisitCategorization].
  Future<void> setDocumentVisitCategorization({
    required String documentId,
    required List<String> tags,
    int? categoryOrder,
  }) async {
    await _documentRepository.setVisitCategorization(
      documentId: documentId,
      tags: tags,
      categoryOrder: categoryOrder,
    );
  }

  /// Réordonne plusieurs documents d'une catégorie en une fois
  /// (drag-to-reorder). Voir
  /// [DocumentRepository.reorderVisitCategory].
  Future<void> reorderVisitCategoryDocuments({
    required List<String> orderedDocumentIds,
  }) async {
    await _documentRepository.reorderVisitCategory(
      orderedDocumentIds: orderedDocumentIds,
    );
  }

  /// Supprime un document. Voir [DocumentRepository.deleteDocument].
  Future<void> deleteDocument(String documentId) async {
    await _documentRepository.deleteDocument(documentId);
  }

  /// Lit les observations de synthèse d'un dossier (Projet usager,
  /// Résumé préconisations, Observations équipements). Renvoie un
  /// objet vide si aucune ligne n'existe encore.
  Future<ObservationsSynthese> fetchObservations(String dossierId) async {
    final existing = await _dossierRepository.fetchObservations(dossierId);
    return existing ?? ObservationsSynthese(dossierId: dossierId);
  }

  /// Upsert local + sync NocoDB des observations de synthèse.
  /// Voir [DossierRepository.upsertObservations].
  Future<void> upsertObservations(
    String dossierId,
    ObservationsSynthese observations,
  ) async {
    await _dossierRepository.upsertObservations(dossierId, observations);
  }

  /// Génère le rapport PDF côté serveur et renvoie ses bytes + nom
  /// de fichier proposé. Voir
  /// [NocodbApiClient.downloadVisitReport]. Le caller est responsable
  /// de l'ouverture / sauvegarde / partage des bytes — ce service ne
  /// touche pas au filesystem.
  ///
  /// Avant l'envoi, on collecte les **assets locaux non-encore-syncés**
  /// (photos VAD + plans) et on les embarque inline dans la requête
  /// multipart. Robuste face à un sync NocoDB intermittent : si l'ergo
  /// clique « Générer » pendant qu'une partie des photos vient juste
  /// d'être uploadée et l'autre pas, le serveur a quand même tous les
  /// bytes nécessaires (les inline gagnent sur la lecture NocoDB).
  Future<({Uint8List bytes, String fileName, Map<String, dynamic>? stats, String? savedDocUuid})>
      downloadVisitReport({required String dossierId}) async {
    // Résolution patientId à partir du dossierId — nécessaire pour
    // récupérer les documents et notes scopés au patient. Si le dossier
    // est introuvable localement, on tombe sur les listes vides → POST
    // simple sans body (comportement v1).
    String? patientId;
    try {
      final dossier = await _dossierRepository.fetchDossierById(dossierId);
      patientId = dossier?.patient.id;
    } catch (_) {
      // Pas bloquant : on génère sans inline si la résolution échoue.
    }

    var inlineDocs = const <InlineDocumentBytes>[];
    var inlinePlans = const <InlinePlanBytes>[];
    if (patientId != null && patientId.isNotEmpty) {
      try {
        inlineDocs = await _documentRepository
            .fetchVisitReportInlineBytes(patientId);
      } catch (e) {
        // ignore: avoid_print
        print('[report] inline docs lookup failed: $e');
      }
      try {
        inlinePlans = await _noteRepository
            .fetchPlanReportInlineBytes(patientId, dossierId: dossierId);
      } catch (e) {
        // ignore: avoid_print
        print('[report] inline plans lookup failed: $e');
      }
    }

    if (inlineDocs.isNotEmpty || inlinePlans.isNotEmpty) {
      // ignore: avoid_print
      print(
        '[report] inline assets joints à la requête : '
        '${inlineDocs.length} doc(s) + ${inlinePlans.length} plan(s)',
      );
    }

    return _nocodbApiClient.downloadVisitReport(
      dossierId: dossierId,
      inlineDocuments: inlineDocs,
      inlinePlans: inlinePlans,
    );
  }

  Future<String?> fetchNoteDrawingJson({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
  }) async {
    return _noteRepository.fetchDrawingJson(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: pageNumber,
    );
  }

  /// Pass-through pour la migration des anciennes notes SDB/WC vers le
  /// tabKey partagé `Sanitaires-Notes`. Voir
  /// [NoteRepository.purgeLegacySanitairesNotes].
  Future<int> purgeLegacySanitairesNotes(String patientId) {
    return _noteRepository.purgeLegacySanitairesNotes(patientId);
  }

  Future<bool> refreshNotePageFromRemote({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
  }) async {
    try {
      final remoteNote = await _nocodbApiClient.fetchNotePage(
        patientId: patientId,
        tabKey: tabKey,
        pageNumber: pageNumber,
      );
      if (remoteNote == null) return false;
      return _noteRepository.mergeRemoteNotePage(
        patientId: patientId,
        tabKey: tabKey,
        pageNumber: pageNumber,
        drawingJson: remoteNote['drawingJson']?.toString() ?? '',
        remotePath: remoteNote['remotePath']?.toString(),
        remoteUrl: remoteNote['remoteUrl']?.toString(),
        updatedAt: remoteNote['updatedAt']?.toString(),
        // Le serveur renvoie 'avant' / 'apres' / null — on transmet
        // tel quel à mergeRemoteNotePage qui se charge du fallback
        // sur la valeur locale si la clé est absente.
        planPhase: remoteNote['planPhase']?.toString(),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> saveNoteDrawingJson({
    required String patientId,
    required String tabKey,
    required String drawingJson,
    int pageNumber = 0,
    String? previewDataUrl,
  }) async {
    await _noteRepository.saveDrawingJson(
      patientId: patientId,
      tabKey: tabKey,
      drawingJson: drawingJson,
      pageNumber: pageNumber,
      previewDataUrl: previewDataUrl,
    );
  }

  /// Met à jour la phase (avant / après / non classé) d'un dessin de
  /// l'onglet Plans. Voir [NoteRepository.setPlanPhase].
  Future<void> setNotePlanPhase({
    required String patientId,
    required String tabKey,
    required int pageNumber,
    required PlanPhase? phase,
  }) async {
    await _noteRepository.setPlanPhase(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: pageNumber,
      phase: phase,
    );
  }

  /// Lit la phase courante d'un dessin Plans (null = non classé).
  Future<PlanPhase?> fetchNotePlanPhase({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
  }) async {
    return _noteRepository.fetchPlanPhase(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: pageNumber,
    );
  }

  Future<void> updatePatientFields(
    String patientLocalId,
    Map<String, dynamic> fields,
  ) async {
    await _dossierRepository.updatePatientFields(patientLocalId, fields);
  }

  Future<void> updateHousingFields(
    String patientLocalId,
    Map<String, dynamic> fields,
  ) async {
    await _dossierRepository.updateHousingFields(patientLocalId, fields);
  }

  Future<void> updateDossierFields(
    String dossierLocalId,
    Map<String, dynamic> fields,
  ) async {
    await _dossierRepository.updateDossierFields(dossierLocalId, fields);
  }

  Future<Map<String, dynamic>> fetchFormData(
    String patientId,
    String formKey,
  ) async {
    return _dossierRepository.fetchFormData(patientId, formKey);
  }

  Future<void> saveFormData(
    String patientId,
    String formKey,
    Map<String, dynamic> data,
  ) async {
    await _dossierRepository.saveFormData(patientId, formKey, data);
  }

  Future<List<SyncOperation>> fetchPendingOperations() async {
    return _syncRepository.fetchRunnableOperations();
  }

  Future<bool> refreshWorkspaceFromRemote() async {
    try {
      // Use the raw-payload path so ALL server-returned fields (including
      // those with no Dart model representation — cheminement_*, rooms_json,
      // heating_details_json, medicalContext, autonomy, occupants, etc.)
      // are persisted to SQLite. UPDATE semantics inside
      // mergeRemoteDossierPayloads also preserve local-only columns that
      // the server doesn't know about.
      final rawPayloads = await _nocodbApiClient.fetchDossierPayloads();
      if (rawPayloads.isEmpty) return false;
      await _dossierRepository.mergeRemoteDossierPayloads(rawPayloads);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Pulls diagnostic sanitaires for [dossierId] from the server and
  /// merges into SQLite. No-op + returns false when offline or when the
  /// local row has pending unsynced edits. Errors swallowed.
  Future<bool> refreshDiagnosticSanitaireFromRemote(String dossierId) async {
    try {
      return await _dossierRepository.refreshDiagnosticSanitaireFromRemote(
        dossierId,
      );
    } catch (_) {
      return false;
    }
  }

  /// Pulls visit recommendations for [dossierId] from the server and
  /// merges into SQLite. Same guards/error handling as above.
  Future<bool> refreshVisitRecommendationsFromRemote(String dossierId) async {
    try {
      return await _dossierRepository.refreshVisitRecommendationsFromRemote(
        dossierId,
      );
    } catch (_) {
      return false;
    }
  }

  Future<SyncRunResult> runSync() async {
    return _nocodbSyncService.pushPendingChanges();
  }

  Future<Dossier?> fetchRemoteDossierById(String dossierId) async {
    try {
      final remoteDossiers = await _nocodbApiClient.fetchDossiers();
      return remoteDossiers.cast<Dossier?>().firstWhere(
        (d) => d!.id == dossierId,
        orElse: () => null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> resolveConflictKeepLocal(Dossier dossier) async {
    await _syncRepository.setEntitySyncState(
      entityType: 'dossier',
      entityLocalId: dossier.id,
      syncState: SyncState.pendingSync,
    );
  }

  Future<void> resolveConflictTakeRemote(Dossier remoteDossier) async {
    await _dossierRepository.forceReplaceWithRemote(remoteDossier);
    await _syncRepository.clearPendingOperationsForEntity(remoteDossier.id);
  }

}
