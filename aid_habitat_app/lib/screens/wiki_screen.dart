import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  /// Combined tag + search filter, matching the React `filteredItems` useMemo:
  /// haystack = "title description tags.join(' ')" lowercased.
  List<WikiItem> get _filteredItems {
    final search = _searchTerm.trim().toLowerCase();
    return _items.where((item) {
      final matchesTag =
          _selectedTag == null || item.tags.contains(_selectedTag);
      if (!matchesTag) return false;
      if (search.isEmpty) return true;
      final haystack = '${item.title} ${item.description} ${item.tags.join(' ')}'
          .toLowerCase();
      return haystack.contains(search);
    }).toList(growable: false);
  }

  Future<void> _openItem(WikiItem item) async {
    final updated = await showDialog<WikiItem>(
      context: context,
      builder: (context) =>
          _WikiItemDialog(item: item, availableTags: _availableTags.toList()),
    );
    if (updated == null) return;

    try {
      final saved = await _dataService.updateWikiItem(updated);
      if (!mounted) return;
      setState(() {
        _items = _items
            .map((entry) => entry.id == saved.id ? saved : entry)
            .toList(growable: false);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _items = _items
            .map((entry) => entry.id == updated.id ? updated : entry)
            .toList(growable: false);
      });
    }
  }

  Future<void> _createItem() async {
    final draft = await showDialog<_WikiItemDraft>(
      context: context,
      builder: (context) =>
          _WikiCreateDialog(availableTags: _availableTags),
    );
    if (draft == null) return;

    try {
      final created = await _dataService.createWikiItem(
        title: draft.title,
        description: draft.description,
        category: draft.category,
        tags: draft.tags,
        imageDataUrl: draft.imageDataUrl,
      );
      if (!mounted) return;
      setState(() {
        _items = [created, ..._items];
      });
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Création impossible : $err')),
      );
    }
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
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  // Grille responsive : 5 col large, 4 moyen, 3 tablette, 2 mobile.
                  final crossAxis = constraints.maxWidth > 1200
                      ? 5
                      : constraints.maxWidth > 900
                          ? 4
                          : constraints.maxWidth > 600
                              ? 3
                              : 2;
                  return GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxis,
                  mainAxisSpacing: 24,
                  crossAxisSpacing: 24,
                  // Card layout: padding(16) + image(square, ~W-32) + gap(16) +
                  // title(~22) + gap(4) + subtitle(~14) + padding(16). Ratio
                  // must leave enough vertical room for the text below.
                  childAspectRatio: 0.68,
                ),
                itemCount: _filteredItems.length,
                itemBuilder: (context, index) {
                  final item = _filteredItems[index];
                  final primaryTag = item.tags.isNotEmpty ? item.tags.first : null;
                  return InkWell(
                    onTap: () => _openItem(item),
                    borderRadius: BorderRadius.circular(28),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(28),
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
                                    )
                                  else
                                    const Center(
                                      child: Icon(
                                        LucideIcons.image,
                                        size: 42,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  // ring-1 ring-black/10 equivalent
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: Colors.black.withValues(
                                              alpha: 0.1,
                                            ),
                                            width: 1,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Tag badge overlay bottom-left
                                  if (primaryTag != null)
                                    Positioned(
                                      left: 8,
                                      bottom: 8,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.55,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: Text(
                                          primaryTag,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                          if (primaryTag != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              primaryTag.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF94A3B8),
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              );
                },
              ),
            ),
            ],
          ),
        ),
        // Floating "+" button (FAB) bottom-right, matches the React layout.
        Positioned(
          right: 24,
          bottom: 24,
          child: Tooltip(
            message: 'Ajouter un élément',
            child: FloatingActionButton(
              onPressed: _createItem,
              backgroundColor: const Color(0xFF907CA1),
              foregroundColor: Colors.white,
              elevation: 4,
              child: const Icon(LucideIcons.plus, size: 28),
            ),
          ),
        ),
      ],
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
    final selectedTag = _selectedTags.isNotEmpty ? _selectedTags.first : '';

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 720),
        child: Stack(
          children: [
            Row(
              children: [
                // Left side: image on neutral slate-100 background (matches React)
                Expanded(
                  flex: 2,
                  child: Container(
                    color: const Color(0xFFF1F5F9),
                    child: widget.item.imageUrl.isNotEmpty
                        ? Image.network(
                            resolveMediaUrl(widget.item.imageUrl),
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
                // Right side: form on white background
                Expanded(
                  flex: 1,
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FormLabel(text: 'Titre'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _titleController,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                          decoration: _inputDecoration(),
                        ),
                        const SizedBox(height: 20),
                        _FormLabel(text: 'Tag'),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: widget.availableTags.contains(selectedTag)
                                  ? selectedTag
                                  : (selectedTag.isEmpty ? '' : null),
                              isExpanded: true,
                              hint: const Text('Aucun tag'),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('Aucun tag'),
                                ),
                                ...widget.availableTags.map(
                                  (tag) => DropdownMenuItem(
                                    value: tag,
                                    child: Text(tag),
                                  ),
                                ),
                              ],
                              onChanged: (value) {
                                setState(() {
                                  _selectedTags =
                                      (value == null || value.isEmpty)
                                          ? []
                                          : [value];
                                });
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        _FormLabel(text: 'Description'),
                        const SizedBox(height: 8),
                        Expanded(
                          child: TextField(
                            controller: _descriptionController,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xFF475569),
                              height: 1.5,
                            ),
                            decoration: _inputDecoration(),
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () {
                              Navigator.of(context).pop(
                                widget.item.copyWith(
                                  title: _titleController.text.trim(),
                                  description:
                                      _descriptionController.text.trim(),
                                  tags: _selectedTags,
                                ),
                              );
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF907CA1),
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            child: const Text(
                              'Enregistrer',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // Close button top-right (over the image)
            Positioned(
              top: 16,
              right: 16,
              child: Material(
                color: Colors.black.withValues(alpha: 0.35),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(context).pop(),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.close, color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 12,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFF907CA1), width: 1.5),
      ),
    );
  }
}

/// Uppercase tracking-wider slate-500 label, equivalent of React's FormBlock.
class _FormLabel extends StatelessWidget {
  const _FormLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Color(0xFF64748B),
        letterSpacing: 1.2,
      ),
    );
  }
}

class _WikiItemDraft {
  final String title;
  final String description;
  final String category;
  final List<String> tags;
  final String imageDataUrl;

  const _WikiItemDraft({
    required this.title,
    required this.description,
    required this.category,
    required this.tags,
    this.imageDataUrl = '',
  });
}

class _WikiCreateDialog extends StatefulWidget {
  const _WikiCreateDialog({required this.availableTags});

  final List<String> availableTags;

  @override
  State<_WikiCreateDialog> createState() => _WikiCreateDialogState();
}

class _WikiCreateDialogState extends State<_WikiCreateDialog> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _categoryController =
      TextEditingController(text: 'Autre');
  final ImagePicker _imagePicker = ImagePicker();
  final List<String> _selectedTags = [];
  bool _submitting = false;
  bool _pickingImage = false;
  Uint8List? _pickedImageBytes;
  String _pickedImageExt = 'jpg';

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _categoryController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    setState(() => _pickingImage = true);
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final ext = picked.path.split('.').last.toLowerCase();
      if (!mounted) return;
      setState(() {
        _pickedImageBytes = bytes;
        _pickedImageExt = switch (ext) {
          'png' => 'png',
          'webp' => 'webp',
          'gif' => 'gif',
          _ => 'jpg',
        };
      });
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Image indisponible : $err')),
      );
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  String _buildImageDataUrl() {
    if (_pickedImageBytes == null) return '';
    final mime = switch (_pickedImageExt) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
    return 'data:$mime;base64,${base64Encode(_pickedImageBytes!)}';
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le titre est obligatoire')),
      );
      return;
    }
    setState(() => _submitting = true);
    Navigator.of(context).pop(_WikiItemDraft(
      title: title,
      description: _descriptionController.text.trim(),
      category: _categoryController.text.trim().isEmpty
          ? 'Autre'
          : _categoryController.text.trim(),
      tags: List.unmodifiable(_selectedTags),
      imageDataUrl: _buildImageDataUrl(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Nouvel élément',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 20),
              _buildImageSection(),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                decoration: _decoration('Titre'),
                autofocus: true,
                enabled: !_submitting,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                decoration: _decoration('Description'),
                maxLines: 4,
                enabled: !_submitting,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _categoryController,
                decoration: _decoration('Catégorie'),
                enabled: !_submitting,
              ),
              const SizedBox(height: 16),
              const Text(
                'Tags',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: widget.availableTags
                    .map(
                      (tag) => FilterChip(
                        label: Text(tag),
                        selected: _selectedTags.contains(tag),
                        onSelected: _submitting
                            ? null
                            : (_) {
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
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Annuler'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF907CA1),
                      foregroundColor: Colors.white,
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Créer'),
                  ),
                ],
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
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
    );
  }

  Widget _buildImageSection() {
    if (_pickedImageBytes != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              _pickedImageBytes!,
              width: 128,
              height: 96,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Image sélectionnée',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF334155),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '.${_pickedImageExt.toUpperCase()}',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _submitting || _pickingImage ? null : _pickImage,
                      icon: const Icon(LucideIcons.refreshCw, size: 14),
                      label: const Text('Changer'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF907CA1),
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => setState(() => _pickedImageBytes = null),
                      icon: const Icon(LucideIcons.x, size: 14),
                      label: const Text('Retirer'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFB91C1C),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }

    return InkWell(
      onTap: _submitting || _pickingImage ? null : _pickImage,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFCBD5E1),
            style: BorderStyle.solid,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_pickingImage)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF907CA1),
                ),
              )
            else
              const Icon(LucideIcons.image, size: 18, color: Color(0xFF64748B)),
            const SizedBox(width: 10),
            Text(
              _pickingImage ? 'Chargement…' : 'Choisir une image (optionnel)',
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
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
