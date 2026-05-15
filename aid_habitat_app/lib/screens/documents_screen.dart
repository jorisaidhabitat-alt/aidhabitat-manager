import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pdfx/pdfx.dart';
import 'package:share_plus/share_plus.dart';

import 'package:http/http.dart' as http;

import '../components/beneficiary_badges.dart';
import '../components/dashed_border_painter.dart';
import '../components/file_drop_zone.dart';
import '../components/soft_transitions.dart';
import '../models/types.dart';
import '../models/visit_report_categories.dart';
import '../services/file_drop_listener.dart' show DroppedFile;
import '../services/image_compressor.dart';
import '../services/web_file_picker.dart';
import '../services/web_file_saver.dart';
import '../services/app_config.dart';
import '../services/data_service.dart';
import '../services/document_repository.dart';
import '../services/media_cache_service.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Tags disponibles dans le picker d'import — parité React.
///
/// Volontairement **sans** les tags Visite (`Visite - Logement /
/// Accessibilité / Sanitaires`) : ces 3 catégories sont gérées
/// exclusivement depuis l'onglet Photos du relevé de visite (VAD)
/// pour éviter à l'ergo de jongler entre deux écrans pendant la
/// visite. Voir `lib/models/visit_report_categories.dart` et
/// `lib/screens/visit_report/photos_tab.dart`.
const List<String> _kAvailableTags = [
  'Mandat',
  'Rapport',
  'Facture',
  'Devis',
  'Cerfa',
  'Photo',
  'Plan',
  'Autre',
];

const Color _kPurple = Color(0xFF8B6FA0);
const Color _kDarkPurple = Color(0xFF554a63);

/// Nombre maximum de fetches binaires en parallèle dans
/// `_warmDocumentBinaryCache`. Calé sur 4 — même valeur que le pool
/// du SyncEngine (cf. `NocodbSyncService._maxConcurrency`). Au-dessus,
/// les navigateurs commencent à empiler les requêtes et les vignettes
/// mettent paradoxalement plus de temps à apparaître.
const int _kWarmCacheConcurrency = 4;

// ---------------------------------------------------------------------------
// Main screen
// ---------------------------------------------------------------------------

class DocumentsScreen extends StatefulWidget {
  final Dossier dossier;
  final VoidCallback onBack;

  const DocumentsScreen({
    super.key,
    required this.dossier,
    required this.onBack,
  });

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen>
    with WidgetsBindingObserver {
  final DataService _dataService = DataService();
  final DocumentRepository _documentRepository = DocumentRepository();
  final ImagePicker _imagePicker = ImagePicker();
  final FocusNode _keyboardFocus = FocusNode();

  /// Compression cible pour les photos importées dans Documents
  /// (caméra ou galerie). Identique à PhotosTab — sans ces paramètres,
  /// `pickImage` retournait des fichiers 5-15 MB qui dépassaient la
  /// limite 4,5 MB de Vercel Hobby → 413 silencieux et doc bloqué en
  /// pending sync (bug reporté 2026-05-06 sur Moreau Henri).
  ///
  /// Ne s'applique pas aux PDF / fichiers non-image importés via
  /// `FilePicker` — ces derniers ne passent pas par image_picker.
  static const double _kCompressMaxWidth = 1600;
  static const int _kCompressQuality = 80;

  String _searchTerm = '';
  // Note : `_isLoading` retiré 2026-05-07. Plus de spinner d'attente —
  // la page s'affiche immédiatement (grille vide ou peuplée depuis
  // SQLite) et les documents apparaissent dès que `_loadDocuments`
  // met à jour `_documents`. Demande utilisateur : « pour l'espace
  // documents, ne fais pas de chargement, affiche simplement la page
  // et les documents s'affichent dès qu'ils sont chargés ». Le
  // pré-pull dans `main_screen._handleSelectDossier` hydrate SQLite
  // pendant que l'utilisateur navigue → la grille est déjà peuplée
  // à l'ouverture.
  bool _isImporting = false;
  bool _isBulkDownloading = false;
  /// True pendant qu'un picker (caméra / galerie / fichier) est ouvert.
  /// Sert de verrou contre les double-taps — sans ça, le même fichier
  /// peut être inséré 2 fois d'affilée sur iPad.
  bool _isPicking = false;
  List<DocItem> _documents = const [];

  // Sélection multiple
  final Set<String> _selectedIds = <String>{};
  bool _isSelectionMode = false;

  /// True pendant qu'un drag OS (Finder Mac) survole la grille — fait
  /// apparaître un overlay violet « Déposer pour importer » qui couvre
  /// toute la zone. Géré par `FileDropZone.onHighlight`.
  bool _dragHighlight = false;

  // _refreshTimer supprimé 2026-05-12 (refactor sync à la (re)connexion).

  String get _patientId => widget.dossier.patient.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDocuments();
    // Refactor 2026-05-12 : suppression du polling 1 s + de
    // `enterActiveContext`. L'écran Documents charge sa grille à
    // l'ouverture et la garde stable pendant toute la session sur
    // l'écran. Les imports faits depuis l'autre device apparaîtront :
    //  - au retour foreground (changement d'app puis retour)
    //  - à la reconnexion réseau
    //  - à la re-connexion utilisateur (logout/login)
    //  - au prochain `_loadDocuments` déclenché par une action locale
    //    (ajout, suppression, etc.)
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh au retour au premier plan (iOS: willEnterForeground / Android: onResume).
    if (state == AppLifecycleState.resumed && mounted) {
      _loadDocuments(silent: true);
    }
  }

  // ----- Data loading -----

  Future<void> _loadDocuments({bool silent = false}) async {
    // Plus de toggle `_isLoading` — la grille reste affichée même
    // pendant le fetch (cf. commentaire sur la déclaration du champ).
    // Le `silent` param est gardé pour compat des appelants existants
    // (importDocument, deleteDocument, etc. qui passent silent:true).
    final docs = await _dataService.fetchDocuments(_patientId);
    if (!mounted) return;
    setState(() {
      _documents = docs;
    });
    // Préchauffe le cache binaire (images + PDFs) en parallèle dès
    // l'affichage de la grille — comme ça les vignettes sont prêtes à
    // s'afficher instantanément au moment où chaque card monte.
    _warmDocumentBinaryCache(docs);

    final refreshed = await _dataService.refreshDocumentsFromRemote(_patientId);
    if (!mounted) return;
    if (refreshed) {
      final remoteDocs = await _dataService.fetchDocuments(_patientId);
      if (!mounted) return;
      setState(() {
        _documents = remoteDocs;
      });
      _warmDocumentBinaryCache(remoteDocs);
    }
    // Remote KO (offline ou erreur) → la grille reste sur le snapshot
    // SQLite affiché juste avant. Le polling timer (2 s) retentera.
  }

  /// Pré-télécharge les bytes de TOUS les documents listés (images
  /// + PDFs) via le cache SQLite `web_media_cache` (web) ou le cache
  /// filesystem (native). Sans ça, chaque vignette ferait son propre
  /// fetch en parallèle au moment du rendu de la card → flash de
  /// placeholder visible avant que l'image / le 1er rendu PDF arrive.
  ///
  /// Fire-and-forget : on n'attend pas. Les fetches échouent
  /// silencieusement individuellement. Idempotent : cache hit = no-op
  /// sub-millisecond.
  ///
  /// Concurrency limit (demande utilisateur 2026-05-06) : avant, on
  /// lançait TOUTES les fetches en parallèle sans limite. Avec 20+
  /// docs sur Wi-Fi domestique, la connexion saturait et chaque
  /// fetch ralentissait — résultat : les vignettes mettaient
  /// **plus** de temps à apparaître qu'avec une limite raisonnable.
  /// On utilise désormais un pool de [_kWarmCacheConcurrency]
  /// workers, comme le pool sync engine (4 entités en // max).
  void _warmDocumentBinaryCache(List<DocItem> docs) {
    if (docs.isEmpty) return;
    final urls = <String>{};
    for (final doc in docs) {
      // On ne précharge que les docs dont l'image / PDF est sur NocoDB
      // (URL publique signed) — les uploads en cours (dataUrl en local)
      // n'ont pas besoin de fetch.
      final url = doc.url?.trim() ?? '';
      if (url.isEmpty) continue;
      // Limite aux types qu'on affiche en preview (image / pdf).
      if (doc.type != 'image' && doc.type != 'pdf') continue;
      urls.add(url);
    }
    if (urls.isEmpty) return;
    if (kIsWeb) {
      // Sur web : `webCachedFetch` lit depuis SQLite, fetch + persiste si
      // miss. Pool de workers — chaque worker prend une URL de la queue
      // partagée, fetch (~quelques 100 ms à quelques s selon la taille),
      // passe à la suivante. Borne la concurrence pour ne pas saturer
      // la connexion ni le navigateur (Safari iOS limite déjà à ~6 req
      // simultanées par origine, mais lancer 50 fetches en parallèle
      // les empile et amplifie les retards perçus).
      final queue = urls.toList();
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          final url = queue.removeAt(0);
          try {
            await MediaCacheService.instance.webCachedFetch(
              url,
              headers: {'X-App-Session': AppConfig.appSessionToken},
            );
          } catch (_) {/* best-effort */}
        }
      }

