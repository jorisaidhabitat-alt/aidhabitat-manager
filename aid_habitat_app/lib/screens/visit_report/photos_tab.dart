import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../components/brand_colors.dart';
import '../../components/confirmation_dialog.dart';
import '../../components/file_drop_zone.dart';
import '../../models/types.dart';
import '../../models/visit_report_categories.dart';
import '../../services/app_config.dart';
import '../../services/connectivity_service.dart';
import '../../services/data_service.dart';
import '../../services/file_drop_listener.dart' show DroppedFile;
import '../../services/image_compressor.dart';
import '../../services/media_cache_service.dart';
import '../../services/sync_engine.dart';
import '../../services/web_file_picker.dart';

/// Onglet « Photos » du relevé de visite — alimente la page 8 du
/// rapport PDF (« Photos du logement »).
///
/// Trois catégories matérialisées par des tags sur la table
/// `documents` :
///   - `Visite - Logement`        → 2 photos paysage (slots PDF
///                                   `logement` / `logement2`)
///   - `Visite - Accessibilité`   → 3 photos portrait (slots
///                                   `acces1` / `acces2` / `acces3`)
///   - `Visite - Sanitaires`      → 3 photos portrait (slots
///                                   `sani1` / `sani2` / `sani3`)
///
/// Décorrélation totale avec l'espace « Documents » du dossier :
///   - L'onglet Photos n'affiche QUE les images portant un des
///     trois tags visite (Logement / Accessibilité / Sanitaires).
///     Les imports faits depuis l'espace Documents (tag « Photo » ou
///     autre) restent dans Documents et ne polluent pas le rapport.
///   - À l'inverse, `DocumentsScreen` filtre désormais ces trois
///     tags visite pour que les photos ajoutées ici ne réapparaissent
///     pas dans la grille générale.
///
/// L'ordre dans une catégorie est piloté par `documents.category_order`
/// (entier croissant) — réordonné via drag (ReorderableListView).
class PhotosTab extends StatefulWidget {
  final Dossier dossier;

  const PhotosTab({super.key, required this.dossier});

  @override
  State<PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends State<PhotosTab>
    with AutomaticKeepAliveClientMixin {
  static const Color _kPurpleLight = Color(0xFFF2ECF5);
  static const Color _kSlate = Color(0xFF2B323A);
  static final Color _kSectionBackground = kBrandPurple.withValues(alpha: 0.08);
  // _kSlateMuted retiré le 2026-05-12 (servait au badge count
  // supprimé, cf. _buildCountBadge également retiré).

  /// Compression cible pour les photos VAD : assez net pour le rapport,
  /// mais volontairement plus léger pour que l'import multi reste fluide.
  static const double _kCompressMaxWidth = 1280;
  static const int _kCompressQuality = 74;

  final DataService _dataService = DataService();
  final ImagePicker _imagePicker = ImagePicker();

  bool _isImporting = false;
  List<DocItem> _photos = const [];
  int _refreshGeneration = 0;

  /// Sections SUPPLÉMENTAIRES ajoutées par l'ergo via le bouton
  /// « + Ajouter une partie » (en plus des 5 sections de base toujours
  /// visibles). Chaque entrée = {baseTag, index} → tag complet
  /// `<baseTag> (#index)` (index >= 1). Permet d'avoir plusieurs
  /// sections de la même catégorie sans mélanger les photos.
  ///
  /// Persistance : automatique via les photos (tag suffixé). Une
  /// section extra avec ≥1 photo réapparaît au reload via
  /// `_deriveExtraSectionsFromPhotos`. Une section extra vide est
  /// volatile (gardée en mémoire le temps de la session, perdue à la
  /// fermeture du dossier — l'ergo doit ajouter une photo pour la
  /// pérenniser).
  List<_ExtraSection> _extraSections = const [];

  @override
  bool get wantKeepAlive => true;

  /// Polling silencieux 2s — accéléré 2026-05-06 (« il faudrait faire
  /// plus court encore » par rapport au 10s historique). Avec push
  /// debounce ~200ms côté iPad + 2s pull côté Mac → latence iPad → Mac
  /// d'environ 2,5s. Coût serveur : ~30 GET/min par utilisateur actif
  /// dans cet onglet, mais la requête est légère (SELECT documents
  /// where patient_local_id, pas de binaire transféré tant que les
  // _refreshTimer supprimé 2026-05-12 (refactor sync à la (re)connexion).

  /// Subscription au stream du SyncEngine — déclenche un refresh
  /// immédiat de la liste des photos quand un pull workspace réussit
  /// (l'autre device a probablement uploadé qqch dans les ~1-3s qui
  /// précèdent). Sans ça, on attendait jusqu'à 1s du polling local
  /// pour voir une nouvelle photo Mac→iPad. Demande utilisateur
  /// 2026-05-07 : « env. 30 sec, ça doit être quasiment instantané ».
  StreamSubscription<SyncEngineState>? _syncSubscription;
  DateTime? _lastObservedSyncAt;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Refactor 2026-05-12 : suppression du polling 1 s + de
    // `enterActiveContext`. Les photos sont chargées au mount + à
    // chaque pull workspace déclenché par un événement (foreground
    // return, reconnexion réseau, login). Les actions locales (ajout,
    // suppression, retag) déclenchent un `_refresh` direct via les
    // callbacks d'édition — donc l'utilisateur voit ses propres
    // modifications instantanément ; il ne voit celles de l'autre
    // device qu'au prochain événement de (re)connexion.
    _syncSubscription = SyncEngine().stateStream.listen((state) {
      if (!mounted) return;
      final at = state.lastSyncAt;
      if (at == null) return;
      if (_lastObservedSyncAt != null && at == _lastObservedSyncAt) return;
      _lastObservedSyncAt = at;
      if (ConnectivityService().isOffline) return;
      // ignore: discarded_futures
      _refresh(silent: true);
    });
  }

  @override
  void dispose() {
    _syncSubscription?.cancel();
    super.dispose();
  }

  // ----- Data -----

  /// Recharge la liste locale immédiatement, puis déclenche un refresh
  /// remote en arrière-plan. L'écran reste utilisable même si l'API met
  /// quelques secondes à répondre.
  Future<void> _refresh({bool silent = false}) async {
    final generation = ++_refreshGeneration;
    try {
      // 1) Lecture locale immédiate (SQLite cache).
      final docs = await _dataService.fetchDocuments(widget.dossier.patient.id);
      // Filtre élargi : on accepte les tags des 5 catégories de base ET
      // leurs variantes suffixées `(#N)` (sections supplémentaires
      // ajoutées via « Ajouter une partie »).
      final visitImages = docs
          .where((d) => d.type == 'image' && d.tags.any(_isAnyVisitTag))
          .toList(growable: false);
      if (!mounted || generation != _refreshGeneration) return;
      // Re-dérive les sections supplémentaires depuis les tags des
      // photos remontées + union avec celles déjà en mémoire (extras
      // créés mais pas encore alimentés en photos cette session).
      final derived = _deriveExtraSectionsFromPhotos(visitImages);
      final union = <_ExtraSection>{...derived, ..._extraSections}.toList()
        ..sort((a, b) {
          final byTag = a.baseTag.compareTo(b.baseTag);
          if (byTag != 0) return byTag;
          return a.index.compareTo(b.index);
        });
      setState(() {
        _photos = visitImages;
        _extraSections = union;
      });
      // 2) Pull remote en arrière-plan (best-effort), puis relecture
      // SQLite uniquement si le serveur a apporté du nouveau.
      unawaited(_refreshRemotePhotos(generation));
    } catch (_) {
      // Pas de loader global à débloquer : les sections restent
      // visibles, même si la lecture locale échoue temporairement.
    }
  }

