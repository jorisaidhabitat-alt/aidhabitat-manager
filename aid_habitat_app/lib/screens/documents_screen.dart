import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pdfx/pdfx.dart';
import 'package:share_plus/share_plus.dart';

import 'package:http/http.dart' as http;

import '../models/types.dart';
import '../services/app_config.dart';
import '../services/data_service.dart';
import '../services/document_repository.dart';
import '../services/media_cache_service.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

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

const Color _kPurple = Color(0xFF907CA1);
const Color _kDarkPurple = Color(0xFF554a63);

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

  String _searchTerm = '';
  bool _isLoading = true;
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

  // Auto-refresh : polling toutes les 10 s + refresh au retour focus app.
  Timer? _refreshTimer;

  String get _patientId => widget.dossier.patient.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDocuments();
    // Polling silencieux toutes les 10 secondes (identique à React).
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) _loadDocuments(silent: true);
    });
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
    if (!silent) setState(() => _isLoading = true);
    final docs = await _dataService.fetchDocuments(_patientId);
    if (!mounted) return;
    setState(() {
      _documents = docs;
      _isLoading = false;
    });

    final refreshed = await _dataService.refreshDocumentsFromRemote(_patientId);
    if (!refreshed || !mounted) return;
    final remoteDocs = await _dataService.fetchDocuments(_patientId);
    if (!mounted) return;
    setState(() {
      _documents = remoteDocs;
    });
  }

  // ----- Import flows -----

  /// Caméra — iOS/Android/web. Sur web (PWA iPad), `image_picker` route
  /// vers `<input type="file" accept="image/*" capture="environment">` qui
  /// ouvre directement l'appareil photo iOS. Sur desktop, fallback sur le
  /// file picker système.
  Future<void> _pickFromCamera() async {
    if (_isPicking || _isImporting) return;
    _isPicking = true;
    try {
      if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
        final xfile =
            await _imagePicker.pickImage(source: ImageSource.camera);
        if (xfile == null) return;
        if (kIsWeb) {
          await _openUploadModalWeb(xfile, defaultTag: 'Photo');
        } else {
          await _openUploadModal(File(xfile.path), defaultTag: 'Photo');
        }
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

  /// Import d'image.
  ///  - iOS / Android natif → `image_picker` gallery (photothèque native)
  ///  - Web (PWA iPad inclus) → `FilePicker` filtré images. Plus fiable
  ///    que `image_picker` sur iOS PWA standalone où l'action-sheet web
  ///    peut ne pas s'ouvrir.
  ///  - Desktop → même `FilePicker` filtré images.
  Future<void> _pickFromGallery() async {
    if (_isPicking || _isImporting) return;
    _isPicking = true;
    try {
      if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
        final xfile =
            await _imagePicker.pickImage(source: ImageSource.gallery);
        if (xfile == null) return;
        await _openUploadModal(File(xfile.path), defaultTag: 'Photo');
        return;
      }
      // Web + desktop → FilePicker (input[type=file] accept=image/*)
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        dialogTitle: 'Sélectionner une image',
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;
      await _importPickedFile(result.files.single, defaultTag: 'Photo');
    } catch (err) {
      _showError('Sélection d\'image impossible: $err');
    } finally {
      _isPicking = false;
    }
  }

  /// Web variant of [_openUploadModal]: reads the XFile bytes directly
  /// (XFile.path is a blob URL on web, unusable as a filesystem path) and
  /// imports them via [DocumentRepository.importDocumentBytes].
  Future<void> _openUploadModalWeb(XFile xfile,
      {required String defaultTag}) async {
    if (!mounted) return;
    final defaultTitle =
        xfile.name.isNotEmpty ? xfile.name.split('.').first : 'Photo';
    final result = await showDialog<_UploadResult>(
      context: context,
      builder: (ctx) => _UploadModal(
        defaultTitle: defaultTitle,
        defaultTag: defaultTag,
      ),
    );
    if (result == null || !mounted) return;

    setState(() => _isImporting = true);
    try {
      final bytes = await xfile.readAsBytes();
      final fileName = xfile.name.isNotEmpty
          ? xfile.name
          : 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await _documentRepository.importDocumentBytes(
        patientId: _patientId,
        bytes: bytes,
        fileName: fileName,
        tags: [result.tag],
        title: result.title,
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

  /// "Scanner un document" → ouvre directement l'appareil photo. iOS
  /// inclut un scanner natif dans son picker caméra (encadre auto le
  /// document), on laisse le user l'utiliser tel quel.
  Future<void> _pickFromScanner() async {
    if (_isPicking || _isImporting) return;
    _isPicking = true;
    try {
      if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
        final xfile =
            await _imagePicker.pickImage(source: ImageSource.camera);
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
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        dialogTitle: 'Importer un fichier',
        withData: kIsWeb,
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
      final defaultTitle = (picked.name.isNotEmpty)
          ? picked.name.split('.').first
          : 'Document';
      final result = await showDialog<_UploadResult>(
        context: context,
        builder: (ctx) => _UploadModal(
          defaultTitle: defaultTitle,
          defaultTag: defaultTag,
        ),
      );
      if (result == null || !mounted) return;
      setState(() => _isImporting = true);
      try {
        await _documentRepository.importDocumentBytes(
          patientId: _patientId,
          bytes: bytes,
          fileName: picked.name,
          tags: [result.tag],
          title: result.title,
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

  Future<void> _openUploadModal(File file, {required String defaultTag}) async {
    if (!mounted) return;
    final defaultTitle = file.path.split('/').last.split('.').first;
    final result = await showDialog<_UploadResult>(
      context: context,
      builder: (ctx) => _UploadModal(
        defaultTitle: defaultTitle,
        defaultTag: defaultTag,
      ),
    );
    if (result == null || !mounted) return;

    setState(() => _isImporting = true);
    try {
      await _documentRepository.importDocument(
        patientId: _patientId,
        sourceFile: file,
        tags: [result.tag],
        title: result.title,
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
    final confirmed = await showDialog<bool>(
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
    // Sur web, quand le document n'a qu'un `dataUrl` (bytes locaux pas
    // encore uploadés), on n'a pas de File et le _PreviewScreen complet
    // (PDF controller, annotator) ne peut pas le lire → on affiche une
    // lightbox simple avec l'image décodée depuis le base64.
    if (kIsWeb &&
        doc.type == 'image' &&
        (doc.localPath == null || doc.localPath!.isEmpty) &&
        (doc.url == null || doc.url!.isEmpty) &&
        doc.dataUrl != null &&
        doc.dataUrl!.isNotEmpty) {
      await _showWebImagePreview(doc);
      return;
    }
    // Quick-Look style pop-up : dialog centré, fond semi-transparent, escape
    // pour fermer. On utilise une barrier colorée + une Dialog translucide
    // qui laisse voir le bureau autour.
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
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
  }

  /// Simple preview dialog for web documents whose bytes live in a data
  /// URL. No annotator, no PDF support — just a zoomable image + a close
  /// button. Once the sync uploads the bytes and populates [DocItem.url],
  /// the full [_PreviewScreen] takes over.
  Future<void> _showWebImagePreview(DocItem doc) async {
    final comma = doc.dataUrl!.indexOf(',');
    if (comma < 0) return;
    final bytes = base64Decode(doc.dataUrl!.substring(comma + 1));
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Aperçu de l\'image',
      barrierColor: Colors.black.withValues(alpha: 0.8),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, _) => SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(ctx).pop(),
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: Material(
                color: Colors.black.withValues(alpha: 0.5),
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    doc.title.isNotEmpty ? doc.title : doc.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
      final fileName = doc.name.isNotEmpty ? doc.name : '${doc.title}.bin';
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
    Iterable<DocItem> docs = _documents;

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
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Bandeau : hauteur fixe égale à celle de la toolbar violette
              // (48 px) — comme ça la grille ne bouge pas d'un pixel quand
              // on entre/quitte le mode sélection.
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    InkWell(
                      onTap: widget.onBack,
                      borderRadius: BorderRadius.circular(50),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          LucideIcons.arrowLeft,
                          size: 20,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "${widget.dossier.patient.lastName.toUpperCase()} ${widget.dossier.patient.firstName}",
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_isSelectionMode) ...[
                      const SizedBox(width: 16),
                      Expanded(child: _buildSelectionToolbar()),
                    ] else
                      const Spacer(),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildGrid(),
              ),
            ],
          ),
        ),
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
                fontWeight: FontWeight.w800,
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
    final confirmed = await showDialog<bool>(
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
    _refreshTimer?.cancel();
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
        side: BorderSide(color: Colors.grey.shade200),
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
                  color: Color(0xFF0F172A),
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
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
            color: _hovering && !widget.disabled
                ? _kPurple.withValues(alpha: 0.06)
                : Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: CustomPaint(
            painter: _DashedBorderPainter(
              color: widget.disabled
                  ? Colors.grey.shade300
                  : _kPurple.withValues(alpha: _hovering ? 1 : 0.8),
              strokeWidth: 2,
              radius: 16,
              dashLength: 8,
              dashGap: 5,
            ),
            child: Center(
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _kPurple.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  LucideIcons.plus,
                  size: 26,
                  color: widget.disabled ? Colors.grey.shade400 : _kPurple,
                ),
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
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double radius;
  final double dashLength;
  final double dashGap;

  _DashedBorderPainter({
    required this.color,
    required this.strokeWidth,
    required this.radius,
    required this.dashLength,
    required this.dashGap,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rect);
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dashLength).clamp(0.0, metric.length);
        canvas.drawPath(
          metric.extractPath(distance, end),
          paint,
        );
        distance = end + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.radius != radius ||
      old.dashLength != dashLength ||
      old.dashGap != dashGap;
}

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
                  // Tag overlay (top-left, caché si la checkbox prend la place)
                  if (doc.tags.isNotEmpty && !showCheckbox)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(50),
                        ),
                        child: Text(
                          doc.tags.first,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
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
                  // Sync badge + delete button (top-right) — hidden in selection mode
                  if (!selMode)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _SyncBadge(syncState: doc.syncState),
                          const SizedBox(height: 6),
                          _IconButton(
                            icon: LucideIcons.trash2,
                            color: Colors.red,
                            tooltip: 'Supprimer',
                            onPressed: widget.onDelete,
                          ),
                        ],
                      ),
                    ),
                  // Download button (bottom-right) — hidden in selection mode
                  if (!selMode)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: _IconButton(
                        icon: LucideIcons.download,
                        color: _kDarkPurple,
                        tooltip: 'Télécharger',
                        onPressed: widget.onDownload,
                      ),
                    ),
                ],
              ),
            ),
            // Title + date
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Inline editable title
                  _isEditingTitle
                      ? TextField(
                          controller: _titleCtrl,
                          focusNode: _titleFocus,
                          maxLines: 1,
                          textInputAction: TextInputAction.done,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
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
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                  const SizedBox(height: 2),
                  Text(
                    dateLabel,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
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

class _DocThumbnail extends StatelessWidget {
  final DocItem doc;

  const _DocThumbnail({required this.doc});

  @override
  Widget build(BuildContext context) {
    if (doc.type == 'image') {
      // Web offline : bytes capturés en base64, décodés directement.
      if (doc.dataUrl != null && doc.dataUrl!.isNotEmpty) {
        final bytes = _decodeDataUrl(doc.dataUrl!);
        if (bytes != null) {
          return Image.memory(bytes, fit: BoxFit.cover, errorBuilder: _fallback);
        }
      }
      if (!kIsWeb &&
          doc.localPath != null &&
          doc.localPath!.isNotEmpty) {
        final file = File(doc.localPath!);
        if (file.existsSync()) {
          return Image.file(file, fit: BoxFit.cover, errorBuilder: _fallback);
        }
      }
      if (doc.url != null && doc.url!.isNotEmpty) {
        // Télécharge via MediaCacheService (cache persistant offline-first).
        return _RemoteImage(
          url: doc.url!,
          fit: BoxFit.cover,
          fallback: _iconPlaceholder(doc.type),
        );
      }
    }
    if (doc.type == 'pdf' &&
        !kIsWeb &&
        doc.localPath != null &&
        doc.localPath!.isNotEmpty &&
        File(doc.localPath!).existsSync()) {
      return _PdfThumbnail(path: doc.localPath!);
    }
    return _iconPlaceholder(doc.type);
  }

  /// Decodes a `data:<mime>;base64,<...>` URL into raw bytes. Returns null
  /// if malformed (missing `,` separator or invalid base64).
  Uint8List? _decodeDataUrl(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  Widget _fallback(BuildContext ctx, Object err, StackTrace? st) =>
      _iconPlaceholder(doc.type);

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
        color = Colors.grey.shade400;
    }
    return Container(
      color: Colors.grey.shade50,
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
        color: Colors.grey.shade50,
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
        color: Colors.grey.shade50,
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
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => Container(
          color: Colors.grey.shade50,
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

    // 3. Native : MediaCacheService (cache filesystem).
    final file = await MediaCacheService().fetch(widget.url);
    if (!mounted) return;
    if (file != null) {
      setState(() => _file = file);
      return;
    }

    // 4. Fallback : l'URL est probablement privée et a besoin du header
    //    `X-App-Session`. On fetch directement via http avec auth.
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
      color: Colors.grey.shade100,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(50),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            syncState.label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  const _IconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 1,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 14, color: color),
          ),
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
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 16),
          Text(
            hasFilter
                ? 'Aucun document ne correspond aux filtres.'
                : 'Aucun document pour ce dossier.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
          ),
          if (!hasFilter) ...[
            const SizedBox(height: 8),
            Text(
              'Utilisez les boutons ci-dessus pour ajouter un document.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
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
      // Mode PDF : le wrapper agrège le dirty-state de toutes les pages
      // (mémoire + live annotator de la page courante).
      return pdfWrapper.hasUnsavedChanges;
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
        if (pdfWrapper != null) {
          // Flush toutes les pages PDF modifiées en une seule passe.
          await pdfWrapper.saveAll();
          // Re-upload PDF annoté (aplati en PNG multi-pages mergées) —
          // voir note en bas : pour l'instant on aplatit uniquement la
          // page courante afin que le serveur en ait au moins une
          // version annotée visible.
          await _reuploadFlattenedCurrentPage();
        } else {
          await _annotatorKey.currentState?.saveAnnotation();
          // Re-upload de l'image aplatie vers NocoDB.
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
    final choice = await showDialog<_UnsavedChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modifications non enregistrées'),
        content: const Text(
          'Souhaitez-vous enregistrer les modifications avant de fermer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _UnsavedChoice.cancel),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _UnsavedChoice.discard),
            child: const Text('Fermer sans enregistrer'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, _UnsavedChoice.save),
            icon: const Icon(LucideIcons.save, size: 16),
            label: const Text('Enregistrer et fermer'),
            style: FilledButton.styleFrom(backgroundColor: _kPurple),
          ),
        ],
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
      child: Center(
        child: GestureDetector(
          onTap: () {}, // absorber tap sur le body (barrier ferme le dialog)
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
                      border: Border.all(color: Colors.amber.shade400),
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

    // Image locale → annotation directe.
    if (isImage &&
        doc.localPath != null &&
        doc.localPath!.isNotEmpty &&
        File(doc.localPath!).existsSync()) {
      return _ImageAnnotator(
        key: _annotatorKey,
        imagePath: doc.localPath!,
        onChanged: () => setState(() {}),
      );
    }
    // Image distante → on télécharge via MediaCacheService pour obtenir un
    // fichier local, puis on active l'annotation dessus.
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
    if (isPdf &&
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
              color: Colors.grey.shade900,
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
                      : Colors.grey.shade400,
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
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
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
        color: Colors.grey.shade900,
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
        color: Colors.grey.shade900,
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
  File? _file;
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
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final file = await MediaCacheService().fetch(widget.url);
    if (!mounted) return;
    setState(() {
      _file = file;
      _failed = file == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    if (_file == null) {
      return Container(
        color: Colors.grey.shade900,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: Colors.white),
      );
    }
    return _ImageAnnotator(
      key: widget.annotatorKey,
      imagePath: _file!.path,
      onChanged: widget.onChanged,
    );
  }
}

class _ImageAnnotator extends StatefulWidget {
  final String imagePath;
  final VoidCallback onChanged;

  /// Si fourni, ces strokes sont utilisés au démarrage au lieu de charger
  /// depuis le fichier `.annotation.json` sur disque. Utile quand un parent
  /// (ex: _PdfAnnotatorWrapper) garde les strokes en mémoire entre deux
  /// changements de page.
  final List<_AnnotStroke>? initialStrokes;

  /// Si false, [saveAnnotation] n'écrit pas sur disque — le parent s'en
  /// charge lui-même via sa propre logique (ex: flush multi-page au Save).
  final bool autoPersistToDisk;

  const _ImageAnnotator({
    super.key,
    required this.imagePath,
    required this.onChanged,
    this.initialStrokes,
    this.autoPersistToDisk = true,
  });

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

  String get _annotationPath => '${widget.imagePath}.annotation.json';

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
    } else {
      _loadAnnotation();
    }
  }

  Future<void> _loadAnnotation() async {
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
      if (!widget.autoPersistToDisk) {
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
    setState(() => _strokes = kept);
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
    });
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
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes = _strokes.sublist(0, _strokes.length - 1));
  }

  void _clear() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes = []);
  }

  // ------------------------ Build ------------------------

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Image + annotation overlay inside a RepaintBoundary to export flat.
        Positioned.fill(
          child: Container(
            color: Colors.grey.shade900,
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
    final file = File(widget.imagePath);
    final img = Image.file(file, fit: BoxFit.contain);
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
            icon: LucideIcons.penTool,
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
                  : Colors.grey.shade100,
              shape: BoxShape.circle,
            ),
            child: Opacity(
              opacity: disabled ? 0.4 : 1,
              child: Icon(
                icon,
                size: 18,
                color: selected
                    ? const Color(0xFF554A63) // _kActiveText
                    : Colors.grey.shade700,
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
