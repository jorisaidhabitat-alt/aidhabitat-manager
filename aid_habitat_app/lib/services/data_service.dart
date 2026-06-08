import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/types.dart';
import '../models/visit_report_categories.dart';
import 'access_members_repository.dart';
import 'auth_service.dart';
import 'dossier_repository.dart';
import 'document_repository.dart';
import 'local_database.dart';
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
  final Map<String, Future<bool>> _documentRefreshInFlight =
      <String, Future<bool>>{};

  Future<void> initialize() async {
    await _dossierRepository.initialize();
    // Câble le callback que `NocodbSyncService` invoque après chaque
    // auto-résolution de conflit 409 (« remote wins ») pour rafraîchir
    // tout de suite les données locales avec la version serveur, sans
    // attendre le prochain tick périodique du SyncEngine. Évite que
    // l'ergo génère un PDF / regarde une page juste après le conflit
    // et voie encore l'ancienne valeur locale écrasée à la milliseconde
    // suivante.
    _nocodbSyncService.onConflictAutoResolved = refreshWorkspaceFromRemote;
  }

  /// One-shot cleanup run at app boot: drops sync operations that are
  /// almost certainly obsolete (failed retries or very old pending ops
  /// captured by a previous app version) AND débloque les entités
  /// historiquement bloquées en `conflict` state (avant la mise en
  /// place de l'auto-résolution « remote wins »). Prevents stale
  /// payloads from overwriting fresh remote data on startup. Errors
  /// are swallowed so a corrupted sync_operations table never blocks
  /// the app from launching.
  Future<void> purgeStaleSyncOperations() async {
    try {
      await _syncRepository.purgeStalePendingOperations();
      // Récupération boot pour les conflits stuck depuis l'ancien
      // monde (où on marquait `conflict` et on attendait l'action
      // utilisateur). On reset ces entités à `synced` et on clear
      // leurs ops pending — le prochain pull workspace appliquera la
      // vérité serveur. Demande utilisateur 2026-04-30 : « tout doit
      // se faire tout seul en backend ».
      final unstuckCount = await _syncRepository.unstickConflictedEntities();
      if (unstuckCount > 0) {
        // ignore: avoid_print
        print(
          '[boot] $unstuckCount entité(s) en conflict débloquée(s) → '
          'le prochain pull les rafraîchira avec la version serveur',
        );
      }
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
  ///
  /// Tous les champs admin (`natureAccompagnement`, `numberPeople`,
  /// `fiscalRevenue`, adresse) sont demandés à la création depuis 2026-04-30
  /// pour que le dossier ait dès le départ assez de données pour le
  /// rapport PDF.
  Future<Dossier> createDossierOffline({
    required String firstName,
    required String lastName,
    String ergoId = '',
    String natureAccompagnement = '',
    int numberPeople = 1,
    double? fiscalRevenue,
    String address = '',
    String city = '',
    String zipCode = '',
  }) async {
    return _dossierRepository.createDossierOffline(
      firstName: firstName,
      lastName: lastName,
      ergoId: ergoId,
      natureAccompagnement: natureAccompagnement,
      numberPeople: numberPeople,
      fiscalRevenue: fiscalRevenue,
      address: address,
      city: city,
      zipCode: zipCode,
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

  /// Toggle local-only du flag « bénéficiaire préparé » d'un dossier
  /// (coche ronde dans le bandeau bénéficiaire). Voir
  /// [DossierRepository.setBeneficiaryPrepared] — pas de sync NocoDB
  /// en v1 (le flag reste sur l'appareil).
  Future<void> setBeneficiaryPrepared({
    required String dossierLocalId,
    required bool prepared,
  }) {
    return _dossierRepository.setBeneficiaryPrepared(
      dossierLocalId: dossierLocalId,
      prepared: prepared,
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
  ///
  /// Refonte 2026-05-15 : on COMPRESSE la photo (max 1024px + JPEG 80)
  /// AVANT de l'enqueuer. Sans ça, une photo iPhone brut (~5-10 Mo)
  /// dépassait la limite Vercel de 4.5 Mo body → 413 Content Too Large
  /// → retry en boucle (« 7 tentatives ») sans aucune chance de
  /// succès. La compression amène la plupart des photos à <500 Ko,
  /// largement sous la limite.
  Future<String> uploadProfilePhoto(File imageFile) async {
    final rawBytes = await imageFile.readAsBytes();
    final dataUrl = _compressForUpload(rawBytes);
    await _authService.persistPendingProfilePhoto(dataUrl);
    SyncEngine().notify();
    return dataUrl;
  }

  /// Variante cross-platform : prend un data URL pré-encodé (Web-safe)
  /// et le persiste localement + enqueue le sync. Utilisée par
  /// `account_dialog._pickAndUploadPhoto` qui lit les bytes via
  /// `XFile.readAsBytes()` (fonctionne sur web où `dart:io.File` ne
  /// peut pas ouvrir un blob URL).
  ///
  /// Refonte 2026-05-15 : compression aussi appliquée ici (cf.
  /// `uploadProfilePhoto`). Le data URL passé peut contenir n'importe
  /// quel format/taille — on décode, resize, ré-encode en JPEG 80.
  Future<String> uploadProfilePhotoBytes(String dataUrl) async {
    final compressed = _compressDataUrlForUpload(dataUrl);
    await _authService.persistPendingProfilePhoto(compressed);
    SyncEngine().notify();
    return compressed;
  }

  /// Resize une image (bytes bruts) à `maxDim` pixels max sur le grand
  /// côté + ré-encode en JPEG quality 80 → renvoie un data URL prêt à
  /// être uploadé. Si le décodage échoue (format inconnu, fichier
  /// corrompu), on tombe sur l'envoi brut tel quel.
  String _compressForUpload(
    Uint8List rawBytes, {
    int maxDim = 1024,
    int quality = 80,
  }) {
    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) {
        // Fallback : on n'arrive pas à décoder, on envoie tel quel.
        return 'data:image/jpeg;base64,${base64Encode(rawBytes)}';
      }
      final resized = (decoded.width > maxDim || decoded.height > maxDim)
          ? img.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? maxDim : null,
              height: decoded.height > decoded.width ? maxDim : null,
              interpolation: img.Interpolation.average,
            )
          : decoded;
      final jpegBytes = img.encodeJpg(resized, quality: quality);
      return 'data:image/jpeg;base64,${base64Encode(jpegBytes)}';
    } catch (_) {
      return 'data:image/jpeg;base64,${base64Encode(rawBytes)}';
    }
  }

  /// Variante qui prend un data URL en entrée (déjà encodé) → décode
  /// le base64, applique `_compressForUpload`. Utilisé par les call
  /// sites web (XFile.readAsBytes() → data URL → ici).
  String _compressDataUrlForUpload(String dataUrl) {
    try {
      final commaIdx = dataUrl.indexOf(',');
      if (commaIdx < 0) return dataUrl;
      final base64Part = dataUrl.substring(commaIdx + 1);
      final raw = base64Decode(base64Part);
      return _compressForUpload(raw);
    } catch (_) {
      return dataUrl; // fallback : envoie le data URL tel quel.
    }
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

  /// Crée une nouvelle caisse de retraite côté serveur (NocoDB
  /// `caisses_de_retraite_complementaires`). Demande utilisateur
  /// 2026-05-12 : bouton « Ajouter une caisse de retraite » dans
  /// l'écran caisses. Le résultat serveur est ensuite re-pull via
  /// `refreshRetirementFundsFromRemote()` pour merger dans la liste
  /// locale.
  Future<RetirementFund> createRetirementFund({
    required String name,
    String phone = '',
    String audience = '',
    String requestMethod = '',
    String requestDelay = '',
    String aidAmount = '',
    String therapistNote = '',
    String website = '',
  }) async {
    final created = await _nocodbApiClient.createRetirementFund(
      name: name,
      phone: phone,
      audience: audience,
      requestMethod: requestMethod,
      requestDelay: requestDelay,
      aidAmount: aidAmount,
      therapistNote: therapistNote,
      website: website,
    );
    // Re-pull la liste complète pour merger en SQLite local et que
    // l'écran appelant puisse re-fetchAll proprement.
    try {
      await refreshRetirementFundsFromRemote();
    } catch (_) {
      /* best-effort */
    }
    return created;
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
    return _wikiRepository.updateLocalItem(item, imageDataUrl: newImageDataUrl);
  }

  Future<List<DocItem>> fetchDocuments(String patientId) async {
    return _documentRepository.fetchDocuments(patientId);
  }

  /// Réhabilite les `upload_file` ops `failed` (cf. doc dans
  /// `SyncRepository.rehabFailedDocumentUploads`). Exposé publiquement
  /// pour permettre à `_generateReport` d'auto-débloquer une vieille
  /// op échouée AVANT le runSync — sans ça la nouvelle génération
  /// retombait en `_enqueueReportForLater` à cause d'une vieille op
  /// stuck (typiquement le 403 finalize transient signalé 2026-04-29).
  Future<int> rehabFailedDocumentUploads() async {
    try {
      final n = await _syncRepository.rehabFailedDocumentUploads();
      if (n > 0) SyncEngine().notify();
      return n;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> refreshDocumentsFromRemote(String patientId) {
    final key = patientId.trim();
    if (key.isEmpty) return Future.value(false);
    final existing = _documentRefreshInFlight[key];
    if (existing != null) return existing;

    final future = _refreshDocumentsFromRemoteUncoalesced(key);
    _documentRefreshInFlight[key] = future;
    future.whenComplete(() {
      if (_documentRefreshInFlight[key] == future) {
        _documentRefreshInFlight.remove(key);
      }
    });
    return future;
  }

  Future<bool> _refreshDocumentsFromRemoteUncoalesced(String patientId) async {
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
    String? title,
    int? categoryOrder,
  }) async {
    return _documentRepository.importDocument(
      patientId: patientId,
      sourceFile: File(filePath),
      tags: tags,
      title: title,
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

    /// Voir [DocumentRepository.importDocumentBytes] : id déterministe
    /// pour la dédup (cas typique : rapport PDF d'un dossier).
    String? localId,
  }) async {
    return _documentRepository.importDocumentBytes(
      patientId: patientId,
      bytes: bytes,
      fileName: fileName,
      tags: tags,
      title: title,
      categoryOrder: categoryOrder,
      dossierId: dossierId,
      localId: localId,
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
    String? clientDocumentId,
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
      clientDocumentId: clientDocumentId,
    );
  }

  Future<void> hideObsoleteReportDocuments({
    required String patientId,
    required String dossierId,
    String keepLocalId = '',
  }) async {
    await _documentRepository.hideObsoleteReportDocuments(
      patientId: patientId,
      dossierId: dossierId,
      keepLocalId: keepLocalId,
    );
  }

  /// Renomme un document et/ou met à jour ses tags. Utilisé par
  /// l'onglet Photos (dialog plein écran) pour permettre à l'ergo de
  /// renommer une photo et de toggle le tag `__pdf_no_label` qui
  /// contrôle l'affichage du label-overlay dans le rapport PDF.
  /// Synchronisé à NocoDB via le sync engine.
  Future<void> updateDocumentMetadata({
    required String documentId,
    required String title,
    required List<String> tags,
  }) async {
    await _documentRepository.updateDocumentMetadata(
      documentId: documentId,
      title: title,
      tags: tags,
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
  Future<
    ({
      Uint8List bytes,
      String fileName,
      Map<String, dynamic>? stats,
      String? savedDocUuid,
    })
  >
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
        inlineDocs = await _documentRepository.fetchVisitReportInlineBytes(
          patientId,
        );
      } catch (e) {
        // ignore: avoid_print
        print('[report] inline docs lookup failed: $e');
      }
      try {
        inlinePlans = await _noteRepository.fetchPlanReportInlineBytes(
          patientId,
          dossierId: dossierId,
        );
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

  /// Pull bulk : récupère TOUTES les notes d'un patient en 1 seul
  /// HTTP request et les merge en SQLite. À appeler au mount du
  /// VisitReportScreen (et idéalement plus tôt, dès que le dossier
  /// devient sélectionné dans la liste) pour que les NotesWidget
  /// affichent la note instantanément à l'arrivée sur le screen.
  ///
  /// Avant 2026-05-07 : chaque NotesWidget faisait son propre fetch
  /// au mount → la note arrivait 1-2 s après les autres infos du
  /// dossier (déjà chargées via le pull workspace). Désormais le
  /// bulk pull précède le mount des widgets → tout arrive ensemble.
  ///
  /// Renvoie le nombre de notes effectivement mergées (utile pour
  /// log/debug). Best-effort, errors swallowed.
  Future<int> refreshAllNotePagesForPatient(String patientId) async {
    try {
      final remoteNotes = await _nocodbApiClient.fetchAllNotePagesForPatient(
        patientId,
      );
      if (remoteNotes.isEmpty) return 0;
      var merged = 0;
      for (final remote in remoteNotes) {
        final tabKey = remote['tabKey']?.toString() ?? '';
        if (tabKey.isEmpty) continue;
        final pageNumberRaw = remote['pageNumber'];
        final pageNumber = pageNumberRaw is int
            ? pageNumberRaw
            : int.tryParse(pageNumberRaw?.toString() ?? '') ?? 0;
        final didMerge = await _noteRepository.mergeRemoteNotePage(
          patientId: patientId,
          tabKey: tabKey,
          pageNumber: pageNumber,
          drawingJson: remote['drawingJson']?.toString() ?? '',
          remotePath: remote['remotePath']?.toString(),
          remoteUrl: remote['remoteUrl']?.toString(),
          updatedAt: remote['updatedAt']?.toString(),
          planPhase: remote['planPhase']?.toString(),
        );
        if (didMerge) merged += 1;
      }
      return merged;
    } catch (_) {
      return 0;
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
      // Pull aussi les entités GLOBALES qui n'étaient rafraîchies
      // qu'au boot (wiki, caisses retraite, photo profil, admin
      // access). Demande utilisateur 2026-05-06 : « ça fait 10 min
      // que mon app est ouverte sur iPad, page bibliothèque vide,
      // page caisses vide … alors que tout est accessible sur Mac ».
      // Sans ces refresh-en-chaîne, ces données restaient stale tant
      // que l'app n'était pas relancée. Best-effort, fire-and-forget
      // pour ne pas allonger le cycle pull (chacun a son timeout
      // interne). Le SyncEngine émettra ensuite `lastSyncAt` →
      // chaque écran (Wiki/Caisses/Documents/VAD) re-fetch via son
      // propre listener.
      // ignore: discarded_futures
      refreshLocalAuthStateFromRemote();
      // ignore: discarded_futures
      refreshWikiItemsFromRemote();
      // ignore: discarded_futures
      refreshRetirementFundsFromRemote();
      // Warmup ANAH — la fonction Vercel `/api/anah-status` n'est appelée
      // qu'à l'ouverture de l'écran ANAH. Sans ce ping au pull workspace,
      // un cold start peut faire attendre 3-10 s la 1ère fois que
      // l'utilisateur clique sur ANAH après une période d'inactivité.
      // En la pinguant ici (fire-and-forget), elle est chaude au moment
      // où l'utilisateur navigue vers l'écran. Demande utilisateur
      // 2026-05-06 : « la première requête après inactivité doit
      // prendre moins de 3 sec ».
      // ignore: discarded_futures
      _nocodbApiClient.fetchAnahStatus().catchError((_) => <String, dynamic>{});
      return true;
    } catch (e) {
      // Avant : `catch (_) { return false; }` → impossible de diagnostiquer
      // un état "pages vides" causé par 401 / 500 / timeout serveur. On
      // logue désormais l'erreur (visible dans `flutter run`) tout en
      // gardant le comportement non-bloquant (retour false → l'app reste
      // utilisable en mode offline-first sur le cache local).
      // ignore: avoid_print
      print('[refreshWorkspace] ERROR: $e');
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

  Future<int> countPendingSyncOperations() {
    return _syncRepository.countPendingOperations();
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

  /// Vide TOUTES les données locales (dossiers, documents, notes, sync_ops,
  /// caches) MAIS préserve les tables d'auth (`app_users`,
  /// `user_access_scopes`, `access_members`, `app_session`) pour que le
  /// re-login fonctionne sans re-fetch initial du serveur.
  ///
  /// Utilisé par :
  ///   - Bouton « Forcer la sync » dans AccountDialog (demande utilisateur
  ///     2026-05-06 : « le bouton doit être accessible quand on clique
  ///     sur le profil »)
  ///   - `AuthService.signOut()` — un logout = état propre, le prochain
  ///     login ré-tire toutes les données depuis NocoDB.
  ///
  /// Renvoie le nombre de lignes supprimées (pour log/debug).
  Future<int> wipeLocalDataForResync() async {
    final db = await LocalDatabase.instance.database;
    int total = 0;
    // Tables de DONNÉES (à wiper) — l'auth + la session sont préservées.
    const dataTables = <String>[
      'dossiers',
      'patients',
      'housings',
      'documents',
      'note_pages',
      'sync_operations',
      'contexte_de_vie',
      'diagnostic_sanitaires',
      'mesures_anthropometriques',
      'observations_synthese',
      'visit_recommendations',
      'wiki_items',
      'retirement_funds',
      'reference_sync_meta',
      'web_media_cache',
    ];
    for (final table in dataTables) {
      try {
        final n = await db.delete(table);
        total += n;
      } catch (_) {
        // Table peut-être pas encore créée (migration partielle) — ignore.
      }
    }
    // Trigger un pull workspace + le SyncEngine reprendra ses pulls
    // adaptatifs. Best-effort : si offline, le data viendra dès le retour
    // online via le polling natif.
    // ignore: discarded_futures
    refreshWorkspaceFromRemote();
    return total;
  }
}
