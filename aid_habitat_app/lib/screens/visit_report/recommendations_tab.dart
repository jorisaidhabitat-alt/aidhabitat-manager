import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../services/save_debounce.dart';
import '../../services/url_resolver.dart';
import '../../services/wiki_repository.dart';
import '../../components/form_widgets.dart';
import '../../components/notes_widget.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
        note: current.note.isNotEmpty ? current.note : picked.description,
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
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

          // ============================================================
          // Bloc « Projet usager » + « Résumé des préconisations »
          // (anciennement onglet Observations, fusionné ici cf. demande
          // utilisateur). Alimente les pages 7 du PDF du rapport.
          //
          // - tabKey 'Préconisations-Projet'   → champ PDF
          //                                      « Projet ou souhait de l'usager »
          // - tabKey 'Préconisations-Résumé'   → champ PDF
          //                                      « Résumé des préconisations »
          //
          // Format identique aux notes des autres onglets : texte +
          // dessin + multi-pages, syncé via le NotesWidget standard.
          // ============================================================
          _buildVadNote(
            tabKey: 'Préconisations-Projet',
            title: 'Projet ou souhait de l’usager',
            subtitle:
                'Ce que le bénéficiaire souhaite obtenir grâce à la visite '
                '(maintien à domicile, aménagement spécifique, plus '
                'd’autonomie pour la toilette…). Apparaîtra page 7 '
                'du rapport.',
          ),
          const SizedBox(height: 20),
          _buildVadNote(
            tabKey: 'Préconisations-Résumé',
            title: 'Résumé des préconisations',
            subtitle:
                'Synthèse rédigée des préconisations majeures à présenter '
                'en amont du détail. Apparaîtra page 7 du rapport, juste '
                'sous le projet usager.',
          ),
          const SizedBox(height: 24),
          const Divider(color: Color(0xFFE2E8F0), height: 1),
          const SizedBox(height: 16),

          if (_items.isEmpty)
            _buildEmpty()
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _items.length,
              onReorder: _reorderItem,
              // Drag handle géré manuellement dans la carte (icône en haut
              // au centre de la carte, dans _RecommendationCard).
              buildDefaultDragHandles: false,
              // Pendant le drag, préserver l'apparence de la carte (radius
              // 24, transparence, légère élévation) — sans proxyDecorator,
              // Flutter entoure la carte d'un Material carré qui casse le
              // border radius arrondi.
              proxyDecorator: (child, index, animation) {
                return Material(
                  color: Colors.transparent,
                  elevation: 4,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: child,
                );
              },
              itemBuilder: (context, i) {
                final item = _items[i];
                return _RecommendationCard(
                  key: ValueKey(item.id),
                  item: item,
                  index: i,
                  reorderable: _items.length > 1,
                  onChange: (updated) => _updateItem(i, updated),
                  onRemove: () => _removeItem(i),
                  onPickWiki: () => _openPicker(i),
                );
              },
            ),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
        ],
      ),
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
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
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
      child: Stack(
        children: [
          // Contenu principal de la carte. Le drag handle est superposé
          // en Align.topCenter (voir plus bas) pour être CENTRÉ
          // horizontalement dans la carte — indépendamment des largeurs
          // relatives titre/image.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InlineTitleField(
                      value: item.customTitle,
                      hint: title.isNotEmpty ? title : 'Titre…',
                      onChanged: (v) =>
                          onChange(item.copyWith(customTitle: v)),
                    ),
                    const SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: onPickWiki,
                      icon: const Icon(Icons.swap_horiz, size: 14),
                      label: Text(hasWiki
                          ? 'Changer la fiche wiki'
                          : 'Choisir une fiche wiki'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF7C6DAA),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: Size.zero,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FormTextField(
                      label: '',
                      value: item.note,
                      maxLines: 3,
                      onChanged: (v) => onChange(item.copyWith(note: v)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Bloc droit : grande image.
          GestureDetector(
            onTap: onPickWiki,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                color: const Color(0xFFF7F7FA),
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.center,
              clipBehavior: Clip.antiAlias,
              child: hasWiki && item.wikiImageUrl.isNotEmpty
                  ? Image.network(
                      resolveMediaUrl(item.wikiImageUrl),
                      fit: BoxFit.cover,
                      width: 180,
                      height: 180,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.image_outlined,
                        color: Color(0xFF94A3B8),
                      ),
                    )
                  : const Icon(
                      Icons.add_photo_alternate_outlined,
                      color: Color(0xFF7C6DAA),
                      size: 40,
                    ),
            ),
          ),
          const SizedBox(width: 4),
          // Bouton supprimer, collé à droite de l'image.
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18),
            color: const Color(0xFF94A3B8),
            tooltip: 'Supprimer',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(
              minWidth: 28,
              minHeight: 28,
            ),
          ),
            ],
          ),
          // Drag handle absolu centré horizontalement en haut — superposé
          // au-dessus du contenu (pas dans la Row) pour être sur l'axe
          // vertical central de la carte.
          if (reorderable)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Center(
                child: ReorderableDragStartListener(
                  index: index,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.drag_handle,
                        size: 22,
                        color: const Color(0xFF94A3B8),
                      ),
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
                    ? Image.network(
                        resolveMediaUrl(it.imageUrl),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Center(
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