  Future<void> _refreshRemotePhotos(int generation) async {
    try {
      final refreshed = await _dataService.refreshDocumentsFromRemote(
        widget.dossier.patient.id,
      );
      if (!mounted || generation != _refreshGeneration || !refreshed) return;
      // Re-lit la SQLite après merge — si remote a apporté du nouveau,
      // l'UI se met à jour silencieusement.
      final remoteDocs = await _dataService.fetchDocuments(
        widget.dossier.patient.id,
      );
      final remoteVisitImages = remoteDocs
          .where((d) => d.type == 'image' && d.tags.any(_isAnyVisitTag))
          .toList(growable: false);
      if (!mounted || generation != _refreshGeneration) return;
      final remoteDerived = _deriveExtraSectionsFromPhotos(remoteVisitImages);
      final remoteUnion =
          <_ExtraSection>{...remoteDerived, ..._extraSections}.toList()
            ..sort((a, b) {
              final byTag = a.baseTag.compareTo(b.baseTag);
              if (byTag != 0) return byTag;
              return a.index.compareTo(b.index);
            });
      // Capture les IDs connus AVANT le setState pour identifier les
      // photos qui viennent vraiment d'apparaître (delta merge).
      final previouslyKnownIds = _photos.map((d) => d.id).toSet();
      setState(() {
        _photos = remoteVisitImages;
        _extraSections = remoteUnion;
      });
      // 4) Pre-warm bytes des NOUVELLES photos en cache mémoire dès
      // qu'elles arrivent par merge — sans attendre que l'utilisateur
      // les regarde. Réduit la latence perçue : la photo est déjà
      // décodée en RAM au moment où la `_PhotoThumbnail` se monte →
      // pas de spinner intermédiaire.
      for (final d in remoteVisitImages) {
        if (!previouslyKnownIds.contains(d.id)) {
          // ignore: discarded_futures
          _resolvePhotoBytes(d);
        }
      }
    } catch (_) {}
  }

  /// Regex strict pour parser le suffixe ` (#N)` à la fin d'un tag
  /// extra. Garantit que :
  ///   - le baseTag est matché à l'identique (pas de collision si
  ///     un futur baseTag contient les caractères ` (#` dans son nom),
  ///   - l'index est uniquement des chiffres > 0,
  ///   - rien après la `)` (pas de trailing whitespace toléré).
  /// Hardening 2026-05-04 (audit).
  static final RegExp _extraSuffixRe = RegExp(r' \(#(\d+)\)$');

  /// Vrai si [tag] est un tag visite reconnu — base (`Visite - X`) OU
  /// suffixe extra (`Visite - X (#N)`).
  static bool _isAnyVisitTag(String tag) => _parseSectionTag(tag) != null;

  /// Décompose un tag photo. Renvoie (baseTag, extraIndex) où
  /// extraIndex = 0 pour une section de base et > 0 pour une extra.
  /// Renvoie null si le tag n'appartient à aucune catégorie connue.
  static ({String baseTag, int index})? _parseSectionTag(String tag) {
    if (kVisitPhotoTags.contains(tag)) {
      return (baseTag: tag, index: 0);
    }
    final match = _extraSuffixRe.firstMatch(tag);
    if (match == null) return null;
    final base = tag.substring(0, match.start);
    if (!kVisitPhotoTags.contains(base)) return null;
    final n = int.tryParse(match.group(1)!);
    if (n == null || n <= 0) return null;
    return (baseTag: base, index: n);
  }

  /// Construit le tag complet à utiliser pour une section donnée.
  /// Section de base (index 0) → `baseTag` ; extra → `baseTag (#N)`.
  static String _tagForSection(_ExtraSection section) {
    if (section.index == 0) return section.baseTag;
    return '${section.baseTag} (#${section.index})';
  }

  /// Reconstruit la liste des sections extras depuis les tags des
  /// photos déjà persistées. Permet à un extra (avec ≥1 photo)
  /// d'être ré-affiché au reload du dossier sans état dédié.
  static Set<_ExtraSection> _deriveExtraSectionsFromPhotos(
    List<DocItem> photos,
  ) {
    final out = <_ExtraSection>{};
    for (final p in photos) {
      for (final t in p.tags) {
        final parsed = _parseSectionTag(t);
        if (parsed != null && parsed.index > 0) {
          out.add(_ExtraSection(baseTag: parsed.baseTag, index: parsed.index));
        }
      }
    }
    return out;
  }

  /// Renvoie les photos d'une SECTION (base ou extra), triées par
  /// `categoryOrder` (croissant) puis par date (DESC pour les rares
  /// rangées NULL). [exactTag] = tag complet, ex. `Visite - Logement`
  /// pour la section base, `Visite - Logement (#1)` pour la 1ère extra.
  List<DocItem> _photosForSectionTag(String exactTag) {
    final filtered = _photos.where((d) => d.tags.contains(exactTag)).toList()
      ..sort((a, b) {
        final ao = a.categoryOrder;
        final bo = b.categoryOrder;
        if (ao != null && bo != null) return ao.compareTo(bo);
        if (ao != null) return -1;
        if (bo != null) return 1;
        return b.date.compareTo(a.date);
      });
    return filtered;
  }

  /// Compat ancienne signature — délègue à [_photosForSectionTag].
  List<DocItem> _photosForCategory(String categoryTag) =>
      _photosForSectionTag(categoryTag);

  // ----- Mutations -----

  /// Calcule le prochain `categoryOrder` libre dans une catégorie
  /// (max + 1) — utilisé quand on ajoute une photo via capture ou
  /// re-tag.
  int _nextOrderInCategory(String categoryTag) {
    final existing = _photosForCategory(categoryTag);
    final max = existing
        .map((d) => d.categoryOrder ?? -1)
        .fold<int>(-1, (a, b) => a > b ? a : b);
    return max + 1;
  }