      final n = urls.length < _kWarmCacheConcurrency
          ? urls.length
          : _kWarmCacheConcurrency;
      // Fire-and-forget — pas d'await sur le Future.wait global.
      // ignore: discarded_futures
      Future.wait(List.generate(n, (_) => worker()));
    } else {
      // Native : `prefetchAll` utilise le filesystem cache.
      // ignore: discarded_futures
      MediaCacheService.instance.prefetchAll(
        urls,
        headers: MediaCacheService.authHeaders(),
      );
    }
  }

  // ----- Import flows -----

  /// Caméra — iOS/Android/web. Sur web (PWA iPad), on bypass complètement
  /// `image_picker` et on utilise `pickWebFile` qui crée un
  /// `<input type="file" accept="image/*" capture="environment">` direct.
  /// `image_picker_for_web` re-encode via canvas et certaines images
  /// ressortaient tronquées à 1 MiB sur Safari macOS (bug rapporté
  /// 2026-05-07, bloc PNG IEND manquant). En lisant le fichier brut
  /// via FileReader on préserve l'intégrité bit-pour-bit.
  Future<void> _pickFromCamera() async {
    if (_isPicking || _isImporting) return;
    _isPicking = true;
    try {
      if (kIsWeb) {
        final picked = await pickWebFile(accept: 'image/*', capture: true);
        if (picked == null) return;
        await _openUploadModalFromBytes(
          bytes: picked.bytes,
          fileName: picked.name,
          defaultTag: 'Photo',
        );
        return;
      }
      if (Platform.isIOS || Platform.isAndroid) {
        final xfile = await _imagePicker.pickImage(
          source: ImageSource.camera,
          maxWidth: _kCompressMaxWidth,
          imageQuality: _kCompressQuality,
        );
        if (xfile == null) return;
        await _openUploadModal(File(xfile.path), defaultTag: 'Photo');
        return;
      }
      // Desktop (macOS/Windows/Linux) → fallback galerie système.
      _showError('Caméra non dispo sur ordinateur — choisissez une image.');
      await _pickFromGallery();
    } catch (err) {
      _showError('Caméra indisponible: $err');
    } finally {
      _isPicking = false;
    }
  }

  /// Import d'image ("Photothèque").
  ///  - iOS / Android natif → `image_picker` gallery
  ///  - Web PWA iPad → `<input type="file" accept="image/*">` créé
  ///    synchroniquement dans le gesture → iOS ouvre l'action-sheet
  ///    "Photothèque / Prendre une photo / Choisir un fichier". Sans ce
  ///    raccourci DOM, `FilePicker` peut perdre le user-activation en
  ///    mode standalone et ne rien ouvrir.
  ///  - Desktop → FilePicker filtré images.
  Future<void> _pickFromGallery() async {
    if (_isPicking || _isImporting) return;
    _isPicking = true;
    try {
      if (kIsWeb) {
        final picked = await pickWebFile(accept: 'image/*');
        if (picked == null) return;
        await _openUploadModalFromBytes(
          bytes: picked.bytes,
          fileName: picked.name,
          defaultTag: 'Photo',
        );
        return;
      }
      if (Platform.isIOS || Platform.isAndroid) {
        final xfile = await _imagePicker.pickImage(
          source: ImageSource.gallery,
          maxWidth: _kCompressMaxWidth,
          imageQuality: _kCompressQuality,
        );
        if (xfile == null) return;
        await _openUploadModal(File(xfile.path), defaultTag: 'Photo');
        return;
      }
      // Desktop
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        dialogTitle: 'Sélectionner une image',
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;
      await _openUploadModal(File(path), defaultTag: 'Photo');
    } catch (err) {
      _showError('Sélection d\'image impossible: $err');
    } finally {
      _isPicking = false;
    }
  }

  /// Web variant of [_openUploadModal] that reads from an [XFile]
  /// (delivered by image_picker camera on web). Delegates to the shared
  /// bytes-based flow.
  Future<void> _openUploadModalWeb(XFile xfile,
      {required String defaultTag}) async {
    final bytes = await xfile.readAsBytes();
    final fileName = xfile.name.isNotEmpty
        ? xfile.name
        : 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _openUploadModalFromBytes(
      bytes: bytes,
      fileName: fileName,
      defaultTag: defaultTag,
    );
  }

  /// Shared web import flow : sauvegarde directe sans demander de tag
  /// (demande utilisateur 2026-04-29 — système de tags supprimé).
  /// Le titre est dérivé automatiquement du nom de fichier (avant
  /// l'extension). Aucun tag n'est appliqué — les docs importés depuis
  /// l'espace Documents sont neutres.
  Future<void> _openUploadModalFromBytes({
    required List<int> bytes,
    required String fileName,
    required String defaultTag,
  }) async {
    if (!mounted) return;

    // Compression image si applicable (PNG/JPEG/HEIC/WebP/...) — passe
    // les autres formats (PDF, etc.) tel quel. Voir
    // `services/image_compressor.dart` pour le rationale (sync Mac→iPad
    // sous 3s, plus de canvas browser donc plus de truncation).
    final compressed = await compressImageForUpload(
      bytes: Uint8List.fromList(bytes),
      fileName: fileName,
    );
    final autoTitle = compressed.fileName.isNotEmpty
        ? compressed.fileName.split('.').first
        : 'Document';

    setState(() => _isImporting = true);
    try {
      await _documentRepository.importDocumentBytes(
        patientId: _patientId,
        bytes: compressed.bytes,
        fileName: compressed.fileName,
        tags: const [],
        title: autoTitle,
      );
      await _loadDocuments(silent: true);
      if (!mounted) return;
      _showSnack(compressed.wasRecompressed
          ? 'Image enregistrée (compressée pour sync rapide).'
          : 'Document enregistré localement.');
    } catch (err) {
      _showError('Import impossible: $err');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// "Scanner un document" → ouvre directement l'appareil photo. iOS
  /// inclut un scanner natif dans son picker caméra (encadre auto le
  /// document), on laisse le user l'utiliser tel quel.
  Future<void> _pickFromScanner() async {
    if (_isPicking || _isImporting) return;
    _isPicking = true;
    try {
      if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
        final xfile = await _imagePicker.pickImage(
          source: ImageSource.camera,
          maxWidth: _kCompressMaxWidth,
          imageQuality: _kCompressQuality,
        );
        if (xfile == null) return;
        if (kIsWeb) {
          await _openUploadModalWeb(xfile, defaultTag: 'Scan');
        } else {
          await _openUploadModal(File(xfile.path), defaultTag: 'Scan');
        }
        return;
      }
      // Desktop → fallback FilePicker (pas de caméra).
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        dialogTitle: 'Scanner — choisir un fichier',
      );
      if (result == null || result.files.isEmpty) return;
      await _importPickedFile(result.files.single, defaultTag: 'Scan');
    } catch (err) {
      _showError('Scanner indisponible: $err');
    } finally {
      _isPicking = false;
    }
  }

  Future<void> _pickFromFile() async {
    if (_isPicking || _isImporting) return;
    _isPicking = true;
    try {
      if (kIsWeb) {
        final picked = await pickWebFile(accept: '*/*');
        if (picked == null) return;
        await _openUploadModalFromBytes(
          bytes: picked.bytes,
          fileName: picked.name,
          defaultTag: 'Autre',
        );
        return;
      }
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        dialogTitle: 'Importer un fichier',
      );
      if (result == null || result.files.isEmpty) return;
      await _importPickedFile(result.files.single, defaultTag: 'Autre');
    } catch (err) {
      _showError('Import impossible: $err');
    } finally {
      _isPicking = false;
    }
  }

  /// Branches a [PlatformFile] picked via FilePicker into either the native
  /// File upload flow or the web bytes flow.
  Future<void> _importPickedFile(PlatformFile picked,
      {required String defaultTag}) async {
    if (kIsWeb) {
      final bytes = picked.bytes;
      if (bytes == null) {
        _showError('Lecture du fichier impossible (aucune donnée).');
        return;
      }
      final autoTitle = (picked.name.isNotEmpty)
          ? picked.name.split('.').first
          : 'Document';
      // Plus de modale de choix de tag (demande utilisateur 2026-04-29).
      setState(() => _isImporting = true);
      try {
        await _documentRepository.importDocumentBytes(
          patientId: _patientId,
          bytes: bytes,
          fileName: picked.name,
          tags: const [],
          title: autoTitle,
        );
        await _loadDocuments(silent: true);
        if (!mounted) return;
        _showSnack('Document enregistré localement.');
      } catch (err) {
        _showError('Import impossible: $err');
      } finally {
        if (mounted) setState(() => _isImporting = false);
      }
      return;
    }
    // Native
    final path = picked.path;
    if (path == null || path.isEmpty) {
      _showError('Chemin du fichier indisponible.');
      return;
    }
    await _openUploadModal(File(path), defaultTag: defaultTag);
  }

  /// Native import flow : sauvegarde directe sans demander de tag
  /// (demande utilisateur 2026-04-29 — système de tags supprimé).
  /// Titre auto-déduit du nom de fichier.
  Future<void> _openUploadModal(File file, {required String defaultTag}) async {
    if (!mounted) return;
    final autoTitle = file.path.split('/').last.split('.').first;

    setState(() => _isImporting = true);
    try {
      await _documentRepository.importDocument(
        patientId: _patientId,
        sourceFile: file,
        tags: const [],
        title: autoTitle,
      );
      await _loadDocuments(silent: true);
      if (!mounted) return;
      _showSnack('Document enregistré localement.');
    } catch (err) {
      _showError('Import impossible: $err');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  // ----- Delete flow -----

  Future<void> _deleteDocument(DocItem doc) async {
    final confirmed = await showSoftDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer le document ?'),
        content: Text(
          'Le document « ${doc.title} » sera supprimé localement et marqué pour suppression distante.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _documentRepository.deleteDocument(doc.id);
    await _loadDocuments(silent: true);
    if (mounted) _showSnack('Document supprimé.');
  }

  Future<void> _previewDocument(DocItem doc) async {
    // Tous les types passent désormais par `_PreviewScreen` (toolbar
    // d'annotation + bouton Save + bouton Download + bouton Delete).
    // Avant, le web shuntait les images vers une lightbox simple
    // `_showWebImagePreview` qui ne supportait pas l'annotation au
    // stylet — l'utilisateur signalait à juste titre qu'il ne pouvait
    // plus dessiner depuis la version Vercel.
    //
    // `_PreviewScreen._buildPreviewBody` détecte `kIsWeb` et route :
    //   - Image (data URL local OU URL distante) → `_ImageAnnotator`
    //     mode bytes (rendu via `Image.memory`, annotations en mémoire)
    //   - PDF → `_WebPdfAnnotatorWrapper` (rasterise chaque page via
    //     `pdfx.openData` + wrap dans `_ImageAnnotator` mode bytes)
    // Quick-Look style pop-up : dialog centré, fond semi-transparent, escape
    // pour fermer. On utilise une barrier colorée + une Dialog translucide
    // qui laisse voir le bureau autour.
    await showGeneralDialog<void>(
      context: context,
      // `barrierDismissible: false` — sans ça, un clic sur le fond
      // sombre ferme le dialog SANS passer par `_handleClose`, donc les
      // annotations en cours sont perdues silencieusement. La fermeture
      // doit toujours passer par le bouton X (qui propose Save / Ignorer
      // si du travail non sauvé est présent).
      barrierDismissible: false,
      barrierLabel: 'Aperçu du document',
      barrierColor: Colors.black.withValues(alpha: 0.6),
      transitionDuration: const Duration(milliseconds: 180),
      transitionBuilder: (ctx, anim, _, child) {
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(
              CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
            ),
            child: child,
          ),
        );
      },
      pageBuilder: (ctx, _, _) {
        return _PreviewScreen(
          doc: doc,
          onDelete: () async {
            final nav = Navigator.of(ctx);
            await _deleteDocument(doc);
            if (nav.canPop()) nav.pop();
          },
          onDownload: () => _downloadDocument(doc),
          onSave: (newTitle) async {
            await _documentRepository.updateDocumentMetadata(
              documentId: doc.id,
              title: newTitle,
              tags: doc.tags,
            );
            await _loadDocuments(silent: true);
            if (mounted) _showSnack('Document mis à jour.');
          },
        );
      },
    );
    // Refresh à la fermeture de la modale : si l'utilisateur a sauvé
    // une annotation, `enqueueAnnotatedReuploadBytes` a écrit un nouveau
    // `local_file_data_url` côté SQLite. Sans ce reload, la grille
    // continuait d'afficher l'ancienne vignette pendant ~10s (le temps
    // du polling auto). Avec, le thumbnail bascule immédiatement sur
    // la version annotée — `_DocThumbnail.didUpdateWidget` invalide
    // son cache mémoire dès que `dataUrl` change.
    if (mounted) {
      await _loadDocuments(silent: true);
    }
  }

  // ----- Selection helpers -----

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) _isSelectionMode = false;
    });
  }

  void _enterSelectionMode(String firstId) {
    // Retour haptique pour signaler l'entrée en mode sélection (comme navigator.vibrate(20) en React).
    HapticFeedback.mediumImpact();
    setState(() {
      _isSelectionMode = true;
      _selectedIds.add(firstId);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedIds.clear();
    });
  }

  void _selectAll() {
    setState(() {
      _isSelectionMode = true;
      _selectedIds.addAll(_filteredDocuments.map((d) => d.id));
    });
  }

  // ----- Download helpers -----

  /// Copie le fichier local du document vers un emplacement choisi par
  /// l'utilisateur (Files app, Téléchargements…) via file_picker.
  Future<void> _downloadDocument(DocItem doc) async {
    final fileName = doc.name.isNotEmpty ? doc.name : '${doc.title}.bin';
    final mime = _mimeTypeFor(doc);

    // Web : pas de filesystem accessible. On résout les bytes (data URL ou
    // cache SQLite des bytes distants) puis on déclenche un download via
    // un Blob → anchor `<a download>`. Avant ce fix, le bouton lisait
    // `doc.localPath` qui est toujours null sur web → erreur "Fichier
    // local indisponible" sur tous les docs synchronisés.
    if (kIsWeb) {
      try {
        final bytes = await _resolveWebDocumentBytes(doc);
        if (bytes == null) {
          _showError('Fichier indisponible (vérifiez la connexion).');
          return;
        }
        final ok = await triggerWebFileDownload(
          bytes: bytes,
          fileName: fileName,
          mimeType: mime,
        );
        if (!ok) {
          _showError('Téléchargement bloqué par le navigateur.');
          return;
        }
        _showSnack('Téléchargement lancé : $fileName');
      } catch (err) {
        _showError('Téléchargement impossible : $err');
      }
      return;
    }

    // Native : lit le fichier local (ou la copie persistée par le
    // pipeline `_persistRemoteDocumentsLocally` pour les docs synchronisés).
    final sourcePath = doc.localPath;
    if (sourcePath == null || sourcePath.isEmpty) {
      _showError('Fichier local indisponible.');
      return;
    }
    final source = File(sourcePath);
    if (!await source.exists()) {
      _showError('Fichier introuvable.');
      return;
    }
    try {
      final bytes = await source.readAsBytes();
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Enregistrer le document',
        fileName: fileName,
        bytes: bytes,
      );
      if (savedPath == null) return;
      _showSnack('Enregistré dans : $savedPath');
    } catch (err) {
      _showError('Téléchargement impossible : $err');
    }
  }

  /// Résout les bytes d'un document côté web. Trois sources, dans l'ordre :
  ///   1. `local_file_data_url` (upload offline avant push) — décodé depuis
  ///      le data URL stocké en SQLite.
  ///   2. `doc.url` distante → cache SQLite via `webCachedFetch` (auth-aware).
  ///   3. null si rien ne marche (déclenche le snack d'erreur côté caller).
  Future<Uint8List?> _resolveWebDocumentBytes(DocItem doc) async {
    final dataUrl = doc.dataUrl;
    if (dataUrl != null && dataUrl.isNotEmpty) {
      final comma = dataUrl.indexOf(',');
      if (comma > 0) {
        try {
          return base64Decode(dataUrl.substring(comma + 1));
        } catch (_) {
          // dataUrl mal formé — on tombe sur l'URL distante.
        }
      }
    }
    final url = doc.url;
    if (url != null && url.isNotEmpty) {
      return MediaCacheService.instance.webCachedFetch(
        url,
        headers: MediaCacheService.authHeaders(),
      );
    }
    return null;
  }

  String _mimeTypeFor(DocItem doc) {
    final ext = doc.name.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'svg':
        return 'image/svg+xml';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _bulkDownload() async {
    if (_selectedIds.isEmpty) return;
    setState(() => _isBulkDownloading = true);
    try {
      final xFiles = <XFile>[];
      for (final id in _selectedIds.toList()) {
        final doc = _documents.firstWhere(
          (d) => d.id == id,
          orElse: () => DocItem(
            id: '',
            type: 'doc',
            name: '',
            title: '',
            date: '',
            tags: const [],
            syncState: SyncState.synced,
          ),
        );
        if (doc.id.isEmpty) continue;
        final path = doc.localPath;
        if (path == null || path.isEmpty) continue;
        if (!await File(path).exists()) continue;
        xFiles.add(XFile(path, name: doc.name.isNotEmpty ? doc.name : doc.title));
      }
      if (xFiles.isEmpty) {
        _showError('Aucun fichier local dans la sélection.');
        return;
      }
      // iOS/Android native share sheet: one tap, user picks destination.
      await Share.shareXFiles(
        xFiles,
        subject: '${xFiles.length} document(s)',
      );
      _exitSelectionMode();
    } catch (err) {
      _showError('Partage impossible : $err');
    } finally {
      if (mounted) setState(() => _isBulkDownloading = false);
    }
  }

  // ----- Inline rename -----

  Future<void> _renameInline(DocItem doc, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty || trimmed == doc.title) return;
    await _documentRepository.updateDocumentMetadata(
      documentId: doc.id,
      title: trimmed,
      tags: doc.tags,
    );
    await _loadDocuments(silent: true);
  }

  // ----- Helpers -----

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
      ));
  }

  List<DocItem> get _filteredDocuments {
    // Décorrélation avec l'onglet Photos du relevé de visite : les 6
    // tags visite (Logement, Accessibilité, Sanitaires, Plan avant,
    // Plan après, Autres) sont gérés exclusivement dans VAD > Photos
    // et NE DOIVENT PAS apparaître dans la grille générale Documents.
    // Demande utilisateur 2026-04-30 : « les photos de l'espace
    // photos ne doivent pas être mélangés avec les documents de
    // l'espace documents ».
    //
    // À terme, les photos ne devraient même plus vivre dans la table
    // `mobile_documents` mais dans une table dédiée
    // `mobile_visit_photos` (cf. plan de refactor en cours). Tant
    // qu'on partage la table, ce filtre UI reste en place.
    String norm(String s) => s
        .toLowerCase()
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('ô', 'o')
        .replaceAll('î', 'i')
        .replaceAll('û', 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final visitTagsNormalized = kVisitPhotoTags.map(norm).toSet();
    bool isVisitTag(String tag) {
      final n = norm(tag);
      if (visitTagsNormalized.contains(n)) return true;
      return n.startsWith('visite - ') || n.startsWith('visite-');
    }
    Iterable<DocItem> docs =
        _documents.where((doc) => !doc.tags.any(isVisitTag));

    final query = _searchTerm.trim().toLowerCase();
    if (query.isNotEmpty) {
      docs = docs.where((doc) {
        return doc.title.toLowerCase().contains(query) ||
            doc.name.toLowerCase().contains(query) ||
            doc.tags.any((tag) => tag.toLowerCase().contains(query));
      });
    }
    return docs.toList();
  }

  // ----- Build -----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: KeyboardListener(
        focusNode: _keyboardFocus,
        autofocus: true,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent) return;
          // Ctrl / Cmd + A → tout sélectionner
          if ((HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed) &&
              event.logicalKey == LogicalKeyboardKey.keyA) {
            _selectAll();
          } else if (event.logicalKey == LogicalKeyboardKey.escape &&
              _isSelectionMode) {
            _exitSelectionMode();
          }
        },
        child: Padding(
          // Marges alignées sur le relevé de visite (`all(24)`) au lieu
          // de `fromLTRB(24, 16, 24, 24)`. Demande utilisateur 2026-04-29 :
          // l'écran Documents doit avoir le même cadre / la même entête
          // que la VAD pour garder la sensation d'être dans le même
          // dossier en passant de l'un à l'autre.
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header bénéficiaire — pattern repris de
              // `VisitReportScreen` : back button rond + NOM Prénom +
              // badges (type d'accompagnement, catégorie de revenu) +
              // pin localisation + adresse complète. Quand on bascule
              // en mode sélection, on remplace badges+pin+adresse par
              // la toolbar (le slot back+nom reste).
              _buildPatientHeader(),
              const SizedBox(height: 16),
              Expanded(
                child: _buildGridWithDropZone(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Wrap la grille des documents dans un `FileDropZone` qui accepte
  /// les drops du Finder Mac (ou Explorer Windows). Sur natif, le
  /// drop zone est un no-op et la grille s'affiche normalement.
  ///
  /// Demande utilisateur 2026-05-05 : « sur Mac, le drag and drop ne
  /// fonctionne pas quand je souhaite prendre un document ou une image
  /// et le mettre direct dans l'espace document. Cela doit être
  /// possible ».
  Widget _buildGridWithDropZone() {
    return FileDropZone(
      onDrop: _importDroppedFiles,
      onHighlight: (on) {
        if (mounted && _dragHighlight != on) {
          setState(() => _dragHighlight = on);
        }
      },
      child: Stack(
        children: [
          _buildGrid(),
          if (_dragHighlight)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: _kPurple.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _kPurple,
                      width: 2,
                      style: BorderStyle.solid,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 16,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          LucideIcons.upload,
                          size: 18,
                          color: _kDarkPurple,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Déposer pour importer',
                          style: TextStyle(
                            color: _kDarkPurple,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
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

  /// Importe les fichiers déposés via drag-and-drop (web Mac uniquement).
  /// Boucle sur chaque fichier et appelle le même chemin que l'import
  /// classique via `pickFiles` → `importDocumentBytes`.
  Future<void> _importDroppedFiles(List<DroppedFile> files) async {
    if (files.isEmpty) return;
    if (_isImporting) return;
    setState(() => _isImporting = true);
    int success = 0;
    int failed = 0;
    try {
      for (final f in files) {
        try {
          // Compression si image (cf. compressImageForUpload).
          final compressed = await compressImageForUpload(
            bytes: f.bytes,
            fileName: f.name,
            sourceMimeType: f.mimeType,
          );
          final autoTitle = compressed.fileName.isNotEmpty
              ? compressed.fileName.split('.').first
              : 'Document';
          await _documentRepository.importDocumentBytes(
            patientId: _patientId,
            bytes: compressed.bytes,
            fileName: compressed.fileName,
            tags: const [],
            title: autoTitle,
          );
          success += 1;
        } catch (_) {
          failed += 1;
        }
      }
      await _loadDocuments(silent: true);
      if (!mounted) return;
      if (success > 0 && failed == 0) {
        _showSnack(
          success == 1
              ? 'Document importé.'
              : '$success documents importés.',
        );
      } else if (success > 0 && failed > 0) {
        _showSnack('$success importé(s), $failed échec(s).');
      } else {
        _showError('Import impossible.');
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// Bouton retour aligné sur celui du VAD (visit_report_screen
  /// `_buildBackButton`). Demande utilisateur 2026-05-13 : « fais la
  /// meme flèche pour les autres pages ». 44×44 transparent,
  /// chevronLeft 24px ink-700.
  Widget _buildBackButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onBack,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
          ),
          alignment: Alignment.center,
          child: const Icon(
            LucideIcons.chevronLeft,
            size: 24,
            color: Color(0xFF2B323A), // ink-700
          ),
        ),
      ),
    );
  }

  /// Entête bénéficiaire — pattern aligné sur `VisitReportScreen`
  /// (demande utilisateur 2026-04-29 : « Pour la page documents fait
  /// pareil que pour la VAD »). Affiche :
  ///
  ///   [retour]  NOM Prénom  [type accompagnement]  [revenu]  📍 adresse
  ///
  /// Quand on entre en mode sélection, badges + pin + adresse sont
  /// remplacés par la toolbar (téléchargement / suppression / etc.).
  /// Le slot back + nom reste pour ne pas désorienter l'ergo.
  Widget _buildPatientHeader() {
    final patient = widget.dossier.patient;
    // Adresse complète sur 1 ligne — mêmes règles de formatage que
    // VisitReportScreen pour la cohérence visuelle entre les 2 écrans.
    final addressLine = [
      patient.address.trim(),
      [patient.zipCode.trim(), patient.city.trim()]
          .where((s) => s.isNotEmpty)
          .join(' '),
    ].where((s) => s.isNotEmpty).join(' · ');
    final accompanimentLabel =
        formatAccompanimentType(widget.dossier.natureAccompagnement).trim();
    final incomeLabel = patient.incomeCategory.trim();

    return SizedBox(
      // Hauteur fixe = 48 px (taille de la toolbar de sélection) pour
      // que la grille en dessous ne bouge pas d'un pixel quand on
      // entre/quitte le mode sélection.
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildBackButton(),
          const SizedBox(width: 16),
          // Bloc nom + (badges + adresse) ou (toolbar de sélection).
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Text(
                    '${patient.lastName.toUpperCase()} ${patient.firstName}',
                    // Refonte 2026-05-13 : Nunito w600 — style uniforme
                    // avec les autres titres de page.
                    style: GoogleFonts.nunito(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.4,
                      color: const Color(0xFF0E1116),
                    ),
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
                if (_isSelectionMode) ...[
                  const SizedBox(width: 16),
                  Expanded(child: _buildSelectionToolbar()),
                ] else ...[
                  // Fallback "MPA complet" 2026-05-07 — cf. commentaire
                  // identique dans visit_report_screen.dart.
                  const SizedBox(width: 10),
                  AccompanimentBadge(
                    value: accompanimentLabel.isNotEmpty
                        ? accompanimentLabel
                        : 'MPA complet',
                    rawType: widget.dossier.natureAccompagnement
                            .trim().isNotEmpty
                        ? widget.dossier.natureAccompagnement
                        : 'complet',
                    large: true,
                  ),
                  if (incomeLabel.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    IncomeCategoryBadge(
                      value: incomeLabel,
                      large: true,
                    ),
                  ],
                  if (addressLine.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    const Icon(
                      LucideIcons.mapPin,
                      size: 18,
                      color: Color(0xFF8A939D),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        addressLine,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF8A939D),
                        ),
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    ),
                  ] else
                    const Spacer(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionToolbar() {
    final allSelected = _filteredDocuments.isNotEmpty &&
        _selectedIds.length >= _filteredDocuments.length;
    // Toolbar sur la même ligne que le titre. Boutons dimensionnés plus
    // confortablement (36px) tout en restant alignés verticalement.
    return SizedBox(
      height: 48,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: _kPurple.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            Text(
              '${_selectedIds.length} sélectionné${_selectedIds.length > 1 ? 's' : ''}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: _kDarkPurple,
                fontSize: 15,
              ),
            ),
            const Spacer(),
            _CompactToolbarButton(
              label: allSelected ? 'Tout désélectionner' : 'Tout sélectionner',
              icon: allSelected ? LucideIcons.checkSquare : LucideIcons.square,
              onTap: allSelected ? _exitSelectionMode : _selectAll,
              color: _kDarkPurple,
              background: Colors.transparent,
            ),
            const SizedBox(width: 6),
            _CompactToolbarButton(
              label: 'Télécharger',
              icon: LucideIcons.download,
              onTap: _isBulkDownloading || _selectedIds.isEmpty
                  ? null
                  : _bulkDownload,
              color: Colors.white,
              background: _kPurple,
              isLoading: _isBulkDownloading,
            ),
            const SizedBox(width: 6),
            _CompactToolbarButton(
              label: 'Supprimer',
              icon: LucideIcons.trash2,
              onTap: _selectedIds.isEmpty ? null : _bulkDelete,
              color: Colors.white,
              background: const Color(0xFFDC2626),
            ),
            const SizedBox(width: 10),
            InkWell(
              onTap: _exitSelectionMode,
              borderRadius: BorderRadius.circular(999),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(LucideIcons.x, size: 20, color: _kDarkPurple),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Supprime tous les documents sélectionnés après une confirmation unique.
  Future<void> _bulkDelete() async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final confirmed = await showSoftDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Supprimer $count document${count > 1 ? 's' : ''} ?'),
        content: Text(
          'Cette action supprimera $count document${count > 1 ? 's' : ''} '
          'localement et les marquera pour suppression distante. Elle est '
          'irréversible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Supprimer en parallèle pour aller vite.
    final ids = _selectedIds.toList();
    for (final id in ids) {
      try {
        await _documentRepository.deleteDocument(id);
      } catch (_) {
        // Continue : on ne bloque pas le bulk si un item échoue.
      }
    }
    if (!mounted) return;
    _exitSelectionMode();
    await _loadDocuments(silent: true);
    if (mounted) _showSnack('$count document${count > 1 ? 's supprimés' : ' supprimé'}.');
  }


  Widget _buildGrid() {
    final docs = _filteredDocuments;
    final hasActiveFilter = _searchTerm.trim().isNotEmpty;
    // Si filtres actifs ET aucun résultat → empty state (pas de tile "+" qui
    // prêterait à confusion). Sinon, toujours afficher le tile "+" suivi des
    // documents (y compris quand la grille est totalement vide).
    if (docs.isEmpty && hasActiveFilter) {
      return _EmptyState(searchTerm: _searchTerm);
    }

    return LayoutBuilder(
      builder: (ctx, constraints) {
        return GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 0.82,
          ),
          itemCount: docs.length + 1,
          itemBuilder: (ctx, i) {
            if (i == 0) {
              return _AddDocumentTile(
                disabled: _isImporting || _isSelectionMode,
                onImage: _pickFromGallery,
                onCamera: _pickFromCamera,
                onScanner: _pickFromScanner,
                onFile: _pickFromFile,
              );
            }
            final doc = docs[i - 1];
            final selected = _selectedIds.contains(doc.id);
            return _DocCard(
              doc: doc,
              selected: selected,
              selectionMode: _isSelectionMode,
              onTap: () {
                if (_isSelectionMode) {
                  _toggleSelection(doc.id);
                } else {
                  _previewDocument(doc);
                }
              },
              onLongPress: () {
                if (!_isSelectionMode) {
                  _enterSelectionMode(doc.id);
                } else {
                  _toggleSelection(doc.id);
                }
              },
              // Clic sur la checkbox (hover ou déjà sélectionné) → active
              // directement le mode sélection et toggle la card.
              onToggleSelect: () {
                if (!_isSelectionMode) {
                  _enterSelectionMode(doc.id);
                } else {
                  _toggleSelection(doc.id);
                }
              },
              onDelete: () => _deleteDocument(doc),
              onDownload: () => _downloadDocument(doc),
              onTitleChanged: (value) => _renameInline(doc, value),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keyboardFocus.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Dashed "Add document" tile — première tuile de la grille (parity React).
// Tap → popup menu avec 4 options (Image / Caméra / Scanner / Importer).
// ---------------------------------------------------------------------------

class _AddDocumentTile extends StatefulWidget {
  final bool disabled;
  final VoidCallback onImage;
  final VoidCallback onCamera;
  final VoidCallback onScanner;
  final VoidCallback onFile;

  const _AddDocumentTile({
    required this.disabled,
    required this.onImage,
    required this.onCamera,
    required this.onScanner,
    required this.onFile,
  });

  @override
  State<_AddDocumentTile> createState() => _AddDocumentTileState();
}

class _AddDocumentTileState extends State<_AddDocumentTile> {
  bool _hovering = false;

  Future<void> _showMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset(box.size.width / 2, box.size.height / 2),
            ancestor: overlay),
        box.localToGlobal(
          box.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final choice = await showMenu<_AddChoice>(
      context: context,
      position: position,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Color(0xFFE4E7EB)),
      ),
      elevation: 12,
      items: [
        _buildMenuItem(
          _AddChoice.image,
          icon: LucideIcons.image,
          label: 'Image',
          subtitle: 'Sélectionner depuis la galerie',
        ),
        _buildMenuItem(
          _AddChoice.camera,
          icon: LucideIcons.camera,
          label: 'Prendre une photo',
          subtitle: 'Avec l\'appareil photo',
        ),
        _buildMenuItem(
          _AddChoice.scanner,
          icon: LucideIcons.scanLine,
          label: 'Scanner un document',
          subtitle: 'PDF ou image',
        ),
        _buildMenuItem(
          _AddChoice.file,
          icon: LucideIcons.upload,
          label: 'Importer',
          subtitle: 'N\'importe quel fichier',
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _AddChoice.image:
        widget.onImage();
        break;
      case _AddChoice.camera:
        widget.onCamera();
        break;
      case _AddChoice.scanner:
        widget.onScanner();
        break;
      case _AddChoice.file:
        widget.onFile();
        break;
    }
  }

  PopupMenuItem<_AddChoice> _buildMenuItem(
    _AddChoice value, {
    required IconData icon,
    required String label,
    required String subtitle,
  }) {
    return PopupMenuItem<_AddChoice>(
      value: value,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _kPurple.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: _kDarkPurple),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0E1116),
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF5C6670),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: widget.disabled
          ? SystemMouseCursors.forbidden
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.disabled ? null : () => _showMenu(context),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            // Fond violet CONSTANT (légère teinte en base, plus foncée au
            // hover). Disabled = gris très clair pour distinguer l'état.
            color: widget.disabled
                ? const Color(0xFFF2F4F6)
                : _hovering
                    ? _kPurple.withValues(alpha: 0.14)
                    : _kPurple.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(16),
          ),
          child: CustomPaint(
            painter: DashedBorderPainter(
              color: widget.disabled
                  ? Color(0xFFB9C0C7)
                  : _kPurple.withValues(alpha: _hovering ? 1 : 0.8),
              strokeWidth: 2,
              radius: 16,
              dashLength: 8,
              dashGap: 5,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _kPurple.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      LucideIcons.plus,
                      size: 26,
                      color: widget.disabled ? Color(0xFF8A939D) : _kPurple,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Déposer un fichier\nou prendre une photo',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      color: widget.disabled
                          ? Color(0xFF8A939D)
                          : _kPurple,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _AddChoice { image, camera, scanner, file }

/// Dessine une bordure pointillée autour d'un rectangle arrondi.
// `DashedBorderPainter` est désormais dans `../components/dashed_border_painter.dart`.

// ---------------------------------------------------------------------------
// Document card
// ---------------------------------------------------------------------------

class _DocCard extends StatefulWidget {
  final DocItem doc;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelect;
  final VoidCallback onDelete;
  final VoidCallback onDownload;
  final Future<void> Function(String newTitle) onTitleChanged;

  const _DocCard({
    required this.doc,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleSelect,
    required this.onDelete,
    required this.onDownload,
    required this.onTitleChanged,
  });

  @override
  State<_DocCard> createState() => _DocCardState();
}

class _DocCardState extends State<_DocCard> {
  bool _isEditingTitle = false;
  bool _hovering = false;
  late TextEditingController _titleCtrl;
  late FocusNode _titleFocus;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.doc.title);
    _titleFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _DocCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEditingTitle && widget.doc.title != _titleCtrl.text) {
      _titleCtrl.text = widget.doc.title;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  Future<void> _commitRename() async {
    final newTitle = _titleCtrl.text.trim();
    setState(() => _isEditingTitle = false);
    if (newTitle.isEmpty || newTitle == widget.doc.title) {
      _titleCtrl.text = widget.doc.title;
      return;
    }
    await widget.onTitleChanged(newTitle);
  }

  void _startEditing() {
    setState(() => _isEditingTitle = true);
    _titleCtrl.text = widget.doc.title;
    Future.microtask(() {
      _titleFocus.requestFocus();
      _titleCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _titleCtrl.text.length,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final createdAt = DateTime.tryParse(doc.date)?.toLocal();
    final dateLabel = createdAt == null
        ? doc.date
        : DateFormat('dd/MM/yyyy').format(createdAt);
    final selMode = widget.selectionMode;
    final selected = widget.selected;

    // La checkbox est visible au survol souris, quand la card est sélectionnée,
    // ou quand on est en mode sélection global (long-press ou checkbox activée).
    final showCheckbox = _hovering || selected || selMode;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail / preview area
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                      child: _DocThumbnail(doc: doc),
                    ),
                  ),
                  // Selection overlay
                  if (selMode)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                        child: Container(
                          color: selected
                              ? _kPurple.withValues(alpha: 0.35)
                              : Colors.black.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                  // Tag overlay supprimé (demande utilisateur
                  // 2026-04-29) — le système de tags a été retiré côté
                  // import (plus de modale de choix de type) et côté
                  // affichage (pas de badge noir en haut-gauche).
                  // Checkbox de sélection (top-left). Apparaît au survol
                  // souris, quand la card est sélectionnée, ou pendant le
                  // mode sélection. Carré à coins arrondis, sans contour
                  // violet — violet seulement quand coché.
                  if (showCheckbox)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onToggleSelect,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: selected ? _kPurple : Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.18),
                                  blurRadius: 4,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: selected
                                ? const Icon(
                                    LucideIcons.check,
                                    size: 14,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                  // Sync badge (top-right) — hidden in selection mode.
                  // Les actions « Télécharger » et « Supprimer » sont
                  // déplacées dans le menu kebab (3 points) sur le
                  // bandeau blanc en bas de la card — plus d'icônes
                  // flottantes sur la vignette.
                  if (!selMode)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _SyncBadge(syncState: doc.syncState),
                    ),
                ],
              ),
            ),
            // Title + date (gauche) + menu actions kebab (droite).
            // Le bandeau blanc accueille à la fois le titre éditable
            // et un bouton 3 points qui ouvre un menu avec « Télécharger »
            // / « Supprimer » — choix design utilisateur pour libérer
            // la vignette de toute icône flottante.
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Inline editable title — Nunito (parité avec
                        // les autres titres de l'app, demande user
                        // 2026-05-13). Taille bumpée 13 → 16, weight
                        // allégé bold (w700) → w500 (demande user
                        // 2026-05-13 : « augmente la taille et reduis
                        // l'epaisseur »).
                        _isEditingTitle
                            ? TextField(
                                controller: _titleCtrl,
                                focusNode: _titleFocus,
                                maxLines: 1,
                                textInputAction: TextInputAction.done,
                                style: GoogleFonts.nunito(
                                  fontWeight: FontWeight.w500,
                                  fontSize: 16,
                                  color: Colors.black87,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                ),
                                onSubmitted: (_) => _commitRename(),
                                onTapOutside: (_) => _commitRename(),
                              )
                            : GestureDetector(
                                onTap: selMode ? null : _startEditing,
                                behavior: HitTestBehavior.opaque,
                                child: Text(
                                  doc.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.nunito(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 16,
                                    color: Colors.black87,
                                  ),
                                ),
                              ),
                        const SizedBox(height: 2),
                        // Date : 10 → 13, weight light (w300) — discret
                        // et lisible avec un peu plus d'air sous le titre.
                        Text(
                          dateLabel,
                          style: GoogleFonts.nunito(
                            fontSize: 13,
                            fontWeight: FontWeight.w300,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Menu kebab (3 points) — caché en mode sélection,
                  // sinon expose Télécharger + Supprimer.
                  if (!selMode)
                    PopupMenuButton<String>(
                      tooltip: 'Actions',
                      icon: const Icon(
                        LucideIcons.moreVertical,
                        size: 18,
                        color: Color(0xFF8A939D),
                      ),
                      padding: EdgeInsets.zero,
                      splashRadius: 18,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      onSelected: (value) {
                        if (value == 'download') {
                          widget.onDownload();
                        } else if (value == 'delete') {
                          widget.onDelete();
                        }
                      },
                      itemBuilder: (ctx) => const [
                        PopupMenuItem<String>(
                          value: 'download',
                          child: Row(
                            children: [
                              Icon(
                                LucideIcons.download,
                                size: 16,
                                color: _kDarkPurple,
                              ),
                              SizedBox(width: 10),
                              Text('Télécharger'),
                            ],
                          ),
                        ),
                        PopupMenuDivider(),
                        PopupMenuItem<String>(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                LucideIcons.trash2,
                                size: 16,
                                color: Colors.red,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Supprimer',
                                style: TextStyle(color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Thumbnail resolver: local image > remote image URL > icon placeholder
// ---------------------------------------------------------------------------

class _DocThumbnail extends StatefulWidget {
  final DocItem doc;

  const _DocThumbnail({required this.doc});

  @override
  State<_DocThumbnail> createState() => _DocThumbnailState();
}

class _DocThumbnailState extends State<_DocThumbnail> {
  /// Cache des bytes décodés par `doc.id` — partagé entre toutes les
  /// instances pour que la grille ne refasse pas de `base64Decode` à
  /// chaque rebuild (c'est cette ré-décoding qui faisait clignoter les
  /// vignettes : Flutter voyait un nouvel `Uint8List` à chaque frame et
  /// rechargeait le décodeur d'image).
  static final Map<String, Uint8List> _bytesCache = {};

  /// Cache partagé des aplats d'annotation (PNG bytes décodés) keyed
  /// par `doc.id`. Invalidé quand `doc.annotationsJson` change (cf.
  /// `didUpdateWidget`) pour que la vignette reflète immédiatement la
  /// dernière save.
  static final Map<String, Uint8List> _annotationOverlayCache = {};
  static final Map<String, String> _annotationCacheJsonKey = {};

  /// Retourne les bytes PNG de l'aplat « page 1 + traits ergo » si
  /// disponibles dans `documents.annotations_json` (clé "1"). null si
  /// le doc n'a pas d'annotation pour la page 1, ou si le JSON est
  /// invalide. Cache mémoire pour éviter de re-decode chaque frame.
  static Uint8List? _firstPageAnnotationBytes(DocItem doc) {
    final raw = doc.annotationsJson;
    if (raw == null || raw.isEmpty) return null;
    // Cache hit ssi le JSON brut n'a pas changé.
    if (_annotationCacheJsonKey[doc.id] == raw) {
      final cached = _annotationOverlayCache[doc.id];
      if (cached != null) return cached;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final dataUrl = decoded['1'];
      if (dataUrl is! String || dataUrl.isEmpty) return null;
      final bytes = _decodeDataUrl(dataUrl);
      if (bytes == null || bytes.isEmpty) return null;
      _annotationOverlayCache[doc.id] = bytes;
      _annotationCacheJsonKey[doc.id] = raw;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _primeBytes();
  }

  @override
  void didUpdateWidget(covariant _DocThumbnail old) {
    super.didUpdateWidget(old);
    if (old.doc.id != widget.doc.id ||
        old.doc.dataUrl != widget.doc.dataUrl) {
      // Invalidate le cache mémoire pour cet `id` quand le dataUrl a
      // changé (cas typique : l'utilisateur vient d'annoter + sauver →
      // `enqueueAnnotatedReuploadBytes` a écrit un nouveau data URL en
      // SQLite). Sans ça, `_primeBytes` retournait l'ancien décodage
      // et la vignette restait sur l'image pré-annotation.
      if (old.doc.dataUrl != widget.doc.dataUrl) {
        _bytesCache.remove(widget.doc.id);
      }
      _primeBytes();
    }
    // Invalidate aussi le cache d'aplat d'annotation quand le JSON a
    // changé (l'ergo vient de saver une annotation page 1) — sinon la
    // vignette PDF restait sur l'aplat précédent (ou pas d'aplat du tout).
    if (old.doc.annotationsJson != widget.doc.annotationsJson) {
      _annotationOverlayCache.remove(widget.doc.id);
      _annotationCacheJsonKey.remove(widget.doc.id);
    }
  }

  void _primeBytes() {
    final dataUrl = widget.doc.dataUrl;
    if (dataUrl == null || dataUrl.isEmpty) {
      setState(() => _bytes = null);
      return;
    }
    final cached = _bytesCache[widget.doc.id];
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    final decoded = _decodeDataUrl(dataUrl);
    if (decoded != null) {
      _bytesCache[widget.doc.id] = decoded;
    }
    setState(() => _bytes = decoded);
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    if (doc.type == 'image') {
      // BoxFit.contain (vs cover historique) — demande utilisateur
      // 2026-05-06 : « je n'ai pas l'image complète, une partie est
      // coupée ». Avec cover, une photo portrait dans une tile carrée
      // perdait haut+bas. contain = lettrebox éventuel mais image
      // entière visible → l'ergo reconnaît son contenu d'un coup d'œil.
      if (_bytes != null) {
        return Image.memory(
          _bytes!,
          fit: BoxFit.contain,
          gaplessPlayback: true, // évite le flash blanc au rebuild
          errorBuilder: _fallback,
        );
      }
      if (!kIsWeb &&
          doc.localPath != null &&
          doc.localPath!.isNotEmpty) {
        final file = File(doc.localPath!);
        if (file.existsSync()) {
          return Image.file(
            file,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: _fallback,
          );
        }
      }
      if (doc.url != null && doc.url!.isNotEmpty) {
        // Télécharge via MediaCacheService (cache persistant offline-first).
        return _RemoteImage(
          url: doc.url!,
          fit: BoxFit.contain,
          fallback: _iconPlaceholder(doc.type),
        );
      }
    }
    if (doc.type == 'pdf') {
      // 1) PRIORITÉ : si l'ergo a annoté la page 1 du PDF, on affiche
      //    directement l'aplat PNG (PDF page 1 + traits) stocké dans
      //    `documents.annotations_json` sous la clé "1". Évite à
      //    l'utilisateur d'ouvrir le doc pour voir qu'il y a une note
      //    par-dessus — cf. demande utilisateur 2026-04-28.
      //
      //    Le décodage est mis en cache mémoire (statique partagé)
      //    pour que les rebuilds de la grille ne re-decode pas chaque
      //    frame (pareil que `_bytesCache` pour les images).
      final overlayBytes = _firstPageAnnotationBytes(doc);
      if (overlayBytes != null) {
        return Image.memory(
          overlayBytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: _fallback,
        );
      }
      // Web : on a soit les bytes en mémoire (upload web → dataUrl
      // décodé par `_primeBytes`), soit on les récupère depuis la
      // cache MediaCacheService (`webCachedFetch`) en passant l'URL
      // signée et le token X-App-Session. Dans les deux cas on rend
      // la 1re page en PNG via pdfx (qui pédale sur PDF.js côté web).
      //
      // Native : on garde le chemin filesystem qui marche déjà via
      // `PdfDocument.openFile`.
      //
      // Plus de fallback "icône PDF par défaut" sur la card : tant
      // qu'on n'a pas confirmé l'échec du rendu, on affiche le
      // placeholder neutre (gris-blanc + icône) — dès que les bytes
      // arrivent on swap. Voir `_PdfThumbnailFromBytes`.
      if (!kIsWeb &&
          doc.localPath != null &&
          doc.localPath!.isNotEmpty &&
          File(doc.localPath!).existsSync()) {
        return _PdfThumbnail(path: doc.localPath!);
      }
      // Bytes déjà en mémoire (upload web pas encore synced) : on
      // les passe directement, pas de round-trip réseau.
      if (kIsWeb && _bytes != null) {
        final pdfBytes = _bytes!;
        return _PdfThumbnailFromBytes(
          docId: doc.id,
          bytesProvider: () async => pdfBytes,
          fallback: _iconPlaceholder('pdf'),
        );
      }
      // Sinon : fetch via cache (webCachedFetch persiste en SQLite,
      // hit instantané au prochain visit).
      final url = doc.url?.trim() ?? '';
      if (url.isNotEmpty) {
        return _PdfThumbnailFromBytes(
          docId: doc.id,
          bytesProvider: () async {
            if (kIsWeb) {
              return await MediaCacheService.instance.webCachedFetch(
                url,
                headers: {'X-App-Session': AppConfig.appSessionToken},
              );
            }
            // Native : MediaCacheService.fetch renvoie un File ; on
            // lit ses bytes pour les passer à pdfx.openData. Permet
            // l'aperçu sur les docs téléchargés mais pas encore
            // ouverts (donc pas encore décodés en localPath).
            final file = await MediaCacheService.instance.fetch(
              url,
              headers: MediaCacheService.authHeaders(),
            );
            if (file == null) return null;
            try {
              return await file.readAsBytes();
            } catch (_) {
              return null;
            }
          },
          fallback: _iconPlaceholder('pdf'),
        );
      }
    }
    return _iconPlaceholder(doc.type);
  }

  /// Decodes a `data:<mime>;base64,<...>` URL into raw bytes. Returns null
  /// if malformed (missing `,` separator or invalid base64).
  static Uint8List? _decodeDataUrl(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  Widget _fallback(BuildContext ctx, Object err, StackTrace? st) =>
      _iconPlaceholder(widget.doc.type);

  Widget _iconPlaceholder(String type) {
    final IconData icon;
    final Color color;
    switch (type) {
      case 'pdf':
        icon = LucideIcons.fileText;
        color = Colors.red.shade300;
        break;
      case 'image':
        icon = LucideIcons.image;
        color = _kPurple;
        break;
      default:
        icon = LucideIcons.file;
        color = Color(0xFF8A939D);
    }
    return Container(
      color: Color(0xFFFAFAFA),
      child: Center(
        child: Icon(icon, size: 56, color: color),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PDF thumbnail: rend la première page du PDF en image bitmap.
// Les bytes sont mémorisés dans un cache par chemin pour éviter de re-render
// à chaque rebuild de la grille.
// ---------------------------------------------------------------------------

class _PdfThumbnail extends StatefulWidget {
  final String path;
  const _PdfThumbnail({required this.path});

  @override
  State<_PdfThumbnail> createState() => _PdfThumbnailState();
}

class _PdfThumbnailState extends State<_PdfThumbnail> {
  static final Map<String, Uint8List> _cache = {};

  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PdfThumbnail old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final cached = _cache[widget.path];
    if (cached != null) {
      if (!mounted) return;
      setState(() => _bytes = cached);
      return;
    }
    try {
      final doc = await PdfDocument.openFile(widget.path);
      final page = await doc.getPage(1);
      final rendered = await page.render(
        width: page.width * 1.5,
        height: page.height * 1.5,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      await page.close();
      await doc.close();
      if (!mounted) return;
      if (rendered?.bytes != null) {
        _cache[widget.path] = rendered!.bytes;
        setState(() => _bytes = rendered.bytes);
      } else {
        setState(() => _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Container(
        color: Color(0xFFFAFAFA),
        child: Center(
          child: Icon(
            LucideIcons.fileText,
            size: 56,
            color: Colors.red.shade300,
          ),
        ),
      );
    }
    if (_bytes == null) {
      return Container(
        color: Color(0xFFFAFAFA),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Container(
      color: Colors.white,
      alignment: Alignment.topCenter,
      child: Image.memory(
        _bytes!,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => Container(
          color: Color(0xFFFAFAFA),
          child: Center(
            child: Icon(
              LucideIcons.fileText,
              size: 56,
              color: Colors.red.shade300,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PDF thumbnail à partir de bytes en mémoire (web ou natif). Pareil que
// `_PdfThumbnail` mais accepte un fournisseur asynchrone de bytes plutôt
// qu'un chemin filesystem — typiquement utilisé sur web où on récupère le
// PDF via `webCachedFetch` (cache SQLite persistant) ou via le data URL
// déjà décodé en mémoire (upload en cours).
//
// Le rendu PNG de la page 1 est mémoïsé par `docId` dans une map statique
// → après le 1er rendu pour un doc, toutes les cards qui référencent ce
// doc s'affichent en O(1). Le cache est purgé seulement à reload de
// l'app (durée de vie process).
// ---------------------------------------------------------------------------

class _PdfThumbnailFromBytes extends StatefulWidget {
  /// Identifiant stable du document — clé du cache mémoire des PNG
  /// rendus. Doit être unique par PDF.
  final String docId;

  /// Fournisseur asynchrone des bytes PDF. Appelé uniquement si le
  /// PNG n'est pas déjà en cache pour [docId].
  final Future<Uint8List?> Function() bytesProvider;

  /// Widget affiché quand on n'a pas pu produire de preview (bytes
  /// manquants OU pdfx en échec). Habituellement l'icône PDF rouge.
  final Widget fallback;

  const _PdfThumbnailFromBytes({
    required this.docId,
    required this.bytesProvider,
    required this.fallback,
  });

  @override
  State<_PdfThumbnailFromBytes> createState() =>
      _PdfThumbnailFromBytesState();
}

class _PdfThumbnailFromBytesState extends State<_PdfThumbnailFromBytes> {
  /// Cache mémoire partagé entre toutes les instances : 1 PNG rendu
  /// par docId. Évite de re-décoder le PDF à chaque rebuild de la
  /// grille (scroll, sélection multiple, refresh polling, …).
  static final Map<String, Uint8List> _previewCache = {};

  /// Inflight Future par docId — si plusieurs cards demandent le
  /// preview du même doc en même temps (scroll rapide, polling),
  /// elles partagent une seule décod/render au lieu de décoder en
  /// parallèle.
  static final Map<String, Future<Uint8List?>> _inflight = {};

  Uint8List? _png;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PdfThumbnailFromBytes old) {
    super.didUpdateWidget(old);
    if (old.docId != widget.docId) {
      _png = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    // 1. Cache mémoire — instantané.
    final cached = _previewCache[widget.docId];
    if (cached != null) {
      if (!mounted) return;
      setState(() => _png = cached);
      return;
    }

    // 2. Inflight ? on attend l'autre instance.
    final pending = _inflight[widget.docId];
    if (pending != null) {
      try {
        final png = await pending;
        if (!mounted) return;
        if (png != null) {
          setState(() => _png = png);
        } else {
          setState(() => _failed = true);
        }
      } catch (_) {
        if (mounted) setState(() => _failed = true);
      }
      return;
    }

    // 3. On lance le rendu — un seul Future en vol pour ce docId.
    final renderFuture = _renderPreview();
    _inflight[widget.docId] = renderFuture;
    try {
      final png = await renderFuture;
      if (!mounted) return;
      if (png != null) {
        _previewCache[widget.docId] = png;
        setState(() => _png = png);
      } else {
        setState(() => _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _inflight.remove(widget.docId);
    }
  }

  /// Récupère les bytes du PDF (via `bytesProvider`), ouvre le doc
  /// avec pdfx, rend la page 1 en PNG. Renvoie null si étape échoue.
  Future<Uint8List?> _renderPreview() async {
    final bytes = await widget.bytesProvider();
    if (bytes == null || bytes.isEmpty) return null;
    PdfDocument? doc;
    PdfPage? page;
    try {
      doc = await PdfDocument.openData(bytes);
      page = await doc.getPage(1);
      final rendered = await page.render(
        // Facteur de scale 1.5x → preview lisible mais pas obèse
        // (la card fait ~200×260 px sur grille typique iPad).
        width: page.width * 1.5,
        height: page.height * 1.5,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      return rendered?.bytes;
    } catch (_) {
      return null;
    } finally {
      try {
        await page?.close();
      } catch (_) {}
      try {
        await doc?.close();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    if (_png == null) {
      // Loading state : on affiche le fallback (icône PDF) plutôt
      // qu'un spinner agressif. Au scroll, l'apparence reste stable
      // jusqu'à ce que la preview arrive (généralement < 200 ms).
      return widget.fallback;
    }
    return Container(
      color: Colors.white,
      alignment: Alignment.topCenter,
      child: Image.memory(
        _png!,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.fallback,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Remote image with MediaCacheService : télécharge (auth-free public URL) et
// met en cache sur disque. Affiche un loader pendant le fetch initial, puis
// l'image depuis le cache à chaque rebuild suivant (offline-first).
// ---------------------------------------------------------------------------

class _RemoteImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final Widget fallback;

  const _RemoteImage({
    required this.url,
    required this.fallback,
    this.fit = BoxFit.cover,
  });

  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<_RemoteImage> {
  File? _file;
  Uint8List? _bytes;
  bool _failed = false;

  // Cache en mémoire pour éviter de refetch à chaque rebuild de card.
  static final Map<String, Uint8List> _memCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RemoteImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _file = null;
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    // 1. Cache mémoire → instantané.
    final cached = _memCache[widget.url];
    if (cached != null) {
      if (!mounted) return;
      setState(() => _bytes = cached);
      return;
    }

    // 2. Web : cache SQLite (persistant + offline). Passe le header
    //    `X-App-Session` en cas de miss réseau pour les URLs privées.
    if (kIsWeb) {
      final bytes = await MediaCacheService().webCachedFetch(
        widget.url,
        headers: {'X-App-Session': AppConfig.appSessionToken},
      );
      if (!mounted) return;
      if (bytes != null) {
        _memCache[widget.url] = bytes;
        setState(() => _bytes = bytes);
        return;
      }
      setState(() => _failed = true);
      return;
    }

    // 3. Native : MediaCacheService (cache filesystem). On lui passe
    //    directement le header `X-App-Session` pour les URLs privées
    //    (`/api/mobile-documents/<id>/content`) — sinon le 1er download
    //    renvoie 401 et on perd un round-trip avant de retomber sur le
    //    fallback authentifié ci-dessous.
    final file = await MediaCacheService().fetch(
      widget.url,
      headers: MediaCacheService.authHeaders(),
    );
    if (!mounted) return;
    if (file != null) {
      setState(() => _file = file);
      return;
    }

    // 4. Fallback final : si même la fetch authentifiée a échoué (URL
    //    inaccessible, déconnexion, etc.), on tente un dernier http.get
    //    pour disposer des bytes en mémoire le temps de la session — le
    //    but est de servir l'image quand le filesystem ne peut pas être
    //    écrit (ex: quota plein) plutôt que d'afficher l'icône d'erreur.
    try {
      final uri = _buildAuthedUri(widget.url);
      if (uri == null) throw Exception('bad url');
      final resp = await http.get(
        uri,
        headers: {'X-App-Session': AppConfig.appSessionToken},
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          resp.bodyBytes.isNotEmpty) {
        _memCache[widget.url] = resp.bodyBytes;
        if (!mounted) return;
        setState(() => _bytes = resp.bodyBytes);
        return;
      }
      // ignore: avoid_print
      print('[docs img] HTTP ${resp.statusCode} for ${widget.url}');
    } catch (e) {
      // ignore: avoid_print
      print('[docs img] fetch failed for ${widget.url}: $e');
    }
    if (!mounted) return;
    setState(() => _failed = true);
  }

  /// Construit l'URI absolue pour les URLs relatives (préfixe apiBaseUrl).
  static Uri? _buildAuthedUri(String raw) {
    if (raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Uri.tryParse(raw);
    }
    final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
    final path = raw.startsWith('/') ? raw : '/$raw';
    return Uri.tryParse('$base$path');
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    if (_file != null) {
      return Image.file(
        _file!,
        fit: widget.fit,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    if (_bytes != null) {
      return Image.memory(
        _bytes!,
        fit: widget.fit,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    return Container(
      color: Color(0xFFF2F4F6),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Compact toolbar button — hauteur fixe ~24 px pour rentrer dans la ligne du
// titre sans agrandir le header.
// ---------------------------------------------------------------------------

class _CompactToolbarButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final Color color;
  final Color background;
  final bool isLoading;

  const _CompactToolbarButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.color,
    required this.background,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: disabled ? 0.4 : 1,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else
                Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sync badge + small icon button
// ---------------------------------------------------------------------------

class _SyncBadge extends StatelessWidget {
  final SyncState syncState;
  const _SyncBadge({required this.syncState});

  @override
  Widget build(BuildContext context) {
    final color = _syncColor(syncState);
    // Refonte 2026-05-13 : on garde uniquement la petite pastille
    // colorée (suppression du label texte). Tooltip ajouté pour ne pas
    // perdre l'info d'état au survol.
    return Tooltip(
      message: syncState.label,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  final String searchTerm;

  const _EmptyState({required this.searchTerm});

  @override
  Widget build(BuildContext context) {
    final hasFilter = searchTerm.trim().isNotEmpty;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasFilter ? LucideIcons.search : LucideIcons.folderOpen,
            size: 64,
            color: Color(0xFF8A939D),
          ),
          const SizedBox(height: 16),
          Text(
            hasFilter
                ? 'Aucun document ne correspond aux filtres.'
                : 'Aucun document pour ce dossier.',
            style: TextStyle(color: Color(0xFF2B323A), fontSize: 14),
          ),
          if (!hasFilter) ...[
            const SizedBox(height: 8),
            Text(
              'Utilisez les boutons ci-dessus pour ajouter un document.',
              style: TextStyle(color: Color(0xFF5C6670), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Upload / edit modal
// ---------------------------------------------------------------------------

class _UploadResult {
  final String title;
  final String tag;
  _UploadResult(this.title, this.tag);
}

class _UploadModal extends StatefulWidget {
  final String defaultTitle;
  final String defaultTag;

  const _UploadModal({
    required this.defaultTitle,
    required this.defaultTag,
  });

  @override
  State<_UploadModal> createState() => _UploadModalState();
}

class _UploadModalState extends State<_UploadModal> {
  late final TextEditingController _titleCtrl;
  late String _tag;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.defaultTitle);
    _tag = _kAvailableTags.contains(widget.defaultTag)
        ? widget.defaultTag
        : 'Autre';
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enregistrer le document'),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Titre',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _kDarkPurple,
                )),
            const SizedBox(height: 8),
            TextField(
              controller: _titleCtrl,
              decoration: InputDecoration(
                hintText: 'Titre du document',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
            const SizedBox(height: 20),
            const Text('Catégorie',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _kDarkPurple,
                )),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _kAvailableTags.map((tag) {
                final active = _tag == tag;
                return GestureDetector(
                  onTap: () => setState(() => _tag = tag),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: active ? _kPurple : Colors.white,
                      borderRadius: BorderRadius.circular(50),
                    ),
                    child: Text(
                      tag,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: active ? Colors.white : _kDarkPurple,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _kPurple),
          onPressed: () {
            final title = _titleCtrl.text.trim();
            if (title.isEmpty) return;
            Navigator.pop(context, _UploadResult(title, _tag));
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Quick-Look style preview dialog :
//   * Pop-up centré (pas plein écran), coins arrondis, fond semi-transparent
//   * Titre éditable + indicateur "• Modifié" + bouton Save
//   * Preview image / PDF
//   * Annotation au stylet sur les images (pen + eraser, 3 couleurs)
//   * L'annotation est persistée en JSON à côté de l'image (.annotation.json)
//   * Le téléchargement aplatit l'annotation sur l'image (flat PNG)
// ---------------------------------------------------------------------------

class _PreviewScreen extends StatefulWidget {
  final DocItem doc;
  final VoidCallback onDelete;
  final Future<void> Function(String newTitle) onSave;
  final VoidCallback onDownload;

  const _PreviewScreen({
    required this.doc,
    required this.onDelete,
    required this.onSave,
    required this.onDownload,
  });

  @override
  State<_PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<_PreviewScreen> {
  late TextEditingController _titleCtrl;
  late FocusNode _titleFocus;
  bool _saving = false;
  PdfControllerPinch? _pdfController;
  final GlobalKey<_ImageAnnotatorState> _annotatorKey =
      GlobalKey<_ImageAnnotatorState>();
  // Clé du wrapper PDF — permet d'appeler `saveAll()` pour flusher toutes les
  // pages annotées en une fois (mode PDF multi-pages).
  final GlobalKey<_PdfAnnotatorWrapperState> _pdfWrapperKey =
      GlobalKey<_PdfAnnotatorWrapperState>();
  // Clé du wrapper PDF web — symétrique de `_pdfWrapperKey` pour le
  // path PWA. Permet à `_handleSave` d'appeler `saveAll(documentId)`
  // qui persiste l'aplat de chaque page modifiée dans
  // `documents.annotations_json` (sans toucher au PDF original).
  final GlobalKey<_WebPdfAnnotatorWrapperState> _webPdfWrapperKey =
      GlobalKey<_WebPdfAnnotatorWrapperState>();

  // Dernier titre effectivement sauvegardé (initialisé à celui passé en prop).
  // Nécessaire car `widget.doc` est immutable : après `onSave()`, le parent
  // rafraîchit sa liste en DB mais la preview garde la même référence. Sans
  // cet état local, le badge "Modifié" et le prompt unsaved-changes
  // persisteraient même après une sauvegarde réussie.
  late String _savedTitle;

  bool get _hasUnsavedTitle =>
      _titleCtrl.text.trim() != _savedTitle &&
      _titleCtrl.text.trim().isNotEmpty;

  bool get _hasUnsavedAnnotation {
    final pdfWrapper = _pdfWrapperKey.currentState;
    if (pdfWrapper != null) {
      // Mode PDF natif : le wrapper agrège le dirty-state de toutes
      // les pages (mémoire + live annotator de la page courante).
      return pdfWrapper.hasUnsavedChanges;
    }
    final webPdf = _webPdfWrapperKey.currentState;
    if (webPdf != null) {
      // Mode PDF web : pareil que natif, agrégat per-page côté PWA.
      return webPdf.hasUnsavedChanges;
    }
    return _annotatorKey.currentState?.hasUnsavedChanges ?? false;
  }

  bool get _hasAnyUnsaved => _hasUnsavedTitle || _hasUnsavedAnnotation;

  @override
  void initState() {
    super.initState();
    _savedTitle = widget.doc.title;
    _titleCtrl = TextEditingController(text: widget.doc.title);
    _titleFocus = FocusNode();
    _titleCtrl.addListener(() => setState(() {}));
    _initPdfIfNeeded();
  }

  void _initPdfIfNeeded() {
    if (widget.doc.type == 'pdf' &&
        widget.doc.localPath != null &&
        widget.doc.localPath!.isNotEmpty &&
        File(widget.doc.localPath!).existsSync()) {
      _pdfController = PdfControllerPinch(
        document: PdfDocument.openFile(widget.doc.localPath!),
      );
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _titleFocus.dispose();
    _pdfController?.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (!_hasAnyUnsaved || _saving) return;
    setState(() => _saving = true);
    try {
      if (_hasUnsavedTitle) {
        final newTitle = _titleCtrl.text.trim();
        await widget.onSave(newTitle);
        // Synchronise la baseline locale — sinon le badge "Modifié" et le
        // prompt unsaved-changes restent actifs après un save réussi.
        _savedTitle = newTitle;
      }
      if (_hasUnsavedAnnotation) {
        final pdfWrapper = _pdfWrapperKey.currentState;
        final webPdfWrapper = _webPdfWrapperKey.currentState;
        if (pdfWrapper != null) {
          // Mode PDF NATIF : flush toutes les pages modifiées sur
          // disque (JSON par page), puis re-upload de la page
          // courante en PNG aplati pour que NocoDB en ait une version
          // annotée visible.
          await pdfWrapper.saveAll();
          await _reuploadFlattenedCurrentPage();
        } else if (webPdfWrapper != null) {
          // Mode PDF WEB : aplatit chaque page modifiée et la stocke
          // dans `documents.annotations_json` (Map<page, dataUrl>) —
          // sans toucher au PDF original. Préserve la navigation
          // multi-pages après save (demande utilisateur 2026-04-28 :
          // "il doit toujours être possible de naviguer sur les pages
          // du pdf même s'il y a un écrit dessus").
          await webPdfWrapper.saveAll(documentId: widget.doc.id);
        } else {
          // Image simple (jpg/png) : aplat unique sans notion de page.
          await _annotatorKey.currentState?.saveAnnotation();
          await _reuploadFlattenedImage();
        }
      }
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Produit un PNG aplati (image originale + strokes) et l'enqueue comme
  /// re-upload pour NocoDB. Sans cela les annotations restaient côté client
  /// uniquement — la version serveur affichait le fichier original pristine.
  Future<void> _reuploadFlattenedImage() async {
    final annotator = _annotatorKey.currentState;
    if (annotator == null) return;
    try {
      final bytes = await annotator.exportFlatPng();
      if (bytes == null) return;
      // Web : pas de filesystem → on enqueue directement les bytes via
      // la variante `enqueueAnnotatedReuploadBytes` qui les encode en
      // data URL côté SQLite et dans le payload de sync.
      if (kIsWeb) {
        await DocumentRepository().enqueueAnnotatedReuploadBytes(
          documentId: widget.doc.id,
          bytes: bytes,
        );
        return;
      }
      // Native : on écrit un fichier `.flat.png` à côté de l'original
      // puis on enqueue par chemin disque (parité avec l'historique).
      final localPath = widget.doc.localPath;
      if (localPath == null || localPath.isEmpty) return;
      final flatPath = '$localPath.flat.png';
      await File(flatPath).writeAsBytes(bytes, flush: true);
      await DocumentRepository().enqueueAnnotatedReupload(
        documentId: widget.doc.id,
        flattenedPath: flatPath,
      );
    } catch (_) {
      // Pas bloquant : l'annotation JSON est sauvée localement, le
      // re-upload pourra être retenté au prochain Save.
    }
  }

  /// Variante PDF : aplatit la page courante affichée et l'enqueue comme
  /// re-upload. Limitation actuelle : on ne ré-écrit qu'un PNG de la page
  /// courante côté serveur. Un flatten multi-pages en PDF nécessite une
  /// lib d'écriture PDF — à faire dans un ticket dédié.
  Future<void> _reuploadFlattenedCurrentPage() async {
    final annotator = _annotatorKey.currentState;
    if (annotator == null) return;
    try {
      final bytes = await annotator.exportFlatPng();
      if (bytes == null) return;
      final localPath = widget.doc.localPath;
      if (localPath == null || localPath.isEmpty) return;
      final flatPath = '$localPath.flat.png';
      await File(flatPath).writeAsBytes(bytes, flush: true);
      await DocumentRepository().enqueueAnnotatedReupload(
        documentId: widget.doc.id,
        flattenedPath: flatPath,
      );
    } catch (_) {}
  }

  Future<void> _handleClose() async {
    if (!_hasAnyUnsaved) {
      Navigator.pop(context);
      return;
    }
    // Confirmation custom : X en haut-droite (annule la sortie),
    // « Ignorer les modifications » (ferme sans sauver), « Enregistrer »
    // (sauve puis ferme). barrierDismissible:false sur ce dialog aussi
    // pour forcer un choix explicite.
    final choice = await showSoftDialog<_UnsavedChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Modifications non enregistrées',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    // X en haut-droite : annule la sortie de l'édition,
                    // l'utilisateur reste sur le doc avec ses annotations
                    // intactes.
                    IconButton(
                      tooltip: 'Annuler',
                      icon: const Icon(LucideIcons.x, size: 20),
                      onPressed: () =>
                          Navigator.pop(ctx, _UnsavedChoice.cancel),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Vous avez des annotations en cours. Que souhaitez-vous faire ?',
                  style: TextStyle(fontSize: 14, color: Color(0xFF5C6670)),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(ctx, _UnsavedChoice.discard),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFB91C1C),
                      ),
                      child: const Text('Ignorer les modifications'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () =>
                          Navigator.pop(ctx, _UnsavedChoice.save),
                      icon: const Icon(LucideIcons.save, size: 16),
                      label: const Text('Enregistrer'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _kPurple,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || choice == null || choice == _UnsavedChoice.cancel) return;
    if (choice == _UnsavedChoice.save) {
      await _handleSave();
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _handleDownloadWithAnnotation() async {
    // For images with annotations : flatten the drawing on the image and let
    // the user save the merged PNG. For other types, delegate to the normal
    // download path.
    final annotator = _annotatorKey.currentState;
    if (widget.doc.type == 'image' && annotator != null) {
      final bytes = await annotator.exportFlatPng();
      if (bytes == null || !mounted) {
        widget.onDownload();
        return;
      }
      final baseName = widget.doc.title.isNotEmpty
          ? widget.doc.title
          : widget.doc.name.split('.').first;
      final suggested = '$baseName-annoté.png';
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Enregistrer le document annoté',
        fileName: suggested,
        bytes: bytes,
      );
      if (!mounted) return;
      if (saved == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Enregistré dans : $saved')),
      );
      return;
    }
    widget.onDownload();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    // Quick-Look sizing : on prend 80% de l'écran, plafonné pour desktop.
    final maxWidth = (screenSize.width * 0.82).clamp(600.0, 1200.0);
    final maxHeight = (screenSize.height * 0.85).clamp(420.0, 900.0);

    return PopScope(
      canPop: !_hasAnyUnsaved,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleClose();
      },
      // Tap sur le fond sombre (en dehors de la card) → on route vers
      // `_handleClose` qui se charge de la logique :
      //   • Aucune modif non sauvée → ferme directement
      //   • Modifs en cours → dialog de confirmation (X / Ignorer / Save)
      // Avant : `barrierDismissible: false` bloquait la fermeture sur
      // clic extérieur, donc même APRÈS un Save l'utilisateur devait
      // cliquer le X. Maintenant, un click extérieur post-save ferme
      // immédiatement (pas de prompt, le travail est sauvé).
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleClose,
        child: Center(
          child: GestureDetector(
            // Absorbe le tap sur le body pour qu'il ne remonte pas au
            // GestureDetector du fond (sinon dessiner = fermer la modale).
            onTap: () {},
            child: Material(
              color: Colors.transparent,
              child: Container(
              width: maxWidth,
              height: maxHeight,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 40,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Column(
                  children: [
                    _buildToolbar(),
                    Expanded(child: _buildPreviewBody()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B31),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: TextField(
                    controller: _titleCtrl,
                    focusNode: _titleFocus,
                    maxLines: 1,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    cursorColor: _kPurple,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 6),
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _handleSave(),
                  ),
                ),
                if (_hasAnyUnsaved) ...[
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade900.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(50),
                    ),
                    child: Text(
                      '• Modifié',
                      style: TextStyle(
                        color: Colors.amber.shade200,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _TopbarButton(
            icon: LucideIcons.download,
            tooltip: 'Télécharger',
            onPressed: _handleDownloadWithAnnotation,
          ),
          const SizedBox(width: 4),
          _SaveButton(
            enabled: _hasAnyUnsaved && !_saving,
            saving: _saving,
            onPressed: _handleSave,
          ),
          const SizedBox(width: 4),
          _TopbarButton(
            icon: LucideIcons.trash2,
            tooltip: 'Supprimer',
            color: Colors.red.shade300,
            onPressed: widget.onDelete,
          ),
          const SizedBox(width: 4),
          _TopbarButton(
            icon: LucideIcons.x,
            tooltip: 'Fermer',
            onPressed: _handleClose,
          ),
        ],
      ),
    );
  }

  /// Détection tolérante du type de fichier : on regarde doc.type MAIS
  /// AUSSI l'extension du nom/URL/path — le type en DB peut être 'doc' pour
  /// une vraie image si l'extension n'a pas été reconnue à l'import.
  bool _looksLikeImage() {
    final doc = widget.doc;
    if (doc.type == 'image') return true;
    final candidates = [
      doc.name,
      doc.localPath ?? '',
      doc.url ?? '',
    ].map((s) => s.toLowerCase()).toList();
    return candidates.any((s) =>
        s.endsWith('.png') ||
        s.endsWith('.jpg') ||
        s.endsWith('.jpeg') ||
        s.endsWith('.webp') ||
        s.endsWith('.gif') ||
        s.endsWith('.heic') ||
        s.endsWith('.bmp'));
  }

  bool _looksLikePdf() {
    final doc = widget.doc;
    if (doc.type == 'pdf') return true;
    final candidates = [doc.name, doc.localPath ?? '', doc.url ?? '']
        .map((s) => s.toLowerCase());
    return candidates.any((s) => s.endsWith('.pdf'));
  }

  Widget _buildPreviewBody() {
    final doc = widget.doc;
    final isImage = _looksLikeImage();
    final isPdf = _looksLikePdf();

    // Image locale (natif) → annotation directe sur le fichier disque.
    if (!kIsWeb &&
        isImage &&
        doc.localPath != null &&
        doc.localPath!.isNotEmpty &&
        File(doc.localPath!).existsSync()) {
      return _ImageAnnotator(
        key: _annotatorKey,
        imagePath: doc.localPath!,
        onChanged: () => setState(() {}),
      );
    }
    // Image avec dataUrl local (web, doc importé offline pas encore poussé)
    // → annotation directe sur les bytes décodés.
    if (kIsWeb && isImage && doc.dataUrl != null && doc.dataUrl!.isNotEmpty) {
      final dataUrl = doc.dataUrl!;
      final comma = dataUrl.indexOf(',');
      if (comma > 0) {
        try {
          final bytes = base64Decode(dataUrl.substring(comma + 1));
          return _ImageAnnotator(
            key: _annotatorKey,
            imageBytes: bytes,
            onChanged: () => setState(() {}),
          );
        } catch (_) {
          // dataUrl mal formé → on tombe sur l'URL distante.
        }
      }
    }
    // Image distante → on télécharge via MediaCacheService (fichier sur
    // natif, bytes sur web), puis on active l'annotation dessus.
    if (isImage && doc.url != null && doc.url!.isNotEmpty) {
      return _RemoteImageAnnotatorWrapper(
        url: doc.url!,
        annotatorKey: _annotatorKey,
        onChanged: () => setState(() {}),
        fallback: _remoteOrIcon(),
      );
    }
    if (isImage) {
      return _remoteOrIcon();
    }

    // PDF local → on rend chaque page en PNG via pdfx et on permet
    // l'annotation au stylet sur chaque page (navigation précédent / suivant).
    // Native uniquement : `_PdfAnnotatorWrapper` repose sur `File` IO pour
    // persister les PNGs annotés.
    if (!kIsWeb &&
        isPdf &&
        doc.localPath != null &&
        doc.localPath!.isNotEmpty &&
        File(doc.localPath!).existsSync()) {
      return _PdfAnnotatorWrapper(
        pdfPath: doc.localPath!,
        annotatorKey: _annotatorKey,
        wrapperKey: _pdfWrapperKey,
        onChanged: () => setState(() {}),
      );
    }

    // PDF distant sur web → on télécharge les bytes (cache SQLite +
    // auth-aware), on rend la page courante en PNG via `pdfx
    // .openData` puis on l'enveloppe dans `_ImageAnnotator` (mode
    // bytes) pour permettre le dessin au stylet. Le re-upload du
    // résultat flattened passe par `enqueueAnnotatedReuploadBytes`.
    if (kIsWeb && isPdf) {
      return _WebPdfAnnotatorWrapper(
        doc: doc,
        annotatorKey: _annotatorKey,
        wrapperKey: _webPdfWrapperKey,
        onChanged: () => setState(() {}),
      );
    }

    return _unsupportedPanel();
  }

  Widget _unsupportedPanel() {
    final doc = widget.doc;
    return Builder(builder: (ctx) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Container(
            padding: const EdgeInsets.all(32),
            margin: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Color(0xFF0E1116),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  doc.type == 'pdf' ? LucideIcons.fileText : LucideIcons.file,
                  size: 96,
                  color: doc.type == 'pdf'
                      ? Colors.red.shade300
                      : Color(0xFF8A939D),
                ),
                const SizedBox(height: 16),
                Text(
                  doc.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Prévisualisation non disponible pour ce format.',
                  style: TextStyle(color: Color(0xFF8A939D), fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (doc.localPath != null && doc.localPath!.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final result = await OpenFilex.open(doc.localPath!);
                        if (result.type != ResultType.done && ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Ouverture impossible : ${result.message}',
                              ),
                            ),
                          );
                        }
                      },
                      icon: const Icon(LucideIcons.externalLink, size: 16),
                      label: const Text('Ouvrir dans une autre app'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _kPurple,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _remoteOrIcon() {
    final doc = widget.doc;
    if (doc.url != null && doc.url!.isNotEmpty) {
      return InteractiveViewer(
        child: Center(
          child: _RemoteImage(
            url: doc.url!,
            fit: BoxFit.contain,
            fallback: const Center(
              child: Icon(LucideIcons.imageOff,
                  size: 96, color: Colors.white54),
            ),
          ),
        ),
      );
    }
    return const Center(
      child: Icon(LucideIcons.imageOff, size: 96, color: Colors.white54),
    );
  }
}

enum _UnsavedChoice { cancel, discard, save }

class _SaveButton extends StatelessWidget {
  final bool enabled;
  final bool saving;
  final VoidCallback onPressed;

  const _SaveButton({
    required this.enabled,
    required this.saving,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Enregistrer',
      child: Material(
        color: enabled ? _kPurple : Colors.white.withValues(alpha: 0.1),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      LucideIcons.save,
                      size: 18,
                      color: enabled
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.3),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color? color;
  final VoidCallback onPressed;

  const _TopbarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: color ?? Colors.white),
      tooltip: tooltip,
    );
  }
}

// ---------------------------------------------------------------------------
// Image annotator : image + overlay de traits au stylet.
// - Persistance : annotation JSON stockée dans `{localPath}.annotation.json`
// - Export : aplati l'annotation sur l'image et renvoie les bytes PNG
// - Toolbar : pen (3 couleurs), eraser, undo, clear
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Web PDF viewer + annotator (mode bytes)
// ---------------------------------------------------------------------------

/// Visualise + annote un PDF côté **web**. Chargement des bytes via
/// `MediaCacheService.webCachedFetch` (cache SQLite + auth
/// `X-App-Session`), rendu de chaque page en PNG via `pdfx` (PdfDocument
/// .openData), puis enveloppe la page courante dans un `_ImageAnnotator`
/// (mode bytes) pour permettre le dessin au stylet.
///
/// Le re-upload du résultat flattened (page courante annotée) passe par
/// `DocumentRepository.enqueueAnnotatedReuploadBytes` — déclenché depuis
/// le bouton Save du `_PreviewScreen` via `exportFlatPng()`.
///
/// Sauvegarde par page : à chaque appel de `saveAll(documentId:)`, on
/// aplatit chaque page modifiée (PDF page + traits) en PNG et on
/// l'écrit dans `documents.annotations_json` (Map<page, dataUrl>) via
/// `DocumentRepository.enqueueAnnotatedPageBytes`. Le PDF original
/// reste intact — la preview affiche l'overlay PNG sur les pages qui
/// ont une entrée dans la map, sinon rendu PDF brut. Conséquence :
/// la navigation multi-pages reste fonctionnelle après save, et les
/// annotations restent localisées à la page où elles ont été dessinées.
class _WebPdfAnnotatorWrapper extends StatefulWidget {
  const _WebPdfAnnotatorWrapper({
    required this.doc,
    required this.annotatorKey,
    required this.onChanged,
    this.wrapperKey,
  }) : super(key: wrapperKey);

  final DocItem doc;
  final GlobalKey<_ImageAnnotatorState> annotatorKey;
  final VoidCallback onChanged;
  final GlobalKey<_WebPdfAnnotatorWrapperState>? wrapperKey;

  @override
  State<_WebPdfAnnotatorWrapper> createState() =>
      _WebPdfAnnotatorWrapperState();
}

class _WebPdfAnnotatorWrapperState extends State<_WebPdfAnnotatorWrapper> {
  PdfDocument? _doc;
  int _currentPage = 1;
  int _totalPages = 1;
  Uint8List? _currentImage;
  bool _loading = true;
  String? _error;

  /// Map en mémoire des annotations par page : clé = numéro de page
  /// (1-indexé), valeur = bytes PNG aplati. Hydraté au boot depuis
  /// `widget.doc.annotationsJson` puis mis à jour quand l'ergo
  /// change de page (capture des strokes courants en aplat). Persisté
  /// sur disque uniquement quand `saveAll(documentId:)` est appelé.
  final Map<int, Uint8List> _flatPagesByPage = {};

  /// Pages dont l'aplat a changé depuis le dernier save — flushées
  /// vers SQLite en bloc dans `saveAll`.
  final Set<int> _dirtyPages = {};

  /// True dès qu'une page a un dirty pending, OU si le live annotator
  /// a des strokes non encore capturés en aplat. Lu par le parent
  /// `_PreviewScreen` pour activer le bouton Save.
  bool get hasUnsavedChanges {
    if (_dirtyPages.isNotEmpty) return true;
    final live = widget.annotatorKey.currentState;
    return live?.hasUnsavedChanges ?? false;
  }

  @override
  void initState() {
    super.initState();
    _hydrateAnnotationsMap();
    _open();
  }

  /// Décode la map persistée dans `documents.annotations_json` pour
  /// repeupler [_flatPagesByPage] avec les bytes des pages déjà
  /// annotées (visibles dès le 1er affichage de la page).
  void _hydrateAnnotationsMap() {
    final raw = widget.doc.annotationsJson;
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        final page = int.tryParse(key.toString());
        final dataUrl = value?.toString() ?? '';
        if (page == null || page < 1) return;
        if (!dataUrl.startsWith('data:')) return;
        final comma = dataUrl.indexOf(',');
        if (comma <= 0) return;
        try {
          _flatPagesByPage[page] = base64Decode(dataUrl.substring(comma + 1));
        } catch (_) {}
      });
    } catch (_) {
      // JSON corrompu — on repart d'une map vide. L'ergo perdra ses
      // anciennes annotations mais c'était déjà cassé.
    }
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _doc?.close();
    super.dispose();
  }

  Future<void> _open() async {
    final url = widget.doc.url;
    final dataUrl = widget.doc.dataUrl;

    Uint8List? bytes;
    // 1. data URL local (upload offline non encore poussé)
    if (dataUrl != null && dataUrl.isNotEmpty) {
      final comma = dataUrl.indexOf(',');
      if (comma > 0) {
        try {
          bytes = base64Decode(dataUrl.substring(comma + 1));
        } catch (_) {}
      }
    }
    // 2. URL distante : on tente d'abord le cache (offline-friendly),
    //    PUIS si le cache renvoie des bytes invalides ou vides, on
    //    force un re-fetch réseau frais. Demande utilisateur 2026-05-05 :
    //    sur macOS web le PDF "Synchronisé" refusait de s'ouvrir parce
    //    qu'une entrée stale (HTML SPA fallback / bytes 0) traînait
    //    dans `web_media_cache` depuis les "Load failed" d'hier.

    /// Capture la dernière exception levée par `PdfDocument.openData` —
    /// utilisée pour enrichir le message d'erreur final si TOUS les
    /// fallbacks (data URL → cache → cache invalidé+refetch) échouent.
    /// Permet à l'ergo de signaler le diagnostic exact (token, 404,
    /// PDF tronqué, etc.) au lieu d'un « fichier introuvable » générique.
    Object? lastOpenError;
    int? lastBytesLength;
    bool lastBytesLookedLikePdf = false;

    Future<bool> tryOpenBytes(Uint8List? data) async {
      if (data == null || data.isEmpty) return false;
      lastBytesLength = data.length;
      // Validation magic-number PDF : un vrai PDF commence par "%PDF-".
      // Si ce n'est pas le cas (= bytes corrompus, HTML, etc.), on
      // skippe pour laisser place à un re-fetch.
      if (data.length < 5 ||
          data[0] != 0x25 ||
          data[1] != 0x50 ||
          data[2] != 0x44 ||
          data[3] != 0x46 ||
          data[4] != 0x2D) {
        lastBytesLookedLikePdf = false;
        return false;
      }
      lastBytesLookedLikePdf = true;
      try {
        final doc = await PdfDocument.openData(data);
        if (!mounted) {
          // ignore: discarded_futures
          doc.close();
          return true;
        }
        _doc = doc;
        _totalPages = doc.pagesCount;
        await _renderCurrent();
        return true;
      } catch (e) {
        lastOpenError = e;
        return false;
      }
    }

    if (await tryOpenBytes(bytes)) return;

    // Cache miss / data URL absente / bytes invalides → fetch via cache.
    if (url != null && url.isNotEmpty) {
      bytes = await MediaCacheService.instance.webCachedFetch(
        url,
        headers: MediaCacheService.authHeaders(),
      );
      if (await tryOpenBytes(bytes)) return;

      // Si même le cache renvoie quelque chose qui n'ouvre pas, on
      // invalide l'entrée stale et on retente un fetch réseau direct
      // (bypass cache). Ça récupère un dossier généré sur un autre
      // device dont la 1ère fetch sur cette machine avait échoué et
      // laissé du HTML/0 byte dans le cache local.
      await MediaCacheService.instance.invalidateUrl(url);
      bytes = await MediaCacheService.instance.webCachedFetch(
        url,
        headers: MediaCacheService.authHeaders(),
      );
      if (await tryOpenBytes(bytes)) return;
    }

    if (!mounted) return;
    // Message d'erreur diagnostic : on précise pourquoi ça a échoué.
    //   - Aucun byte récupéré → URL invalide / 401 / 404 silencieux
    //   - Bytes mais pas du PDF → SPA HTML / JSON erreur / fichier
    //     corrompu côté serveur (template generation crash ?)
    //   - Bytes PDF mais openData échoue → PDF tronqué / lib pdfx
    //     incompatible avec ce PDF particulier
    String message;
    if (lastBytesLength == null) {
      message = 'Lecture du PDF impossible — aucun fichier reçu '
          '(URL invalide, problème d\'authentification ou hors-ligne).';
    } else if (!lastBytesLookedLikePdf) {
      message = 'Lecture du PDF impossible — le serveur a renvoyé '
          '${lastBytesLength!} octets qui ne sont pas un PDF valide '
          '(fichier corrompu côté serveur ou réponse d\'erreur).';
    } else {
      final errStr = lastOpenError?.toString() ?? 'erreur inconnue';
      message = 'Lecture du PDF impossible — $errStr';
    }
    setState(() {
      _loading = false;
      _error = message;
    });
  }

  /// Rend la page courante. Si la page a une annotation déjà sauvée
  /// dans [_flatPagesByPage], on l'utilise directement (l'utilisateur
  /// retrouve ses traits) — sinon on rasterise le PDF brut.
  Future<void> _renderCurrent() async {
    final doc = _doc;
    if (doc == null) return;
    setState(() => _loading = true);

    // 1. Si la page courante a un aplat sauvegardé → on l'affiche
    //    directement. L'_ImageAnnotator partira d'un canvas vierge
    //    par-dessus (les strokes ont été baked dans l'aplat).
    final cachedFlat = _flatPagesByPage[_currentPage];
    if (cachedFlat != null) {
      if (!mounted) return;
      setState(() {
        _currentImage = cachedFlat;
        _loading = false;
      });
      return;
    }

    try {
      final page = await doc.getPage(_currentPage);
      // Render à 2x la taille naturelle pour un peu de netteté sur les
      // écrans Retina sans exploser la mémoire.
      final raster = await page.render(
        width: page.width * 2,
        height: page.height * 2,
        format: PdfPageImageFormat.png,
      );
      await page.close();
      if (!mounted) return;
      setState(() {
        _currentImage = raster?.bytes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Rendu page $_currentPage impossible : $e';
      });
    }
  }

  /// Capture les strokes courants en aplat PNG et les stocke en
  /// mémoire pour la page courante. Marque la page dirty si l'aplat
  /// a changé. Appelé avant chaque navigation et avant chaque save.
  Future<void> _captureCurrentPageFlat() async {
    final live = widget.annotatorKey.currentState;
    if (live == null) return;
    if (!live.hasUnsavedChanges) return;
    try {
      final flat = await live.exportFlatPng();
      if (flat == null) return;
      _flatPagesByPage[_currentPage] = flat;
      _dirtyPages.add(_currentPage);
    } catch (_) {
      // Silent — l'ergo réessayera au save.
    }
  }

  /// Persiste tous les aplats de pages modifiées dans
  /// `documents.annotations_json` via `enqueueAnnotatedPageBytes`. Ne
  /// touche PAS au PDF original (qui reste navigable). Appelé par
  /// `_PreviewScreen._handleSave`.
  Future<void> saveAll({required String documentId}) async {
    // 1. Capture la page courante depuis l'annotator live.
    await _captureCurrentPageFlat();
    // 2. Persiste chaque page dirty.
    for (final page in _dirtyPages.toList()) {
      final bytes = _flatPagesByPage[page];
      if (bytes == null) continue;
      try {
        await DocumentRepository().enqueueAnnotatedPageBytes(
          documentId: documentId,
          pageNumber: page,
          bytes: bytes,
        );
      } catch (_) {
        // Silent — au prochain save l'ergo retentera.
      }
    }
    _dirtyPages.clear();
    // Reset le hash du live annotator pour faire disparaître le
    // badge "Modifié" même si on reste sur la même page.
    widget.annotatorKey.currentState?.saveAnnotation();
    if (mounted) {
      setState(() {});
      widget.onChanged();
    }
  }

  Future<void> _goPrev() async {
    if (_currentPage <= 1) return;
    await _captureCurrentPageFlat();
    setState(() => _currentPage -= 1);
    await _renderCurrent();
  }

  Future<void> _goNext() async {
    if (_currentPage >= _totalPages) return;
    await _captureCurrentPageFlat();
    setState(() => _currentPage += 1);
    await _renderCurrent();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_loading && _currentImage == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: _currentImage == null
              ? const SizedBox.shrink()
              // L'_ImageAnnotator utilise la GlobalKey du parent pour
              // que `_PreviewScreen` puisse l'interroger
              // (`hasUnsavedChanges`, `exportFlatPng`, `saveAnnotation`).
              // On wrap la GlobalKey via une ValueKey extérieure indexée
              // sur `_currentPage` : à chaque changement de page,
              // Flutter détruit le sous-arbre et le recrée → les strokes
              // de la page précédente ne suivent PAS sur la nouvelle
              // page (demande utilisateur 2026-04-28 : "l'écrit doit
              // rester uniquement sur la page du PDF concerné, pas sur
              // toutes les pages"). Les strokes de la page précédente
              // ont été capturés en aplat dans `_captureCurrentPageFlat`
              // juste avant la navigation, donc rien n'est perdu : ils
              // sont incrustés dans `_currentImage` au render suivant.
              : KeyedSubtree(
                  key: ValueKey('webpdf-page-$_currentPage'),
                  child: _ImageAnnotator(
                    key: widget.annotatorKey,
                    imageBytes: _currentImage,
                    onChanged: widget.onChanged,
                  ),
                ),
        ),
        if (_totalPages > 1)
          Container(
            color: Colors.black.withValues(alpha: 0.6),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(LucideIcons.chevronLeft,
                      color: Colors.white),
                  onPressed: _currentPage > 1 ? _goPrev : null,
                  tooltip: 'Page précédente',
                ),
                const SizedBox(width: 12),
                Text(
                  '$_currentPage / $_totalPages',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(LucideIcons.chevronRight,
                      color: Colors.white),
                  onPressed: _currentPage < _totalPages ? _goNext : null,
                  tooltip: 'Page suivante',
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Wrapper qui télécharge une image distante via [MediaCacheService] puis
/// affiche un [_ImageAnnotator] sur le fichier local mis en cache. Permet
/// d'annoter des documents synchronisés depuis le serveur (pas de localPath).
/// Wrapper qui rend les pages d'un PDF en PNG (via pdfx) et les passe au
/// [_ImageAnnotator]. Permet d'annoter chaque page avec le stylet, exactement
/// comme une image. Navigation précédent/suivant entre les pages.
class _PdfAnnotatorWrapper extends StatefulWidget {
  final String pdfPath;
  final GlobalKey<_ImageAnnotatorState> annotatorKey;
  final VoidCallback onChanged;

  /// Clé pour permettre au parent d'appeler `saveAll()` — écrit toutes les
  /// pages modifiées sur disque en une fois.
  final GlobalKey<_PdfAnnotatorWrapperState>? wrapperKey;

  _PdfAnnotatorWrapper({
    required this.pdfPath,
    required this.annotatorKey,
    required this.onChanged,
    this.wrapperKey,
  }) : super(key: wrapperKey);

  @override
  State<_PdfAnnotatorWrapper> createState() => _PdfAnnotatorWrapperState();
}

class _PdfAnnotatorWrapperState extends State<_PdfAnnotatorWrapper> {
  PdfDocument? _doc;
  int _currentPage = 1;
  int _totalPages = 1;
  final Map<int, String> _pagePngPaths = {};
  bool _rendering = false;
  String? _error;

  // Snapshots en mémoire des annotations par page — préservés entre deux
  // changements de page. Non écrits sur disque tant que `saveAll()` n'est
  // pas appelé (via le bouton Save global).
  final Map<int, List<_AnnotStroke>> _memoryStrokesByPage = {};
  // Pages dont le contenu en mémoire diffère du disque — à flush au Save.
  final Set<int> _dirtyPages = {};

  /// True dès qu'au moins une page a été modifiée depuis le dernier save.
  bool get hasUnsavedChanges {
    if (_dirtyPages.isNotEmpty) return true;
    // La page actuellement affichée peut avoir des modifs que le wrapper
    // n'a pas encore "capturées" dans la map mémoire.
    final live = widget.annotatorKey.currentState;
    return live?.hasUnsavedChanges ?? false;
  }

  /// Sauvegarde toutes les pages modifiées sur disque (JSON annotation par
  /// page). Appelé par _PreviewScreen._handleSave.
  Future<void> saveAll() async {
    // 1. Capture la page courante depuis le live annotator.
    _captureCurrentPage();
    // 2. Persiste chaque page dirty sur disque.
    for (final page in _dirtyPages.toList()) {
      final pngPath = _pagePngPaths[page] ?? '${widget.pdfPath}.page$page.png';
      final jsonPath = '$pngPath.annotation.json';
      final strokes = _memoryStrokesByPage[page] ?? const [];
      try {
        final f = File(jsonPath);
        if (strokes.isEmpty) {
          if (await f.exists()) await f.delete();
        } else {
          final json =
              jsonEncode(strokes.map((s) => s.toJson()).toList());
          await f.writeAsString(json);
        }
      } catch (_) {
        // silent — l'utilisateur pourra retenter.
      }
    }
    _dirtyPages.clear();
    // Reset le hash de l'annotator courant pour que le badge "Modifié"
    // disparaisse aussi côté UI.
    widget.annotatorKey.currentState?.saveAnnotation();
    widget.onChanged();
  }

  /// Copie les strokes live du `_ImageAnnotator` courant dans la map mémoire.
  void _captureCurrentPage() {
    final live = widget.annotatorKey.currentState;
    if (live == null) return;
    final strokes = live.currentStrokes;
    final previous = _memoryStrokesByPage[_currentPage];
    _memoryStrokesByPage[_currentPage] = strokes;
    // Marque comme dirty si les strokes ont changé par rapport au précédent
    // snapshot mémoire, OU si le live annotator a des modifs non sauvées.
    if (previous == null || !_strokesEqual(previous, strokes)) {
      _dirtyPages.add(_currentPage);
    } else if (live.hasUnsavedChanges) {
      _dirtyPages.add(_currentPage);
    }
  }

  bool _strokesEqual(List<_AnnotStroke> a, List<_AnnotStroke> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].points.length != b[i].points.length) return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _openDoc();
  }

  @override
  void dispose() {
    _doc?.close();
    // Cleanup des PNGs temporaires créés par `_renderPage` (un par page
    // visitée) — sans ça, à chaque ouverture/fermeture du preview on
    // créait `<pdf>.page1.png`, `<pdf>.page2.png`, etc. qui restaient
    // sur disque indéfiniment. Sur iPad après 100 ouvertures, le dossier
    // offline_documents devenait énorme. Les fichiers `.annotation.json`
    // sont préservés (c'est la source de vérité des annotations).
    for (final path in _pagePngPaths.values.toList()) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // Best effort — un échec de cleanup ne doit pas faire crasher
        // la fermeture de l'aperçu.
      }
    }
    super.dispose();
  }

  Future<void> _openDoc() async {
    try {
      final doc = await PdfDocument.openFile(widget.pdfPath);
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _totalPages = doc.pagesCount;
      });
      await _renderPage(1);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Ouverture PDF impossible : $e');
    }
  }

  Future<void> _renderPage(int pageNumber) async {
    final doc = _doc;
    if (doc == null || pageNumber < 1 || pageNumber > _totalPages) return;
    // Avant de quitter la page courante, on capture ses strokes en mémoire
    // pour ne pas les perdre lors du rebuild.
    _captureCurrentPage();
    setState(() {
      _rendering = true;
      _currentPage = pageNumber;
    });
    try {
      // On ne rerend le PNG que si on ne l'a pas déjà fait pour cette page.
      var pngPath = _pagePngPaths[pageNumber];
      if (pngPath == null) {
        final page = await doc.getPage(pageNumber);
        final rendered = await page.render(
          width: page.width * 2,
          height: page.height * 2,
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        await page.close();
        if (rendered?.bytes == null || !mounted) {
          setState(() => _rendering = false);
          return;
        }
        pngPath = '${widget.pdfPath}.page$pageNumber.png';
        await File(pngPath).writeAsBytes(rendered!.bytes, flush: true);
        _pagePngPaths[pageNumber] = pngPath;
      }
      if (!mounted) return;
      setState(() {
        _rendering = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Rendu de la page impossible : $e';
        _rendering = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        color: Color(0xFF0E1116),
        alignment: Alignment.center,
        child: Text(
          _error!,
          style: const TextStyle(color: Colors.white),
        ),
      );
    }
    final pngPath = _pagePngPaths[_currentPage];
    if (pngPath == null) {
      return Container(
        color: Color(0xFF0E1116),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: Colors.white),
      );
    }
    // Strokes à injecter dans l'annotator : mémoire d'abord, sinon laisser
    // charger depuis disque si JSON existant.
    final seeded = _memoryStrokesByPage[_currentPage];
    return Stack(
      children: [
        Positioned.fill(
          child: _ImageAnnotator(
            // Recrée un annotator à chaque changement de page. La key
            // change pour forcer Flutter à détruire l'ancien state et
            // démarrer un nouveau, seeded depuis notre map mémoire si on
            // a déjà visité cette page.
            key: ValueKey('pdf-page-$_currentPage-${widget.annotatorKey}'),
            imagePath: pngPath,
            onChanged: widget.onChanged,
            initialStrokes: seeded,
            // Le save est piloté par le wrapper (`saveAll()`), pas par
            // chaque annotator individuel.
            autoPersistToDisk: false,
          ),
        ),
        // Navigation entre pages (seulement si > 1 page).
        if (_totalPages > 1)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: _currentPage > 1
                          ? () => _renderPage(_currentPage - 1)
                          : null,
                      icon: const Icon(LucideIcons.chevronLeft, size: 18),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Page précédente',
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        '$_currentPage / $_totalPages',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _currentPage < _totalPages
                          ? () => _renderPage(_currentPage + 1)
                          : null,
                      icon: const Icon(LucideIcons.chevronRight, size: 18),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Page suivante',
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_rendering)
          const Positioned(
            top: 12,
            right: 12,
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}

class _RemoteImageAnnotatorWrapper extends StatefulWidget {
  final String url;
  final GlobalKey<_ImageAnnotatorState> annotatorKey;
  final VoidCallback onChanged;
  final Widget fallback;

  const _RemoteImageAnnotatorWrapper({
    required this.url,
    required this.annotatorKey,
    required this.onChanged,
    required this.fallback,
  });

  @override
  State<_RemoteImageAnnotatorWrapper> createState() =>
      _RemoteImageAnnotatorWrapperState();
}

class _RemoteImageAnnotatorWrapperState
    extends State<_RemoteImageAnnotatorWrapper> {
  /// Mode natif : `File` issu du cache filesystem.
  File? _file;

  /// Mode web : bytes issus du cache SQLite (`webCachedFetch`).
  Uint8List? _bytes;

  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RemoteImageAnnotatorWrapper old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _file = null;
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  /// Vérifie qu'un buffer ressemble à une image COMPLÈTE (JPEG / PNG /
  /// GIF / WebP / BMP / HEIC). Détecte les entrées stales dans
  /// `web_media_cache` (HTML SPA fallback, 0 byte) ET les uploads
  /// tronqués (PNG sans bloc IEND, JPEG sans marqueur EOI 0xFFD9).
  ///
  /// Renforcé 2026-05-07 — bug rapporté : un PNG tronqué à exactement
  /// 1 MiB était stocké tel quel sur NocoDB, le serveur le re-servait
  /// au format complet (1 MiB), mais Safari iPad PWA refusait de
  /// rendre la moitié inférieure car bloc IEND manquant. La validation
  /// head-only laissait passer ces bytes corrompus dans le cache.
  bool _looksLikeImageBytes(Uint8List? bytes) {
    if (bytes == null || bytes.length < 8) return false;
    // JPEG: FF D8 FF en tête + FF D9 en queue
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      if (bytes.length < 4) return false;
      final last = bytes.length;
      return bytes[last - 2] == 0xFF && bytes[last - 1] == 0xD9;
    }
    // PNG: 89 50 4E 47 en tête + bloc IEND (12 bytes) en queue
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      if (bytes.length < 12) return false;
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
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return true;
    }
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
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    if (bytes.length >= 12 &&
        bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return true;
    }
    return false;
  }

  Future<void> _load() async {
    // Web : fetch bytes via le cache SQLite (`dart:io File` n'existe pas
    // dans le navigateur). Native : fetch File via le cache filesystem.
    // Dans les deux cas on passe l'auth `X-App-Session` pour que les URLs
    // privées `/api/mobile-documents/<id>/content` ne renvoient pas 401.
    if (kIsWeb) {
      var bytes = await MediaCacheService.instance.webCachedFetch(
        widget.url,
        headers: MediaCacheService.authHeaders(),
      );
      // Si le cache renvoie quelque chose qui n'est PAS une image (HTML
      // SPA fallback, 0 byte, JSON d'erreur), on invalide l'entrée stale
      // et on retente un fetch frais. Demande utilisateur 2026-05-04 :
      // les photos importées sur iPad apparaissaient mais ne pouvaient
      // pas être prévisualisées sur Mac à cause d'un cache pourri.
      if (bytes != null && !_looksLikeImageBytes(bytes)) {
        await MediaCacheService.instance.invalidateUrl(widget.url);
        bytes = await MediaCacheService.instance.webCachedFetch(
          widget.url,
          headers: MediaCacheService.authHeaders(),
        );
      }
      if (!mounted) return;
      setState(() {
        _bytes = _looksLikeImageBytes(bytes) ? bytes : null;
        _failed = _bytes == null;
      });
      return;
    }
    final file = await MediaCacheService().fetch(
      widget.url,
      headers: MediaCacheService.authHeaders(),
    );
    if (!mounted) return;
    setState(() {
      _file = file;
      _failed = file == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    if (_file == null && _bytes == null) {
      return Container(
        color: Color(0xFF0E1116),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: Colors.white),
      );
    }
    return _ImageAnnotator(
      key: widget.annotatorKey,
      imagePath: _file?.path,
      imageBytes: _bytes,
      onChanged: widget.onChanged,
    );
  }
}

class _ImageAnnotator extends StatefulWidget {
  /// Chemin disque de l'image — mode natif (`dart:io File`).
  final String? imagePath;

  /// Bytes de l'image — mode web (pas de filesystem accessible). Au moins
  /// l'un des deux doit être fourni, sinon le widget rend un placeholder.
  final Uint8List? imageBytes;

  final VoidCallback onChanged;

  /// Si fourni, ces strokes sont utilisés au démarrage au lieu de charger
  /// depuis le fichier `.annotation.json` sur disque. Utile quand un parent
  /// (ex: _PdfAnnotatorWrapper) garde les strokes en mémoire entre deux
  /// changements de page.
  final List<_AnnotStroke>? initialStrokes;

  /// Si false, [saveAnnotation] n'écrit pas sur disque — le parent s'en
  /// charge lui-même via sa propre logique (ex: flush multi-page au Save).
  /// Forcé `false` automatiquement quand `imagePath` est null (web mode).
  final bool autoPersistToDisk;

  const _ImageAnnotator({
    super.key,
    this.imagePath,
    this.imageBytes,
    required this.onChanged,
    this.initialStrokes,
    this.autoPersistToDisk = true,
  }) : assert(
          imagePath != null || imageBytes != null,
          '_ImageAnnotator: provide imagePath OR imageBytes',
        );

  @override
  State<_ImageAnnotator> createState() => _ImageAnnotatorState();
}

class _ImageAnnotatorState extends State<_ImageAnnotator> {
  // Strokes actuellement affichés.
  List<_AnnotStroke> _strokes = [];
  // Hash des strokes lors du dernier save → permet de détecter des modifs.
  int _savedHash = 0;
  // Clé du RepaintBoundary pour l'export PNG.
  final GlobalKey _boundaryKey = GlobalKey();

  // Outils courants. Crayon noir simple, comme les notes rapides (quick toolset).
  _AnnotTool _tool = _AnnotTool.pen;
  static const Color _color = Color(0xFF111827); // noir (dark gray)
  final double _strokeWidth = 2.0;

  /// Mode natif uniquement — sur web (`imagePath == null`) on ne persiste
  /// rien sur disque (les annotations vivent en mémoire jusqu'au Save qui
  /// flatten + ré-upload).
  String get _annotationPath => '${widget.imagePath}.annotation.json';

  /// True quand on tourne en mode "bytes only" (web). Dans ce mode :
  ///   • Pas de chargement depuis le disque (`_loadAnnotation` no-op)
  ///   • Pas d'écriture sur le disque (`saveAnnotation` met juste à jour
  ///     `_savedHash` pour faire disparaître le badge "Modifié")
  ///   • Le rendu image utilise `Image.memory(bytes)` au lieu de
  ///     `Image.file`
  bool get _webMode => widget.imagePath == null;

  bool get hasUnsavedChanges => _hashStrokes(_strokes) != _savedHash;

  /// Expose les strokes actuels (copie immutable) pour permettre au parent
  /// d'en conserver un snapshot en mémoire avant de reconstruire le widget.
  List<_AnnotStroke> get currentStrokes => List.unmodifiable(_strokes);

  @override
  void initState() {
    super.initState();
    final seeded = widget.initialStrokes;
    if (seeded != null) {
      // Seed depuis la mémoire (changement de page PDF) — pas de disque.
      _strokes = List.of(seeded);
      _savedHash = _hashStrokes(_strokes);
    } else if (!_webMode) {
      _loadAnnotation();
    }
    // Web mode : pas de chargement depuis disque (impossible dans le
    // navigateur). Les annotations démarrent vides à chaque ouverture.
  }

  Future<void> _loadAnnotation() async {
    if (_webMode) return; // garde-fou : appelé indirectement, ne fait rien.
    final f = File(_annotationPath);
    if (!await f.exists()) return;
    try {
      final raw = await f.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      final loaded = list
          .whereType<Map<String, dynamic>>()
          .map(_AnnotStroke.fromJson)
          .whereType<_AnnotStroke>()
          .toList();
      // Filtre défensif : si un JSON historique contient des coordonnées en
      // pixels absolus (> 1), on ignore ces strokes car on ne peut plus les
      // dénormaliser correctement.
      final valid = loaded.where((s) {
        return s.points.every((p) =>
            p.dx >= 0 && p.dx <= 1 && p.dy >= 0 && p.dy <= 1);
      }).toList();
      if (!mounted) return;
      setState(() {
        _strokes = valid;
        _savedHash = _hashStrokes(_strokes);
      });
    } catch (_) {
      // Fichier corrompu : on ignore, l'utilisateur repart de zéro.
    }
  }

  /// Sauvegarde le JSON des strokes sur disque. Appelé via GlobalKey depuis
  /// _PreviewScreen.
  Future<void> saveAnnotation() async {
    try {
      // Mode "piloté par le parent" (ex: PDF multi-pages) → ne touche pas
      // au disque, mais met juste à jour le hash pour indiquer que les
      // modifs courantes sont considérées comme sauvegardées.
      // Idem en mode web (`_webMode`) : pas de filesystem, le re-upload
      // de l'image flattenée se fait via le bouton Save du _PreviewScreen.
      if (!widget.autoPersistToDisk || _webMode) {
        if (!mounted) return;
        setState(() => _savedHash = _hashStrokes(_strokes));
        widget.onChanged();
        return;
      }
      final f = File(_annotationPath);
      if (_strokes.isEmpty) {
        if (await f.exists()) await f.delete();
      } else {
        final json = jsonEncode(_strokes.map((s) => s.toJson()).toList());
        await f.writeAsString(json);
      }
      if (!mounted) return;
      setState(() => _savedHash = _hashStrokes(_strokes));
      widget.onChanged();
    } catch (_) {
      // silent
    }
  }

  /// Export l'image + l'annotation aplatie en PNG (bytes).
  Future<Uint8List?> exportFlatPng() async {
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;
      // Pixel ratio plus élevé → meilleure qualité.
      final image = await boundary.toImage(pixelRatio: 2.5);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  // ------------------------ Dessin ------------------------
  //
  // Points stockés en coordonnées NORMALISÉES (0..1) pour que les annotations
  // s'alignent quel que soit la taille du canvas à la réouverture (le dialog
  // de preview peut avoir des dimensions différentes, ou l'image peut être
  // affichée en BoxFit.contain avec des marges).

  // Taille actuelle du canvas — mise à jour par LayoutBuilder dans build().
  Size _canvasSize = Size.zero;

  Offset _normalize(Offset local) {
    if (_canvasSize.isEmpty) return Offset.zero;
    return Offset(
      (local.dx / _canvasSize.width).clamp(0.0, 1.0),
      (local.dy / _canvasSize.height).clamp(0.0, 1.0),
    );
  }

  /// Rayon effectif de la gomme en coordonnées normalisées (0..1).
  /// La gomme ne peint PAS un trait blanc : elle supprime les traits existants
  /// dont au moins un point tombe sous le pinceau. Ainsi l'image dessous
  /// reste intacte.
  double get _eraserRadius {
    const kEraserPx = 24.0;
    final shortest = math.min(_canvasSize.width, _canvasSize.height);
    if (shortest <= 0) return 0.04;
    return kEraserPx / shortest;
  }

  /// Pile de redo : chaque entrée est un snapshot complet de [_strokes]
  /// au moment où l'utilisateur a fait undo. Refaire (`_redo`) repop
  /// le dernier snapshot. Toute nouvelle action utilisateur (nouveau
  /// stroke, gomme) clear cette pile — comportement attendu d'un
  /// historique linéaire.
  final List<List<_AnnotStroke>> _redoStack = [];

  void _eraseAt(Offset normalizedPoint) {
    final r = _eraserRadius;
    final kept = <_AnnotStroke>[];
    var touched = false;
    for (final stroke in _strokes) {
      final hit = stroke.points
          .any((p) => (p - normalizedPoint).distance <= r);
      if (hit) {
        touched = true;
      } else {
        kept.add(stroke);
      }
    }
    if (!touched) return;
    setState(() {
      _strokes = kept;
      _redoStack.clear();
    });
    // Notifie le parent (`_PreviewScreen`) que l'annotation a changé →
    // il rebuild, recalcule `_hasAnyUnsaved`, le bouton Save s'active.
    widget.onChanged();
  }

  void _startStroke(Offset pos) {
    final normalized = _normalize(pos);
    if (_tool == _AnnotTool.eraser) {
      _eraseAt(normalized);
      return;
    }
    setState(() {
      _strokes = [
        ..._strokes,
        _AnnotStroke(
          tool: _tool,
          color: _color,
          strokeWidth: _strokeWidth,
          points: [normalized],
        ),
      ];
      _redoStack.clear();
    });
    widget.onChanged();
  }

  void _appendStroke(Offset pos) {
    final normalized = _normalize(pos);
    if (_tool == _AnnotTool.eraser) {
      _eraseAt(normalized);
      return;
    }
    if (_strokes.isEmpty) return;
    setState(() {
      final last = _strokes.last;
      _strokes = [
        ..._strokes.sublist(0, _strokes.length - 1),
        last.copyWith(points: [...last.points, normalized]),
      ];
    });
    // Pas besoin de notifier ici à chaque move (très bruyant) —
    // `_startStroke` a déjà notifié au début du trait. Le parent voit
    // déjà `_hasUnsavedAnnotation = true`.
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() {
      _redoStack.add(List.of(_strokes));
      _strokes = _strokes.sublist(0, _strokes.length - 1);
    });
    widget.onChanged();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      _strokes = _redoStack.removeLast();
    });
    widget.onChanged();
  }

  void _clear() {
    if (_strokes.isEmpty) return;
    setState(() {
      _redoStack.add(List.of(_strokes));
      _strokes = [];
    });
    widget.onChanged();
  }

  // ------------------------ Build ------------------------

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Image + annotation overlay inside a RepaintBoundary to export flat.
        Positioned.fill(
          child: Container(
            color: Color(0xFF0E1116),
            child: Center(
              child: RepaintBoundary(
                key: _boundaryKey,
                child: _buildImageWithOverlay(),
              ),
            ),
          ),
        ),
        // Annotation toolbar (floating, bottom-centered).
        Positioned(
          left: 0,
          right: 0,
          bottom: 16,
          child: Center(child: _buildToolbar()),
        ),
      ],
    );
  }

  Widget _buildImageWithOverlay() {
    // Charge l'image depuis bytes (web) OU disque (natif). Avant ce switch
    // l'annotation web était impossible car `Image.file` (et `dart:io File`)
    // ne fonctionnent pas dans le navigateur — l'utilisateur tombait sur un
    // placeholder vide.
    final Image img = _webMode
        ? Image.memory(widget.imageBytes!, fit: BoxFit.contain)
        : Image.file(File(widget.imagePath!), fit: BoxFit.contain);
    // Enroule image + canvas dans le même widget pour que le RepaintBoundary
    // capture tout en cohérence.
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // Met à jour _canvasSize après le frame pour que _normalize() utilise
        // la bonne taille. En post-frame pour éviter setState() pendant build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_canvasSize != size) setState(() => _canvasSize = size);
        });
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _startStroke(d.localPosition),
          onPanUpdate: (d) => _appendStroke(d.localPosition),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: img),
              Positioned.fill(
                child: CustomPaint(
                  painter: _AnnotPainter(strokes: _strokes),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildToolbar() {
    // Toolbar ronde pilule claire, identique à celle de NotesWidget
    // (toolset quick) : Crayon + Gomme + Annuler + Tout effacer.
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolButton(
            // `LucideIcons.pencil` (crayon classique) — même icône que
            // les autres notes (NotesWidget, plan_canvas) pour la
            // cohérence visuelle. Avant on utilisait `penTool` (stylo
            // plume) qui détonnait avec le reste de l'app.
            icon: LucideIcons.pencil,
            selected: _tool == _AnnotTool.pen,
            tooltip: 'Crayon',
            onTap: () => setState(() => _tool = _AnnotTool.pen),
          ),
          const SizedBox(width: 6),
          _ToolButton(
            icon: LucideIcons.eraser,
            selected: _tool == _AnnotTool.eraser,
            tooltip: 'Gomme',
            onTap: () => setState(() => _tool = _AnnotTool.eraser),
          ),
          const SizedBox(width: 6),
          _ToolButton(
            icon: LucideIcons.undo2,
            tooltip: 'Annuler',
            onTap: _strokes.isEmpty ? null : _undo,
          ),
          const SizedBox(width: 6),
          _ToolButton(
            icon: LucideIcons.redo2,
            tooltip: 'Rétablir',
            onTap: _redoStack.isEmpty ? null : _redo,
          ),
          const SizedBox(width: 6),
          _ToolButton(
            icon: LucideIcons.trash2,
            tooltip: 'Tout effacer',
            onTap: _strokes.isEmpty ? null : _clear,
          ),
        ],
      ),
    );
  }

  static int _hashStrokes(List<_AnnotStroke> strokes) {
    if (strokes.isEmpty) return 0;
    // Hash approximatif mais stable : nb de strokes + nb total de points.
    final nPoints = strokes.fold<int>(0, (acc, s) => acc + s.points.length);
    return Object.hash(strokes.length, nPoints,
        strokes.isNotEmpty ? strokes.last.points.length : 0);
  }
}

enum _AnnotTool { pen, eraser }

class _AnnotStroke {
  final _AnnotTool tool;
  final Color color;
  final double strokeWidth;
  final List<Offset> points;

  const _AnnotStroke({
    required this.tool,
    required this.color,
    required this.strokeWidth,
    required this.points,
  });

  _AnnotStroke copyWith({List<Offset>? points}) => _AnnotStroke(
        tool: tool,
        color: color,
        strokeWidth: strokeWidth,
        points: points ?? this.points,
      );

  Map<String, dynamic> toJson() => {
        'tool': tool.name,
        'color': color.toARGB32(),
        'strokeWidth': strokeWidth,
        'points': points.map((p) => [p.dx, p.dy]).toList(),
      };

  static _AnnotStroke? fromJson(Map<String, dynamic> json) {
    try {
      final toolName = json['tool']?.toString() ?? 'pen';
      final tool = _AnnotTool.values.firstWhere(
        (t) => t.name == toolName,
        orElse: () => _AnnotTool.pen,
      );
      final color =
          Color((json['color'] as num?)?.toInt() ?? 0xFFE11D48);
      final strokeWidth =
          (json['strokeWidth'] as num?)?.toDouble() ?? 3.0;
      final pts = (json['points'] as List?) ?? const [];
      final points = pts.whereType<List>().map<Offset>((p) {
        return Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
      }).toList();
      return _AnnotStroke(
        tool: tool,
        color: color,
        strokeWidth: strokeWidth,
        points: points,
      );
    } catch (_) {
      return null;
    }
  }
}

class _AnnotPainter extends CustomPainter {
  final List<_AnnotStroke> strokes;

  const _AnnotPainter({required this.strokes});

  /// Convertit un point normalisé (0..1) en coordonnées pixel du canvas.
  Offset _toCanvas(Offset p, Size size) => Offset(p.dx * size.width, p.dy * size.height);

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = stroke.strokeWidth
        ..isAntiAlias = true;

      if (stroke.tool == _AnnotTool.eraser) {
        // "Eraser" : en mode overlay persistant, on simule avec des traits
        // blancs plus larges. (Pour un vrai erase, il faudrait un
        // Canvas.saveLayer + BlendMode.clear, complexe en export.)
        paint.color = Colors.white;
      } else {
        paint.color = stroke.color;
      }

      final pts = stroke.points.map((p) => _toCanvas(p, size)).toList();

      if (pts.length < 2) {
        if (pts.isNotEmpty) {
          canvas.drawCircle(
            pts.first,
            stroke.strokeWidth / 2,
            Paint()
              ..color = paint.color
              ..isAntiAlias = true,
          );
        }
        continue;
      }

      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AnnotPainter old) => old.strokes != strokes;
}

/// Bouton circulaire style "notes rapides" : pilule claire 40×40, fond gris
/// quand inactif, violet soft (_kAccentSoft) quand actif.
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final String tooltip;
  final VoidCallback? onTap;

  const _ToolButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFFD8D0DC) // _kAccentSoft
                  : Color(0xFFF2F4F6),
              shape: BoxShape.circle,
            ),
            child: Opacity(
              opacity: disabled ? 0.4 : 1,
              child: Icon(
                icon,
                size: 18,
                color: selected
                    ? const Color(0xFF554265) // _kActiveText
                    : Color(0xFF2B323A),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sync color helper
// ---------------------------------------------------------------------------

Color _syncColor(SyncState syncState) {
  switch (syncState) {
    case SyncState.synced:
      return Colors.green.shade700;
    case SyncState.pendingSync:
    case SyncState.localOnly:
    case SyncState.syncing:
      return Colors.orange.shade700;
    case SyncState.syncError:
    case SyncState.conflict:
      return Colors.red.shade700;
  }
}
