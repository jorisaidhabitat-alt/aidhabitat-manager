import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:scribble/scribble.dart';

import '../services/data_service.dart';

class NotesWidget extends StatefulWidget {
  const NotesWidget({super.key, required this.patientId, required this.tabKey});

  final String patientId;
  final String tabKey;

  @override
  State<NotesWidget> createState() => _NotesWidgetState();
}

class _NotesWidgetState extends State<NotesWidget> {
  late final ScribbleNotifier notifier;
  final DataService _dataService = DataService();
  Timer? _saveDebounce;
  bool _isLoaded = false;
  bool _isHydrating = false;

  @override
  void initState() {
    super.initState();
    notifier = ScribbleNotifier();
    notifier.addListener(_scheduleSave);
    _loadDrawing();
  }

  @override
  void didUpdateWidget(covariant NotesWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.patientId != widget.patientId ||
        oldWidget.tabKey != widget.tabKey) {
      _loadDrawing();
    }
  }

  Future<void> _loadDrawing() async {
    setState(() => _isLoaded = false);
    final drawingJson = await _dataService.fetchNoteDrawingJson(
      patientId: widget.patientId,
      tabKey: widget.tabKey,
    );

    _isHydrating = true;
    notifier.clear();
    if (drawingJson != null && drawingJson.isNotEmpty) {
      final state = ScribbleState.fromJson(
        jsonDecode(drawingJson) as Map<String, dynamic>,
      );
      notifier.setSketch(sketch: state.sketch, addToUndoHistory: false);
    }
    _isHydrating = false;

    if (mounted) {
      setState(() => _isLoaded = true);
    }

    final refreshed = await _dataService.refreshNotePageFromRemote(
      patientId: widget.patientId,
      tabKey: widget.tabKey,
    );
    if (!refreshed) return;

    final remoteDrawingJson = await _dataService.fetchNoteDrawingJson(
      patientId: widget.patientId,
      tabKey: widget.tabKey,
    );
    if (remoteDrawingJson == null || remoteDrawingJson.isEmpty) return;

    _isHydrating = true;
    notifier.clear();
    final remoteState = ScribbleState.fromJson(
      jsonDecode(remoteDrawingJson) as Map<String, dynamic>,
    );
    notifier.setSketch(sketch: remoteState.sketch, addToUndoHistory: false);
    _isHydrating = false;
  }

  void _scheduleSave() {
    if (!_isLoaded || _isHydrating) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _persistDrawing);
  }

  Future<void> _persistDrawing() async {
    await _dataService.saveNoteDrawingJson(
      patientId: widget.patientId,
      tabKey: widget.tabKey,
      drawingJson: jsonEncode(notifier.value.toJson()),
    );
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    notifier.removeListener(_scheduleSave);
    notifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Notes",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.tabKey,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Icon(LucideIcons.edit3, color: Colors.grey.shade400),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _isLoaded
                ? ClipRect(child: Scribble(notifier: notifier, drawPen: true))
                : const Center(child: CircularProgressIndicator()),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ToolButton(
                  icon: LucideIcons.penTool,
                  isActive: true,
                  onTap: () {
                    notifier.setColor(Colors.black);
                    notifier.setStrokeWidth(4);
                  },
                ),
                const SizedBox(width: 16),
                _ToolButton(
                  icon: LucideIcons.eraser,
                  isActive: false,
                  onTap: notifier.setEraser,
                ),
                const SizedBox(width: 16),
                _ToolButton(
                  icon: LucideIcons.highlighter,
                  isActive: false,
                  onTap: () {
                    notifier.setColor(Colors.yellow.withValues(alpha: 0.5));
                    notifier.setStrokeWidth(10);
                  },
                ),
                const SizedBox(width: 32),
                _ColorDot(
                  color: Colors.black,
                  onTap: () => notifier.setColor(Colors.black),
                ),
                const SizedBox(width: 8),
                _ColorDot(
                  color: Colors.blue,
                  onTap: () => notifier.setColor(Colors.blue),
                ),
                const SizedBox(width: 8),
                _ColorDot(
                  color: Colors.red,
                  onTap: () => notifier.setColor(Colors.red),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFF907CA1).withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isActive ? Border.all(color: const Color(0xFF907CA1)) : null,
        ),
        child: Icon(
          icon,
          color: isActive ? const Color(0xFF907CA1) : Colors.grey,
          size: 24,
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;

  const _ColorDot({required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.grey.shade300),
        ),
      ),
    );
  }
}