  Future<void> _captureFromSource({
    required String categoryTag,
    required ImageSource source,
  }) async {
    if (_isImporting) return;
    setState(() => _isImporting = true);
    try {
      // Sur web : on bypass complètement `image_picker` et on lit le
      // fichier ORIGINAL via FileReader (`pickWebFile`). Bug rapporté
      // 2026-05-07 : `image_picker_for_web` re-encode l'image via canvas
      // (toBlob) et certaines images ressortaient tronquées à exactement
      // 1 MiB sur Mac Safari/Chrome — bloc PNG IEND manquant, photo
      // affichée moitié grise sur iPad. En lisant le fichier brut on
      // préserve l'intégrité bit-pour-bit. Le serveur valide ensuite
      // qu'il n'y a pas de troncature avant de stocker (cf.
      // `validateImageBufferIsComplete` dans server/index.mjs).
      if (kIsWeb) {
        if (source == ImageSource.camera) {
          final picked = await pickWebFile(accept: 'image/*', capture: true);
          if (picked == null) return;
          await _persistPickedFilesOptimistic([
            DroppedFile(
              name: picked.name,
              bytes: Uint8List.fromList(picked.bytes),
              mimeType: 'image/*',
            ),
          ], categoryTag);
        } else {
          final picked = await pickWebFiles(accept: 'image/*');
          if (picked.isEmpty) return;
          await _persistPickedFilesOptimistic(
            picked
                .map(
                  (f) => DroppedFile(
                    name: f.name,
                    bytes: Uint8List.fromList(f.bytes),
                    mimeType: 'image/*',
                  ),
                )
                .toList(growable: false),
            categoryTag,
          );
        }
        return;
      }
      final XFile? picked = await _imagePicker.pickImage(
        source: source,
        // image_picker compresse côté natif : on demande JPEG ≤1600px
        // de large, qualité 80. Cible ~150-300 Ko par photo.
        maxWidth: _kCompressMaxWidth,
        imageQuality: _kCompressQuality,
      );
      if (picked == null) return;
      await _persistPicked(picked, categoryTag);
    } catch (e) {
      _showError('Import impossible : $e');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// Importe une liste de fichiers déposés via drag-and-drop OS dans
  /// la section [categoryTag]. Filtre les non-images (le drop d'un
  /// fichier vidéo ou PDF dans la section Photos serait incohérent et
  /// rejeté côté repo de toute façon). Demande utilisateur 2026-05-05 :
  /// « le drag and drop ne fonctionne pas quand je souhaite mettre une
  /// image direct dans une des parties photos de la VAD ».
  Future<void> _persistDroppedFiles(
    List<DroppedFile> files,
    String categoryTag,
  ) async {
    if (_isImporting) return;
    final images = files.where((f) => f.isImage).toList();
    if (images.isEmpty) {
      _showError('Seules les images peuvent être déposées dans les Photos.');
      return;
    }

    await _persistPickedFilesOptimistic(images, categoryTag);
  }

  Future<void> _persistPickedFilesOptimistic(
    List<DroppedFile> images,
    String categoryTag,
  ) async {
    if (images.isEmpty) return;

    // Optimistic UI (fix 2026-05-15) : les tuiles photos s'affichent
    // INSTANTANÉMENT au drop, sans attendre la compression + l'upload.
    // Pattern :
    //   1. Crée un DocItem placeholder par image (id temp_xxx, bytes
    //      bruts dans `_photoBytesCache` pour rendu immédiat depuis la
    //      mémoire).
    //   2. setState une seule fois → toutes les tuiles apparaissent
    //      dans la milliseconde du drop.
    //   3. En arrière-plan, pour chaque image : compresse + persiste
    //      via `_dataService.importDocumentBytes` → quand le vrai
    //      DocItem revient, on remplace le placeholder par le réel
    //      (l'utilisateur ne voit rien, les bytes sont identiques).
    //   4. Si une image échoue : on retire silencieusement son
    //      placeholder (les autres continuent).
    final nowIso = DateTime.now().toIso8601String();
    final stampUs = DateTime.now().microsecondsSinceEpoch;
    final baseOrder = _nextOrderInCategory(categoryTag);
    final placeholders = <DocItem>[];
    for (var i = 0; i < images.length; i++) {
      final f = images[i];
      final tempId = 'temp_${stampUs}_$i';
      final order = baseOrder + i;
      final simpleTitle = _buildSimplePhotoTitle(categoryTag, order);
      // Cache des bytes BRUTS (non compressés) sous l'id temporaire →
      // la tuile rend l'image immédiatement depuis la mémoire.
      _photoBytesCache[tempId] = f.bytes;
      placeholders.add(
        DocItem(
          id: tempId,
          type: 'image',
          name: f.name,
          title: simpleTitle,
          date: nowIso,
          tags: [categoryTag],
          syncState: SyncState.pendingSync,
          categoryOrder: order,
        ),
      );
    }
    setState(() => _photos = [..._photos, ...placeholders]);

    unawaited(
      _persistPlaceholdersInBackground(
        images: images,
        placeholders: placeholders,
        categoryTag: categoryTag,
      ),
    );
  }

  Future<void> _persistPlaceholdersInBackground({
    required List<DroppedFile> images,
    required List<DocItem> placeholders,
    required String categoryTag,
  }) async {
    try {
      for (var i = 0; i < images.length; i++) {
        final f = images[i];
        final temp = placeholders[i];
        try {
          final compressed = await compressImageForUpload(
            bytes: f.bytes,
            fileName: f.name,
            maxWidthPx: _kCompressMaxWidth.round(),
            jpegQuality: _kCompressQuality,
            fastResize: true,
          );
          final fileName = _buildPhotoFileName(
            categoryTag,
            compressed.fileName,
            temp.title,
          );
          final inserted = await _dataService.importDocumentBytes(
            patientId: widget.dossier.patient.id,
            bytes: compressed.bytes,
            fileName: fileName,
            title: temp.title,
            tags: [categoryTag],
            categoryOrder: temp.categoryOrder,
          );
          if (!mounted) return;
          setState(() {
            // Swap cache : bytes compressés sous le nouvel id réel, et
            // on retire l'ancien tempId pour ne pas polluer la mémoire.
            _photoBytesCache[inserted.id] = compressed.bytes;
            _photoBytesCache.remove(temp.id);
            _photos = _photos
                .map((p) => p.id == temp.id ? inserted : p)
                .toList(growable: false);
          });
        } catch (_) {
          // Échec d'UNE image : retire son placeholder, continue avec
          // les autres. L'utilisateur peut re-dropper l'image si besoin.
          if (mounted) {
            setState(() {
              _photoBytesCache.remove(temp.id);
              _photos = _photos
                  .where((p) => p.id != temp.id)
                  .toList(growable: false);
            });
          }
        }
      }
      // Pull silencieux pour aligner l'ordre / l'état serveur canonique.
      // `silent: true` évite tout spinner / flash de loading visible.
      if (mounted) await _refresh(silent: true);
    } catch (_) {}
  }

  Future<void> _persistPicked(XFile xfile, String categoryTag) async {
    final order = _nextOrderInCategory(categoryTag);
    final simpleTitle = _buildSimplePhotoTitle(categoryTag, order);
    final fileName = _buildPhotoFileName(categoryTag, xfile.name, simpleTitle);
    if (kIsWeb) {
      final bytes = await xfile.readAsBytes();
      final inserted = await _dataService.importDocumentBytes(
        patientId: widget.dossier.patient.id,
        bytes: bytes,
        fileName: fileName,
        title: simpleTitle,
        tags: [categoryTag],
        categoryOrder: order,
      );
      // Prime le cache mémoire des vignettes avec les bytes qu'on
      // vient de capturer → la vignette s'affiche INSTANTANÉMENT au
      // prochain `_refresh` sans attendre un re-decode base64.
      _photoBytesCache[inserted.id] = Uint8List.fromList(bytes);
    } else {
      final inserted = await _dataService.importDocument(
        patientId: widget.dossier.patient.id,
        filePath: xfile.path,
        title: simpleTitle,
        tags: [categoryTag],
        categoryOrder: order,
      );
      // Native : on lit le fichier qu'on vient d'écrire pour primer
      // la cache. Coût ~quelques Mo en RAM mais l'image était déjà
      // chargée par image_picker, on évite un round-trip filesystem.
      try {
        final bytes = await xfile.readAsBytes();
        _photoBytesCache[inserted.id] = bytes;
      } catch (_) {
        // Pas critique : si la lecture échoue, le cache se remplira
        // au 1er rendu de la vignette via _resolvePhotoBytes.
      }
    }
    await _refresh();
  }

  /// Titre humain simple par défaut, type « Logement 1 », « Sanitaires 2 ».
  /// Demande utilisateur 2026-05-04 : « le nom de base doit être plus
  /// simple que actuellement ». L'index est dérivé de l'ordre dans la
  /// catégorie (`order` 0-indexé → affiché 1-indexé). Si la photo est
  /// déposée dans une section extra (ex. `Visite - Logement (#2)`),
  /// on utilise le baseTag pour le label — la distinction des
  /// sections multiples se fait via le titre de section, pas via le
  /// nom de chaque cliché.
  String _buildSimplePhotoTitle(String categoryTag, int order) {
    final base = _parseSectionTag(categoryTag)?.baseTag ?? categoryTag;
    return '${visitPhotoTagShortLabel(base)} ${order + 1}';
  }

  /// Nom de fichier propre dérivé du titre humain simple — type
  /// `Logement 1.jpg`. Facilite la reconnaissance dans NocoDB et
  /// Google Drive ; les caractères non sûrs (espaces, accents) sont
  /// remplacés par `_`. L'extension reprend l'original (jpg/png/heic).
  String _buildPhotoFileName(
    String categoryTag,
    String originalName,
    String simpleTitle,
  ) {
    final safe = simpleTitle
        .toLowerCase()
        // Strip diacritics (é→e, è→e, à→a…) avant le filtre alphanum.
        .replaceAll(RegExp(r'[àâä]'), 'a')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[îï]'), 'i')
        .replaceAll(RegExp(r'[ôö]'), 'o')
        .replaceAll(RegExp(r'[ùûü]'), 'u')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final ext = (() {
      final dot = originalName.lastIndexOf('.');
      if (dot < 0) return 'jpg';
      return originalName.substring(dot + 1).toLowerCase();
    })();
    return '$safe.$ext';
  }

  /// Retire les éventuels tags visite et applique [newTag]. Si
  /// [newTag] est null, on retire tous les tags visite (la photo
  /// retourne dans « À classer »).
  Future<void> _moveToCategory({
    required DocItem doc,
    required String? newTag,
  }) async {
    // Conserve les tags non-visite (Photo, Plan, …) pour ne pas
    // perdre la classification d'origine côté DocumentsScreen.
    final preserved = doc.tags
        .where((t) => !kVisitPhotoTags.contains(t))
        .toList();
    final nextTags = <String>[...preserved, if (newTag != null) newTag];
    final order = newTag == null ? null : _nextOrderInCategory(newTag);
    await _dataService.setDocumentVisitCategorization(
      documentId: doc.id,
      tags: nextTags,
      categoryOrder: order,
    );
    await _refresh();
  }

  /// Supprime une photo SANS confirmation supplémentaire — la
  /// confirmation est posée par `_PhotoFullscreenDialog._confirmAndDelete`
  /// avant d'appeler ce callback. Si tu rajoutes un autre point
  /// d'entrée pour la suppression (ex. swipe-to-delete dans le grid),
  /// ajoute la confirmation côté caller.
  Future<void> _deletePhoto(DocItem doc) async {
    await _dataService.deleteDocument(doc.id);
    await _refresh();
  }

  void _previewPhotoReorder({
    required String tag,
    required String draggedId,
    required String targetId,
    required bool insertAfter,
  }) {
    if (draggedId == targetId) return;
    final current = _photosForCategory(tag);
    final fromIndex = current.indexWhere((doc) => doc.id == draggedId);
    final targetIndex = current.indexWhere((doc) => doc.id == targetId);
    if (fromIndex < 0 || targetIndex < 0) return;
    final naturalInsertAfter = fromIndex < targetIndex;
    final insertionIndex = targetIndex + (naturalInsertAfter ? 1 : 0);
    final nextIndex = insertionIndex > fromIndex
        ? insertionIndex - 1
        : insertionIndex;
    if (nextIndex == fromIndex) return;
    final reordered = List<DocItem>.from(current);
    final moved = reordered.removeAt(fromIndex);
    reordered.insert(nextIndex.clamp(0, reordered.length), moved);
    setState(() {
      final byId = <String, int>{
        for (var i = 0; i < reordered.length; i++) reordered[i].id: i,
      };
      _photos = _photos
          .map((doc) {
            final nextOrder = byId[doc.id];
            if (nextOrder == null) return doc;
            return doc.copyWith(categoryOrder: nextOrder);
          })
          .toList(growable: false);
    });
  }

  Future<void> _commitPhotoOrder(String tag) async {
    final current = _photosForCategory(tag);
    await _dataService.reorderVisitCategoryDocuments(
      orderedDocumentIds: current.map((doc) => doc.id).toList(),
    );
    await _refresh();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ----- Build -----

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Layout 2026-05-04 v2 : les 5 sections de BASE sont toujours
    // visibles (Logement / Accessibilité / Sanitaires / Plan avant /
    // Plan après). Les sections SUPPLÉMENTAIRES (extras) s'ajoutent
    // au bout via le bouton « Ajouter une partie » et coexistent —
    // chaque extra a son propre groupe de photos via un tag
    // suffixé (#N). Catégorie « Autres » retirée.
    //
    // Layout : grille 3 colonnes en Wrap. Ordre : 5 bases puis
    // extras dans l'ordre (baseTag, index croissant) puis le bouton
    // « + Ajouter une partie ».
    final allSections = <_ExtraSection>[
      // Sections de base (index 0).
      for (final tag in kVisitPhotoTags) _ExtraSection(baseTag: tag, index: 0),
      // Sections supplémentaires (index >= 1).
      ..._extraSections,
    ];
    // Numérotation « du projet N » pour les sections « Plan travaux
    // préconisés » uniquement quand il y en a plusieurs (demande
    // utilisateur 2026-05-04). La base devient projet 1, les extras
    // suivent dans l'ordre. Si une seule section existe, on garde le
    // libellé court par défaut.
    final planApresProjectNumbers = <_ExtraSection, int>{};
    final planApresSections = allSections
        .where((s) => s.baseTag == kPhotoTagPlanApres)
        .toList();
    if (planApresSections.length > 1) {
      for (var i = 0; i < planApresSections.length; i++) {
        planApresProjectNumbers[planApresSections[i]] = i + 1;
      }
    }
    // Layout : grille manuelle de 3 cellules par ligne, chaque cellule
    // garde sa hauteur naturelle. Le `Column` parent stacke les rangées
    // de manière déterministe — pas de chevauchement quand une card
    // grandit dynamiquement (ajout de photo).
    //
    // Bouton « Ajouter une partie » retiré 2026-05-13 (demande user :
    // « il sert à rien car on ajoute direct les images supplémentaires
    // à la suite en drag and drop »). Les sections supplémentaires sont
    // désormais créées automatiquement quand une catégorie déborde.
    const spacing = 14.0;
    final rows = <Widget>[];
    for (var i = 0; i < allSections.length; i += 3) {
      final rowSections = allSections.sublist(
        i,
        i + 3 > allSections.length ? allSections.length : i + 3,
      );
      final minSlotRows = rowSections
          .map(_slotRowsForSection)
          .fold<int>(1, (maxRows, rows) => rows > maxRows ? rows : maxRows);
      final rowCells = <Widget>[
        for (final section in rowSections)
          _buildCategorySection(
            tag: _tagForSection(section),
            icon: _iconForCategory(section.baseTag),
            maxSlots: kVisitPhotoSlotCount[section.baseTag] ?? 0,
            minSlotRows: minSlotRows,
            titleOverride: planApresProjectNumbers.containsKey(section)
                ? 'Travaux préconisés du projet '
                      '${planApresProjectNumbers[section]}'
                : (section.index == 0
                      ? null
                      : '${visitPhotoTagShortLabel(section.baseTag)} '
                            '#${section.index + 1}'),
            onRemove: section.index == 0
                ? null
                : () => _removeExtraSection(section),
          ),
      ];
      // Pad la dernière ligne avec des Expanded vides pour garder les
      // cellules à 1/3 de la largeur (sinon elles s'étirent).
      while (rowCells.length < 3) {
        rowCells.add(const SizedBox.shrink());
      }
      if (i > 0) rows.add(const SizedBox(height: spacing));

      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: rowCells[0]),
            const SizedBox(width: spacing),
            Expanded(child: rowCells[1]),
            const SizedBox(width: spacing),
            Expanded(child: rowCells[2]),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }

  int _slotRowsForSection(_ExtraSection section) {
    final tag = _tagForSection(section);
    final photosCount = _photosForCategory(tag).length;
    final maxSlots = kVisitPhotoSlotCount[section.baseTag] ?? 0;
    final totalSlots = photosCount + 1 > maxSlots ? photosCount + 1 : maxSlots;
    return ((totalSlots + 2) ~/ 3).clamp(1, 999);
  }

  /// Retire une section supplémentaire (en mémoire + photos
  /// associées si présentes). Confirmation explicite à cause du
  /// risque de perte de photos.
  Future<void> _removeExtraSection(_ExtraSection section) async {
    final photosInSection = _photosForSectionTag(_tagForSection(section));
    if (photosInSection.isNotEmpty) {
      final confirm = await showAppDestructiveConfirmation(
        context: context,
        title: 'Supprimer cette partie ?',
        message:
            'Cette section contient ${photosInSection.length} '
            'photo${photosInSection.length > 1 ? 's' : ''} qui seront '
            'aussi supprimées définitivement.',
        confirmLabel: 'Supprimer',
        icon: LucideIcons.imageMinus,
      );
      if (confirm != true) return;
      for (final p in photosInSection) {
        await _dataService.deleteDocument(p.id);
      }
    }
    if (!mounted) return;
    setState(() {
      _extraSections = _extraSections
          .where((s) => s != section)
          .toList(growable: false);
    });
    await _refresh();
  }

  // `_buildAddSectionButton`, `_showAddSectionMenu`, `_addSectionMenuItem`
  // retirés 2026-05-13 (demande user : « la partie ajouter une partie
  // sert à rien car on ajoute direct les images supplémentaires à la
  // suite en drag and drop »). Les sections supplémentaires (ex.
  // Travaux préconisés #2, #3…) sont créées automatiquement par le
  // pipeline de drop quand une catégorie déborde.

  IconData _iconForCategory(String tag) {
    switch (tag) {
      case kPhotoTagLogement:
        return LucideIcons.home;
      case kPhotoTagAccessibilite:
        return LucideIcons.armchair;
      case kPhotoTagSanitaires:
        return LucideIcons.bath;
      case kPhotoTagPlanAvant:
        return LucideIcons.map;
      case kPhotoTagPlanApres:
        return LucideIcons.layers;
      default:
        return LucideIcons.image;
    }
  }

  Widget _buildCategorySection({
    required String tag,
    required IconData icon,
    required int maxSlots,
    required int minSlotRows,

    /// Si fourni, override le label par défaut (utilisé pour
    /// distinguer les extras « Logement #2 » des bases).
    String? titleOverride,

    /// Si fourni, affiche un bouton X (supprimer la section). Réservé
    /// aux extras — les sections de base ne sont jamais supprimables.
    VoidCallback? onRemove,
  }) {
    final photos = _photosForCategory(tag);
    final shortLabel =
        titleOverride ??
        visitPhotoTagShortLabel(_parseSectionTag(tag)?.baseTag ?? tag);

    // DragTarget englobe TOUT le container — drop n'importe où dans la
    // section (entête, photos, espace vide, boutons) accepte la photo.
    // Le drop se traduit par `_moveToCategory(doc, newTag = tag)` :
    //   - si l'origine == catégorie courante → no-op (déjà au bon endroit)
    //   - sinon → la photo est re-taggée et apparaît dans cette section.
    //
    // `onWillAcceptWithDetails` highlight la cible quand un drag survole
    // (border violet → bleu pâle), retour à la normale au leave.
    //
    // FileDropZone (web) : enveloppe en plus tout le container pour
    // accepter les drops Finder / Explorer / onglet image — l'image
    // déposée est importée comme nouvelle photo dans la catégorie de
    // cette section. Sur natif (iPad), la zone est un no-op et le
    // DragTarget interne reste seul actif.
    return _PhotoSectionDropWrapper(
      categoryTag: tag,
      onDrop: (files) => _persistDroppedFiles(files, tag),
      child: DragTarget<_DragPhotoPayload>(
        onWillAcceptWithDetails: (details) => details.data.fromTag != tag,
        onAcceptWithDetails: (details) async {
          if (details.data.fromTag == tag) return;
          await _moveToCategory(doc: details.data.doc, newTag: tag);
        },
        builder: (context, candidates, rejected) {
          final hovering = candidates.isNotEmpty;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: hovering ? _kPurpleLight : _kSectionBackground,
              borderRadius: BorderRadius.circular(16),
              border: hovering
                  ? Border.all(color: kBrandPurple, width: 2)
                  : null,
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // En-tête : icône + nom (compteur "X / max" retiré le
                // 2026-05-12 — demande utilisateur : on garde seulement le
                // nombre d'emplacements de base par catégorie via `maxSlots`,
                // pas de badge pollue le header).
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _kPurpleLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 18, color: kBrandPurple),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        shortLabel,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: _kSlate,
                        ),
                      ),
                    ),
                    // Bouton X de suppression — visible uniquement pour les
                    // sections supplémentaires (cf. demande 2026-05-04 :
                    // « il faut simplement pouvoir en ajouter davantage
                    // sans les retirer » → les bases sont protégées).
                    if (onRemove != null) ...[
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: onRemove,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEE2E2),
                            // Refonte 2026-05-13 : pill radius 999 uniforme.
                            borderRadius: BorderRadius.circular(999),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            LucideIcons.x,
                            size: 14,
                            color: Color(0xFFB91C1C),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                // Grille unifiée : photos existantes + emplacements gris
                // vides jusqu'à maxSlots (capacité PDF). Chaque emplacement
                // vide est un DragTarget (drop d'une photo d'une autre
                // catégorie pour la re-tagger ici) ET tappable (ouvre la
                // galerie pour ajouter une photo). Plus de boutons
                // « Prendre / Galerie » dédiés — demande utilisateur
                // 2026-04-28.
                _buildSlotsGrid(
                  tag: tag,
                  photos: photos,
                  maxSlots: maxSlots,
                  minRows: minSlotRows,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Construit la grille des emplacements pour une catégorie : photos
  /// existantes + slots gris vides (jusqu'à maxSlots). Le tap sur un
  /// slot vide ouvre la galerie ; le drop sur un slot vide importe ou
  /// re-tagge la photo dragguée.
  ///
  /// Implémentation 2026-05-04 : `Row + Expanded` (au lieu de
  /// `LayoutBuilder + Wrap`) — `IntrinsicHeight` côté parent ne peut
  /// pas calculer les hauteurs intrinsèques d'un sous-arbre contenant
  /// un `LayoutBuilder` (rendu blanc). En cassant chaque rangée de 3
  /// avec `Expanded` + `AspectRatio`, on garde le même résultat
  /// visuel sans dépendre des constraints du parent.
  Widget _buildSlotsGrid({
    required String tag,
    required List<DocItem> photos,
    required int maxSlots,
    required int minRows,
  }) {
    const spacing = 6.0;
    // Nombre total d'emplacements visibles :
    //   - au moins `maxSlots` (les emplacements de base attendus)
    //   - au moins `photos.length + 1` → garantit qu'il y a TOUJOURS
    //     un cadre drag-and-drop vide après la dernière photo pour
    //     que l'ergo puisse en ajouter à l'infini (demande utilisateur
    //     2026-05-12 : "des que j'ai upload la dernière photo d'une
    //     partie, un nouveau cadre drag and drop doit toujours
    //     apparaitre après pour que je puisse en ajouter autant que
    //     j'en veux"). La grille reste à 3 colonnes max (cf. la
    //     boucle ci-dessous) → la taille des images ne change pas,
    //     ça passe simplement à la ligne suivante.
    final totalSlots = photos.length + 1 > maxSlots
        ? photos.length + 1
        : maxSlots;
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = (constraints.maxWidth - spacing * 2) / 3;
        final safeTileWidth = tileWidth.isFinite && tileWidth > 0
            ? tileWidth
            : 0.0;
        final safeMinRows = minRows < 1 ? 1 : minRows;
        final minHeight =
            safeTileWidth * safeMinRows + spacing * (safeMinRows - 1);
        final totalRows = totalSlots == 0 ? 0 : ((totalSlots - 1) ~/ 3) + 1;
        final contentHeight =
            safeTileWidth * totalRows + spacing * (totalRows - 1);
        final gridHeight = contentHeight < minHeight
            ? minHeight
            : contentHeight;

        Offset offsetFor(int index) {
          return Offset(
            (index % 3) * (safeTileWidth + spacing),
            (index ~/ 3) * (safeTileWidth + spacing),
          );
        }

        return SizedBox(
          height: gridHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < totalSlots; i++)
                AnimatedPositioned(
                  key: ValueKey(
                    i < photos.length
                        ? 'photo_position_${photos[i].id}'
                        : 'photo_empty_${tag}_$i',
                  ),
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: offsetFor(i).dx,
                  top: offsetFor(i).dy,
                  width: safeTileWidth,
                  height: safeTileWidth,
                  child: i < photos.length
                      ? _buildOccupiedSlot(tag: tag, photos: photos, index: i)
                      : _buildEmptySlot(tag: tag),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Tile pour une photo existante — drag (LongPressDraggable) + drop
  /// (DragTarget) côté tile. Reorder intra-catégorie ou re-tag inter.
  /// Extrait depuis l'ancien `_buildReorderableGrid` (refactor pour
  /// permettre l'affichage des slots vides à côté).
  Widget _buildOccupiedSlot({
    required String tag,
    required List<DocItem> photos,
    required int index,
  }) {
    return _PhotoDragSlot(
      key: ValueKey('photo_slot_${photos[index].id}'),
      tag: tag,
      photos: photos,
      index: index,
      onPreviewReorder: _previewPhotoReorder,
      onCommitOrder: _commitPhotoOrder,
      onMoveToCategory: _moveToCategory,
      onOpen: _openFullscreenWithDelete,
    );
  }

  /// Slot vide : gris clair avec icône `+`. Tap → galerie. Drop → re-tag.
  Widget _buildEmptySlot({required String tag}) {
    return DragTarget<_DragPhotoPayload>(
      onWillAcceptWithDetails: (details) => details.data.fromTag != tag,
      onAcceptWithDetails: (details) async {
        await _moveToCategory(doc: details.data.doc, newTag: tag);
      },
      builder: (context, candidates, rejected) {
        final hovering = candidates.isNotEmpty;
        return GestureDetector(
          onTap: () =>
              _captureFromSource(categoryTag: tag, source: ImageSource.gallery),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: hovering
                  ? const Color(0xFFF2ECF5)
                  : const Color(0xFFF2F4F6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hovering ? kBrandPurple : const Color(0xFFB9C0C7),
                width: hovering ? 2 : 1,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              LucideIcons.imagePlus,
              size: 22,
              color: hovering ? kBrandPurple : Color(0xFF8A939D),
            ),
          ),
        );
      },
    );
  }

  // _buildCountBadge supprimé le 2026-05-12 — demande utilisateur :
  // pas de badge "X / max" dans le header, on garde uniquement les
  // emplacements de base affichés dans la grille (+1 slot vide
  // toujours disponible cf. _buildSlotsGrid).

  // _buildEmptyState supprimé : remplacé par les slots gris vides
  // de _buildSlotsGrid (chaque slot tappable + DragTarget). Demande
  // utilisateur 2026-04-28.

  // _buildReorderableGrid retiré : la grille unifiée
  // `_buildSlotsGrid` (photos + slots vides) le remplace. La logique
  // par-tile a été extraite dans `_buildOccupiedSlot`. Demande
  // utilisateur 2026-04-28.

  /// Ouvre la preview plein écran pour une photo en passant le
  /// callback de suppression — le bouton poubelle dans la dialog
  /// déclenche la confirmation puis ferme la dialog en cas d'accord.
  Future<void> _openFullscreenWithDelete(DocItem doc) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (ctx) => _PhotoFullscreenDialog(
        doc: doc,
        onDelete: () async {
          Navigator.of(ctx).pop();
          await _deletePhoto(doc);
        },
        onMetadataChanged:
            ({required String newTitle, required bool showLabelOnPdf}) async {
              // Préserve les autres tags (catégorie visite, classification).
              // Modèle opt-in 2026-05-05 : on retire les DEUX tags magiques
              // (le legacy `__pdf_no_label` ET le nouveau `__pdf_show_label`)
              // et on rajoute UNIQUEMENT `__pdf_show_label` si l'ergo a
              // coché. Default (tag absent) = pas d'overlay titre PDF.
              final preserved = doc.tags
                  .where(
                    (t) =>
                        t != kPhotoTagPdfNoLabel && t != kPhotoTagPdfShowLabel,
                  )
                  .toList();
              final nextTags = <String>[
                ...preserved,
                if (showLabelOnPdf) kPhotoTagPdfShowLabel,
              ];
              await _dataService.updateDocumentMetadata(
                documentId: doc.id,
                title: newTitle,
                tags: nextTags,
              );
              await _refresh();
            },
      ),
    );
  }

  // _buildAddButton retiré : les boutons « Prendre / Galerie » ont
  // été supprimés au profit du tap sur les slots vides gris (cf.
  // `_buildEmptySlot`). Demande utilisateur 2026-04-28.
}

// ---------------------------------------------------------------------------
// Wrapper Stateful pour le drag-and-drop OS au niveau d'une section
// Photos — affiche un overlay violet « Déposer ici » quand un drag
// Finder Mac survole la section. Web uniquement (sur natif iPad le
// FileDropZone est no-op et le wrapper rend juste son child).
// ---------------------------------------------------------------------------

class _PhotoSectionDropWrapper extends StatefulWidget {
  /// Tag complet de la section (`Visite - Logement`, ou
  /// `Visite - Logement (#2)` pour une extra). Passé tel quel au
  /// callback de drop pour l'attribution du tag.
  final String categoryTag;

  /// Reçoit les fichiers déposés. L'appelant filtre les non-images via
  /// `DroppedFile.isImage`.
  final void Function(List<DroppedFile> files) onDrop;
  final Widget child;

  const _PhotoSectionDropWrapper({
    required this.categoryTag,
    required this.onDrop,
    required this.child,
  });

  @override
  State<_PhotoSectionDropWrapper> createState() =>
      _PhotoSectionDropWrapperState();
}

class _PhotoSectionDropWrapperState extends State<_PhotoSectionDropWrapper> {
  bool _highlight = false;

  @override
  Widget build(BuildContext context) {
    return FileDropZone(
      onDrop: widget.onDrop,
      onHighlight: (on) {
        if (mounted && _highlight != on) {
          setState(() => _highlight = on);
        }
      },
      // N'accepte que les images : le drop d'un PDF dans une section
      // photo serait incohérent (les rapports/templates vivent dans
      // l'espace Documents, pas la VAD). Le filtre prevent aussi
      // l'overlay vert de s'afficher pour des fichiers qu'on
      // refuserait de toute façon.
      accept: (files) => files.any((f) => f.isImage),
      child: Stack(
        children: [
          widget.child,
          if (_highlight)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2ECF5).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBrandPurple, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          LucideIcons.imagePlus,
                          size: 16,
                          color: Color(0xFF554265),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Déposer ici',
                          style: TextStyle(
                            color: Color(0xFF554265),
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Drag payload — passé entre LongPressDraggable (source) et DragTarget
// (destination) via le système de gestures Flutter. Le `fromTag`
// permet à la cible de détecter "je suis déjà la catégorie d'origine
// → ne rien faire" sans round-trip dans la liste de tags du document.
// ---------------------------------------------------------------------------

class _DragPhotoPayload {
  final DocItem doc;
  final String fromTag;
  const _DragPhotoPayload({required this.doc, required this.fromTag});
}

class _PhotoDragSlot extends StatefulWidget {
  const _PhotoDragSlot({
    super.key,
    required this.tag,
    required this.photos,
    required this.index,
    required this.onPreviewReorder,
    required this.onCommitOrder,
    required this.onMoveToCategory,
    required this.onOpen,
  });

  final String tag;
  final List<DocItem> photos;
  final int index;
  final void Function({
    required String tag,
    required String draggedId,
    required String targetId,
    required bool insertAfter,
  })
  onPreviewReorder;
  final Future<void> Function(String tag) onCommitOrder;
  final Future<void> Function({required DocItem doc, required String newTag})
  onMoveToCategory;
  final void Function(DocItem doc) onOpen;

  @override
  State<_PhotoDragSlot> createState() => _PhotoDragSlotState();
}

class _PhotoDragSlotState extends State<_PhotoDragSlot> {
  bool? _insertAfter;

  DocItem get _doc => widget.photos[widget.index];

  bool _isAfterTarget(Offset globalOffset) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final local = renderObject.globalToLocal(globalOffset);
    return local.dx > renderObject.size.width / 2;
  }

  bool _isCloseEnoughToTarget(Offset globalOffset) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final local = renderObject.globalToLocal(globalOffset);
    final normalizedX = local.dx / renderObject.size.width;
    final normalizedY = local.dy / renderObject.size.height;
    return normalizedX >= 0.18 &&
        normalizedX <= 0.82 &&
        normalizedY >= 0.18 &&
        normalizedY <= 0.82;
  }

  void _updateInsertionSide(Offset globalOffset) {
    final next = _isAfterTarget(globalOffset);
    if (_insertAfter == next) return;
    setState(() => _insertAfter = next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = constraints.maxWidth;
        return DragTarget<_DragPhotoPayload>(
          onWillAcceptWithDetails: (details) => details.data.doc.id != _doc.id,
          onMove: (details) {
            if (!_isCloseEnoughToTarget(details.offset)) return;
            final insertAfter = _isAfterTarget(details.offset);
            _updateInsertionSide(details.offset);
            if (details.data.fromTag == widget.tag) {
              widget.onPreviewReorder(
                tag: widget.tag,
                draggedId: details.data.doc.id,
                targetId: _doc.id,
                insertAfter: insertAfter,
              );
            }
          },
          onLeave: (_) {
            if (_insertAfter != null) {
              setState(() => _insertAfter = null);
            }
          },
          onAcceptWithDetails: (details) async {
            final payload = details.data;
            if (payload.fromTag == widget.tag) {
              // L'ordre intra-section est déjà prévisualisé au survol et
              // confirmé une seule fois par `onDragEnd`.
            } else {
              await widget.onMoveToCategory(
                doc: payload.doc,
                newTag: widget.tag,
              );
            }
            if (mounted && _insertAfter != null) {
              setState(() => _insertAfter = null);
            }
          },
          builder: (context, candidates, rejected) {
            final child = Stack(
              clipBehavior: Clip.none,
              children: [
                _PhotoTile(
                  key: ValueKey('photo_${_doc.id}'),
                  doc: _doc,
                  onTap: () => widget.onOpen(_doc),
                  highlight: false,
                ),
              ],
            );
            return MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Draggable<_DragPhotoPayload>(
                data: _DragPhotoPayload(doc: _doc, fromTag: widget.tag),
                feedbackOffset: Offset.zero,
                hitTestBehavior: HitTestBehavior.opaque,
                maxSimultaneousDrags: 1,
                onDragEnd: (_) => widget.onCommitOrder(widget.tag),
                feedback: Material(
                  color: Colors.transparent,
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    width: tileWidth,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.22),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: _PhotoTile(
                      key: ValueKey('photo_drag_${_doc.id}'),
                      doc: _doc,
                      onTap: () {},
                      highlight: false,
                    ),
                  ),
                ),
                childWhenDragging: _PhotoTile(
                  key: ValueKey('photo_ghost_${_doc.id}'),
                  doc: _doc,
                  onTap: () {},
                  highlight: false,
                ),
                child: child,
              ),
            );
          },
        );
      },
    );
  }
}

/// Identifie une section d'affichage de l'onglet Photos.
/// • `index == 0` = section de base (5 toujours visibles)
/// • `index >= 1` = section supplémentaire ajoutée par l'ergo via
///   « + Ajouter une partie ». Tag complet = `<baseTag> (#index)`.
class _ExtraSection {
  final String baseTag;
  final int index;
  const _ExtraSection({required this.baseTag, required this.index});

