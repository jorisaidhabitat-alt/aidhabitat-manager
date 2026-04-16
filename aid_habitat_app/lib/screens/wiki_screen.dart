import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/data_service.dart';
import '../services/wiki_repository.dart';

class WikiScreen extends StatefulWidget {
  const WikiScreen({super.key});

  @override
  State<WikiScreen> createState() => _WikiScreenState();
}

class _WikiScreenState extends State<WikiScreen> {
  final WikiRepository _wikiRepository = WikiRepository();
  final DataService _dataService = DataService();

  List<WikiItem> _items = const [];
  Set<String> _availableTags = {};
  String? _selectedTag;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    try {
      // Load from local SQLite cache immediately.
      final cached = await _wikiRepository.fetchAllItems();
      if (mounted) {
        setState(() {
          _items = cached;
          _availableTags = _extractTags(cached);
          _isLoading = false;
          _error = null;
        });
      }

      // Refresh from remote in background.
      final didRefresh = await _dataService.refreshWikiItemsFromRemote();
      if (!didRefresh || !mounted) return;

      final refreshed = await _wikiRepository.fetchAllItems();
      if (!mounted) return;
      setState(() {
        _items = refreshed;
        _availableTags = _extractTags(refreshed);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = _items.isEmpty ? 'Chargement impossible' : null;
      });
    }
  }

  static Set<String> _extractTags(List<WikiItem> items) {
    final tags = <String>{};
    for (final item in items) {
      tags.addAll(item.tags);
    }
    return tags;
  }

  List<WikiItem> get _filteredItems {
    if (_selectedTag == null) return _items;
    return _items
        .where((item) => item.tags.contains(_selectedTag))
        .toList(growable: false);
  }

  Future<void> _openItem(WikiItem item) async {
    final updated = await showDialog<WikiItem>(
      context: context,
      builder: (context) =>
          _WikiItemDialog(item: item, availableTags: _availableTags.toList()),
    );
    if (updated == null) return;

    setState(() {
      _items = _items
          .map((entry) => entry.id == updated.id ? updated : entry)
          .toList(growable: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final sortedTags = _availableTags.toList()..sort();

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Wiki & Inspiration',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Bibliotheque visuelle pour garder des reperes de solutions.',
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 24),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterChip(
                  label: 'Tous',
                  isActive: _selectedTag == null,
                  onTap: () => setState(() => _selectedTag = null),
                ),
                for (final tag in sortedTags)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _FilterChip(
                      label: tag,
                      isActive: _selectedTag == tag,
                      onTap: () => setState(
                        () => _selectedTag = _selectedTag == tag ? null : tag,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (_error != null && _items.isEmpty)
            Expanded(
              child: Center(
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            )
          else if (_filteredItems.isEmpty)
            const Expanded(child: Center(child: Text('Aucun element trouve')))
          else
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 280,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 20,
                  childAspectRatio: 0.88,
                ),
                itemCount: _filteredItems.length,
                itemBuilder: (context, index) {
                  final item = _filteredItems[index];
                  return InkWell(
                    onTap: () => _openItem(item),
                    borderRadius: BorderRadius.circular(28),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: _colorForCategory(item.category),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: item.imageUrl.isNotEmpty
                                    ? Image.network(
                                        item.imageUrl,
                                        fit: BoxFit.cover,
                                        width: double.infinity,
                                        errorBuilder: (_, __, ___) =>
                                            const Center(
                                              child: Icon(
                                                LucideIcons.image,
                                                size: 42,
                                                color: Colors.black54,
                                              ),
                                            ),
                                      )
                                    : const Center(
                                        child: Icon(
                                          LucideIcons.image,
                                          size: 42,
                                          color: Colors.black54,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item.description.isEmpty
                                ? 'Aucune description'
                                : item.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              height: 1.35,
                            ),
                          ),
                          if (item.tags.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: item.tags
                                  .map(
                                    (tag) => Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF1F5F9),
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        tag,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  static Color _colorForCategory(String category) {
    switch (category.toLowerCase()) {
      case 'salle de bain':
        return const Color(0xFFB9D4C2);
      case 'wc':
        return const Color(0xFFD7CEE6);
      case 'cuisine':
        return const Color(0xFFE2C9B0);
      case 'chambre':
        return const Color(0xFFC5D2D8);
      case 'escaliers & ascenseur':
        return const Color(0xFFE8D5B7);
      default:
        return const Color(0xFFC5D2D8);
    }
  }
}

class _WikiItemDialog extends StatefulWidget {
  const _WikiItemDialog({required this.item, required this.availableTags});

  final WikiItem item;
  final List<String> availableTags;

  @override
  State<_WikiItemDialog> createState() => _WikiItemDialogState();
}

class _WikiItemDialogState extends State<_WikiItemDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late List<String> _selectedTags;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.item.title);
    _descriptionController = TextEditingController(
      text: widget.item.description,
    );
    _selectedTags = [...widget.item.tags];
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFB9D4C2),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: widget.item.imageUrl.isNotEmpty
                        ? Image.network(
                            widget.item.imageUrl,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Icon(
                                LucideIcons.image,
                                size: 72,
                                color: Colors.black54,
                              ),
                            ),
                          )
                        : const Center(
                            child: Icon(
                              LucideIcons.image,
                              size: 72,
                              color: Colors.black54,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Fiche inspiration',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _titleController,
                      decoration: _decoration('Titre'),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: TextField(
                        controller: _descriptionController,
                        maxLines: null,
                        expands: true,
                        decoration: _decoration('Description'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: widget.availableTags
                          .map(
                            (tag) => FilterChip(
                              label: Text(tag),
                              selected: _selectedTags.contains(tag),
                              onSelected: (_) {
                                setState(() {
                                  if (_selectedTags.contains(tag)) {
                                    _selectedTags.remove(tag);
                                  } else {
                                    _selectedTags.add(tag);
                                  }
                                });
                              },
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Fermer'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            Navigator.of(context).pop(
                              widget.item.copyWith(
                                title: _titleController.text.trim(),
                                description: _descriptionController.text.trim(),
                                tags: _selectedTags,
                              ),
                            );
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF907CA1),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Enregistrer'),
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

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF907CA1) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isActive ? const Color(0xFF907CA1) : const Color(0xFFE2E8F0),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.white : const Color(0xFF475569),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
