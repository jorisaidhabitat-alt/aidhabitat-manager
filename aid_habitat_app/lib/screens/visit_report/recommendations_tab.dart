import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../services/save_debounce.dart';
import '../../services/url_resolver.dart';
import '../../services/wiki_repository.dart';
import '../../components/brand_colors.dart';
import '../../components/cached_remote_image.dart';
import '../../components/dashed_border_painter.dart';
import '../../components/form_widgets.dart';
import '../../components/soft_transitions.dart';

/// Préconisations tab — parité 1:1 avec `PreconisationsForm` React.
///
/// Chaque préconisation est liée à un item wiki (image + titre + tag). Un
/// "wiki picker" s'ouvre pour chaque item vide : grille d'images filtrable
/// par catégorie et recherche texte. L'utilisateur peut aussi personnaliser
/// le titre affiché (`customTitle`) et ajouter une note libre.
class RecommendationsTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;
  final RecommendationsTabController? controller;

  const RecommendationsTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.controller,
  });

  @override
  State<RecommendationsTab> createState() => _RecommendationsTabState();
}

/// Bridge used by the report screen before PDF generation.
///
/// Recommendations are debounced while the ergo edits titles/notes. Before
/// "Generer", the parent flushes the pending save so the forced sync sends the
/// same list the user sees on screen.
class RecommendationsTabController {
  Future<void> Function()? _flushPendingSave;

  Future<void> flushPendingSave() async {
    final flush = _flushPendingSave;
    if (flush == null) return;
    await flush();
  }

  void _attach(Future<void> Function() flush) {
    _flushPendingSave = flush;
  }

  void _detach(Future<void> Function() flush) {
    if (_flushPendingSave == flush) {
      _flushPendingSave = null;
    }
  }
}

