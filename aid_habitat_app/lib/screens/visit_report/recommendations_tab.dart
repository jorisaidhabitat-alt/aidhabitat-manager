import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

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

class _RecommendationsTabState extends State<RecommendationsTab> {
  List<VisitRecommendationItem> _items = [];
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadItems() async {
    final items = await widget.repository.fetchVisitRecommendations(widget.dossier.id);
    if (mounted) {
      setState(() => _items = items);
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      widget.repository.saveVisitRecommendations(widget.dossier.id, _items);
    });
  }

  void _addItem() {
    final now = DateTime.now().toIso8601String();
    final newItem = VisitRecommendationItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      wikiTitle: '',
      wikiTag: '',
      note: '',
      createdAt: now,
      updatedAt: now,
    );
    setState(() => _items = [..._items, newItem]);
    _scheduleSave();
  }

  void _updateItem(int index, VisitRecommendationItem updated) {
    setState(() {
      _items = List.of(_items);
      _items[index] = updated;
    });
    _scheduleSave();
  }

  void _removeItem(int index) {
    setState(() {
      _items = List.of(_items)..removeAt(index);
    });
    _scheduleSave();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Préconisations de visite',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF334155),
            ),
          ),
          const SizedBox(height: 16),
          ..._items.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;
            return _RecommendationCard(
              key: ValueKey(item.id),
              item: item,
              onChanged: (updated) => _updateItem(index, updated),
              onDelete: () => _removeItem(index),
            );
          }),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _addItem,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Ajouter une préconisation'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF907CA1),
                side: const BorderSide(color: Color(0xFF907CA1)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  final VisitRecommendationItem item;
  final ValueChanged<VisitRecommendationItem> onChanged;
  final VoidCallback onDelete;

  const _RecommendationCard({
    super.key,
    required this.item,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Préconisation',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF334155),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: const Color(0xFFEF4444),
                  tooltip: 'Supprimer',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FormTextField(
              label: 'Titre wiki',
              value: item.wikiTitle,
              onChanged: (v) => onChanged(VisitRecommendationItem(
                id: item.id,
                wikiItemId: item.wikiItemId,
                wikiTitle: v,
                wikiImageUrl: item.wikiImageUrl,
                wikiTag: item.wikiTag,
                note: item.note,
                createdAt: item.createdAt,
                updatedAt: DateTime.now().toIso8601String(),
              )),
            ),
            const SizedBox(height: 8),
            FormTextField(
              label: 'Tag wiki',
              value: item.wikiTag,
              onChanged: (v) => onChanged(VisitRecommendationItem(
                id: item.id,
                wikiItemId: item.wikiItemId,
                wikiTitle: item.wikiTitle,
                wikiImageUrl: item.wikiImageUrl,
                wikiTag: v,
                note: item.note,
                createdAt: item.createdAt,
                updatedAt: DateTime.now().toIso8601String(),
              )),
            ),
            const SizedBox(height: 8),
            FormTextField(
              label: 'Note',
              value: item.note,
              maxLines: 3,
              onChanged: (v) => onChanged(VisitRecommendationItem(
                id: item.id,
                wikiItemId: item.wikiItemId,
                wikiTitle: item.wikiTitle,
                wikiImageUrl: item.wikiImageUrl,
                wikiTag: item.wikiTag,
                note: v,
                createdAt: item.createdAt,
                updatedAt: DateTime.now().toIso8601String(),
              )),
            ),
          ],
        ),
      ),
    );
  }
}
