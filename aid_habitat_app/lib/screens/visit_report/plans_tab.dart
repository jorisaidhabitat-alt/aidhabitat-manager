import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../components/confirmation_dialog.dart';
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
///    via le pill flottant en haut-centre. La valeur est
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
  static const String _kEmptyPlanDrawingJson =
      '{"format":"plan_canvas_v1","strokes":[]}';

  final DataService _dataService = DataService();
  final PlanCanvasController _planCanvasController = PlanCanvasController();
  int _currentPage = 0;
  int _totalPages = 1;
  bool _probed = false;

  /// Phase de la page courante (avant / après / null). Mise à jour à
  /// chaque navigation via [_loadPhaseForCurrentPage].
  PlanPhase? _currentPhase = PlanPhase.avant;

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

  void _addScenario() {
    _addScenarioAsync();
  }

  Future<void> _addScenarioAsync() async {
    await _planCanvasController.flush();
    final newIndex = _totalPages;
    final sourceJson = await _drawingJsonForNewScenario();
    await _dataService.saveNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: newIndex,
      drawingJson: sourceJson,
    );
    await _dataService.setNotePlanPhase(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: newIndex,
      phase: PlanPhase.apres,
    );
    if (!mounted) return;
    setState(() {
      _totalPages += 1;
      _currentPage = newIndex;
      _currentPhase = PlanPhase.apres;
      _phaseCache[newIndex] = PlanPhase.apres;
    });
  }

  /// Charge la phase de la page courante depuis le cache (instantané)
  /// ou SQLite (1 lecture). Met à jour `_currentPhase` côté UI dès que
  /// disponible — le pill se rafraîchit automatiquement.
  Future<void> _loadPhaseForCurrentPage() async {
    final page = _currentPage;
    if (page == 0) {
      _phaseCache[page] = PlanPhase.avant;
      if (!mounted) return;
      setState(() => _currentPhase = PlanPhase.avant);
      return;
    }
    if (_phaseCache.containsKey(page)) {
      if (!mounted) return;
      setState(() => _currentPhase = _phaseCache[page]);
      return;
    }
    final persistedPhase = await _dataService.fetchNotePlanPhase(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: page,
    );
    final phase = persistedPhase ?? PlanPhase.apres;
    _phaseCache[page] = phase;
    if (!mounted || page != _currentPage) return;
    setState(() => _currentPhase = phase);
  }

  Future<void> _deleteCurrentPage() async {
    if (_totalPages <= 1 || _currentPage == 0) return;
    final confirm = await showAppDestructiveConfirmation(
      context: context,
      title: 'Supprimer le scénario ?',
      message: '${_scenarioLabel(_currentPage)} sera supprimé définitivement.',
      confirmLabel: 'Supprimer',
      icon: LucideIcons.fileX2,
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
      final nextPhase =
          await _dataService.fetchNotePlanPhase(
            patientId: widget.dossier.patient.id,
            tabKey: _kTabKey,
            pageNumber: i + 1,
          ) ??
          PlanPhase.apres;
      await _dataService.saveNoteDrawingJson(
        patientId: widget.dossier.patient.id,
        tabKey: _kTabKey,
        pageNumber: i,
        drawingJson: next ?? '',
      );
      await _dataService.setNotePlanPhase(
        patientId: widget.dossier.patient.id,
        tabKey: _kTabKey,
        pageNumber: i,
        phase: i == 0 ? PlanPhase.avant : nextPhase,
      );
    }
    // Clear the last page (now a duplicate).
    await _dataService.saveNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: _totalPages - 1,
      drawingJson: '',
    );
    await _dataService.setNotePlanPhase(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: _totalPages - 1,
      phase: PlanPhase.apres,
    );

    if (!mounted) return;
    setState(() {
      _totalPages -= 1;
      _currentPage = 0;
      _currentPhase = PlanPhase.avant;
      _phaseCache.clear();
      _phaseCache[0] = PlanPhase.avant;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Pagination et outils sont fusionnés dans la toolbar flottante du canvas.
    // On wrap le canvas dans un Stack pour y faire flotter le toggle « Phase »
    // hors de la zone d'outils.
    if (!_probed) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        Positioned.fill(
          child: _PlanCanvasPhaseSwitcher(
            pageIndex: _currentPage,
            phase: _currentPhase,
            child: PlanCanvas(
              key: ValueKey('plans-${widget.dossier.patient.id}-$_currentPage'),
              patientId: widget.dossier.patient.id,
              controller: _planCanvasController,
              tabKey: _kTabKey,
              pageNumber: _currentPage,
              refreshPreviewOnLoad: _currentPhase == PlanPhase.apres,
              currentPage: _currentPage,
              totalPages: _totalPages,
              onPrevPage: () => _goToPage(_currentPage - 1),
              onNextPage: () => _goToPage(_currentPage + 1),
              onAddPage: null,
              onDuplicatePage: null,
              onDeletePage: _currentPage == 0 ? null : _deleteCurrentPage,
            ),
          ),
        ),
        // Sélecteur de scénarios : page 1 = plan avant travaux, pages
        // suivantes = scénarios des travaux préconisés.
        Positioned(
          // La palette d'équipements occupe le coin haut-gauche dans le
          // canvas. On décale donc les scénarios à sa droite pour éviter
          // toute superposition.
          left: 360,
          right: 180,
          top: 16,
          child: Align(
            alignment: Alignment.topLeft,
            child: _ScenarioTabs(
              currentPage: _currentPage,
              totalPages: _totalPages,
              onSelect: _selectScenarioPage,
              onAdd: _addScenario,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _selectScenarioPage(int page) async {
    if (page == _currentPage) return;
    await _planCanvasController.flush();
    _goToPage(page);
  }

  Future<String> _drawingJsonForNewScenario() async {
    final sourcePage = _totalPages > 1 ? _totalPages - 1 : 0;
    final source = await _dataService.fetchNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: sourcePage,
    );
    return _isEmptyPlanDrawingJson(source) ? _kEmptyPlanDrawingJson : source!;
  }

  static String _scenarioLabel(int pageIndex) {
    return _PlansScenarioLabels.labelFor(pageIndex);
  }

  bool _isEmptyPlanDrawingJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return true;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['format'] != 'plan_canvas_v1') return false;
      final strokes = decoded['strokes'];
      return strokes is! List || strokes.isEmpty;
    } catch (_) {
      return false;
    }
  }
}

