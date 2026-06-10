import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../components/brand_colors.dart';
import '../../components/notes_widget.dart';
import '../../models/types.dart';

class SummaryTabController {
  void Function(_SummaryMode mode, _SummaryTextNote? note)? _selectMode;
  String? _pendingTextTabKey;

  void showDrawing() {
    final select = _selectMode;
    if (select == null) {
      _pendingTextTabKey = null;
      return;
    }
    select(_SummaryMode.drawing, null);
  }

  void showTextNote(String tabKey) {
    final select = _selectMode;
    if (select == null) {
      _pendingTextTabKey = tabKey;
      return;
    }
    select(_SummaryMode.text, _textNoteFromTabKey(tabKey));
  }

  void _attach(
    void Function(_SummaryMode mode, _SummaryTextNote? note) select,
  ) {
    _selectMode = select;
    final pending = _pendingTextTabKey;
    if (pending != null) {
      _pendingTextTabKey = null;
      select(_SummaryMode.text, _textNoteFromTabKey(pending));
    }
  }

  void _detach(
    void Function(_SummaryMode mode, _SummaryTextNote? note) select,
  ) {
    if (_selectMode == select) {
      _selectMode = null;
    }
  }
}

/// Onglet Résumé :
/// - mode initial dessin pleine page, sans fond silhouette ;
/// - mode note écrite avec deux notes historiques :
///   `Préconisations-Résumé` et `Préconisations-Projet`.
class SummaryTab extends StatefulWidget {
  final Dossier dossier;
  final SummaryTabController? controller;
  final VoidCallback? onExpandToTab;
  final void Function(String tabKey)? onExpandTextNote;
  final String? liveTextProjet;
  final String? liveTextResume;
  final void Function(String tabKey, String text)? onDraftChange;

  const SummaryTab({
    super.key,
    required this.dossier,
    this.controller,
    this.onExpandToTab,
    this.onExpandTextNote,
    this.liveTextProjet,
    this.liveTextResume,
    this.onDraftChange,
  });

  @override
  State<SummaryTab> createState() => _SummaryTabState();
}

enum _SummaryMode { drawing, text }

enum _SummaryTextNote { recommendations, project }

_SummaryTextNote _textNoteFromTabKey(String tabKey) {
  return tabKey == 'Préconisations-Projet'
      ? _SummaryTextNote.project
      : _SummaryTextNote.recommendations;
}

