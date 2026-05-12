import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/connectivity_service.dart';
import '../../services/dossier_repository.dart';
import '../../services/save_debounce.dart';
import '../../services/url_resolver.dart';
import '../../services/wiki_repository.dart';
import '../../components/cached_remote_image.dart';
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

  const RecommendationsTab({
    super.key,
    required this.dossier,
    required this.repository,
  });

  @override
  State<RecommendationsTab> createState() => _RecommendationsTabState();
}

class _RecommendationsTabState extends State<RecommendationsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<VisitRecommendationItem> _items = [];
  List<WikiItem> _wikiItems = [];
  bool _loaded = false;
  bool _saving = false;
  Timer? _saveDebounce;
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
  ///    items sans `wikiItemId` (= picker pas encore validé) — ne
  ///    sont jamais écrasés par le remote
  ///
  /// On ajoute un garde-fou supplémentaire ici : skip si l'utilisateur
  /// a un save en attente (`_saveDebounce.isActive`) ou en flight
  /// (`_saving`) → on ne touche pas à `_items` pendant qu'il édite.
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // Refactor 2026-05-12 : suppression du polling 2 s. Recommandations
    // chargées au mount. Modifs distantes visibles au prochain
    // événement de (re)connexion (foreground/reconnect/login).
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
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

  /// Tick de polling cross-device : refresh remote → relit SQLite
  /// → met à jour `_items` si changement. Best-effort, swallows
  /// errors. Ne touche RIEN si la fetch remote échoue (offline,
  /// 5xx, etc.) — on garde l'état local courant.
  Future<void> _pollRefresh() async {
    try {
      final didRefresh = await widget.repository
          .refreshVisitRecommendationsFromRemote(widget.dossier.id);
      if (!mounted) return;
      // Re-checks après l'await : utilisateur peut avoir commencé à
      // éditer pendant la requête HTTP (~500ms-1s).
      if (_saveDebounce?.isActive == true) return;
      if (_saving) return;
      if (!didRefresh) return;
      final fresh = await widget.repository
          .fetchVisitRecommendations(widget.dossier.id);
      if (!mounted) return;
      if (_saveDebounce?.isActive == true) return;
      if (_saving) return;
      // Diff léger : on ne setState que si la liste a vraiment changé,
      // sinon on déclenche un rebuild inutile à chaque tick.
      if (_recommendationListsEqual(_items, fresh)) return;
      setState(() => _items = fresh);
    } catch (_) {
      // best-effort : un échec ponctuel ne casse rien.
    }
  }

  /// Compare deux listes d'items recommandation. Renvoie true si
  /// strictement identiques (mêmes ids dans le même ordre, mêmes
  /// champs serializables). Utilisé pour skipper les setState
  /// no-op côté polling.
  bool _recommendationListsEqual(
    List<VisitRecommendationItem> a,
    List<VisitRecommendationItem> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id) return false;
      if (x.wikiItemId != y.wikiItemId) return false;
      if (x.customTitle != y.customTitle) return false;
      if (x.note != y.note) return false;
    }
    return true;
  }

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
    final localItems =
        await widget.repository.fetchVisitRecommendations(widget.dossier.id);
    final localWiki = await _wikiRepo.fetchAllItems().catchError((_) {
      return <WikiItem>[];
    });
    if (!mounted) return;
    setState(() {
      _items = localItems;
      _wikiItems = localWiki;
      _loaded = true;
    });
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    // Debounce uniformisé sur kSaveDebounceText (400 ms) — élimine les
    // races offline où 2 onglets sauvent en parallèle. Le saut de 100ms
    // → 400ms reste imperceptible parce que ConflictAlgorithm.replace
    // collapse les saves successifs en une seule sync_op.
    _saveDebounce = Timer(kSaveDebounceText, _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    // Pas de setState(_saving) — voir dossier_screen.dart.
    await widget.repository
        .saveVisitRecommendations(widget.dossier.id, _items);
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  void _addItem() {
    final now = DateTime.now().toIso8601String();
    final id =
        'rec_${DateTime.now().millisecondsSinceEpoch}_${_items.length}';
    setState(() {
      _items = [
        ..._items,
        VisitRecommendationItem(
          id: id,
          createdAt: now,
          updatedAt: now,
        ),
      ];
    });
    _scheduleSave();
    // Auto-open picker for the newly added item.
    Future.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _openPicker(_items.length - 1);
    });
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

  /// Déplace un item depuis [oldIndex] vers [newIndex] (insertion au
  /// nouvel index après suppression). Utilisé par le drag-to-reorder
  /// custom de la grille 3 colonnes (cf. `_buildRecommendationsGrid`).
  void _reorderItem(int oldIndex, int newIndex) {
    setState(() {
      final next = List<VisitRecommendationItem>.from(_items);
      if (newIndex > oldIndex) newIndex -= 1;
      final moved = next.removeAt(oldIndex);
      next.insert(newIndex, moved);
      _items = next;
    });
    _scheduleSave();
  }

  Future<void> _openPicker(int index) async {
    if (index < 0 || index >= _items.length) return;
    final picked = await showSoftDialog<WikiItem>(
      context: context,
      builder: (_) => _WikiPickerDialog(items: _wikiItems),
    );
    if (picked == null) return;
    final current = _items[index];

    // Si la fiche wiki a plusieurs descriptions (demande utilisateur
    // 2026-05-04), ouvrir une 2e popup avec checkboxes pour permettre
    // à l'ergo de choisir celles qui s'appliquent. Une seule
    // description → comportement historique (pré-remplissage direct).
    final descriptions = picked.descriptionsList;
    String prefillNote = '';
    if (descriptions.length <= 1) {
      prefillNote = descriptions.isEmpty ? '' : descriptions.first;
    } else {
      if (!mounted) return;
      final selected = await showSoftDialog<List<String>>(
        context: context,
        builder: (_) => _DescriptionsPickerDialog(
          title: picked.title,
          descriptions: descriptions,
        ),
      );
      // Annulation → on garde la fiche choisie mais sans pré-remplir
      // la note (l'ergo pourra la rééditer). Si selected est vide
      // (toutes décochées), idem note vide.
      if (selected != null && selected.isNotEmpty) {
        // Format : 1 description par ligne, séparées par une ligne
        // vide pour respirer (le TextField multi-lignes du card les
        // affichera l'une sous l'autre, modifiables).
        prefillNote = selected.join('\n\n');
      }
    }

    _updateItem(
      index,
      current.copyWith(
        wikiItemId: picked.id,
        wikiTitle: picked.title,
        wikiImageUrl: picked.imageUrl,
        wikiTag: picked.tags.isNotEmpty ? picked.tags.first : picked.category,
        // Pré-remplit le titre personnalisé avec le titre wiki uniquement
        // si l'utilisateur n'a encore rien tapé (ne pas écraser une
        // saisie manuelle).
        customTitle:
            current.customTitle.isNotEmpty ? current.customTitle : picked.title,
        // Only pre-fill note if empty (don't overwrite user input).
        note: current.note.isNotEmpty ? current.note : prefillNote,
      ),
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
    // Cet onglet ne contient plus que la grille de préconisations + le
    // bouton d'ajout. Les tabKeys 'Préconisations-Projet' et
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
                if (_items.isEmpty)
                  _buildEmpty()
                else
                  // Grille 3 colonnes : chaque préconisation est ajoutée
                  // sur la même ligne jusqu'à 3, puis on saute à une
                  // nouvelle ligne (demande utilisateur 2026-04-28).
                  // Le drag-to-reorder est désactivé dans ce mode (la
                  // grille manuelle Row+Expanded est incompatible avec
                  // ReorderableListView qui est mono-axial).
                  _buildRecommendationsGrid(),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ElevatedButton.icon(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Ajouter une préconisation'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C6DAA),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
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
  ///   - Pendant le hover sur une autre carte : bordure violette qui
  ///     indique le slot d'insertion
  ///   - Drop : `_reorderItem` est appelé pour réorganiser la liste
  ///     (la carte se retrouve insérée AVANT la carte cible)
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
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (int i = 0; i < _items.length; i++)
              SizedBox(
                width: cardWidth,
                child: _DraggableRecoSlot(
                  key: ValueKey('slot-${_items[i].id}'),
                  index: i,
                  cardWidth: cardWidth,
                  itemsCount: _items.length,
                  onReorder: _reorderItem,
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
          ],
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Container(
      padding: const EdgeInsets.all(24),
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7FA),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Column(
        children: [
          Icon(Icons.auto_awesome_outlined,
              size: 36, color: Color(0xFF94A3B8)),
          SizedBox(height: 8),
          Text(
            'Aucune préconisation pour l\'instant.',
            style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
          ),
        ],
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFE2E8F0),
          width: 1,
        ),
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
                                color: Color(0xFF94A3B8),
                              ),
                            ),
                          )
                        : const Center(
                            child: Icon(
                              Icons.add_photo_alternate_outlined,
                              color: Color(0xFF7C6DAA),
                              size: 40,
                            ),
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
                      color: const Color(0xFFEDE8F5),
                      shape: const CircleBorder(),
                      child: InkWell(
                        onTap: onPickWiki,
                        customBorder: const CircleBorder(),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.cached,
                            size: 20,
                            color: const Color(0xFF7C6DAA),
                            semanticLabel: hasWiki
                                ? 'Changer la fiche wiki'
                                : 'Choisir une fiche wiki',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Material(
                      color: const Color(0xFFEDE8F5),
                      shape: const CircleBorder(),
                      child: InkWell(
                        onTap: onRemove,
                        customBorder: const CircleBorder(),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(
                            Icons.close,
                            size: 20,
                            color: Color(0xFF7C6DAA),
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
          // Description : fontSize 14 (vs 12 par défaut). 4 lignes max
          // (relevé 2026-05-04 : permet d'afficher 2-3 descriptions
          // sélectionnées depuis une fiche multi-descriptions sans
          // troncature visuelle, tout en gardant la grille compacte).
          // Le contenu reste scroll dans le champ si plus de 4 lignes.
          FormTextField(
            label: '',
            value: item.note,
            maxLines: 4,
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
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
                        const Expanded(
                          child: Text(
                            'Bibliothèque wiki',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF334155),
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
                        fillColor: const Color(0xFFF7F7FA),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
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
                        style: TextStyle(color: Color(0xFF94A3B8)),
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
                      itemBuilder: (context, i) =>
                          _buildTile(filtered[i]),
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
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
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
                color: const Color(0xFFF1F5F9),
                child: it.imageUrl.isNotEmpty
                    ? CachedRemoteImage(
                        url: resolveMediaUrl(it.imageUrl),
                        fit: BoxFit.cover,
                        errorWidget: const Center(
                          child: Icon(Icons.image_outlined,
                              color: Color(0xFF94A3B8)),
                        ),
                      )
                    : const Center(
                        child: Icon(Icons.image_outlined,
                            color: Color(0xFF94A3B8)),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 8),
              child: Text(
                it.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF334155),
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
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Color(0xFF334155),
      ),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
        focusedBorder: InputBorder.none,
        enabledBorder: InputBorder.none,
        hintText: widget.hint,
        hintStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: Color(0xFF94A3B8),
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
/// Au drop : `onReorder(fromIndex, toIndex)` est appelé. La carte
/// déplacée est insérée AVANT la carte cible. Pour mettre une carte
/// tout à la fin, l'ergo peut la déposer sur la dernière + utiliser
/// l'ordre naturel (les cards sont 1-3-5 par ligne, pas de slot
/// fantôme final pour le moment).
class _DraggableRecoSlot extends StatelessWidget {
  const _DraggableRecoSlot({
    super.key,
    required this.index,
    required this.cardWidth,
    required this.itemsCount,
    required this.onReorder,
    required this.child,
  });

  final int index;
  final double cardWidth;
  final int itemsCount;
  final void Function(int oldIndex, int newIndex) onReorder;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) {
        // On accepte tout sauf un drop sur soi-même.
        return details.data != index;
      },
      onAcceptWithDetails: (details) {
        final from = details.data;
        // L'index "newIndex" attendu par `_reorderItem` est l'index
        // d'INSERTION dans la liste post-removal — donc juste `index`.
        onReorder(from, index);
      },
      builder: (context, candidates, rejected) {
        final isHovered = candidates.isNotEmpty;
        final highlight = Container(
          decoration: isHovered
              ? BoxDecoration(
                  border: Border.all(
                    color: const Color(0xFF7C6DAA),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(16),
                )
              : null,
          child: child,
        );
        return LongPressDraggable<int>(
          data: index,
          // Délai court — réactivité améliorée sur tactile sans
          // déclencher de drags accidentels lors de simples taps.
          delay: const Duration(milliseconds: 250),
          // Le fantôme est un clone visuel de la carte avec une
          // élévation prononcée pour suggérer "elle flotte".
          feedback: Material(
            color: Colors.transparent,
            elevation: 12,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: cardWidth, child: child),
          ),
          // Pendant que la carte est draggée, la version "originale"
          // reste à sa place (pour préserver le layout de la grille)
          // mais en semi-transparence.
          childWhenDragging: Opacity(opacity: 0.3, child: child),
          child: highlight,
        );
      },
    );
  }
}

// =============================================================================
// Descriptions picker dialog — apparaît APRÈS le wiki picker quand la
// fiche choisie contient plusieurs descriptions (cf.
// WikiItem.descriptionsList). L'ergo coche celle(s) qu'il veut voir
// pré-remplies dans la note de la préconisation. Toutes cochées par
// défaut. Les descriptions sélectionnées sont jointes par un saut de
// ligne double avant d'alimenter le champ note (modifiable ensuite
// depuis la card).
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
  late Set<int> _selectedIndexes;

  @override
  void initState() {
    super.initState();
    // Toutes cochées par défaut — l'ergo décoche celles qui ne
    // s'appliquent pas plutôt que de tout cocher manuellement.
    _selectedIndexes = Set<int>.from(
      List<int>.generate(widget.descriptions.length, (i) => i),
    );
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
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
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
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF64748B),
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.descriptions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final selected = _selectedIndexes.contains(i);
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() {
                          if (selected) {
                            _selectedIndexes.remove(i);
                          } else {
                            _selectedIndexes.add(i);
                          }
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFFF5F0FA)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFF7C6DAA)
                                : Colors.grey.shade300,
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
                                color: selected
                                    ? const Color(0xFF7C6DAA)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: selected
                                      ? const Color(0xFF7C6DAA)
                                      : Colors.grey.shade400,
                                  width: 1.5,
                                ),
                              ),
                              child: selected
                                  ? const Icon(Icons.check,
                                      size: 14, color: Colors.white)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.descriptions[i],
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF334155),
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
                      backgroundColor: const Color(0xFF7C6DAA),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      // On renvoie les descriptions sélectionnées
                      // dans l'ordre original (pas l'ordre de clic).
                      final selected = <String>[];
                      for (var i = 0; i < widget.descriptions.length; i++) {
                        if (_selectedIndexes.contains(i)) {
                          selected.add(widget.descriptions[i]);
                        }
                      }
                      Navigator.pop(context, selected);
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
