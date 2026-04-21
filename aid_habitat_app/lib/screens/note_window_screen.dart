import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
// Desktop-only. Sur web/mobile, un stub no-op fait passer la compilation
// — cet écran n'est de toute façon jamais instancié hors desktop.
import '../services/multi_window_stub.dart'
    if (dart.library.io) 'package:desktop_multi_window/desktop_multi_window.dart';

/// Dedicated MaterialApp shown in a SECONDARY OS window (launched via
/// `DesktopMultiWindow.createWindow`). Hosts a single full-screen note
/// editor.
///
/// The secondary Flutter engine does NOT have sqflite / path_provider /
/// google_fonts registered — so this window cannot touch the local DB or
/// use remote fonts. All persistence goes through the MAIN window via
/// `invokeMethod` IPC:
///   - initial text is passed inline in the launch payload
///   - every keystroke is sent immediately via `liveNote` (no debounce)
///   - the main window mirrors the change into the in-app NotesWidget
///     AND schedules a debounced SQLite write + NocoDB sync
///   - the window also periodically reports its size via `reportNoteSize`
///     so subsequent note windows open at the same dimensions
class NoteWindowApp extends StatelessWidget {
  final int windowId;
  final String patientId;
  final String tabKey;
  final String title;
  final String initialText;

  const NoteWindowApp({
    super.key,
    required this.windowId,
    required this.patientId,
    required this.tabKey,
    required this.title,
    required this.initialText,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF907CA1),
          primary: const Color(0xFF907CA1),
        ),
        useMaterial3: true,
      ),
      home: NoteWindowScreen(
        windowId: windowId,
        patientId: patientId,
        tabKey: tabKey,
        title: title,
        initialText: initialText,
      ),
    );
  }
}

class NoteWindowScreen extends StatefulWidget {
  final int windowId;
  final String patientId;
  final String tabKey;
  final String title;
  final String initialText;

  const NoteWindowScreen({
    super.key,
    required this.windowId,
    required this.patientId,
    required this.tabKey,
    required this.title,
    required this.initialText,
  });

  @override
  State<NoteWindowScreen> createState() => _NoteWindowScreenState();
}

class _NoteWindowScreenState extends State<NoteWindowScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _sizeReportTimer;
  Size? _lastReportedSize;
  Offset? _lastReportedOrigin;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialText;
    _controller.selection =
        TextSelection.collapsed(offset: widget.initialText.length);

    // IPC handler: the main window pushes text when the user types in
    // the in-app NotesWidget — mirror it here unless we're actively
    // typing (we don't want to yank the cursor out from under them).
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'pushNote') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (args['patientId'] != widget.patientId ||
            args['tabKey'] != widget.tabKey) return;
        final text = args['text'] as String? ?? '';
        if (_controller.text == text) return;
        if (_focusNode.hasFocus) return;
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    });

    // Periodically report our current size to the main window so the
    // next popup opens with the same dimensions.
    _sizeReportTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _reportSize());
  }

  @override
  void dispose() {
    _sizeReportTimer?.cancel();
    // Final flush — send one last IPC with the current text before the
    // window vanishes, so nothing is lost.
    _sendLive(_controller.text, flush: true);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  static const _windowFrameChannel = MethodChannel('aidhabitat/window_frame');

  Future<void> _reportSize() async {
    if (!mounted) return;
    // Lit la frame native (origine + taille) via le plugin Swift local
    // `WindowFramePlugin` — le plugin Dart `desktop_multi_window` 0.2.1
    // n'expose pas getFrame().
    try {
      final raw = await _windowFrameChannel.invokeMethod<List<dynamic>>('getFrame');
      if (raw == null || raw.length != 4) return;
      final x = (raw[0] as num).toDouble();
      final y = (raw[1] as num).toDouble();
      final w = (raw[2] as num).toDouble();
      final h = (raw[3] as num).toDouble();
      final size = Size(w, h);
      if (_lastReportedSize == size && _lastReportedOrigin == Offset(x, y)) {
        return;
      }
      _lastReportedSize = size;
      _lastReportedOrigin = Offset(x, y);
      DesktopMultiWindow.invokeMethod(0, 'reportNoteFrame', {
        'x': x,
        'y': y,
        'width': w,
        'height': h,
      }).catchError((_) {});
    } catch (_) {
      // Fallback : si le plugin natif n'est pas dispo, on envoie au moins
      // la taille comme avant (pas de position, conservée entre ouvertures).
      final size = MediaQuery.of(context).size;
      if (_lastReportedSize == size) return;
      _lastReportedSize = size;
      DesktopMultiWindow.invokeMethod(0, 'reportNoteSize', {
        'width': size.width,
        'height': size.height,
      }).catchError((_) {});
    }
  }

  /// Fire-and-forget push of the current text to the main window. Called
  /// on EVERY keystroke — no debounce — so the in-app NotesWidget updates
  /// instantly. The main window throttles the SQLite/NocoDB writes on
  /// its side.
  void _sendLive(String text, {bool flush = false}) {
    DesktopMultiWindow.invokeMethod(0, 'liveNote', {
      'patientId': widget.patientId,
      'tabKey': widget.tabKey,
      'text': text,
      'flush': flush,
    }).catchError((_) {});
  }

  void _closeWindow() {
    WindowController.fromWindowId(widget.windowId).close();
  }

  @override
  Widget build(BuildContext context) {
    // La NSWindow secondaire a déjà `titlebarAppearsTransparent + titleVisibility.hidden
    // + fullSizeContentView` (cf. plugin desktop_multi_window). La title bar
    // macOS (28 px) reste interactive pour afficher les 3 pastilles rouge/
    // jaune/vert, mais elle est transparente. Notre contenu Flutter glisse
    // donc sous cette bande — un padding-top aligne le titre verticalement
    // avec les pastilles, et le padding-left leur laisse la place.
    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(82, 6, 14, 6),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF334155),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                maxLines: null,
                expands: true,
                autofocus: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 14, height: 1.5),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Écrivez votre note…',
                ),
                onChanged: _sendLive,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