class _PlanCanvasPhaseSwitcher extends StatefulWidget {
  const _PlanCanvasPhaseSwitcher({
    required this.pageIndex,
    required this.phase,
    required this.child,
  });

  final int pageIndex;
  final PlanPhase? phase;
  final Widget child;

  @override
  State<_PlanCanvasPhaseSwitcher> createState() =>
      _PlanCanvasPhaseSwitcherState();
}

class _PlanCanvasPhaseSwitcherState extends State<_PlanCanvasPhaseSwitcher> {
  int _direction = 1;

  int _phaseRank(PlanPhase? phase, int pageIndex) {
    switch (phase) {
      case PlanPhase.avant:
        return 0;
      case PlanPhase.apres:
        return 1;
      case null:
        return pageIndex;
    }
  }

  @override
  void didUpdateWidget(covariant _PlanCanvasPhaseSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pageIndex == oldWidget.pageIndex &&
        widget.phase == oldWidget.phase) {
      return;
    }
    final oldRank = _phaseRank(oldWidget.phase, oldWidget.pageIndex);
    final newRank = _phaseRank(widget.phase, widget.pageIndex);
    if (oldRank != newRank) {
      _direction = newRank > oldRank ? 1 : -1;
    } else {
      _direction = widget.pageIndex >= oldWidget.pageIndex ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentKey = ValueKey<int>(widget.pageIndex);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      reverseDuration: kSoftMedium,
      switchInCurve: kSoftCurve,
      switchOutCurve: kSoftCurveIn,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [...previousChildren, if (currentChild != null) currentChild],
      ),
      transitionBuilder: (child, animation) {
        final isIncoming = child.key == currentKey;
        final direction = _direction.toDouble();
        final slideBegin = isIncoming
            ? Offset(0.08 * direction, 0)
            : Offset(-0.05 * direction, 0);
        const scaleBegin = 0.985;
        const scaleEnd = 1.0;
        final curved = CurvedAnimation(
          parent: animation,
          curve: isIncoming ? kSoftCurve : kSoftCurveIn,
        );

        return ClipRect(
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: slideBegin,
                end: Offset.zero,
              ).animate(curved),
              child: ScaleTransition(
                scale: Tween<double>(
                  begin: scaleBegin,
                  end: scaleEnd,
                ).animate(curved),
                child: child,
              ),
            ),
          ),
        );
      },
      child: KeyedSubtree(key: currentKey, child: widget.child),
    );
  }
}

// ---------------------------------------------------------------------------
// Sélecteur de scénarios — page 1 = avant travaux, pages suivantes = scénarios
// ---------------------------------------------------------------------------

class _ScenarioTabs extends StatelessWidget {
  final int currentPage;
  final int totalPages;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;

  const _ScenarioTabs({
    required this.currentPage,
    required this.totalPages,
    required this.onSelect,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < totalPages; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _ScenarioChip(
                label: _PlansScenarioLabels.labelFor(i),
                selected: currentPage == i,
                onTap: () => onSelect(i),
              ),
            ],
            const SizedBox(width: 6),
            Tooltip(
              message: 'Ajouter un scénario',
              child: Material(
                color: const Color(0xFFF2ECF5),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onAdd,
                  child: const SizedBox(
                    width: 34,
                    height: 34,
                    child: Icon(
                      LucideIcons.plus,
                      size: 18,
                      color: Color(0xFF554265),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScenarioChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ScenarioChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? const Color(0xFF554265) : const Color(0xFF2B323A);
    final bg = selected ? const Color(0xFFF2ECF5) : Colors.transparent;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? const Color(0xFF8E6AA3).withValues(alpha: 0.28)
                  : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlansScenarioLabels {
  static String labelFor(int pageIndex) {
    return pageIndex == 0 ? 'Plan avant travaux' : 'Scénario $pageIndex';
  }
}
