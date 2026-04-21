import 'dart:convert';
import 'dart:io';

import '../models/types.dart';
import 'auth_service.dart';
import 'dossier_repository.dart';
import 'document_repository.dart';
import 'note_repository.dart';
import 'nocodb_api_client.dart';
import 'nocodb_sync_service.dart';
import 'retirement_funds_repository.dart';
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

  /// Uploads a [File] as the current user's profile photo.
  /// Reads the file, base64-encodes it as a `data:<mime>;base64,...` URL,
  /// and POSTs to the backend. Returns the resolved public photo URL.
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
    return _nocodbApiClient.uploadProfilePhoto(dataUrl);
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

  Future<RetirementFund> updateRetirementFund(RetirementFund fund) async {
    final saved = await _nocodbApiClient.updateRetirementFund(
      fundId: fund.id,
      fund: fund,
    );
    await _retirementFundsRepository.upsertFund(saved);
    return saved;
  }

  Future<List<AdminAccessMember>> fetchAdminAccessMembers() async {
    return _nocodbApiClient.fetchAdminAccessMembers();
  }

  Future<String?> regenerateAccessPassword(String email) async {
    return _nocodbApiClient.regenerateAccessPassword(email);
  }

  Future<String?> setAccessPassword({
    required String email,
    String? password,
  }) async {
    return _nocodbApiClient.setAccessPassword(email: email, password: password);
  }

  Future<AdminAccessMember> createAccessMember({
    required String email,
    required String displayName,
    required LocalUserRole role,
    String? establishmentId,
    String? password,
  }) async {
    return _nocodbApiClient.createAccessMember(
      email: email,
      displayName: displayName,
      role: role,
      establishmentId: establishmentId,
      password: password,
    );
  }

  Future<AdminAccessMember> updateAccessMember({
    required String email,
    String? displayName,
    String? establishmentId,
  }) async {
    return _nocodbApiClient.updateAccessMember(
      email: email,
      displayName: displayName,
      establishmentId: establishmentId,
    );
  }

  Future<void> deleteAccessMember(String email) async {
    return _nocodbApiClient.deleteAccessMember(email);
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
    try {
      final remoteDocuments = await _nocodbApiClient.fetchDocuments(patientId);
      if (remoteDocuments.isEmpty) return false;
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
  }) async {
    return _documentRepository.importDocument(
      patientId: patientId,
      sourceFile: File(filePath),
      tags: tags,
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
  }) async {
    await _noteRepository.saveDrawingJson(
      patientId: patientId,
      tabKey: tabKey,
      drawingJson: drawingJson,
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
