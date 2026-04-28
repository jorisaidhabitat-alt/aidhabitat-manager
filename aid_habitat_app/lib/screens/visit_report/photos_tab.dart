import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../components/soft_transitions.dart';
import '../../models/types.dart';
import '../../models/visit_report_categories.dart';
import '../../services/data_service.dart';

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
  static const Color _kPurple = Color(0xFF7C6DAA);
  static const Color _kPurpleLight = Color(0xFFEDE8F5);
  static const Color _kSlate = Color(0xFF334155);
  static const Color _kSlateMuted = Color(0xFF64748B);

  /// Compression cible — `image_picker` accepte directement ces
  /// paramètres et applique le redimensionnement + ré-encodage JPEG
  /// côté natif. Sur PWA web, image_picker compresse aussi (le
  /// browser retourne un blob déjà JPEG via `pickImage`).
  static const double _kCompressMaxWidth = 1600;
  static const int _kCompressQuality = 80;

  final DataService _dataService = DataService();
  final ImagePicker _imagePicker = ImagePicker();

  bool _isLoading = true;
  bool _isImporting = false;
  List<DocItem> _photos = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  // ----- Data -----

  /// Recharge la liste depuis SQLite et la trie par catégorie. Appelé
  /// après chaque action (import / re-tag / delete / reorder).
  ///
  /// Filtre : images portant AU MOINS un des trois tags visite. Les
  /// photos d'archive importées depuis l'espace Documents ne sont pas
  /// chargées — elles restent dans Documents et n'apparaissent jamais
  /// ici.
  Future<void> _refresh() async {
    try {
      final docs = await _dataService.fetchDocuments(widget.dossier.patient.id);
      final visitImages = docs
          .where((d) =>
              d.type == 'image' && kVisitPhotoTags.any(d.tags.contains))
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _photos = visitImages;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  /// Renvoie les photos d'une catégorie visite, triées par
  /// `categoryOrder` (croissant) puis par date (DESC pour les rares
  /// rangées NULL).
  List<DocItem> _photosForCategory(String categoryTag) {
    final filtered = _photos.where((d) => d.tags.contains(categoryTag)).toList()
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

  Future<void> _persistPicked(XFile xfile, String categoryTag) async {
    final order = _nextOrderInCategory(categoryTag);
    final fileName = _buildPhotoFileName(categoryTag, xfile.name);
    if (kIsWeb) {
      final bytes = await xfile.readAsBytes();
      await _dataService.importDocumentBytes(
        patientId: widget.dossier.patient.id,
        bytes: bytes,
        fileName: fileName,
        tags: [categoryTag],
        categoryOrder: order,
      );
    } else {
      await _dataService.importDocument(
        patientId: widget.dossier.patient.id,
        filePath: xfile.path,
        tags: [categoryTag],
        categoryOrder: order,
      );
    }
    await _refresh();
  }

  /// Nom de fichier propre du type
  /// `visite_logement_20260427_HHMMSS.jpg` — facilite la
  /// reconnaissance dans NocoDB et Google Drive.
  String _buildPhotoFileName(String categoryTag, String originalName) {
    final shortCategory = visitPhotoTagShortLabel(categoryTag)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '_');
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final ext = (() {
      final dot = originalName.lastIndexOf('.');
      if (dot < 0) return 'jpg';
      return originalName.substring(dot + 1).toLowerCase();
    })();
    return 'visite_${shortCategory}_$stamp.$ext';
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
    final preserved =
        doc.tags.where((t) => !kVisitPhotoTags.contains(t)).toList();
    final nextTags = <String>[
      ...preserved,
      if (newTag != null) newTag,
    ];
    final order = newTag == null ? null : _nextOrderInCategory(newTag);
    await _dataService.setDocumentVisitCategorization(
      documentId: doc.id,
      tags: nextTags,
      categoryOrder: order,
    );
    await _refresh();
  }

  Future<void> _deletePhoto(DocItem doc) async {
    final confirm = await showSoftDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Supprimer cette photo ?'),
        content: Text(
          'La photo "${doc.title}" sera supprimée définitivement '
          '(localement et sur le serveur).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
            ),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _dataService.deleteDocument(doc.id);
    await _refresh();
  }

  Future<void> _reorderInCategory({
    required String categoryTag,
    required int oldIndex,
    required int newIndex,
  }) async {
    final list = _photosForCategory(categoryTag);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    // Convention ReorderableListView : si on bouge vers le bas, le
    // newIndex est décalé d'un cran qu'il faut compenser.
    final adjusted = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final moved = list.removeAt(oldIndex);
    list.insert(adjusted.clamp(0, list.length), moved);
    await _dataService.reorderVisitCategoryDocuments(
      orderedDocumentIds: list.map((d) => d.id).toList(),
    );
    await _refresh();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ----- Build -----

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    // Layout 3 colonnes (Logement / Accessibilité / Sanitaires) côte
    // à côte. Demande utilisateur : sur iPad au format paysage on a
    // largement la place pour afficher les 3 catégories sans scroll
    // vertical → l'ergo voit d'un coup d'œil l'état de remplissage
    // des 3 buckets pendant la VAD.
    //
    // Chaque colonne a `crossAxisAlignment: CrossAxisAlignment.start`
    // pour que les en-têtes restent alignés haut, et `IntrinsicHeight`
    // côté parent assure que les fonds blancs aient la même hauteur
    // (visuel propre, pas de "marche d'escalier" entre les 3
    // sections quand l'une a 3 photos et l'autre 0).
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: SingleChildScrollView(
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < kVisitPhotoTags.length; i++) ...[
                if (i > 0) const SizedBox(width: 14),
                Expanded(
                  child: _buildCategorySection(
                    tag: kVisitPhotoTags[i],
                    icon: _iconForCategory(kVisitPhotoTags[i]),
                    maxSlots:
                        kVisitPhotoSlotCount[kVisitPhotoTags[i]] ?? 0,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForCategory(String tag) {
    switch (tag) {
      case kPhotoTagLogement:
        return LucideIcons.home;
      case kPhotoTagAccessibilite:
        return LucideIcons.armchair;
      case kPhotoTagSanitaires:
        return LucideIcons.bath;
      default:
        return LucideIcons.image;
    }
  }

  Widget _buildCategorySection({
    required String tag,
    required IconData icon,
    required int maxSlots,
  }) {
    final photos = _photosForCategory(tag);
    final count = photos.length;
    final isFull = count >= maxSlots;
    final overCapacity = count > maxSlots;
    final shortLabel = visitPhotoTagShortLabel(tag);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête : icône + nom + compteur "X / max"
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _kPurpleLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: _kPurple),
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
              _buildCountBadge(
                count: count,
                max: maxSlots,
                full: isFull && !overCapacity,
                over: overCapacity,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (photos.isEmpty)
            _buildEmptyState(tag)
          else
            _buildReorderableGrid(
              tag: tag,
              photos: photos,
              maxSlots: maxSlots,
            ),
          const SizedBox(height: 10),
          // Boutons capture / galerie — toujours présents même si la
          // catégorie est pleine (l'ergo peut vouloir une 4e photo en
          // surplus, marquée comme « non utilisée »).
          Row(
            children: [
              Expanded(
                child: _buildAddButton(
                  icon: LucideIcons.camera,
                  label: 'Prendre',
                  onTap: () => _captureFromSource(
                    categoryTag: tag,
                    source: ImageSource.camera,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildAddButton(
                  icon: LucideIcons.image,
                  label: 'Galerie',
                  onTap: () => _captureFromSource(
                    categoryTag: tag,
                    source: ImageSource.gallery,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCountBadge({
    required int count,
    required int max,
    required bool full,
    required bool over,
  }) {
    final bg = over
        ? const Color(0xFFFEE2E2)
        : full
            ? const Color(0xFFDCFCE7)
            : const Color(0xFFF1F5F9);
    final fg = over
        ? const Color(0xFFB91C1C)
        : full
            ? const Color(0xFF15803D)
            : _kSlateMuted;
    final label = over ? '$count / $max +' : '$count / $max';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (full && !over) ...[
            Icon(LucideIcons.check, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFE2E8F0),
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        children: [
          Icon(LucideIcons.imagePlus, size: 22, color: Colors.grey.shade400),
          const SizedBox(height: 6),
          Text(
            'Aucune photo dans cette catégorie',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReorderableGrid({
    required String tag,
    required List<DocItem> photos,
    required int maxSlots,
  }) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: photos.length,
      onReorder: (oldIndex, newIndex) => _reorderInCategory(
        categoryTag: tag,
        oldIndex: oldIndex,
        newIndex: newIndex,
      ),
      proxyDecorator: (child, _, animation) => AnimatedBuilder(
        animation: animation,
        builder: (ctx, _) {
          final t = Curves.easeInOut.transform(animation.value);
          return Material(
            color: Colors.transparent,
            elevation: 6 * t,
            shadowColor: Colors.black.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
            child: Transform.scale(
              scale: 1 + 0.02 * t,
              child: child,
            ),
          );
        },
      ),
      itemBuilder: (ctx, index) {
        final doc = photos[index];
        final inSlot = index < maxSlots;
        return _PhotoTile(
          key: ValueKey('photo_${doc.id}'),
          doc: doc,
          slotNumber: index + 1,
          inSlot: inSlot,
          dragHandleIndex: index,
          onMoveTo: (newTag) => _moveToCategory(doc: doc, newTag: newTag),
          onUntag: () => _moveToCategory(doc: doc, newTag: null),
          onDelete: () => _deletePhoto(doc),
        );
      },
    );
  }

  Widget _buildAddButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: _isImporting ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
        decoration: BoxDecoration(
          color: _isImporting ? const Color(0xFFF1F5F9) : _kPurpleLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: _kPurple),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _kPurple,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tile — une photo d'une catégorie visite, draggable + actions
// ---------------------------------------------------------------------------

class _PhotoTile extends StatelessWidget {
  final DocItem doc;
  final int slotNumber;
  final bool inSlot;
  final int dragHandleIndex;
  final ValueChanged<String> onMoveTo;
  final VoidCallback onUntag;
  final VoidCallback onDelete;

  const _PhotoTile({
    super.key,
    required this.doc,
    required this.slotNumber,
    required this.inSlot,
    required this.dragHandleIndex,
    required this.onMoveTo,
    required this.onUntag,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: inSlot
                ? const Color(0xFFE2E8F0)
                : const Color(0xFFFEE2E2),
          ),
        ),
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            // Drag handle (à gauche pour faciliter l'accès au pouce)
            ReorderableDragStartListener(
              index: dragHandleIndex,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  LucideIcons.gripVertical,
                  size: 18,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Numéro de slot (1, 2, 3, …) — vert si occupe un slot,
            // rouge "+" si surplus.
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: inSlot
                    ? const Color(0xFFDCFCE7)
                    : const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                inSlot ? '$slotNumber' : '+',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: inSlot
                      ? const Color(0xFF15803D)
                      : const Color(0xFFB91C1C),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56,
                height: 56,
                child: _PhotoThumbnail(doc: doc),
              ),
            ),
            const SizedBox(width: 12),
            // Métadonnées
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    doc.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF334155),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    inSlot
                        ? 'Slot $slotNumber du rapport'
                        : 'Surplus — non utilisé',
                    style: TextStyle(
                      fontSize: 11,
                      color: inSlot
                          ? const Color(0xFF64748B)
                          : const Color(0xFFB91C1C),
                    ),
                  ),
                ],
              ),
            ),
            // Menu d'actions
            PopupMenuButton<String>(
              tooltip: 'Actions',
              icon: const Icon(
                LucideIcons.moreVertical,
                size: 18,
                color: Color(0xFF94A3B8),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onSelected: (value) {
                if (value == 'untag') {
                  onUntag();
                } else if (value == 'delete') {
                  onDelete();
                } else if (value.startsWith('move:')) {
                  onMoveTo(value.substring('move:'.length));
                }
              },
              itemBuilder: (ctx) {
                final items = <PopupMenuEntry<String>>[];
                // Sous-menu « Déplacer vers »
                final currentTag = doc.tags
                    .firstWhere(kVisitPhotoTags.contains, orElse: () => '');
                for (final tag in kVisitPhotoTags) {
                  if (tag == currentTag) continue;
                  items.add(
                    PopupMenuItem<String>(
                      value: 'move:$tag',
                      child: Row(
                        children: [
                          const Icon(LucideIcons.arrowRight,
                              size: 14, color: Color(0xFF7C6DAA)),
                          const SizedBox(width: 8),
                          Text(visitPhotoTagShortLabel(tag)),
                        ],
                      ),
                    ),
                  );
                }
                items.add(const PopupMenuDivider());
                items.add(
                  const PopupMenuItem<String>(
                    value: 'untag',
                    child: Row(
                      children: [
                        Icon(LucideIcons.folderMinus,
                            size: 14, color: Color(0xFF92400E)),
                        SizedBox(width: 8),
                        Text('Retirer la catégorie'),
                      ],
                    ),
                  ),
                );
                items.add(
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(LucideIcons.trash2,
                            size: 14, color: Color(0xFFB91C1C)),
                        SizedBox(width: 8),
                        Text('Supprimer'),
                      ],
                    ),
                  ),
                );
                return items;
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helper widget — affiche une vignette quel que soit le support
// ---------------------------------------------------------------------------

class _PhotoThumbnail extends StatelessWidget {
  final DocItem doc;
  const _PhotoThumbnail({required this.doc});

  @override
  Widget build(BuildContext context) {
    // Ordre de préférence pour l'affichage :
    //   1. PWA web : `dataUrl` (bytes capturés ou anciens imports web)
    //   2. natif   : `localPath` (fichier filesystem)
    //   3. fallback : `url` distant si déjà uploadé sur NocoDB
    final dataUrl = doc.dataUrl;
    if (dataUrl != null && dataUrl.startsWith('data:')) {
      try {
        final base64 = dataUrl.split(',').last;
        return Image.memory(
          base64Decode(base64),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) => _placeholder(),
        );
      } catch (_) {
        return _placeholder();
      }
    }
    final localPath = doc.localPath;
    if (!kIsWeb && localPath != null && File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => _placeholder(),
      );
    }
    final url = doc.url;
    if (url != null && url.isNotEmpty) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() => Container(
        color: const Color(0xFFF1F5F9),
        alignment: Alignment.center,
        child: const Icon(
          LucideIcons.imageOff,
          size: 18,
          color: Color(0xFF94A3B8),
        ),
      );
}
