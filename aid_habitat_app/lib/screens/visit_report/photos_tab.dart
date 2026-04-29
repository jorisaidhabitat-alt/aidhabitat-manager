import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../components/soft_transitions.dart';
import '../../models/types.dart';
import '../../models/visit_report_categories.dart';
import '../../services/app_config.dart';
import '../../services/data_service.dart';
import '../../services/media_cache_service.dart';

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
      final inserted = await _dataService.importDocumentBytes(
        patientId: widget.dossier.patient.id,
        bytes: bytes,
        fileName: fileName,
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

  /// Supprime une photo SANS confirmation supplémentaire — la
  /// confirmation est posée par `_PhotoFullscreenDialog._confirmAndDelete`
  /// avant d'appeler ce callback. Si tu rajoutes un autre point
  /// d'entrée pour la suppression (ex. swipe-to-delete dans le grid),
  /// ajoute la confirmation côté caller.
  Future<void> _deletePhoto(DocItem doc) async {
    await _dataService.deleteDocument(doc.id);
    await _refresh();
  }

  /// Réordonne deux photos d'une même catégorie : la photo d'index
  /// [fromIndex] est insérée à la position [toIndex] (les autres se
  /// décalent). Persisté dans `documents.category_order` via
  /// [DataService.reorderVisitCategoryDocuments] — sera renvoyé au
  /// serveur au prochain push de sync.
  ///
  /// Demande utilisateur 2026-04-28 : "drag to reorder doit resté
  /// parfaitement fonctionnel sur toute la card". On déclenche le
  /// reorder via un `DragTarget` posé sur chaque tile (cf.
  /// `_buildReorderableGrid`).
  Future<void> _reorderWithinCategory({
    required String tag,
    required int fromIndex,
    required int toIndex,
  }) async {
    if (fromIndex == toIndex) return;
    final current = _photosForCategory(tag);
    if (fromIndex < 0 ||
        fromIndex >= current.length ||
        toIndex < 0 ||
        toIndex >= current.length) {
      return;
    }
    final next = List<DocItem>.from(current);
    final moved = next.removeAt(fromIndex);
    next.insert(toIndex, moved);
    await _dataService.reorderVisitCategoryDocuments(
      orderedDocumentIds: next.map((d) => d.id).toList(),
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
    // Layout sur 2 lignes de 3 colonnes (demande utilisateur 2026-04-28) :
    //   Ligne 1 : Logement · Accessibilité · Sanitaires
    //   Ligne 2 : Plan avant travaux · Plan travaux préconisés · Autres
    //
    // Chaque colonne fait 1/3 de la largeur disponible. Le container
    // s'adapte en hauteur à son contenu (pas de stretch). Les photos
    // dans chaque colonne sont posées HORIZONTALEMENT (côte à côte)
    // et se redimensionnent automatiquement pour rentrer toutes dans
    // la largeur du container — pas de scroll, pas de stack vertical.
    final tagsRow1 = kVisitPhotoTags.sublist(0, 3);
    final tagsRow2 = kVisitPhotoTags.sublist(3);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildCategoryRow(tagsRow1),
            const SizedBox(height: 14),
            _buildCategoryRow(tagsRow2),
          ],
        ),
      ),
    );
  }

  /// Construit une ligne de 3 colonnes pour les tags donnés. Chaque
  /// colonne occupe 1/3 de la largeur et appelle `_buildCategorySection`.
  Widget _buildCategoryRow(List<String> tags) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < tags.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(
            child: _buildCategorySection(
              tag: tags[i],
              icon: _iconForCategory(tags[i]),
              maxSlots: kVisitPhotoSlotCount[tags[i]] ?? 0,
            ),
          ),
        ],
      ],
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
      case kPhotoTagPlanAvant:
        return LucideIcons.map;
      case kPhotoTagPlanApres:
        return LucideIcons.layers;
      case kPhotoTagAutres:
        return LucideIcons.folderPlus;
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

    // DragTarget englobe TOUT le container — drop n'importe où dans la
    // section (entête, photos, espace vide, boutons) accepte la photo.
    // Le drop se traduit par `_moveToCategory(doc, newTag = tag)` :
    //   - si l'origine == catégorie courante → no-op (déjà au bon endroit)
    //   - sinon → la photo est re-taggée et apparaît dans cette section.
    //
    // `onWillAcceptWithDetails` highlight la cible quand un drag survole
    // (border violet → bleu pâle), retour à la normale au leave.
    return DragTarget<_DragPhotoPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.fromTag != tag,
      onAcceptWithDetails: (details) async {
        if (details.data.fromTag == tag) return;
        await _moveToCategory(doc: details.data.doc, newTag: tag);
      },
      builder: (context, candidates, rejected) {
        final hovering = candidates.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: hovering
                ? const Color(0xFFEDE8F5)
                : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: hovering
                  ? _kPurple
                  : const Color(0xFFE2E8F0),
              width: hovering ? 2 : 1,
            ),
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
          ),
        ],
      ),
        );
      },
    );
  }

  /// Construit la grille des emplacements pour une catégorie : photos
  /// existantes + slots gris vides (jusqu'à maxSlots). Le tap sur un
  /// slot vide ouvre la galerie ; le drop sur un slot vide importe ou
  /// re-tagge la photo dragguée.
  Widget _buildSlotsGrid({
    required String tag,
    required List<DocItem> photos,
    required int maxSlots,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 6.0;
        final tileWidth = (constraints.maxWidth - 2 * spacing) / 3;
        // Nombre total d'emplacements visibles : au moins maxSlots, et
        // au moins le nombre de photos existantes (au cas où l'ergo a
        // dépassé la capacité — mode « surplus »).
        final totalSlots =
            photos.length > maxSlots ? photos.length : maxSlots;
        final children = <Widget>[];
        for (var i = 0; i < totalSlots; i++) {
          if (i < photos.length) {
            // Slot occupé — tile photo existante.
            children.add(SizedBox(
              width: tileWidth,
              child: _buildOccupiedSlot(
                tag: tag,
                photos: photos,
                index: i,
              ),
            ));
          } else {
            // Slot vide — gris, tappable + DragTarget.
            children.add(SizedBox(
              width: tileWidth,
              child: AspectRatio(
                aspectRatio: 1.0,
                child: _buildEmptySlot(tag: tag),
              ),
            ));
          }
        }
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: children,
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
    final i = index;
    return LayoutBuilder(builder: (context, constraints) {
      final tileWidth = constraints.maxWidth;
      return DragTarget<_DragPhotoPayload>(
        onWillAcceptWithDetails: (details) {
          return details.data.doc.id != photos[i].id;
        },
        onAcceptWithDetails: (details) async {
          final payload = details.data;
          if (payload.fromTag == tag) {
            final fromIdx =
                photos.indexWhere((d) => d.id == payload.doc.id);
            if (fromIdx >= 0) {
              await _reorderWithinCategory(
                tag: tag,
                fromIndex: fromIdx,
                toIndex: i,
              );
            }
          } else {
            await _moveToCategory(
              doc: payload.doc,
              newTag: tag,
            );
          }
        },
        builder: (context, candidates, rejected) {
          final hovering = candidates.isNotEmpty;
          return LongPressDraggable<_DragPhotoPayload>(
            data: _DragPhotoPayload(doc: photos[i], fromTag: tag),
            delay: const Duration(milliseconds: 250),
            feedback: Material(
              color: Colors.transparent,
              elevation: 12,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Opacity(
                opacity: 0.85,
                child: SizedBox(
                  width: tileWidth,
                  child: _PhotoTile(
                    key: ValueKey('photo_drag_${photos[i].id}'),
                    doc: photos[i],
                    onTap: () {},
                    highlight: false,
                  ),
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.3,
              child: _PhotoTile(
                key: ValueKey('photo_ghost_${photos[i].id}'),
                doc: photos[i],
                onTap: () {},
                highlight: false,
              ),
            ),
            child: _PhotoTile(
              key: ValueKey('photo_${photos[i].id}'),
              doc: photos[i],
              onTap: () => _openFullscreenWithDelete(photos[i]),
              highlight: hovering,
            ),
          );
        },
      );
    });
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
          onTap: () => _captureFromSource(
            categoryTag: tag,
            source: ImageSource.gallery,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: hovering
                  ? const Color(0xFFEDE8F5)
                  : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hovering
                    ? _kPurple
                    : const Color(0xFFCBD5E1),
                width: hovering ? 2 : 1,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              LucideIcons.imagePlus,
              size: 22,
              color: hovering ? _kPurple : Colors.grey.shade400,
            ),
          ),
        );
      },
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
      ),
    );
  }

  // _buildAddButton retiré : les boutons « Prendre / Galerie » ont
  // été supprimés au profit du tap sur les slots vides gris (cf.
  // `_buildEmptySlot`). Demande utilisateur 2026-04-28.
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
    // Aucun container visible : pas de Card, pas de border, pas de
    // background. Juste l'image clipée en coins arrondis légers (pour
    // les bords nets sur fond blanc) + un overlay border violet
    // optionnel quand un drag passe au-dessus.
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _PhotoThumbnail(doc: doc),
            ),
            if (highlight)
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF7C6DAA),
                      width: 2,
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

