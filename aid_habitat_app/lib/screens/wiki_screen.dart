import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/cached_remote_image.dart';
import '../components/soft_transitions.dart';
import '../models/types.dart';
import '../services/data_service.dart';
import '../services/sync_engine.dart';
import '../services/url_resolver.dart';
import '../services/wiki_repository.dart';

class WikiScreen extends StatefulWidget {
  const WikiScreen({super.key});

  @override
  State<WikiScreen> createState() => _WikiScreenState();
}

class _WikiScreenState extends State<WikiScreen> {
  final WikiRepository _wikiRepository = WikiRepository();
  final DataService _dataService = DataService();

  final TextEditingController _searchController = TextEditingController();

  List<WikiItem> _items = const [];
  Set<String> _availableTags = {};
  String? _selectedTag;
  bool _isLoading = true;
  String? _error;

  String get _searchTerm => _searchController.text;

  /// Subscription au sync engine — re-fetch les items wiki depuis
  /// SQLite à chaque pull workspace réussi (Mac↔iPad sync).
  StreamSubscription<SyncEngineState>? _syncSubscription;
  DateTime? _lastObservedSyncAt;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadItems();
    _syncSubscription = SyncEngine().stateStream.listen((state) {
      if (!mounted) return;
      final at = state.lastSyncAt;
      if (at == null) return;
      if (_lastObservedSyncAt != null && at == _lastObservedSyncAt) return;
      _lastObservedSyncAt = at;
      // ignore: discarded_futures
      _refetchFromCacheAfterPull();
    });
  }

  Future<void> _refetchFromCacheAfterPull() async {
    try {
      final refreshed = await _wikiRepository.fetchAllItems();
      if (!mounted) return;
      setState(() {
        _items = refreshed;
        _availableTags = _extractTags(refreshed);
        _isLoading = false;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchController.dispose();
    _syncSubscription?.cancel();
    _syncSubscription = null;
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
    final updated = await showSoftDialog<WikiItem>(
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
    final draft = await showSoftDialog<_WikiItemDraft>(
      context: context,
      builder: (context) =>
          _WikiCreateDialog(availableTags: _availableTags.toList()),
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

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // En-tête : titre + sous-titre à gauche, champ de recherche
              // standalone à droite (fond blanc arrondi, pas de carte
              // englobante). Style aligné avec "Caisses de retraite
              // complémentaires".
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      'Bibliothèque',
                      // Refonte 2026-05-13 : Nunito w600 — style
                      // uniforme avec les autres titres de page.
                      style: GoogleFonts.nunito(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  // Style aligné avec la barre de recherche de
                  // "Mes dossiers" : pastille pill (radius 999), fond
                  // blanc, contour gris #E2E8F0, icône search + champ
                  // sans bordures internes.
                  SizedBox(
                    width: 320,
                    child: Container(
                      height: 52,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        border:
                            Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Row(
                        children: [
                          const Icon(LucideIcons.search,
                              size: 18, color: Color(0xFF64748B)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              decoration: const InputDecoration(
                                hintText: 'Rechercher un élément…',
                                hintStyle: TextStyle(
                                    color: Color(0xFF94A3B8)),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                isCollapsed: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Filtres par tag — sous l'en-tête, alignés à gauche.
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
                            () => _selectedTag =
                                _selectedTag == tag ? null : tag,
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
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                )
              else if (_filteredItems.isEmpty)
                const Expanded(
                  child: Center(child: Text('Aucun element trouve')),
                )
              else
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 280,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      // Hauteur alignée sur Caisses (+10 px pour le hero
                      // image plus haut qu'un logo).
                      mainAxisExtent: 260,
                    ),
                    itemCount: _filteredItems.length,
                    itemBuilder: (context, index) {
                      final item = _filteredItems[index];
                      final primaryTag =
                          item.tags.isNotEmpty ? item.tags.first : null;
                      return _WikiCard(
                        item: item,
                        primaryTag: primaryTag,
                        heroBg: _colorForCategory(item.category),
                        onTap: () => _openItem(item),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          right: 24,
          bottom: 24,
          // Bouton « + Ajouter un élément » — demande utilisateur
          // 2026-05-12 : « ajoute du radius pour que ça devienne un
          // véritable arrondi et ajoute le texte ajouter un élément ».
          // Extended FAB avec StadiumBorder (radius max = pill complet),
          // icône `+` à gauche + label.
          child: FloatingActionButton.extended(
            onPressed: _createItem,
            backgroundColor: const Color(0xFF8B6FA0),
            foregroundColor: Colors.white,
            // Demande user 2026-05-12 : retire l'ombre du FAB. On force
            // toutes les variantes d'élévation à 0 (idle/hover/focus/
            // highlight) pour qu'aucun shadow ne réapparaisse au tap.
            elevation: 0,
            hoverElevation: 0,
            focusElevation: 0,
            highlightElevation: 0,
            shape: const StadiumBorder(),
            icon: const Icon(LucideIcons.plus, size: 22),
            // Demande utilisateur 2026-05-13 : « le texte de ajouter
            // un élément également » (passage en Nunito comme les tags
            // de bibliothèque).
            label: Text(
              'Ajouter un élément',
              style: GoogleFonts.nunito(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
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
  /// Une description = un controller. La fiche peut en contenir plusieurs
  /// (demande utilisateur 2026-05-04) — l'ergo peut alors cocher
  /// celle(s) qui s'appliquent à la préconisation au moment de
  /// l'ajouter dans le relevé de visite. Stockage : JSON array dans
  /// la colonne `description` (cf. WikiItem.serializeDescriptions).
  late List<TextEditingController> _descCtrls;
  late List<String> _selectedTags;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.item.title);
    final initial = widget.item.descriptionsList;
    // Toujours au moins 1 champ visible (sinon l'ergo ne sait pas
    // qu'il peut renseigner une description).
    _descCtrls = (initial.isEmpty ? <String>[''] : initial)
        .map((s) => TextEditingController(text: s))
        .toList();
    _selectedTags = [...widget.item.tags];
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (final c in _descCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _addDescription() {
    setState(() => _descCtrls.add(TextEditingController()));
  }

  void _removeDescription(int index) {
    if (index < 0 || index >= _descCtrls.length) return;
    if (_descCtrls.length == 1) {
      // Au lieu de supprimer le dernier, on le vide → garde au moins
      // un champ visible (cf. initState).
      _descCtrls[0].clear();
      setState(() {});
      return;
    }
    setState(() {
      _descCtrls.removeAt(index).dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedTag = _selectedTags.isNotEmpty ? _selectedTags.first : '';

    // Taille alignée sur la popup Caisses de retraite (demande
    // utilisateur 2026-04-29 : « fait la même taille de pop up pour la
    // bibliothèque »). Avant : 1040 × 720 + insetPadding all(24).
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 680),
        // Pas de `StackFit.expand` (demande utilisateur 2026-04-29 v2 :
        // « c'est la hauteur de la partie de droite qui doit réduire »
        // — pas l'inverse). Sans ce fit, le Stack se dimensionne sur la
        // hauteur intrinsèque de son enfant Row → la Row prend la
        // hauteur naturelle du formulaire de droite (Column avec
        // mainAxisSize.min ci-dessous), et l'image (Expanded gauche)
        // s'aligne sur cette même hauteur côté Row. Résultat : popup
        // compacte sans espace vide vertical.
        child: Stack(
          children: [
            Row(
              children: [
                // Left side: image on neutral slate-100 background (matches React)
                Expanded(
                  flex: 2,
                  child: Container(
                    color: const Color(0xFFF1F5F9),
                    // BoxFit.cover (au lieu de contain) — demande
                    // utilisateur 2026-04-29 : « aligne bien la hauteur
                    // à l'image sans prendre en compte le blanc autour
                    // (haut et bas de l'image) ». Avec contain, on
                    // gardait des bandes slate-100 au-dessus/dessous
                    // quand le ratio de l'image différait du conteneur.
                    // Avec cover, l'image remplit toute la moitié
                    // gauche → la hauteur visible = la hauteur du
                    // formulaire de droite, sans blanc parasite.
                    child: (widget.item.imageUrl.isNotEmpty ||
                            widget.item.pendingImageDataUrl.isNotEmpty)
                        ? CachedRemoteImage(
                            url: resolveMediaUrl(widget.item.imageUrl),
                            pendingDataUrl: widget.item.pendingImageDataUrl,
                            fit: BoxFit.cover,
                            errorWidget: const Center(
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
                    // `mainAxisSize.min` → la Column shrink-wrap à la
                    // hauteur naturelle de ses enfants, ce qui devient
                    // la hauteur de la popup. L'Expanded sur le
                    // TextField description est remplacé par une
                    // hauteur fixe (180 pt) pour que la Column ait bien
                    // une hauteur intrinsèque finie (sinon Expanded
                    // dans une Column non-bornée → erreur layout).
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
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
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(child: _FormLabel(text: 'Descriptions')),
                            // Bouton « + » discret pour ajouter une
                            // description supplémentaire (l'ergo pourra
                            // ensuite cocher celles qui s'appliquent
                            // depuis l'écran préconisations).
                            Material(
                              color: const Color(0xFFEDE8F5),
                              shape: const CircleBorder(),
                              child: InkWell(
                                onTap: _addDescription,
                                customBorder: const CircleBorder(),
                                child: const Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(
                                    Icons.add,
                                    size: 18,
                                    color: Color(0xFF8B6FA0),
                                    semanticLabel: 'Ajouter une description',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Liste des descriptions — hauteur globale fixe
                        // (180 pt) en scroll vertical pour pouvoir héberger
                        // 1 à N champs sans déformer la popup.
                        SizedBox(
                          height: 180,
                          child: ListView.separated(
                            itemCount: _descCtrls.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, i) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _descCtrls[i],
                                      maxLines: 3,
                                      minLines: 2,
                                      textAlignVertical: TextAlignVertical.top,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Color(0xFF475569),
                                        height: 1.5,
                                      ),
                                      decoration: _inputDecoration(),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  IconButton(
                                    onPressed: () => _removeDescription(i),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                      color: Color(0xFF94A3B8),
                                    ),
                                    tooltip: 'Supprimer cette description',
                                    visualDensity: VisualDensity.compact,
                                    splashRadius: 18,
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () {
                              final descriptions = _descCtrls
                                  .map((c) => c.text.trim())
                                  .where((s) => s.isNotEmpty)
                                  .toList();
                              Navigator.of(context).pop(
                                widget.item.copyWith(
                                  title: _titleController.text.trim(),
                                  description:
                                      WikiItem.serializeDescriptions(descriptions),
                                  tags: _selectedTags,
                                ),
                              );
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF8B6FA0),
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
      fillColor: const Color(0xFFF7F7FA),
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
        borderSide: const BorderSide(color: Color(0xFF8B6FA0), width: 1.5),
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
    // Design refondu 2026-05-12 : parité avec les dialogs « Nouvelle
    // caisse de retraite » (header icône + titre + X, champs labelisés
    // violet 12px avec OutlineInputBorder radius 10, bouton X de close).
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B6FA0).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      LucideIcons.plus,
                      color: Color(0xFF8B6FA0),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Nouvel élément',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: 20),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildImageSection(),
              const SizedBox(height: 16),
              _WikiLabeledField(
                label: 'Titre *',
                controller: _titleController,
                hint: 'ex. Barre d\'appui salle de bain',
                autofocus: true,
                enabled: !_submitting,
              ),
              const SizedBox(height: 12),
              _WikiLabeledField(
                label: 'Description',
                controller: _descriptionController,
                hint: 'Détails de l\'aménagement, dimensions, conseils…',
                maxLines: 4,
                enabled: !_submitting,
              ),
              const SizedBox(height: 12),
              _WikiLabeledField(
                label: 'Catégorie',
                controller: _categoryController,
                hint: 'ex. Salle de bain, WC, Cuisine, Chambre…',
                enabled: !_submitting,
              ),
              const SizedBox(height: 16),
              const Text(
                'Tags',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF8B6FA0),
                ),
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
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF8B6FA0),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _submitting ? null : _submit,
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
                        foregroundColor: const Color(0xFF8B6FA0),
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
          color: const Color(0xFFF7F7FA),
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
                  color: Color(0xFF8B6FA0),
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
    // Refonte 2026-05-13 : animation de transition entre tags + border
    // sur les tags inactifs (demande utilisateur : « fais une animation
    // de transition de remplissage entre les tags (fade in et fade
    // out) et ajoute des border aux tags qui ne sont pas sélectionnés »).
    //
    // - AnimatedContainer : interpole `color` (white ↔ mauve-500) et
    //   `border` (slate-200 ↔ transparent) sur 220 ms ease-out cubic.
    //   Visuellement équivalent à un cross-fade du fond entre les deux
    //   tags concernés (ancien actif s'éclaircit, nouveau actif se
    //   teinte).
    // - AnimatedDefaultTextStyle : interpole la couleur de texte
    //   (slate-600 ↔ blanc) sur le même tempo. On part de
    //   `GoogleFonts.nunito(...)` pour conserver la fontFamily Nunito
    //   (pas de retombée Roboto).
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF8B6FA0) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isActive
                ? Colors.transparent
                : const Color(0xFFE2E8F0), // slate-200
            width: 1,
          ),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          style: GoogleFonts.nunito(
            color: isActive ? Colors.white : const Color(0xFF475569),
            fontWeight: FontWeight.w600,
          ),
          child: Text(label),
        ),
      ),
    );
  }
}

/// Étiquette de date pour une carte bibliothèque : "Modifié le …" si
/// `updatedAt` diffère de `createdAt`, sinon "Ajouté le …", sinon
/// "Nouveau". Format DD/MM/YYYY. Symétrique de `_buildDateLabel` côté
/// Caisses de retraite.
String _wikiDateLabel(WikiItem item) {
  final created = item.createdAt;
  final updated = item.updatedAt;
  final hasUpdate = updated.isNotEmpty &&
      updated != created &&
      DateTime.tryParse(updated) != null;
  if (hasUpdate) {
    final formatted = _formatWikiDate(updated);
    if (formatted != null) return 'Modifié le $formatted';
  }
  if (created.isNotEmpty) {
    final formatted = _formatWikiDate(created);
    if (formatted != null) return 'Ajouté le $formatted';
  }
  return 'Nouveau';
}

String? _formatWikiDate(String iso) {
  final date = DateTime.tryParse(iso);
  if (date == null) return null;
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  return '$day/$month/${date.year}';
}

/// Carte d'un élément de bibliothèque — coque visuelle alignée sur
/// `_FundCard` de la page Caisses de retraite (fond blanc, ombre douce,
/// borderRadius 16, lift au survol, clip antialias).
///
/// Anatomie :
///   • Hero (140 px) : image de l'élément cadrée par un fond pastel
///     dérivé de la catégorie. Pas d'overlay.
///   • Texte : titre 16 px w800 + date uppercase + chip tag primaire.
class _WikiCard extends StatefulWidget {
  final WikiItem item;
  final String? primaryTag;
  final Color heroBg;
  final VoidCallback onTap;

  const _WikiCard({
    required this.item,
    required this.primaryTag,
    required this.heroBg,
    required this.onTap,
  });

  @override
  State<_WikiCard> createState() => _WikiCardState();
}

class _WikiCardState extends State<_WikiCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        transform: _hover
            ? (Matrix4.identity()..translateByDouble(0.0, -3.0, 0.0, 1.0))
            : Matrix4.identity(),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: const Color(0xFF8B6FA0).withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------- Hero image ----------
              // Pas de tag overlay sur la photo — le tag reste visible
              // sous le titre. Les filtres par tag en haut de page sont
              // conservés.
              Container(
                height: 140,
                width: double.infinity,
                color: widget.heroBg,
                child: (item.imageUrl.isNotEmpty ||
                        item.pendingImageDataUrl.isNotEmpty)
                    ? CachedRemoteImage(
                        url: resolveMediaUrl(item.imageUrl),
                        pendingDataUrl: item.pendingImageDataUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorWidget: const Center(
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
              // ---------- Text content ----------
              // Anatomie identique aux cartes Caisses :
              //   • titre
              //   • info (date d'ajout/modif uppercase)
              //   • widget (pastille avec le tag primaire)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Date d'ajout / modification — format uppercase,
                      // identique aux cartes Caisses de retraite.
                      Text(
                        _wikiDateLabel(item).toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF94A3B8),
                          letterSpacing: 1.2,
                        ),
                      ),
                      // Widget : pastille avec le tag primaire — même
                      // style que le chip téléphone des cartes Caisses
                      // (fond gris très clair, texte slate-700). Pas
                      // d'icône — uniquement le texte du tag.
                      if (widget.primaryTag != null) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(50),
                            ),
                            child: Text(
                              widget.primaryTag!,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF475569),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Champ texte labelisé pour le dialog de création wiki. Parité 1:1
/// avec `_LabeledField` (caisses complémentaires) et
/// `_PrincipalLabeledField` (caisses principales) — label violet
/// 12px bold au-dessus, TextField avec OutlineInputBorder radius 10.
class _WikiLabeledField extends StatelessWidget {
  const _WikiLabeledField({
    required this.label,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.autofocus = false,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  final bool autofocus;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF8B6FA0),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          autofocus: autofocus,
          enabled: enabled,
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF8B6FA0), width: 1.4),
            ),
          ),
        ),
      ],
    );
  }
}
