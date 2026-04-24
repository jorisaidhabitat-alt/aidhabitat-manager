import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../components/plan_canvas.dart';
import '../../components/soft_transitions.dart';
import '../../models/types.dart';
import '../../services/data_service.dart';

/// Plans tab — React-parity multi-page canvas:
///  - Pagination bar with Previous / Next / Add / Delete
///  - Each page persists its own strokes under the same `tabKey='Plans'`
///    discriminated by `pageNumber`
class PlansTab extends StatefulWidget {
  final Dossier dossier;

  const PlansTab({super.key, required this.dossier});

  @override
  State<PlansTab> createState() => _PlansTabState();
}

class _PlansTabState extends State<PlansTab> {
  static const String _kTabKey = 'Plans';
  static const int _kProbeLimit = 10;

  final DataService _dataService = DataService();
  int _currentPage = 0;
  int _totalPages = 1;
  bool _probed = false;

  @override
  void initState() {
    super.initState();
    _probeInitialPages();
  }

  /// Scans pages 0..n to determine how many pages already have strokes.
  /// We stop at the first empty page (or at [_kProbeLimit]).
  Future<void> _probeInitialPages() async {
    int max = 0;
    for (int i = 0; i < _kProbeLimit; i++) {
      final json = await _dataService.fetchNoteDrawingJson(
        patientId: widget.dossier.patient.id,
        tabKey: _kTabKey,
        pageNumber: i,
      );
      if (json == null || json.isEmpty) {
        if (i == 0) {
          // No pages at all — keep 1 empty page.
          break;
        }
        // First empty page beyond the first: stop, keep the previous count.
        break;
      }
      max = i + 1;
    }
    if (!mounted) return;
    setState(() {
      _totalPages = max > 0 ? max : 1;
      _probed = true;
    });
  }

  void _goToPage(int page) {
    if (page < 0 || page >= _totalPages) return;
    setState(() => _currentPage = page);
  }

  void _addPage() {
    setState(() {
      _totalPages += 1;
      _currentPage = _totalPages - 1;
    });
  }

  Future<void> _deleteCurrentPage() async {
    if (_totalPages <= 1) return;
    final confirm = await showSoftDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Supprimer la page ?'),
        content: Text(
          'Page ${_currentPage + 1} sur $_totalPages. Le dessin de cette page sera supprimé.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
            ),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // Shift remaining pages up: load page i+1 content and save to i, then
    // clear the last page.
    for (int i = _currentPage; i < _totalPages - 1; i++) {
      final next = await _dataService.fetchNoteDrawingJson(
        patientId: widget.dossier.patient.id,
        tabKey: _kTabKey,
        pageNumber: i + 1,
      );
      await _dataService.saveNoteDrawingJson(
        patientId: widget.dossier.patient.id,
        tabKey: _kTabKey,
        pageNumber: i,
        drawingJson: next ?? '',
      );
    }
    // Clear the last page (now a duplicate).
    await _dataService.saveNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: _totalPages - 1,
      drawingJson: '',
    );

    if (!mounted) return;
    setState(() {
      _totalPages -= 1;
      if (_currentPage >= _totalPages) _currentPage = _totalPages - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Pagination et outils sont maintenant fusionnés dans la toolbar du canvas
    // (une seule ligne en haut). Pas de titre "Plans de visite" redondant.
    return _probed
        ? PlanCanvas(
            key: ValueKey('plans-${widget.dossier.patient.id}-$_currentPage'),
            patientId: widget.dossier.patient.id,
            tabKey: _kTabKey,
            pageNumber: _currentPage,
            currentPage: _currentPage,
            totalPages: _totalPages,
            onPrevPage: () => _goToPage(_currentPage - 1),
            onNextPage: () => _goToPage(_currentPage + 1),
            onAddPage: _addPage,
            onDeletePage: _deleteCurrentPage,
          )
        : const Center(child: CircularProgressIndicator());
  }

  Widget _buildPaginationBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _iconButton(
            icon: LucideIcons.chevronLeft,
            tooltip: 'Page précédente',
            enabled: _currentPage > 0,
            onTap: () => _goToPage(_currentPage - 1),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Page ${_currentPage + 1} / $_totalPages',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF334155),
              ),
            ),
          ),
          _iconButton(
            icon: LucideIcons.chevronRight,
            tooltip: 'Page suivante',
            enabled: _currentPage < _totalPages - 1,
            onTap: () => _goToPage(_currentPage + 1),
          ),
          const SizedBox(width: 8),
          Container(width: 1, height: 20, color: const Color(0xFFE2E8F0)),
          const SizedBox(width: 8),
          _iconButton(
            icon: LucideIcons.plus,
            tooltip: 'Ajouter une page',
            enabled: true,
            onTap: _addPage,
          ),
          _iconButton(
            icon: LucideIcons.trash2,
            tooltip: 'Supprimer la page',
            enabled: _totalPages > 1,
            onTap: _deleteCurrentPage,
            dangerous: true,
          ),
        ],
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
    bool dangerous = false,
  }) {
    final color = enabled
        ? (dangerous ? const Color(0xFFB91C1C) : const Color(0xFF334155))
        : const Color(0xFFCBD5E1);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}