  @override
  bool operator ==(Object other) =>
      other is _ExtraSection &&
      other.baseTag == baseTag &&
      other.index == index;

  @override
  int get hashCode => Object.hash(baseTag, index);
}

// `_PhotoDashedBorderPainter` retiré 2026-05-13 — seul utilisé par le
// bouton « Ajouter une partie » désormais supprimé.

// ---------------------------------------------------------------------------
// Tile — une photo d'une catégorie visite. Image SEULE, sans badge
// numéro ni menu kebab (demande user 2026-04-28). Tap → ouvre la
// preview plein écran (où vit le bouton poubelle). Long-press →
// déclenche le drag (géré par le `LongPressDraggable` parent).
// ---------------------------------------------------------------------------

class _PhotoTile extends StatelessWidget {
  final DocItem doc;
  final VoidCallback onTap;

  /// Bordure violette quand un drag survole cette tile (DragTarget
  /// hover) — feedback visuel pour indiquer le slot d'insertion.
  final bool highlight;

  const _PhotoTile({
    super.key,
    required this.doc,
    required this.onTap,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    // Les photos remplissent désormais directement leur carré :
    // pas de cadre blanc/padding type polaroid autour de la preview.
    //  - Aspect ratio 1:1 préservé pour matcher les cadres vides
    //  - Highlight au drag : border mauve-500 1.5px sur l'extérieur
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AspectRatio(
        aspectRatio: 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: highlight
                ? Border.all(color: kBrandPurple, width: 1.5)
                : null,
            boxShadow: [
              BoxShadow(
                color: const Color(0x141F1E14).withValues(alpha: 0.08),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: _PhotoThumbnail(doc: doc),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helper widget — vignette photo avec cache mémoire + cache SQLite
// (MediaCacheService) pour un affichage INSTANTANÉ après le 1er rendu.
// ---------------------------------------------------------------------------

/// Cache global partagé par toutes les instances de `_PhotoThumbnail`
/// et `_PhotoFullscreenDialog` — clé = `doc.id`. Une fois que les
/// bytes ont été décodés (base64) ou téléchargés (URL), toutes les
/// vignettes du même doc s'affichent en O(1) depuis cette map. Le
/// cache vit pour la durée du process — survit aux changements
/// d'onglet, scrolls, rebuilds réorderables.
final Map<String, Uint8List> _photoBytesCache = {};

/// Inflight de-dup : si plusieurs widgets demandent les mêmes bytes
/// en parallèle (mounting de plusieurs tiles simultané), une seule
/// fetch réseau est lancée et toutes attendent la même Future.
final Map<String, Future<Uint8List?>> _photoBytesInflight = {};

/// Vérifie si les bytes ressemblent à une image valide via les signatures
/// magic-number standard (JPEG, PNG, GIF, WebP, BMP, HEIC/HEIF). Permet
/// de détecter une entrée stale dans `web_media_cache` qui contiendrait
/// par exemple du HTML (SPA fallback après "Load failed") ou 0 byte —
/// cas observé sur Mac quand iPad a poussé la photo sur NocoDB et qu'un
/// premier fetch côté Mac avait échoué silencieusement.
///
/// Renforcé 2026-05-07 : on vérifie AUSSI les marqueurs end-of-file
/// pour PNG (bloc IEND) et JPEG (marqueur EOI 0xFFD9). Sans ça, un
/// upload tronqué (~1 MiB exactement coupé par le browser ou Vercel
/// Edge) passait l'ancien check head-only et s'affichait avec la
/// moitié inférieure en gris sur Safari iPad. Maintenant les bytes
/// tronqués sont rejetés du cache → placeholder propre + l'utilisateur
/// sait qu'il doit réimporter.
bool _looksLikeImageBytes(Uint8List? bytes) {
  if (bytes == null || bytes.length < 8) return false;
  // JPEG: FF D8 FF en tête + FF D9 en queue
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    if (bytes.length < 4) return false;
    final last = bytes.length;
    return bytes[last - 2] == 0xFF && bytes[last - 1] == 0xD9;
  }
  // PNG: 89 50 4E 47 0D 0A 1A 0A en tête + IEND (49 45 4E 44) au début
  // des 8 derniers bytes (suivi de 4 bytes CRC).
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    if (bytes.length < 12) return false;
    // Les 12 derniers bytes d'un PNG complet sont :
    // 00 00 00 00  49 45 4E 44  AE 42 60 82
    final last = bytes.length;
    return bytes[last - 12] == 0x00 &&
        bytes[last - 11] == 0x00 &&
        bytes[last - 10] == 0x00 &&
        bytes[last - 9] == 0x00 &&
        bytes[last - 8] == 0x49 &&
        bytes[last - 7] == 0x45 &&
        bytes[last - 6] == 0x4E &&
        bytes[last - 5] == 0x44 &&
        bytes[last - 4] == 0xAE &&
        bytes[last - 3] == 0x42 &&
        bytes[last - 2] == 0x60 &&
        bytes[last - 1] == 0x82;
  }
  // GIF: "GIF8"
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true;
  }
  // WebP: "RIFF....WEBP"
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  // BMP: 42 4D
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
  // HEIC/HEIF: "ftypheic" / "ftypheix" / "ftypmif1" à l'offset 4
  if (bytes.length >= 12 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    return true;
  }
  return false;
}

/// Récupère les bytes d'une photo via la chaîne de fallback :
///   1. cache mémoire (`_photoBytesCache`)
///   2. inflight (autre instance en train de fetch)
///   3. `dataUrl` (web upload encore en mémoire) → décodage base64
///   4. `localPath` (native filesystem) → readAsBytes
///   5. `url` (NocoDB signed URL) → MediaCacheService web cache
///      (SQLite-backed, persistant offline-first)
///   6. Si le cache renvoie des bytes invalides (HTML stale, 0 byte),
///      on invalide l'entrée et on retente un fetch frais. Évite que
///      l'app reste coincée sur une image cassée à cause d'une réponse
///      foirée stockée dans `web_media_cache`.
///
/// Renvoie null seulement si aucune source n'a marché.
Future<Uint8List?> _resolvePhotoBytes(DocItem doc) async {
  final cached = _photoBytesCache[doc.id];
  if (cached != null) return cached;

  final pending = _photoBytesInflight[doc.id];
  if (pending != null) return pending;

  final future = () async {
    final dataUrl = doc.dataUrl;
    if (dataUrl != null && dataUrl.startsWith('data:')) {
      try {
        final b64 = dataUrl.split(',').last;
        final decoded = base64Decode(b64);
        if (_looksLikeImageBytes(decoded)) return decoded;
      } catch (_) {}
    }
    if (!kIsWeb) {
      final localPath = doc.localPath;
      if (localPath != null && localPath.isNotEmpty) {
        try {
          final file = File(localPath);
          if (await file.exists()) {
            return await file.readAsBytes();
          }
        } catch (_) {}
      }
    }
    final url = doc.url?.trim() ?? '';
    if (url.isNotEmpty) {
      try {
        if (kIsWeb) {
          var bytes = await MediaCacheService.instance.webCachedFetch(
            url,
            headers: {'X-App-Session': AppConfig.appSessionToken},
          );
          if (_looksLikeImageBytes(bytes)) return bytes;
          // Cache renvoie quelque chose qui ne ressemble PAS à une image
          // (HTML SPA fallback, 0 byte, JSON d'erreur). On invalide
          // l'entrée stale et on retente un fetch réseau direct — fix
          // pour les photos iPad non-cliquables sur Mac.
          if (bytes != null) {
            await MediaCacheService.instance.invalidateUrl(url);
            bytes = await MediaCacheService.instance.webCachedFetch(
              url,
              headers: {'X-App-Session': AppConfig.appSessionToken},
            );
            if (_looksLikeImageBytes(bytes)) return bytes;
          }
        } else {
          final file = await MediaCacheService.instance.fetch(
            url,
            headers: MediaCacheService.authHeaders(),
          );
          if (file != null) return await file.readAsBytes();
        }
      } catch (_) {}
    }
    return null;
  }();

  _photoBytesInflight[doc.id] = future;
  try {
    final bytes = await future;
    if (bytes != null) {
      _photoBytesCache[doc.id] = bytes;
    }
    return bytes;
  } finally {
    _photoBytesInflight.remove(doc.id);
  }
}

class _PhotoThumbnail extends StatefulWidget {
  final DocItem doc;
  const _PhotoThumbnail({required this.doc});

  @override
  State<_PhotoThumbnail> createState() => _PhotoThumbnailState();
}

class _PhotoThumbnailState extends State<_PhotoThumbnail> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // Cache hit VRAIMENT synchrone : on assigne `_bytes` AVANT le
    // premier build pour qu'il rende l'image directement, sans passer
    // par un placeholder. Avant 2026-05-06 : le hit était fait dans
    // `_load()` async → assigné après le premier build SANS setState
    // → la vignette d'une photo fraîchement importée restait sur le
    // placeholder jusqu'à ce que l'utilisateur quitte/rouvre l'écran
    // (symptôme reporté : « la preview n'a jamais été disponible »).
    _bytes = _photoBytesCache[widget.doc.id];
    if (_bytes == null) _load();
  }

  @override
  void didUpdateWidget(covariant _PhotoThumbnail old) {
    super.didUpdateWidget(old);
    if (old.doc.id != widget.doc.id ||
        old.doc.dataUrl != widget.doc.dataUrl ||
        old.doc.url != widget.doc.url) {
      // Tente le cache mémoire d'abord — si déjà chargée par
      // _persistPicked (import frais), on l'affiche immédiatement.
      final cached = _photoBytesCache[widget.doc.id];
      setState(() {
        _bytes = cached;
        _failed = false;
      });
      if (cached == null) _load();
    }
  }

  Future<void> _load() async {
    // Cache check (couvre le cas où une autre miniature aurait primé
    // le cache pendant qu'on attendait — race condition au refresh).
    final cached = _photoBytesCache[widget.doc.id];
    if (cached != null) {
      if (mounted) setState(() => _bytes = cached);
      return;
    }
    final bytes = await _resolvePhotoBytes(widget.doc);
    if (!mounted) return;
    if (bytes != null) {
      setState(() => _bytes = bytes);
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(
        _bytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    }
    if (_failed) return _placeholder();
    // Loading state — placeholder neutre pour ne pas faire flasher
    // un spinner sur des chargements < 50 ms (cas courant cache hit).
    return _placeholder();
  }

  Widget _placeholder() => Container(
    color: const Color(0xFFF2F4F6),
    alignment: Alignment.center,
    child: const Icon(LucideIcons.imageOff, size: 18, color: Color(0xFF8A939D)),
  );
}

// ---------------------------------------------------------------------------
// Dialog plein écran — affiche la photo en grand avec un fond noir.
// Tap n'importe où pour fermer. Lit les bytes via le même cache que
// la vignette → ouverture instantanée (l'image est déjà décodée).
// ---------------------------------------------------------------------------

class _PhotoFullscreenDialog extends StatefulWidget {
  final DocItem doc;

  /// Si fourni, un bouton poubelle apparaît en haut à droite (à côté
  /// du `X` de fermeture). Le callback DOIT gérer lui-même la
  /// fermeture de la dialog (typiquement après confirmation).
  final Future<void> Function()? onDelete;

  /// Appelé après un rename ou un toggle du switch « Afficher dans le
  /// PDF ». Le callback persiste dans SQLite + déclenche le sync, et
  /// le parent rafraîchit la liste des photos.
  ///
  /// Sémantique 2026-05-05 : `showLabelOnPdf` est un OPT-IN — true =
  /// ajout du tag `__pdf_show_label`, false = retrait (default).
  /// L'inverse de l'ancien `hideLabelOnPdf` (qui posait
  /// `__pdf_no_label`).
  final Future<void> Function({
    required String newTitle,
    required bool showLabelOnPdf,
  })?
  onMetadataChanged;

  const _PhotoFullscreenDialog({
    required this.doc,
    this.onDelete,
    this.onMetadataChanged,
  });

  @override
  State<_PhotoFullscreenDialog> createState() => _PhotoFullscreenDialogState();
}

class _PhotoFullscreenDialogState extends State<_PhotoFullscreenDialog> {
  Uint8List? _bytes;
  bool _failed = false;

  /// Titre courant affiché dans la barre du bas — peut différer de
  /// `widget.doc.title` après un rename (la nouvelle valeur est
  /// reflétée localement avant que le parent ne rafraîchisse via
  /// `onMetadataChanged`).
  late String _currentTitle;

  /// État du switch « Afficher le nom dans le PDF ». Default = false
  /// (= label MASQUÉ par défaut, opt-in seulement). Initialisé à
  /// partir de la présence du tag `kPhotoTagPdfShowLabel` sur le doc.
  /// Demande utilisateur 2026-05-05 : « le switch doit être
  /// désélectionné par défaut pour ne pas afficher le titre. On le
  /// sélectionne uniquement si nécessaire ».
  ///
  /// Compat ascendante : si la photo a l'ancien tag `__pdf_no_label`
  /// (rare désormais), le switch reste OFF (cohérent avec le sens
  /// historique « ne pas afficher »).
  late bool _showLabelOnPdf;

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _currentTitle = widget.doc.title;
    _showLabelOnPdf =
        widget.doc.tags.contains(kPhotoTagPdfShowLabel) &&
        !widget.doc.tags.contains(kPhotoTagPdfNoLabel);
    _load();
  }

  Future<void> _load() async {
    final bytes = await _resolvePhotoBytes(widget.doc);
    if (!mounted) return;
    if (bytes != null) {
      setState(() => _bytes = bytes);
    } else {
      setState(() => _failed = true);
    }
  }

  /// Ouvre une mini-dialog avec un TextField pour renommer la photo.
  /// Retourne le nouveau titre en cas de validation, null si annulé.
  Future<void> _openRenameDialog(BuildContext ctx) async {
    final controller = TextEditingController(text: _currentTitle);
    final newName = await showDialog<String>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Renommer la photo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          stylusHandwritingEnabled: true,
          decoration: const InputDecoration(
            labelText: 'Nom',
            hintText: 'ex. Salle de bain',
          ),
          onSubmitted: (v) => Navigator.pop(dialogCtx, v.trim()),
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    if (newName == _currentTitle) return;
    final cb = widget.onMetadataChanged;
    if (cb == null) return;
    setState(() => _isSaving = true);
    try {
      await cb(newTitle: newName, showLabelOnPdf: _showLabelOnPdf);
      if (mounted) setState(() => _currentTitle = newName);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Toggle le switch « Afficher le nom dans le PDF ». Persiste
  /// immédiatement via le callback.
  Future<void> _toggleShowLabel(bool next) async {
    final cb = widget.onMetadataChanged;
    if (cb == null) return;
    setState(() {
      _showLabelOnPdf = next;
      _isSaving = true;
    });
    try {
      await cb(newTitle: _currentTitle, showLabelOnPdf: next);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Affiche la confirmation puis délègue à `widget.onDelete` qui se
  /// charge de fermer la dialog après validation. La confirmation
  /// utilise la bannière de confirmation commune de l'app.
  Future<void> _confirmAndDelete(BuildContext context) async {
    final confirm = await showAppDestructiveConfirmation(
      context: context,
      title: 'Supprimer cette photo ?',
      message:
          'La photo "${widget.doc.title}" sera supprimée définitivement '
          '(localement et sur le serveur).',
      confirmLabel: 'Supprimer',
      icon: LucideIcons.imageOff,
    );
    if (confirm != true) return;
    final cb = widget.onDelete;
    if (cb != null) await cb();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            Center(
              child: _bytes != null
                  ? InteractiveViewer(
                      // Pinch-to-zoom et pan natifs — utile pour
                      // examiner un détail de la photo (par ex. un
                      // équipement, un défaut sanitaire).
                      maxScale: 4.0,
                      child: Image.memory(
                        _bytes!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    )
                  : _failed
                  ? const Icon(
                      LucideIcons.imageOff,
                      size: 64,
                      color: Colors.white54,
                    )
                  : const CircularProgressIndicator(color: Colors.white),
            ),
            // Boutons d'action en haut à droite. Toujours accessibles
            // même après un zoom/pan via `InteractiveViewer`.
            //   - Poubelle : ouvre la confirmation avant suppression
            //     (uniquement si `onDelete` fourni — pas affiché dans
            //     un contexte read-only).
            //   - Croix : ferme la preview (équivalent au tap sur le
            //     fond noir du `GestureDetector` parent).
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onDelete != null) ...[
                    Material(
                      color: Colors.black.withValues(alpha: 0.4),
                      shape: const CircleBorder(),
                      child: IconButton(
                        icon: const Icon(
                          LucideIcons.trash2,
                          color: Color(0xFFFCA5A5),
                        ),
                        tooltip: 'Supprimer la photo',
                        onPressed: () => _confirmAndDelete(context),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Material(
                    color: Colors.black.withValues(alpha: 0.4),
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(LucideIcons.x, color: Colors.white),
                      tooltip: 'Fermer',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),
            // Bandeau bas : titre + crayon (rename) + switch (afficher
            // le nom sur le PDF). GestureDetector arrête la propagation
            // du tap vers le parent (qui ferme la dialog au tap fond).
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: GestureDetector(
                onTap: () {}, // Absorbe les taps sur le bandeau
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          _currentTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (widget.onMetadataChanged != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          icon: _isSaving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white70,
                                  ),
                                )
                              : const Icon(
                                  LucideIcons.pencil,
                                  color: Colors.white,
                                  size: 18,
                                ),
                          tooltip: 'Renommer',
                          onPressed: _isSaving
                              ? null
                              : () => _openRenameDialog(context),
                        ),
                        const SizedBox(width: 4),
                        // Switch + label compact « PDF »
                        Tooltip(
                          message: _showLabelOnPdf
                              ? 'Le nom apparaît sur le PDF'
                              : 'Le nom est masqué sur le PDF',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'PDF',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Switch.adaptive(
                                value: _showLabelOnPdf,
                                onChanged: _isSaving ? null : _toggleShowLabel,
                                activeThumbColor: kBrandPurple,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
