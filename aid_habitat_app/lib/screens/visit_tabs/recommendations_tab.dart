import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/brand_colors.dart';
import '../../models/types.dart';
import '../../services/data_service.dart';
import 'form_widgets.dart';

class RecommendationsTab extends StatefulWidget {
  final Dossier dossier;

  const RecommendationsTab({super.key, required this.dossier});

  @override
  State<RecommendationsTab> createState() => _RecommendationsTabState();
}

class _RecommendationsTabState extends State<RecommendationsTab> {
  final _dataService = DataService();
  Map<String, dynamic> _formData = {};
  Timer? _saveTimer;
  bool _loaded = false;

  static const _tags = [
    'Salle de bain',
    'WC',
    'Cuisine',
    'Chambre',
    'Escaliers & ascenseur',
    'Acc\u00e8s ext\u00e9rieurs',
    "Barres d'appui",
    'Ouvertures',
    '\u00c9quipements',
  ];

  String get _patientId => widget.dossier.patient.id;

  List<Map<String, dynamic>> get _items {
    final raw = _formData['items'];
    if (raw is List) return raw.cast<Map<String, dynamic>>();
    return [];
  }

  @override
  void initState() {
    super.initState();
    _loadFormData();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFormData() async {
    final data =
        await _dataService.fetchFormData(_patientId, 'preconisations');
    if (mounted) setState(() { _formData = data; _loaded = true; });
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _dataService.saveFormData(_patientId, 'preconisations', _formData);
    });
  }

  void _addItem() {
    final items = List<Map<String, dynamic>>.from(_items);
    items.add({
      'id': 'rec_${DateTime.now().millisecondsSinceEpoch}',
      'tag': '',
      'title': '',
      'note': '',
      'createdAt': DateTime.now().toIso8601String(),
    });
    setState(() => _formData['items'] = items);
    _scheduleSave();
  }

  void _updateItem(int index, String key, dynamic value) {
    final items = List<Map<String, dynamic>>.from(_items);
    items[index] = Map<String, dynamic>.from(items[index])..[key] = value;
    setState(() => _formData['items'] = items);
    _scheduleSave();
  }

  void _removeItem(int index) {
    final items = List<Map<String, dynamic>>.from(_items);
    items.removeAt(index);
    setState(() => _formData['items'] = items);
    _scheduleSave();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              const Text(
                'Pr\u00e9conisations',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: kBrandDarkPurple,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _addItem,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ajouter'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF597E8D),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _items.isEmpty
              ? const Center(
                  child: Text(
                    'Aucune pr\u00e9conisation.\nCliquez \u00ab\u00a0Ajouter\u00a0\u00bb pour commencer.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: kBrandPurple,
                      fontSize: 13,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(right: 16),
                  itemCount: _items.length,
                  separatorBuilder: (_, _a) => const Divider(height: 24),
                  itemBuilder: (context, i) => _buildItem(i),
                ),
        ),
      ],
    );
  }

  Widget _buildItem(int index) {
    final item = _items[index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Pr\u00e9conisation ${index + 1}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: kBrandDarkPurple,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              color: Colors.red.shade300,
              onPressed: () => _removeItem(index),
              tooltip: 'Supprimer',
            ),
          ],
        ),
        VDropdown(
          label: 'Cat\u00e9gorie',
          options: _tags,
          selected: item['tag']?.toString() ?? '',
          onChanged: (v) => _updateItem(index, 'tag', v),
        ),
        VTextField(
          label: 'Titre',
          initialValue: item['title']?.toString() ?? '',
          onChanged: (v) => _updateItem(index, 'title', v),
        ),
        VTextArea(
          label: 'Commentaire',
          initialValue: item['note']?.toString() ?? '',
          maxLines: 3,
          onChanged: (v) => _updateItem(index, 'note', v),
        ),
      ],
    );
  }
}