/// Récupère les bytes d'une photo via la chaîne de fallback :
///   1. cache mémoire (`_photoBytesCache`)
///   2. inflight (autre instance en train de fetch)
///   3. `dataUrl` (web upload encore en mémoire) → décodage base64
///   4. `localPath` (native filesystem) → readAsBytes
///   5. `url` (NocoDB signed URL) → MediaCacheService web cache
///      (SQLite-backed, persistant offline-first)
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
        return base64Decode(b64);
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
          final bytes = await MediaCacheService.instance.webCachedFetch(
            url,
            headers: {'X-App-Session': AppConfig.appSessionToken},
          );
          if (bytes != null) return bytes;
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
    _load();
  }

  @override
  void didUpdateWidget(covariant _PhotoThumbnail old) {
    super.didUpdateWidget(old);
    if (old.doc.id != widget.doc.id ||
        old.doc.dataUrl != widget.doc.dataUrl ||
        old.doc.url != widget.doc.url) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    // Cache hit synchrone → render direct, pas de flicker.
    final cached = _photoBytesCache[widget.doc.id];
    if (cached != null) {
      _bytes = cached;
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
        color: const Color(0xFFF1F5F9),
        alignment: Alignment.center,
        child: const Icon(
          LucideIcons.imageOff,
          size: 18,
          color: Color(0xFF94A3B8),
        ),
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

  const _PhotoFullscreenDialog({
    required this.doc,
    this.onDelete,
  });

  @override
  State<_PhotoFullscreenDialog> createState() =>
      _PhotoFullscreenDialogState();
}

class _PhotoFullscreenDialogState extends State<_PhotoFullscreenDialog> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
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

  /// Affiche la confirmation puis délègue à `widget.onDelete` qui se
  /// charge de fermer la dialog après validation. La confirmation
  /// utilise `showSoftDialog` (transitions cohérentes avec le reste
  /// de l'app — cf. `components/soft_transitions.dart`).
  Future<void> _confirmAndDelete(BuildContext context) async {
    final confirm = await showSoftDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Supprimer cette photo ?'),
        content: Text(
          'La photo "${widget.doc.title}" sera supprimée définitivement '
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
                      : const CircularProgressIndicator(
                          color: Colors.white,
                        ),
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
            // Titre de la photo en bas
            Positioned(
              left: 16,
              right: 56,
              bottom: 16,
              child: Text(
                widget.doc.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(
                      offset: Offset(0, 1),
                      blurRadius: 3,
                      color: Colors.black54,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
