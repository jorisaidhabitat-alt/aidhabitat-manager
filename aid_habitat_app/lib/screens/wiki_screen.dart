import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

class WikiScreen extends StatefulWidget {
  const WikiScreen({super.key});

  @override
  State<WikiScreen> createState() => _WikiScreenState();
}

class _WikiScreenState extends State<WikiScreen> {
  static const List<String> _availableTags = [
    'Douche PMR',
    'WC PMR',
    'Rampe d\'accès',
    'Monte escalier',
    'Sol anti derapant',
    'Barre d\'appui',
  ];

  final List<_WikiItem> _items = [
    const _WikiItem(
      id: 'wiki_1',
      title: 'Douche PMR',
      description:
          'Douche de plain-pied avec siège rabattable et barre d’appui.',
      tags: ['Douche PMR'],
      accentColor: Color(0xFFB9D4C2),
    ),
    const _WikiItem(
      id: 'wiki_2',
      title: 'Rampe d’accès',
      description: 'Rampe antidérapante pour franchissement de seuil.',
      tags: ['Rampe d\'accès'],
      accentColor: Color(0xFFE2C9B0),
    ),
    const _WikiItem(
      id: 'wiki_3',
      title: 'Barre d’appui',
      description: 'Barre coudée 135° pour transfert toilette.',
      tags: ['Barre d\'appui'],
      accentColor: Color(0xFFD7CEE6),
    ),
  ];

  String? _selectedTag;

  List<_WikiItem> get _filteredItems {
    if (_selectedTag == null) return _items;
    return _items
        .where((item) => item.tags.contains(_selectedTag))
        .toList(growable: false);
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return;

    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) return;

    setState(() {
      _items.insert(
        0,
        _WikiItem(
          id: 'wiki_${DateTime.now().millisecondsSinceEpoch}',
          title: file.name.split('.').first,
          description: '',
          tags: const [],
          accentColor: const Color(0xFFC5D2D8),
          imageBytes: bytes,
        ),
      );
    });
  }

  Future<void> _openItem(_WikiItem item) async {
    final updated = await showDialog<_WikiItem>(
      context: context,
      builder: (context) =>
          _WikiItemDialog(item: item, availableTags: _availableTags),
    );
    if (updated == null) return;

    setState(() {
      final index = _items.indexWhere((entry) => entry.id == updated.id);
      if (index >= 0) {
        _items[index] = updated;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
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
            'Bibliothèque visuelle locale pour garder des repères de solutions.',
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
                for (final tag in _availableTags)
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
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 280,
                mainAxisSpacing: 20,
                crossAxisSpacing: 20,
                childAspectRatio: 0.88,
              ),
              itemCount: _filteredItems.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _AddWikiCard(onTap: _pickImage);
                }

                final item = _filteredItems[index - 1];
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
                              color: item.accentColor,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: item.imageBytes != null
                                  ? Image.memory(
                                      item.imageBytes!,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
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
}

class _WikiItemDialog extends StatefulWidget {
  const _WikiItemDialog({required this.item, required this.availableTags});

  final _WikiItem item;
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
                    color: widget.item.accentColor,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: widget.item.imageBytes != null
                        ? Image.memory(
                            widget.item.imageBytes!,
                            fit: BoxFit.contain,
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

class _AddWikiCard extends StatelessWidget {
  const _AddWikiCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.plusCircle, size: 46, color: Color(0xFF907CA1)),
            SizedBox(height: 14),
            Text(
              'Ajouter une image',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
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

class _WikiItem {
  const _WikiItem({
    required this.id,
    required this.title,
    required this.description,
    required this.tags,
    required this.accentColor,
    this.imageBytes,
  });

  final String id;
  final String title;
  final String description;
  final List<String> tags;
  final Color accentColor;
  final Uint8List? imageBytes;

  _WikiItem copyWith({String? title, String? description, List<String>? tags}) {
    return _WikiItem(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      tags: tags ?? this.tags,
      accentColor: accentColor,
      imageBytes: imageBytes,
    );
  }
}
