import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../components/plan_canvas.dart';
import '../../components/soft_transitions.dart';
import '../../models/types.dart';
import '../../models/visit_report_categories.dart';
import '../../services/data_service.dart';

/// Plans tab — React-parity multi-page canvas:
///  - Pagination bar with Previous / Next / Add / Delete
///  - Each page persists its own strokes under the same `tabKey='Plans'`
///    discriminated by `pageNumber`
///  - Each page can be tagged "Avant travaux" / "Après travaux" /
///    non classé via le pill flottant en haut à droite. La valeur est
///    persistée dans `note_pages.plan_phase` (cf. v11→v12 migration)
///    et alimente les pages 9 (avant) / 10 (après) du rapport PDF.
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

  /// Phase de la page courante (avant / après / null). Mise à jour à
  /// chaque navigation via [_loadPhaseForCurrentPage], ré-écrite côté
  /// SQLite + sync engine via [_setPhaseForCurrentPage].
  PlanPhase? _currentPhase;

  /// Cache local des phases déjà fetched pour éviter un round-trip
  /// SQLite à chaque changement de page. Invalidé lors d'un setPhase.
  final Map<int, PlanPhase?> _phaseCache = {};

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
    // Première hydratation de la phase pour la page 0 (ou page
    // courante restaurée). Asynchrone, ne bloque pas le rendu.
    _loadPhaseForCurrentPage();
  }

  void _goToPage(int page) {
    if (page < 0 || page >= _totalPages) return;
    setState(() => _currentPage = page);
    _loadPhaseForCurrentPage();
  }

  void _addPage() {
    setState(() {
      _totalPages += 1;
      _currentPage = _totalPages - 1;
    });
    // Page neuve → pas de phase enregistrée encore.
    _phaseCache[_currentPage] = null;
    setState(() => _currentPhase = null);
  }

  /// Charge la phase de la page courante depuis le cache (instantané)
  /// ou SQLite (1 lecture). Met à jour `_currentPhase` côté UI dès que
  /// disponible — le pill se rafraîchit automatiquement.
  Future<void> _loadPhaseForCurrentPage() async {
    final page = _currentPage;
    if (_phaseCache.containsKey(page)) {
      if (!mounted) return;
      setState(() => _currentPhase = _phaseCache[page]);
      return;
    }
    final phase = await _dataService.fetchNotePlanPhase(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: page,
    );
    _phaseCache[page] = phase;
    if (!mounted || page != _currentPage) return;
    setState(() => _currentPhase = phase);
  }

  /// Met à jour la phase de la page courante. Persiste localement +
  /// enqueue une sync_op pour propager côté NocoDB. UI optimiste : on
  /// met à jour l'état tout de suite, le sync se fait derrière.
  Future<void> _setPhaseForCurrentPage(PlanPhase? phase) async {
    final page = _currentPage;
    setState(() {
      _currentPhase = phase;
      _phaseCache[page] = phase;
    });
    await _dataService.setNotePlanPhase(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: page,
      phase: phase,
    );
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
    // Pagination et outils sont fusionnés dans la toolbar du canvas
    // (une seule ligne en haut). On wrap le canvas dans un Stack pour
    // y faire flotter le pill « Phase » dans le coin bas-droit, hors
    // de la zone de toolbar du canvas.
    if (!_probed) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        Positioned.fill(
          child: PlanCanvas(
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
          ),
        ),
        // Pill « Phase » : positionné en bas-droite pour ne pas
        // empiéter sur la toolbar du canvas (en haut). Tap → menu
        // avec 3 choix (avant / après / non classé).
        Positioned(
          right: 16,
          bottom: 16,
          child: _PhasePill(
            phase: _currentPhase,
            onTap: _showPhaseMenu,
          ),
        ),
      ],
    );
  }

  /// Ouvre un menu modal proposant les 3 états possibles (avant /
  /// après / retirer la phase). Le tap appelle [_setPhaseForCurrentPage]
  /// qui persiste + synchronise.
  Future<void> _showPhaseMenu() async {
    final selected = await showModalBottomSheet<_PhaseChoice>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Phase de cette page',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF334155),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Détermine si le dessin alimente la page « Plans avant '
                'travaux » (page 9) ou « Plans des travaux préconisés » '
                '(page 10) du rapport PDF.',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 14),
              _phaseMenuItem(
                ctx: ctx,
                phase: PlanPhase.avant,
                icon: LucideIcons.history,
                bg: const Color(0xFFFFEDD5),
                fg: const Color(0xFF9A3412),
                title: 'Avant travaux',
                subtitle: 'État actuel du logement (page 9 du PDF)',
              ),
              const SizedBox(height: 8),
              _phaseMenuItem(
                ctx: ctx,
                phase: PlanPhase.apres,
                icon: LucideIcons.checkCircle,
                bg: const Color(0xFFD1FAE5),
                fg: const Color(0xFF065F46),
                title: 'Après travaux',
                subtitle: 'Plan des travaux préconisés (page 10 du PDF)',
              ),
              const SizedBox(height: 8),
              _phaseMenuItem(
                ctx: ctx,
                phase: null,
                icon: LucideIcons.minusCircle,
                bg: const Color(0xFFF1F5F9),
                fg: const Color(0xFF475569),
                title: 'Retirer la classification',
                subtitle: 'La page ne sera pas insérée dans le rapport',
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null) return;
    await _setPhaseForCurrentPage(selected.phase);
  }

  Widget _phaseMenuItem({
    required BuildContext ctx,
    required PlanPhase? phase,
    required IconData icon,
    required Color bg,
    required Color fg,
    required String title,
    required String subtitle,
  }) {
    final isCurrent = phase == _currentPhase;
    return InkWell(
      onTap: () => Navigator.pop(ctx, _PhaseChoice(phase)),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: isCurrent ? bg.withValues(alpha: 0.6) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isCurrent ? fg.withValues(alpha: 0.4) : const Color(0xFFE2E8F0),
            width: isCurrent ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: fg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: isCurrent ? fg : const Color(0xFF334155),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            if (isCurrent)
              Icon(LucideIcons.check, size: 18, color: fg),
          ],
        ),
      ),
    );
  }
}

