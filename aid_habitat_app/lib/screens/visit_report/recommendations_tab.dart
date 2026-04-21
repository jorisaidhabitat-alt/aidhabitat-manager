import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../services/url_resolver.dart';
import '../../services/wiki_repository.dart';
import '../../components/form_widgets.dart';

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
    _saveDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // Pull from server first — dossier GET doesn't include
    // visit_recommendations. Skips if local row is pendingSync.
    try {
      await widget.repository
          .refreshVisitRecommendationsFromRemote(widget.dossier.id);
    } catch (_) {
      // offline
    }
    final items =
        await widget.repository.fetchVisitRecommendations(widget.dossier.id);
    List<WikiItem> wiki = const [];
    try {
      wiki = await _wikiRepo.fetchAllItems();
    } catch (_) {
      // Offline fallback: leave empty.
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _wikiItems = wiki;
      _loaded = true;
    });
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await widget.repository
          .saveVisitRecommendations(widget.dossier.id, _items);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
    final picked = await showDialog<WikiItem>(
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Préconisations de visite',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF334155),
                  ),
                ),
              ),
              if (_saving) const SaveStatusIndicator(saving: true),
            ],
          ),
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
              // à droite de la carte, dans _RecommendationCard).
              buildDefaultDragHandles: false,
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
                backgroundColor: const Color(0xFF907CA1),
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
        color: const Color(0xFFF8FAFC),
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
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Bloc gauche : titre + inputs.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Ligne titre (custom) — sans tag, sans pastille.
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF334155),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: onPickWiki,
                  icon: const Icon(Icons.swap_horiz, size: 14),
                  label: Text(hasWiki
                      ? 'Changer la fiche wiki'
                      : 'Choisir une fiche wiki'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF907CA1),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: Size.zero,
                  ),
                ),
                const SizedBox(height: 12),
                FormTextField(
                  label: 'Titre personnalisé',
                  value: item.customTitle,
                  onChanged: (v) => onChange(item.copyWith(customTitle: v)),
                ),
                const SizedBox(height: 10),
                FormTextField(
                  label: 'Note',
                  value: item.note,
                  maxLines: 3,
                  onChanged: (v) => onChange(item.copyWith(note: v)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          // Bloc droit : drag handle (haut-droite) + grande image.
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Drag handle + bouton supprimer sur la même ligne en haut-
              // droite de la carte.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (reorderable)
                    ReorderableDragStartListener(
                      index: index,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.drag_indicator,
                            size: 20,
                            color: const Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                    ),
                  IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.close, size: 18),
                    color: const Color(0xFF94A3B8),
                    tooltip: 'Supprimer',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: onPickWiki,
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
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
                          color: Color(0xFF907CA1),
                          size: 40,
                        ),
                ),
              ),
            ],
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
                      decoration: InputDecoration(
                        hintText: 'Rechercher (titre, description)',
                        prefixIcon: const Icon(Icons.search),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
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
