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

  void _addPage() {
    setState(() {
      _totalPages += 1;
      _currentPage = _totalPages - 1;
    });
    // Page neuve → par défaut elle alimente le plan "Avant travaux".
    _phaseCache[_currentPage] = PlanPhase.avant;
    setState(() => _currentPhase = PlanPhase.avant);
  }

  /// Duplique la page courante : crée une nouvelle page après la
  /// dernière, avec exactement le même `drawingJson` (strokes +
  /// symboles + texte) et la phase "Après travaux". Demande utilisateur
  /// 2026-05-04 : « possibilité d'ajouter une page (vierge) ou de
  /// dupliquer la page actuelle ». Le clone est immédiat (lecture +
  /// écriture SQLite) puis on bascule l'utilisateur dessus.
  Future<void> _duplicatePage() async {
    final sourcePage = _currentPage;
    // Lit le contenu de la page courante AVANT d'augmenter le compteur.
    final sourceJson = await _dataService.fetchNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: sourcePage,
    );
    if (!mounted) return;
    final newIndex = _totalPages; // page index 0-based de la nouvelle page
    setState(() {
      _totalPages += 1;
      _currentPage = newIndex;
    });
    // Persiste le clone du drawingJson sur la nouvelle page. Même si la
    // source est vide, on crée la ligne pour pouvoir enregistrer la phase.
    await _dataService.saveNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: newIndex,
      drawingJson: sourceJson ?? '',
    );
    const duplicatedPhase = PlanPhase.apres;
    _phaseCache[newIndex] = duplicatedPhase;
    await _dataService.setNotePlanPhase(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: newIndex,
      phase: duplicatedPhase,
    );
    if (!mounted) return;
    setState(() => _currentPhase = duplicatedPhase);
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
    final persistedPhase = await _dataService.fetchNotePlanPhase(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: page,
    );
    final phase = persistedPhase ?? PlanPhase.avant;
    _phaseCache[page] = phase;
    if (!mounted || page != _currentPage) return;
    setState(() => _currentPhase = phase);
  }

  Future<void> _deleteCurrentPage() async {
    if (_totalPages <= 1) return;
    final confirm = await showAppDestructiveConfirmation(
      context: context,
      title: 'Supprimer la page ?',
      message:
          'Page ${_currentPage + 1} sur $_totalPages. Le dessin de cette page sera supprimé.',
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
              onAddPage: _addPage,
              onDuplicatePage: _duplicatePage,
              onDeletePage: _deleteCurrentPage,
            ),
          ),
        ),
        // Toggle « Phase » : positionné en haut-centre. Tap = changement
        // direct entre les pages Avant travaux / Après travaux.
        Positioned(
          left: 0,
          right: 0,
          top: 16,
          child: Center(
            child: _PhasePill(
              phase: _currentPhase,
              onTap: _switchToOppositePhase,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _switchToOppositePhase() async {
    await _planCanvasController.flush();
    final target = _currentPhase == PlanPhase.apres
        ? PlanPhase.avant
        : PlanPhase.apres;
    await _switchToPhasePage(target);
  }

  Future<void> _switchToPhasePage(PlanPhase targetPhase) async {
    for (int i = 0; i < _totalPages; i++) {
      final cached = _phaseCache.containsKey(i)
          ? _phaseCache[i]
          : await _dataService.fetchNotePlanPhase(
              patientId: widget.dossier.patient.id,
              tabKey: _kTabKey,
              pageNumber: i,
            );
      final phase = cached ?? PlanPhase.avant;
      _phaseCache[i] = phase;
      if (phase == targetPhase) {
        if (targetPhase == PlanPhase.apres) {
          await _seedAfterPageFromAvantIfEmpty(i);
        }
        if (!mounted) return;
        setState(() {
          _currentPage = i;
          _currentPhase = phase;
        });
        return;
      }
    }

    final newIndex = _totalPages;
    final initialDrawingJson = targetPhase == PlanPhase.apres
        ? await _copySourceDrawingJsonForAfter()
        : _kEmptyPlanDrawingJson;
    await _dataService.saveNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: newIndex,
      drawingJson: initialDrawingJson,
    );
    await _dataService.setNotePlanPhase(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: newIndex,
      phase: targetPhase,
    );
    if (!mounted) return;
    setState(() {
      _totalPages += 1;
      _currentPage = newIndex;
      _currentPhase = targetPhase;
      _phaseCache[newIndex] = targetPhase;
    });
  }

  Future<void> _seedAfterPageFromAvantIfEmpty(int afterPage) async {
    final existing = await _dataService.fetchNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: afterPage,
    );
    if (!_isEmptyPlanDrawingJson(existing)) return;
    final source = await _copySourceDrawingJsonForAfter();
    if (_isEmptyPlanDrawingJson(source)) return;
    await _dataService.saveNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: afterPage,
      drawingJson: source,
    );
  }

  Future<String> _copySourceDrawingJsonForAfter() async {
    final sourcePage = _currentPhase == PlanPhase.avant
        ? _currentPage
        : await _findFirstPageForPhase(PlanPhase.avant);
    if (sourcePage == null) return _kEmptyPlanDrawingJson;
    final source = await _dataService.fetchNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: sourcePage,
    );
    return _isEmptyPlanDrawingJson(source) ? _kEmptyPlanDrawingJson : source!;
  }

  Future<int?> _findFirstPageForPhase(PlanPhase targetPhase) async {
    for (int i = 0; i < _totalPages; i++) {
      final cached = _phaseCache.containsKey(i)
          ? _phaseCache[i]
          : await _dataService.fetchNotePlanPhase(
              patientId: widget.dossier.patient.id,
              tabKey: _kTabKey,
              pageNumber: i,
            );
      final phase = cached ?? PlanPhase.avant;
      _phaseCache[i] = phase;
      if (phase == targetPhase) return i;
    }
    return null;
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
              Text(
                palette.label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: palette.fg,
                ),
              ),
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
          label: 'Avant travaux',
          bg: Color(0xFFFFEDD5),
          fg: Color(0xFF9A3412),
        );
      case PlanPhase.apres:
        return const _PhasePalette(
          label: 'Après travaux',
          bg: Color(0xFFD1FAE5),
          fg: Color(0xFF065F46),
        );
      case null:
        return const _PhasePalette(
          label: 'Choisir la phase',
          bg: Color(0xFFF2F4F6),
          fg: Color(0xFF2B323A),
        );
    }
  }
}

class _PhasePalette {
  final String label;
  final Color bg;
  final Color fg;
  const _PhasePalette({
    required this.label,
    required this.bg,
    required this.fg,
  });
}