/// Wrapper pour un retour Navigator nullable distinct de "annulé".
/// Sans ça, `null` retourné par `Navigator.pop` se confondait avec le
/// choix « Retirer la classification » (PlanPhase null) — l'ergo
/// aurait perdu sa phase à chaque ouverture-fermeture du menu sans
/// sélection.
class _PhaseChoice {
  final PlanPhase? phase;
  const _PhaseChoice(this.phase);
}

// ---------------------------------------------------------------------------
// Pill « Phase » flottant — affiche l'état courant + tap pour changer
// ---------------------------------------------------------------------------

class _PhasePill extends StatelessWidget {
  final PlanPhase? phase;
  final VoidCallback onTap;

  const _PhasePill({required this.phase, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = _palette();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: palette.bg,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
            border: Border.all(color: palette.fg.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(palette.icon, size: 16, color: palette.fg),
              const SizedBox(width: 8),
              Text(
                palette.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: palette.fg,
                ),
              ),
              const SizedBox(width: 6),
              Icon(LucideIcons.chevronDown, size: 14, color: palette.fg),
            ],
          ),
        ),
      ),
    );
  }

  _PhasePalette _palette() {
    switch (phase) {
      case PlanPhase.avant:
        return const _PhasePalette(
          icon: LucideIcons.history,
          label: 'Avant travaux',
          bg: Color(0xFFFFEDD5),
          fg: Color(0xFF9A3412),
        );
      case PlanPhase.apres:
        return const _PhasePalette(
          icon: LucideIcons.checkCircle,
          label: 'Après travaux',
          bg: Color(0xFFD1FAE5),
          fg: Color(0xFF065F46),
        );
      case null:
        return const _PhasePalette(
          icon: LucideIcons.tag,
          label: 'Choisir la phase',
          bg: Color(0xFFF1F5F9),
          fg: Color(0xFF475569),
        );
    }
  }
}

class _PhasePalette {
  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  const _PhasePalette({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
  });
}