class _SummaryTabState extends State<SummaryTab>
    with AutomaticKeepAliveClientMixin {
  _SummaryMode _mode = _SummaryMode.drawing;
  _SummaryTextNote _activeTextNote = _SummaryTextNote.project;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(_applyControllerMode);
  }

  @override
  void didUpdateWidget(covariant SummaryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(_applyControllerMode);
      widget.controller?._attach(_applyControllerMode);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(_applyControllerMode);
    super.dispose();
  }

  void _applyControllerMode(_SummaryMode mode, _SummaryTextNote? note) {
    void apply() {
      _mode = mode;
      if (note != null) _activeTextNote = note;
    }

    if (!mounted) {
      apply();
      return;
    }
    setState(apply);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final patientId = widget.dossier.patient.id;
    final child = _mode == _SummaryMode.drawing
        ? KeyedSubtree(
            key: const ValueKey('summary-mode-releve'),
            child: _buildDrawingMode(patientId),
          )
        : KeyedSubtree(
            key: const ValueKey('summary-mode-rapport'),
            child: _buildTextMode(patientId),
          );
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 340),
        reverseDuration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            fit: StackFit.expand,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          );
        },
        transitionBuilder: _buildModeTransition,
        child: child,
      ),
    );
  }

  Widget _buildModeTransition(Widget child, Animation<double> animation) {
    final isRapport = child.key == const ValueKey('summary-mode-rapport');
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: isRapport ? const Offset(0.045, 0) : const Offset(-0.045, 0),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.985, end: 1).animate(curved),
          child: child,
        ),
      ),
    );
  }

  Widget _buildDrawingMode(String patientId) {
    return NotesWidget(
      key: ValueKey('summary-canvas-$patientId'),
      patientId: patientId,
      tabKey: 'Résumé',
      title: 'Résumé',
      toolset: NoteToolset.advanced,
      mode: NoteCanvasMode.freeform,
      allowPagination: true,
      showText: false,
      allowTextModal: true,
      onExpandToTab: widget.onExpandToTab,
      showSaveButton: false,
      fillParentHeight: true,
      embedded: false,
      showCanvasTopDivider: false,
      showHeaderUndoRedo: false,
      undoRedoInToolbar: true,
      toolbarPlacement: NoteToolbarPlacement.bottomCenter,
      leadingNavWidget: _SummaryModeSwitch(mode: _mode, onChanged: _setMode),
    );
  }

  Widget _buildTextMode(String patientId) {
    return _buildTextNotebook(patientId);
  }

  Widget _buildTextNotebook(String patientId) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTextTabs(),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildTextNoteLayer(
                  note: _SummaryTextNote.recommendations,
                  child: _buildTextNote(
                    patientId: patientId,
                    tabKey: 'Préconisations-Résumé',
                    title: 'Préconisations',
                    liveText: widget.liveTextResume,
                  ),
                ),
                _buildTextNoteLayer(
                  note: _SummaryTextNote.project,
                  child: _buildTextNote(
                    patientId: patientId,
                    tabKey: 'Préconisations-Projet',
                    title: "Projet de l'usager",
                    liveText: widget.liveTextProjet,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextNoteLayer({
    required _SummaryTextNote note,
    required Widget child,
  }) {
    final active = _activeTextNote == note;
    final slideOffset = note == _SummaryTextNote.recommendations
        ? const Offset(-0.025, 0)
        : const Offset(0.025, 0);
    return IgnorePointer(
      ignoring: !active,
      child: AnimatedOpacity(
        opacity: active ? 1 : 0,
        duration: const Duration(milliseconds: 240),
        curve: active ? Curves.easeOutCubic : Curves.easeInCubic,
        child: AnimatedSlide(
          offset: active ? Offset.zero : slideOffset,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: active ? 1 : 0.992,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildTextTabs() {
    return Container(
      height: 64,
      color: const Color(0xFFF2ECF5),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabsWidth = (constraints.maxWidth - 210).clamp(280.0, 520.0);
          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: 12,
                child: _SummaryModeSwitch(mode: _mode, onChanged: _setMode),
              ),
              SizedBox(
                width: tabsWidth,
                child: Row(
                  children: [
                    _SummaryTextTab(
                      icon: LucideIcons.fileText,
                      label: 'Préconisations',
                      selected:
                          _activeTextNote == _SummaryTextNote.recommendations,
                      onTap: () =>
                          _setTextNote(_SummaryTextNote.recommendations),
                    ),
                    _SummaryTextTab(
                      icon: LucideIcons.user,
                      label: "Projet de l'usager",
                      selected: _activeTextNote == _SummaryTextNote.project,
                      onTap: () => _setTextNote(_SummaryTextNote.project),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTextNote({
    required String patientId,
    required String tabKey,
    required String title,
    required String? liveText,
  }) {
    return NotesWidget(
      key: ValueKey('summary-written-$tabKey-$patientId'),
      patientId: patientId,
      tabKey: tabKey,
      title: title,
      placeholder: 'Texte...',
      showCanvas: false,
      embedded: true,
      showSaveButton: false,
      allowPagination: false,
      allowTextModal: true,
      onExpandToTab: widget.onExpandTextNote == null
          ? null
          : () => widget.onExpandTextNote!(tabKey),
      expandModalFullscreen: widget.onExpandTextNote == null,
      liveText: liveText,
      onDraftChange: widget.onDraftChange == null
          ? null
          : (draft) => widget.onDraftChange!(tabKey, draft.text),
      fillParentHeight: true,
      attachedToTitleBanner: true,
      borderlessTextEditor: true,
    );
  }

  void _setMode(_SummaryMode mode) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
  }

  void _setTextNote(_SummaryTextNote note) {
    if (_activeTextNote == note) return;
    setState(() => _activeTextNote = note);
  }
}

class _SummaryModeSwitch extends StatelessWidget {
  final _SummaryMode mode;
  final ValueChanged<_SummaryMode> onChanged;

  const _SummaryModeSwitch({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFE4E7EB)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SummaryModeSegment(
              icon: LucideIcons.pencil,
              label: 'Relevé',
              selected: mode == _SummaryMode.drawing,
              onTap: () => onChanged(_SummaryMode.drawing),
            ),
            _SummaryModeSegment(
              icon: LucideIcons.fileText,
              label: 'Rapport',
              selected: mode == _SummaryMode.text,
              onTap: () => onChanged(_SummaryMode.text),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryModeSegment extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SummaryModeSegment({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : const Color(0xFF554265);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? kBrandPurple : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryTextTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SummaryTextTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: const Color(0xFF0E1116)),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF0E1116),
                ),
              ),
              const SizedBox(height: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: selected ? (label.length * 3.2).clamp(18.0, 72.0) : 0,
                height: 1.5,
                decoration: BoxDecoration(
                  color: const Color(0xFF8E6AA4),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