class _RecommendationsTabState extends State<RecommendationsTab>
    with AutomaticKeepAliveClientMixin {
  static const int _maxRecommendations = 8;
  static const Color _recommendationCardBackground = Color(0xFFF2ECF5);

  @override
  bool get wantKeepAlive => true;

  List<VisitRecommendationItem> _items = [];
  List<WikiItem> _wikiItems = [];
  bool _loaded = false;
  final bool _saving = false;
  Timer? _saveDebounce;
  bool _hasPendingSave = false;
  int _saveGeneration = 0;
  Future<void>? _saveInFlight;
  final WikiRepository _wikiRepo = WikiRepository();

  /// Polling cross-device 2 s. Demande utilisateur 2026-05-07 :
  /// les préconisations doivent se synchroniser comme les autres
  /// onglets (avant ce fix, c'était PURE LOCAL — la liste sur
  /// l'autre device n'était mise à jour qu'au reload de l'app).
  ///
  /// Le polling est SAFE grâce aux gardes existantes côté
  /// `refreshVisitRecommendationsFromRemote` (cf. `dossier_repository.
  /// dart`) :
  ///  - skip si `existingSyncState == pendingSync` (modifs locales en
  ///    cours pas encore poussées)
  ///  - merge `[...remoteItems, ...localDrafts]` où localDrafts =
  // _refreshTimer supprimé 2026-05-12 (refactor sync à la (re)connexion).

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(_flushPendingSave);
    _load();
    // Refactor 2026-05-12 : suppression du polling 2 s. Recommandations
    // chargées au mount. Modifs distantes visibles au prochain
    // événement de (re)connexion (foreground/reconnect/login).
  }

  @override
  void didUpdateWidget(covariant RecommendationsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(_flushPendingSave);
      widget.controller?._attach(_flushPendingSave);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(_flushPendingSave);
    // Flush immédiat si un save était en attente (debounce non tiré).
    // Sinon, toute modif dans les 2 dernières secondes avant fermeture
    // de l'onglet / app était perdue.
    final hadPending = _saveDebounce?.isActive ?? false;
    _saveDebounce?.cancel();
    if (hadPending) {
      // Fire-and-forget : on écrit en SQLite local + enqueue sync_op
      // via le repository. Pas de setState (le widget se démonte).
      widget.repository
          .saveVisitRecommendations(widget.dossier.id, _items)
          .catchError((_) {});
    }
    super.dispose();
  }

  // _pollRefresh + _recommendationListsEqual supprimés 2026-05-12
  // (refactor sync à la (re)connexion). Le pull workspace se charge de
  // rafraîchir les recommandations au foreground return / reconnect /
  // login.

  Future<void> _load() async {
    // PURE LOCAL : on affiche ce qui est en SQLite, point. Les éditions
    // locales sont la source de vérité. Le push vers NocoDB continue via
    // le SyncEngine (save = write SQLite + enqueue sync_op + notify),
    // mais aucun pull remote ne peut plus écraser l'état local.
    //
    // Pourquoi pas de refresh remote ici : le mapping remote→local est
    // fragile (id serveur ≠ id local, customTitle en cours d'édition
    // non encore pushé, etc.) et la moindre race condition faisait
    // disparaître des items ou réinitialiser les titres à chaque tab
    // switch. Le compromis : si un second device modifie la liste
    // pendant la session, on ne le verra qu'après un redémarrage de
    // l'app (SyncEngine pull pull côté init).
    final localItems = await widget.repository.fetchVisitRecommendations(
      widget.dossier.id,
    );
    final localWiki = await _wikiRepo.fetchAllItems().catchError((_) {
      return <WikiItem>[];
    });
    final hydratedItems = _hydrateDescriptionsFromWiki(localItems, localWiki);
    final visibleItems = hydratedItems
        .where(_hasSelectedLibraryItem)
        .toList(growable: false);
    final removedEmptyItems = visibleItems.length != hydratedItems.length;
    if (!mounted) return;
    setState(() {
      _items = visibleItems;
      _wikiItems = localWiki;
      _loaded = true;
    });
    if (removedEmptyItems) _scheduleSave();
  }

  bool _hasSelectedLibraryItem(VisitRecommendationItem item) {
    return item.wikiItemId.trim().isNotEmpty ||
        item.wikiTitle.trim().isNotEmpty ||
        item.wikiImageUrl.trim().isNotEmpty;
  }

  List<VisitRecommendationItem> _hydrateDescriptionsFromWiki(
    List<VisitRecommendationItem> items,
    List<WikiItem> wikiItems,
  ) {
    if (items.isEmpty || wikiItems.isEmpty) return items;
    final byId = {
      for (final item in wikiItems)
        if (item.id.trim().isNotEmpty) item.id.trim(): item,
    };
    final byTitle = {
      for (final item in wikiItems)
        if (item.title.trim().isNotEmpty) item.title.trim().toLowerCase(): item,
    };
    return items.map((item) {
      final wiki =
          byId[item.wikiItemId.trim()] ??
          byTitle[item.wikiTitle.trim().toLowerCase()];
      if (wiki == null) return item;
      final descriptions = wiki.descriptionsList;
      final description = descriptions.isNotEmpty
          ? descriptions.first
          : wiki.description.trim();
      if (description.isEmpty || description == item.wikiDescription) {
        return item;
      }
      return item.copyWith(wikiDescription: description);
    }).toList();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _markPendingSave();
    // Debounce uniformisé sur kSaveDebounceText (400 ms) — élimine les
    // races offline où 2 onglets sauvent en parallèle. Le saut de 100ms
    // → 400ms reste imperceptible parce que ConflictAlgorithm.replace
    // collapse les saves successifs en une seule sync_op.
    _saveDebounce = Timer(kSaveDebounceText, _save);
  }

  void _markPendingSave() {
    _hasPendingSave = true;
    _saveGeneration += 1;
  }

  Future<void> _save() {
    if (!mounted) return Future<void>.value();
    final inFlight = _saveInFlight;
    if (inFlight != null) return inFlight;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _saveInFlight = _drainPendingSaves();
    return _saveInFlight!;
  }

  Future<void> _drainPendingSaves() async {
    // Pas de setState(_saving) — voir dossier_screen.dart.
    try {
      while (mounted && _hasPendingSave) {
        final generation = _saveGeneration;
        await widget.repository.saveVisitRecommendations(
          widget.dossier.id,
          _items,
        );
        if (_saveGeneration == generation) {
          _hasPendingSave = false;
        }
      }
    } finally {
      _saveInFlight = null;
      if (mounted && _hasPendingSave) {
        unawaited(_save());
      }
    }
  }

  Future<void> _flushPendingSave() async {
    if (!_hasPendingSave) return;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  Future<void> _addItem() async {
    if (_items.length >= _maxRecommendations) {
      _showMaxRecommendationsReached();
      return;
    }
    final now = DateTime.now().toIso8601String();
    final id = 'rec_${DateTime.now().millisecondsSinceEpoch}_${_items.length}';
    final draft = VisitRecommendationItem(
      id: id,
      createdAt: now,
      updatedAt: now,
    );
    final selected = await _pickLibraryItemFor(draft);
    if (!mounted || selected == null) return;
    setState(() {
      _items = [..._items, selected];
    });
    _scheduleSave();
  }

  void _showMaxRecommendationsReached() {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Maximum 8 préconisations dans le rapport.'),
        ),
      );
  }

  void _updateItem(int index, VisitRecommendationItem updated) {
    if (index < 0 || index >= _items.length) return;
    final nextItem = updated.copyWith(
      updatedAt: DateTime.now().toIso8601String(),
    );
    setState(() {
      final next = List<VisitRecommendationItem>.from(_items);
      next[index] = nextItem;
      _items = next;
    });
    _scheduleSave();
  }

  void _removeItem(int index) {
    if (index < 0 || index >= _items.length) return;
    setState(() {
      _items = List.of(_items)..removeAt(index);
    });
    _scheduleSave();
  }

  void _previewReorderItem(
    String draggedId,
    String targetId,
    bool insertAfter,
  ) {
    if (draggedId == targetId) return;
    final fromIndex = _items.indexWhere((item) => item.id == draggedId);
    final targetIndex = _items.indexWhere((item) => item.id == targetId);
    if (fromIndex < 0 || targetIndex < 0) return;
    final naturalInsertAfter = fromIndex < targetIndex;
    final insertionIndex = targetIndex + (naturalInsertAfter ? 1 : 0);
    final nextIndex = insertionIndex > fromIndex
        ? insertionIndex - 1
        : insertionIndex;
    if (nextIndex == fromIndex) return;
    setState(() {
      final next = List<VisitRecommendationItem>.from(_items);
      final moved = next.removeAt(fromIndex);
      next.insert(nextIndex.clamp(0, next.length), moved);
      _items = next;
    });
  }

  void _commitReorderPreview() {
    _scheduleSave();
  }

  Future<void> _openPicker(int index) async {
    if (index < 0 || index >= _items.length) return;
    final selected = await _pickLibraryItemFor(_items[index]);
    if (selected == null) return;
    _updateItem(index, selected);
  }

  Future<VisitRecommendationItem?> _pickLibraryItemFor(
    VisitRecommendationItem current,
  ) async {
    final picked = await showSoftDialog<WikiItem>(
      context: context,
      builder: (_) => _WikiPickerDialog(items: _wikiItems),
    );
    if (picked == null) return null;

    // Si la fiche wiki a plusieurs descriptions, ouvrir une 2e popup
    // pour choisir exactement celle qui s'applique à cette visite. La
    // première est sélectionnée par défaut.
    final descriptions = picked.descriptionsList;
    String prefillNote = '';
    String wikiDescription = picked.description;
    if (descriptions.length <= 1) {
      wikiDescription = descriptions.isEmpty
          ? picked.description
          : descriptions.first;
    } else {
      if (!mounted) return null;
      final selected = await showSoftDialog<String>(
        context: context,
        builder: (_) => _DescriptionsPickerDialog(
          title: picked.title,
          descriptions: descriptions,
        ),
      );
      if (selected == null) return null;
      prefillNote = selected;
      wikiDescription = selected;
    }

    return current.copyWith(
      wikiItemId: picked.id,
      wikiTitle: picked.title,
      wikiImageUrl: picked.imageUrl,
      wikiTag: picked.tags.isNotEmpty ? picked.tags.first : picked.category,
      wikiDescription: wikiDescription,
      // Pré-remplit le titre personnalisé avec le titre wiki uniquement
      // si l'utilisateur n'a encore rien tapé (ne pas écraser une
      // saisie manuelle).
      customTitle: current.customTitle.isNotEmpty
          ? current.customTitle
          : picked.title,
      // Pour une description simple, on garde la bibliothèque comme
      // source vivante via wikiDescription. Les choix multi-description
      // restent une note dossier, car ils sont spécifiques à la visite.
      note: current.note.isNotEmpty ? current.note : prefillNote,
      updatedAt: DateTime.now().toIso8601String(),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    // Layout — depuis 2026-05-04, l'onglet a été allégé : les 2 cadres
    // notes (Projet de l'usager + Résumé des préconisations) ont
    // déménagé dans le nouvel onglet « Résumé » (cf. summary_tab.dart).
    // Cet onglet ne contient plus que la grille de préconisations avec
    // la card d'ajout intégrée en fin de grille. Les tabKeys
    // 'Préconisations-Projet' et
    // 'Préconisations-Résumé' restent intacts et continuent d'alimenter
    // les pages 7 du PDF — ils sont juste affichés ailleurs maintenant.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Zone scrollable : liste des préconisations + bouton d'ajout.
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_saving)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SaveStatusIndicator(saving: true),
                    ),
                  ),
                // Grille 3 colonnes : chaque préconisation est ajoutée
                // sur la même ligne jusqu'à 3, puis on saute à une
                // nouvelle ligne (demande utilisateur 2026-04-28).
                // La card "Ajouter" reste toujours visible en fin de
                // grille, même après l'ajout d'une préconisation.
                _buildRecommendationsGrid(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Grille 3 colonnes pour les cartes de préconisations, avec
  /// drag-to-reorder fonctionnel sur **toute la carte** via
  /// `LongPressDraggable` + `DragTarget`.
  ///
  /// Comportement :
  ///   - Long press sur n'importe quelle zone d'une carte → début du drag
  ///   - Pendant le drag : la carte source devient semi-transparente,
  ///     un fantôme suit le doigt (Material elevation 12 + radius 16)
  ///   - Pendant le hover sur une autre carte : bordure violette + repère
  ///     latéral indiquant si l'insertion se fera avant ou après la cible
  ///   - Drop : `_reorderItem` est appelé pour réorganiser la liste
  ///     (la carte se retrouve insérée avant/après selon la moitié ciblée)
  ///
  /// Le drag handle dédié (icône en haut de la carte) est masqué — la
  /// carte entière est draggable, plus besoin d'un espace dédié
  /// (demande utilisateur 2026-04-28).
  Widget _buildRecommendationsGrid() {
    const int columns = 3;
    const double gap = 12.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final cardWidth = (available - gap * (columns - 1)) / columns;
        final cardHeight = _recommendationCardHeight(cardWidth);
        final totalItems =
            _items.length + (_items.length < _maxRecommendations ? 1 : 0);
        final rows = totalItems == 0 ? 0 : ((totalItems - 1) ~/ columns) + 1;
        final gridHeight = rows * cardHeight + (rows - 1) * gap;

        return SizedBox(
          height: gridHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (int i = 0; i < _items.length; i++)
                AnimatedPositioned(
                  key: ValueKey('reco_position_${_items[i].id}'),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  left: (i % columns) * (cardWidth + gap),
                  top: (i ~/ columns) * (cardHeight + gap),
                  width: cardWidth,
                  height: cardHeight,
                  child: _DraggableRecoSlot(
                    key: ValueKey('slot-${_items[i].id}'),
                    itemId: _items[i].id,
                    cardWidth: cardWidth,
                    onPreviewReorder: _previewReorderItem,
                    onCommitReorder: _commitReorderPreview,
                    child: _RecommendationCard(
                      key: ValueKey(_items[i].id),
                      item: _items[i],
                      index: i,
                      // Drag handle dédié masqué : la carte entière est
                      // déjà draggable via LongPressDraggable du parent.
                      reorderable: false,
                      onChange: (updated) => _updateItem(i, updated),
                      onRemove: () => _removeItem(i),
                      onPickWiki: () => _openPicker(i),
                    ),
                  ),
                ),
              if (_items.length < _maxRecommendations)
                AnimatedPositioned(
                  key: const ValueKey('reco_add_position'),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  left: (_items.length % columns) * (cardWidth + gap),
                  top: (_items.length ~/ columns) * (cardHeight + gap),
                  width: cardWidth,
                  height: cardHeight,
                  child: _buildAddRecommendationCard(),
                ),
            ],
          ),
        );
      },
    );
  }

  double _recommendationCardHeight(double cardWidth) {
    final imageHeight = (cardWidth - 24) / 1.5;
    return imageHeight + 174;
  }

  Widget _buildAddRecommendationCard() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _addItem,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: _RecommendationsTabState._recommendationCardBackground,
            borderRadius: BorderRadius.circular(16),
          ),
          child: CustomPaint(
            painter: DashedBorderPainter(
              color: kBrandPurple.withValues(alpha: 0.8),
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
                      color: kBrandPurple.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.add, size: 28, color: kBrandPurple),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Ajouter une\npréconisation',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.nunito(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      height: 1.35,
                      letterSpacing: 0,
                      color: kBrandPurple,
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

// =============================================================================
// Recommendation card
// =============================================================================

class _RecommendationCard extends StatelessWidget {
  final VisitRecommendationItem item;
  final int index;
  final bool reorderable;
  final ValueChanged<VisitRecommendationItem> onChange;
  final VoidCallback onRemove;
  final VoidCallback onPickWiki;

  const _RecommendationCard({
    super.key,
    required this.item,
    required this.index,
    required this.reorderable,
    required this.onChange,
    required this.onRemove,
    required this.onPickWiki,
  });

  @override
  Widget build(BuildContext context) {
    final hasWiki = item.wikiItemId.isNotEmpty || item.wikiImageUrl.isNotEmpty;
    // Titre affiché : customTitle si renseigné, sinon le titre de l'item
    // bibliothèque wiki ajouté. Si aucun des deux → titre vide (le TextField
    // "Titre personnalisé" en-dessous reste là pour saisir manuellement).
    final title = item.customTitle.trim().isNotEmpty
        ? item.customTitle.trim()
        : item.wikiTitle.trim();
    final descriptionValue = item.note.trim().isNotEmpty
        ? item.note
        : item.wikiDescription;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _RecommendationsTabState._recommendationCardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ----------------------------------------------------------
          // Image en haut, pleine largeur de la carte, sans fond gris
          // de remplissage (l'image elle-même couvre tout). Aspect
          // ratio 1.5 = compact, gain de hauteur vs carrée.
          // 2 boutons flottants violet clair en haut-droite : modifier
          // la fiche wiki (↻) + supprimer (✕).
          // ----------------------------------------------------------
          Stack(
            children: [
              GestureDetector(
                onTap: onPickWiki,
                child: AspectRatio(
                  aspectRatio: 1.5,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    // Avant 2026-05-04 : Image.network direct → ne gérait
                    // pas correctement le cache local des médias ni les
                    // URLs `data:`. Symptôme rapporté : « les images
                    // s'affichent dans la bibliothèque mais pas dans la
                    // VAD partie préconisations ». CachedRemoteImage est
                    // le même composant que la bibliothèque (cf.
                    // _WikiItemDialogState image side), garantit la parité
                    // de rendu entre les deux écrans + survit au mode
                    // offline grâce au cache MediaCacheService.
                    child: hasWiki && item.wikiImageUrl.isNotEmpty
                        ? CachedRemoteImage(
                            url: resolveMediaUrl(item.wikiImageUrl),
                            fit: BoxFit.cover,
                            errorWidget: const Center(
                              child: Icon(
                                Icons.image_outlined,
                                color: Color(0xFF8A939D),
                              ),
                            ),
                          )
                        : const Center(
                            child: Icon(
                              Icons.add_photo_alternate_outlined,
                              color: kBrandPurple,
                              size: 40,
                            ),
                          ),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2ECF5),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: kBrandPurple,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Material(
                      color: const Color(0xFFF2ECF5),
                      shape: const CircleBorder(),
                      child: InkWell(
                        onTap: onPickWiki,
                        customBorder: const CircleBorder(),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.cached,
                            size: 20,
                            color: kBrandPurple,
                            semanticLabel: hasWiki
                                ? 'Changer la fiche wiki'
                                : 'Choisir une fiche wiki',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Material(
                      color: const Color(0xFFF2ECF5),
                      shape: const CircleBorder(),
                      child: InkWell(
                        onTap: onRemove,
                        customBorder: const CircleBorder(),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(
                            Icons.close,
                            size: 20,
                            color: kBrandPurple,
                            semanticLabel: 'Supprimer',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Titre éditable. Marge réduite avec la description (4 px)
          // pour resserrer le bloc texte (demande utilisateur).
          _InlineTitleField(
            value: item.customTitle,
            hint: title.isNotEmpty ? title : 'Titre…',
            onChanged: (v) => onChange(item.copyWith(customTitle: v)),
          ),
          const SizedBox(height: 4),
          // Description multi-ligne : auto-grow (refonte 2026-05-13).
          // `maxLines: null` = pas de limite haute → toutes les lignes
          // saisies restent visibles. `minLines: 2` = démarre sur
          // 2 lignes pour donner un look « text area ». Radius léger
          // (12px) appliqué automatiquement par FormTextField en mode
          // multi-ligne (vs pill 999 pour single-line).
          FormTextField(
            label: '',
            value: descriptionValue,
            maxLines: null,
            minLines: 2,
            valueSize: 14,
            onChanged: (v) => onChange(item.copyWith(note: v)),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Wiki picker dialog
// =============================================================================

class _WikiPickerDialog extends StatefulWidget {
  final List<WikiItem> items;
  const _WikiPickerDialog({required this.items});

  @override
  State<_WikiPickerDialog> createState() => _WikiPickerDialogState();
}

class _WikiPickerDialogState extends State<_WikiPickerDialog> {
  String _search = '';

  List<WikiItem> get _filtered {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    return widget.items.where((it) {
      if (it.title.toLowerCase().contains(q)) return true;
      if (it.description.toLowerCase().contains(q)) return true;
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: Colors.white,
      // `shape` explicite + `clipBehavior` antiAlias : le `Material`
      // opaque du header (ligne suivante, elevation 1) peignait un
      // rectangle aux angles vifs qui masquait les coins supérieurs
      // arrondis du Dialog, alors que le bas restait correctement
      // arrondi (rien n'y empiète). Sans le clip, on ne pouvait pas
      // forcer le radius côté Material child. Avec le clip, le Dialog
      // découpe lui-même son contenu au shape — radius uniforme sur
      // les 4 coins (demande utilisateur 2026-05-04).
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 800,
        height: 600,
        child: Column(
          children: [
            // Header + barre de recherche : conteneur opaque pour masquer les
            // images qui scrollent en dessous.
            Material(
              color: Colors.white,
              elevation: 1,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Bibliothèque wiki',
                            // Refonte 2026-05-13 : Nunito w700.
                            style: GoogleFonts.nunito(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.25,
                              color: const Color(0xFF2B323A),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                    child: TextField(
                      stylusHandwritingEnabled: true,
                      decoration: InputDecoration(
                        hintText: 'Rechercher (titre, description)',
                        prefixIcon: const Icon(Icons.search),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Color(0xFFB9C0C7)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Color(0xFFB9C0C7)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: kBrandPurple,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                ],
              ),
            ),
            // Grid
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'Aucun résultat.',
                        style: TextStyle(color: Color(0xFF8A939D)),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 0.85,
                          ),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) => _buildTile(filtered[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(WikiItem it) {
    return InkWell(
      onTap: () => Navigator.pop(context, it),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: const Color(0xFFF2F4F6),
                child: it.imageUrl.isNotEmpty
                    ? CachedRemoteImage(
                        url: resolveMediaUrl(it.imageUrl),
                        fit: BoxFit.cover,
                        errorWidget: const Center(
                          child: Icon(
                            Icons.image_outlined,
                            color: Color(0xFF8A939D),
                          ),
                        ),
                      )
                    : const Center(
                        child: Icon(
                          Icons.image_outlined,
                          color: Color(0xFF8A939D),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(
                it.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2B323A),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Titre inline éditable (sans cadre) — utilisé pour le titre de chaque
// préconisation. Stocke dans `customTitle`. Affiche un hint grisé quand
// vide. N'écrase pas la saisie de l'utilisateur quand un rebuild asynchrone
// survient (même logique que FormTextField).
// =============================================================================

class _InlineTitleField extends StatefulWidget {
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;

  const _InlineTitleField({
    required this.value,
    required this.hint,
    required this.onChanged,
  });

  @override
  State<_InlineTitleField> createState() => _InlineTitleFieldState();
}

class _InlineTitleFieldState extends State<_InlineTitleField> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _InlineTitleField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_focusNode.hasFocus) return;
    if (oldWidget.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      maxLines: 2,
      minLines: 1,
      stylusHandwritingEnabled: true,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: Color(0xFF2B323A),
      ),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFB9C0C7)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFB9C0C7)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kBrandPurple, width: 1.5),
        ),
        hintText: widget.hint,
        hintStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Color(0xFF8A939D),
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}

// =============================================================================
// Draggable wrapper around a recommendation card (grid 3 cols)
// =============================================================================

/// Slot draggable + drop target pour une carte de préconisation dans la
/// grille 3 colonnes. Le drag est déclenché par un long press n'importe
/// où sur la carte (pas de handle dédié — demande utilisateur 2026-04-28).
///
/// Visuels pendant le drag :
///   - Carte source : opacité 0.3 (signale qu'elle "voyage")
///   - Fantôme sous le doigt : Material elevation 12 + radius 16
///   - Carte cible (hover) : bordure violette 2 px + radius 16
///
/// Au drop : `onReorder(fromIndex, insertionIndex)` est appelé. La carte
/// déplacée est insérée avant la cible si le drop est sur la moitié gauche,
/// après la cible si le drop est sur la moitié droite.
class _DraggableRecoSlot extends StatefulWidget {
  const _DraggableRecoSlot({
    super.key,
    required this.itemId,
    required this.cardWidth,
    required this.onPreviewReorder,
    required this.onCommitReorder,
    required this.child,
  });

  final String itemId;
  final double cardWidth;
  final void Function(String draggedId, String targetId, bool insertAfter)
  onPreviewReorder;
  final VoidCallback onCommitReorder;
  final Widget child;

  @override
  State<_DraggableRecoSlot> createState() => _DraggableRecoSlotState();
}

class _DraggableRecoSlotState extends State<_DraggableRecoSlot> {
  bool? _insertAfter;

  bool _isAfterTarget(Offset globalOffset) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final local = renderObject.globalToLocal(globalOffset);
    return local.dx > renderObject.size.width / 2;
  }

  bool _isCloseEnoughToTarget(Offset globalOffset) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    // DragTargetDetails.offset correspond au coin du feedback dans
    // plusieurs plateformes Flutter. On teste donc le centre du clone,
    // pas seulement ce coin, sinon le reorder devient quasi impossible.
    final centerOffset = globalOffset + renderObject.size.center(Offset.zero);
    final local = renderObject.globalToLocal(centerOffset);
    final normalizedX = local.dx / renderObject.size.width;
    final normalizedY = local.dy / renderObject.size.height;
    return normalizedX >= 0.24 &&
        normalizedX <= 0.76 &&
        normalizedY >= 0.24 &&
        normalizedY <= 0.76;
  }

  void _updateInsertionSide(Offset globalOffset) {
    final next = _isAfterTarget(globalOffset);
    if (_insertAfter == next) return;
    setState(() => _insertAfter = next);
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) {
        // On accepte tout sauf un drop sur soi-même.
        return details.data != widget.itemId;
      },
      onMove: (details) {
        if (!_isCloseEnoughToTarget(details.offset)) return;
        _updateInsertionSide(details.offset);
        widget.onPreviewReorder(
          details.data,
          widget.itemId,
          _isAfterTarget(details.offset),
        );
      },
      onLeave: (_) {
        if (_insertAfter != null) {
          setState(() => _insertAfter = null);
        }
      },
      onAcceptWithDetails: (details) {
        if (_insertAfter != null) {
          setState(() => _insertAfter = null);
        }
      },
      builder: (context, candidates, rejected) {
        final highlight = Stack(
          clipBehavior: Clip.none,
          children: [widget.child],
        );
        return MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Draggable<String>(
            data: widget.itemId,
            feedbackOffset: Offset.zero,
            hitTestBehavior: HitTestBehavior.opaque,
            maxSimultaneousDrags: 1,
            onDragEnd: (_) => widget.onCommitReorder(),
            // Le fantôme garde exactement le même fond violet clair que
            // la carte réelle. Pas d'opacité ni de voile sombre pendant
            // le déplacement.
            feedback: Material(
              color: Colors.transparent,
              elevation: 0,
              shadowColor: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Container(
                width: widget.cardWidth,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 28,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: widget.child,
              ),
            ),
            // La carte d'origine reste pleine couleur : l'utilisateur
            // voit uniquement les autres éléments coulisser, sans trou
            // sombre ni placeholder transparent.
            childWhenDragging: widget.child,
            child: highlight,
          ),
        );
      },
    );
  }
}

// =============================================================================
// Descriptions picker dialog — apparaît APRÈS le wiki picker quand la
// fiche choisie contient plusieurs descriptions (cf.
// WikiItem.descriptionsList). L'ergo en choisit une seule pour
// pré-remplir la note de la préconisation. La première est sélectionnée
// par défaut, puis chaque nouveau choix remplace le précédent.
// =============================================================================

class _DescriptionsPickerDialog extends StatefulWidget {
  final String title;
  final List<String> descriptions;
  const _DescriptionsPickerDialog({
    required this.title,
    required this.descriptions,
  });

  @override
  State<_DescriptionsPickerDialog> createState() =>
      _DescriptionsPickerDialogState();
}

class _DescriptionsPickerDialogState extends State<_DescriptionsPickerDialog> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.descriptions.isEmpty ? -1 : 0;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      'Choisir les descriptions',
                      // Refonte 2026-05-13 : Nunito w700.
                      style: GoogleFonts.nunito(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.25,
                        color: const Color(0xFF0E1116),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.title,
                style: const TextStyle(fontSize: 13, color: Color(0xFF5C6670)),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.descriptions.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final selected = _selectedIndex == i;
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() => _selectedIndex = i);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFFF5F0FA)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected ? kBrandPurple : Color(0xFFB9C0C7),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 20,
                              height: 20,
                              margin: const EdgeInsets.only(top: 1),
                              decoration: BoxDecoration(
                                color: selected ? kBrandPurple : Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selected
                                      ? kBrandPurple
                                      : Color(0xFF8A939D),
                                  width: 1.5,
                                ),
                              ),
                              child: selected
                                  ? const Icon(
                                      Icons.circle,
                                      size: 8,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.descriptions[i],
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF2B323A),
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Annuler'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kBrandPurple,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      if (_selectedIndex < 0 ||
                          _selectedIndex >= widget.descriptions.length) {
                        Navigator.pop(context);
                        return;
                      }
                      Navigator.pop(
                        context,
                        widget.descriptions[_selectedIndex],
                      );
                    },
                    child: const Text('Valider'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
