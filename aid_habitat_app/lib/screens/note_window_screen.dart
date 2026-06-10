import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
// Desktop-only. Sur web/mobile, un stub no-op fait passer la compilation.
import '../services/multi_window_stub.dart'
    if (dart.library.io) 'package:desktop_multi_window/desktop_multi_window.dart';
// Web-only : BroadcastChannel IPC + persistance frame en localStorage.
import '../services/note_window_web_stub.dart'
    if (dart.library.html) '../services/note_window_web.dart'
    as note_window_web;
import '../components/brand_colors.dart';
import '../components/notes_canvas_painters.dart';
import '../services/data_service.dart';

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
  final Map<int, String> initialDrawingPages;

  /// 'text' (défaut, comportement historique : TextField synchronisé
  /// par IPC avec la fenêtre principale) ou 'drawing' (canvas plein
  /// écran avec pagination, persistance directe dans IndexedDB partagé
  /// — démarré uniquement pour le canvas Résumé du relevé de visite,
  /// demande utilisateur 2026-05-04).
  final String mode;

  const NoteWindowApp({
    super.key,
    required this.windowId,
    required this.patientId,
    required this.tabKey,
    required this.title,
    required this.initialText,
    this.initialDrawingPages = const <int, String>{},
    this.mode = 'text',
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF7F7FA),
        colorScheme: ColorScheme.fromSeed(
          seedColor: kBrandPurple,
          primary: kBrandPurple,
        ),
        useMaterial3: true,
      ),
      home: mode == 'drawing'
          ? NoteWindowDrawingScreen(
              windowId: windowId,
              patientId: patientId,
              tabKey: tabKey,
              title: title,
              initialDrawingPages: initialDrawingPages,
            )
          : NoteWindowScreen(
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

class _NoteWindowScreenState extends State<NoteWindowScreen>
    with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _sizeReportTimer;
  Size? _lastReportedSize;
  Offset? _lastReportedOrigin;
  StreamSubscription<dynamic>? _webIpcSub;
  bool _nativeIpcAvailable = true;
  bool _tearingDown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.text = widget.initialText;
    _controller.selection = TextSelection.collapsed(
      offset: widget.initialText.length,
    );
    _focusNode.addListener(_handleFocusChange);

    // IPC handler: the main window pushes text when the user types in
    // the in-app NotesWidget — mirror it here EVEN if we're focused.
    //
    // Avant 2026-05-05 : on skippait l'update quand le TextField avait
    // le focus (pour éviter de yanker le curseur de l'utilisateur).
    // Demande utilisateur 2026-05-05 : « tout doit être complètement
    // instantané sur cette partie là et parfaitement synchronisé sans
    // délais ». Le BroadcastChannel ne renvoie PAS le message à
    // l'expéditeur (spec W3C) → quand on reçoit `pushNote`, c'est
    // forcément que l'autre fenêtre a tapé, donc le curseur courant
    // ici n'est pas en train de bouger. On préserve quand même la
    // position du caret (clampée à la nouvelle longueur) au cas où
    // l'utilisateur aurait juste cliqué dans le champ sans taper.
    void onPushNote(Map<String, dynamic> args) {
      if (args['patientId'] != widget.patientId ||
          args['tabKey'] != widget.tabKey) {
        return;
      }
      final text = args['text']?.toString() ?? '';
      if (_controller.text == text) return;
      final oldOffset = _controller.selection.baseOffset.clamp(0, text.length);
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: oldOffset >= 0 ? oldOffset : text.length,
        ),
      );
    }

    if (kIsWeb) {
      _webIpcSub = note_window_web.listenNoteIpc((method, args) {
        if (method == 'pushNote') onPushNote(args);
      });
    } else {
      DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
        if (call.method == 'pushNote') {
          onPushNote(Map<String, dynamic>.from(call.arguments as Map));
        }
      });
    }

    // Periodically report our current size to the main window so the
    // next popup opens with the same dimensions.
    //
    // Intervalle 5s (vs 1s avant — fix audit 2026-05-04) :
    // `_reportSize` lui-même short-circuite si la size n'a pas changé,
    // donc 1s amenait 3600 round-trips IPC + 3600 écritures
    // localStorage par heure pour rien. 5s reste assez réactif pour
    // que la prochaine ouverture de la popup retrouve la dernière
    // dimension utilisée (l'ergo ne resize jamais 5 fois en 5s).
    _sizeReportTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _reportSize(),
    );
  }

  @override
  void deactivate() {
    if (!kIsWeb) {
      _flushLiveSafely();
    }
    super.deactivate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _flushLiveSafely();
    }
  }

  @override
  void dispose() {
    _tearingDown = true;
    WidgetsBinding.instance.removeObserver(this);
    _sizeReportTimer?.cancel();
    _webIpcSub?.cancel();
    _focusNode.removeListener(_handleFocusChange);
    if (kIsWeb) {
      // Sur web la popup ne subit pas le teardown de moteur Flutter du
      // plugin desktop_multi_window. On peut donc conserver le flush final.
      _sendLive(_controller.text, flush: true);
    } else {
      DesktopMultiWindow.setMethodHandler(null);
    }
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  static const _windowFrameChannel = MethodChannel('aidhabitat/window_frame');

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) {
      _flushLiveSafely();
    }
  }

  void _flushLiveSafely() {
    if (_tearingDown) return;
    if (!kIsWeb && !_nativeIpcAvailable) return;
    _sendLive(_controller.text, flush: true);
  }

  Future<void> _reportSize() async {
    if (!mounted || _tearingDown) return;
    final viewportSize = MediaQuery.of(context).size;
    // Sur web : pas de plugin natif pour la frame. On lit
    // `window.outerWidth/Height` + `screenX/Y` côté JS pour récupérer
    // la position de la POPUP (vs `MediaQuery` qui ne donne que le
    // viewport interne). Le helper `persistNoteWindowFrame` écrit en
    // localStorage — la fenêtre principale relira au prochain open
    // pour rouvrir aux mêmes dimensions et position.
    if (kIsWeb) {
      try {
        final size = viewportSize;
        // Web : `window.screenLeft/Top` donne l'origine écran de la
        // popup (cf. dart:html via le helper).
        // On passe par 2 chemins :
        //   1) écrit en localStorage (réutilisé par tryOpenNoteWindow)
        //   2) broadcast via BroadcastChannel pour que la fenêtre
        //      principale mette à jour son cache mémoire à chaud
        //      (sinon il faudrait fermer/rouvrir pour propager).
        if (_lastReportedSize == size) return;
        _lastReportedSize = size;
        // L'origine n'est pas accessible depuis Flutter Web sans dart:html
        // (qui est dans le helper). On envoie juste la taille — la
        // position est captée côté localStorage par persistNoteWindowFrame
        // qui a accès à window.screenX directement.
        note_window_web.sendNoteIpc(
          method: 'reportNoteSize',
          args: {'width': size.width, 'height': size.height},
        );
        // Le helper persistNoteWindowFrame lit lui-même window.screenX/Y
        // → on lui passe la taille connue, il complète avec l'origine.
        note_window_web.persistNoteWindowFrame(
          tabKey: widget.tabKey,
          // -1 = sentinel pour dire "lis depuis window.screenX/Y" côté
          // helper. Pas implémenté — on écrit la taille seule pour l'instant
          // et on laisse la position au navigateur (qui réouvre généralement
          // au même endroit pour une popup d'origine identique).
          left: -1,
          top: -1,
          width: size.width,
          height: size.height,
        );
      } catch (_) {
        /* ignore */
      }
      return;
    }
    // Native macOS : lit la frame via le plugin Swift local
    // `WindowFramePlugin` — le plugin Dart `desktop_multi_window` 0.2.1
    // n'expose pas getFrame().
    try {
      final raw = await _windowFrameChannel.invokeMethod<List<dynamic>>(
        'getFrame',
      );
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
      if (!_nativeIpcAvailable) return;
      DesktopMultiWindow.invokeMethod(0, 'reportNoteFrame', {
        'x': x,
        'y': y,
        'width': w,
        'height': h,
      }).catchError((_) {
        _nativeIpcAvailable = false;
      });
    } catch (_) {
      // Fallback : si le plugin natif n'est pas dispo, on envoie au moins
      // la taille comme avant (pas de position, conservée entre ouvertures).
      final size = viewportSize;
      if (_lastReportedSize == size) return;
      _lastReportedSize = size;
      if (!_nativeIpcAvailable) return;
      DesktopMultiWindow.invokeMethod(0, 'reportNoteSize', {
        'width': size.width,
        'height': size.height,
      }).catchError((_) {
        _nativeIpcAvailable = false;
      });
    }
  }

  /// Fire-and-forget push of the current text to the main window. Called
  /// on EVERY keystroke — no debounce — so the in-app NotesWidget updates
  /// instantly. The main window throttles the SQLite/NocoDB writes on
  /// its side.
  void _sendLive(String text, {bool flush = false}) {
    if (kIsWeb) {
      note_window_web.sendNoteIpc(
        method: 'liveNote',
        args: {
          'patientId': widget.patientId,
          'tabKey': widget.tabKey,
          'text': text,
          'flush': flush,
        },
      );
      return;
    }
    if (_tearingDown || !_nativeIpcAvailable) return;
    DesktopMultiWindow.invokeMethod(0, 'liveNote', {
      'patientId': widget.patientId,
      'tabKey': widget.tabKey,
      'text': text,
      'flush': flush,
    }).catchError((_) {
      _nativeIpcAvailable = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // La NSWindow secondaire a déjà `titlebarAppearsTransparent + titleVisibility.hidden
    // + fullSizeContentView` (cf. plugin desktop_multi_window). La title bar
    // macOS (28 px) reste interactive pour afficher les 3 pastilles rouge/
    // jaune/vert, mais elle est transparente. Notre contenu Flutter glisse
    // donc sous cette bande — un padding-top aligne le titre verticalement
    // avec les pastilles, et le padding-left leur laisse la place.
    // Sur web : la fenêtre est un VRAI popup browser, donc la chrome
    // (pastilles + URL bar) est dessinée par le navigateur AU-DESSUS de
    // notre contenu. Pas besoin de réserver les 82 px à gauche pour les
    // pastilles (qui sont fake sur natif quand titlebar est transparente).
    final isWebPopup = kIsWeb;
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              Container(
                padding: EdgeInsets.fromLTRB(isWebPopup ? 16 : 82, 6, 14, 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: Color(0xFFE4E7EB))),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2B323A),
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
          // Indicateur visuel de redimensionnement dans le coin bas-droite
          // (3 petits traits diagonaux). Purement décoratif : le vrai resize
          // est géré par la NSWindow native (styleMask .resizable) — le
          // curseur devient automatiquement la poignée de redimensionnement
          // quand il passe au-dessus du coin.
          const Positioned(
            bottom: 3,
            right: 3,
            child: IgnorePointer(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CustomPaint(painter: _ResizeHintPainter()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 3 petits traits diagonaux (haut-droite → bas-gauche) dessinés en gris
/// clair, pour suggérer visuellement que la fenêtre est redimensionnable
/// par ce coin. Pattern classique (textarea HTML, windows macOS).
class _ResizeHintPainter extends CustomPainter {
  const _ResizeHintPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color =
          const Color(0xFF8A939D) // slate-400
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    // 3 traits diagonaux de longueurs croissantes (les plus proches du
    // coin sont les plus longs).
    for (var i = 0; i < 3; i++) {
      final offset = (i + 1) * 4.0;
      canvas.drawLine(
        Offset(size.width, size.height - offset),
        Offset(size.width - offset, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResizeHintPainter oldDelegate) => false;
}

/// Variante drawing de [NoteWindowScreen] — visualisation lecture seule
/// du canvas Résumé, avec pagination. Démarrée par [NoteWindowApp] quand
/// `mode == 'drawing'`.
///
/// Demande utilisateur 2026-05-04 : seule note format dessin du VAD
/// pouvant s'agrandir dans une 2e fenêtre browser. Voir summary_tab.dart
/// (callback `onExpandToTab`) et visit_report_screen.dart
/// (`_openDrawingNoteInSeparateWindow`).
class NoteWindowDrawingScreen extends StatelessWidget {
  final int windowId;
  final String patientId;
  final String tabKey;
  final String title;
  final Map<int, String> initialDrawingPages;

  const NoteWindowDrawingScreen({
    super.key,
    required this.windowId,
    required this.patientId,
    required this.tabKey,
    required this.title,
    this.initialDrawingPages = const <int, String>{},
  });

  @override
  Widget build(BuildContext context) {
    final isWebPopup = kIsWeb;
    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(isWebPopup ? 16 : 82, 6, 14, 6),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFE4E7EB))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$title · lecture seule',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2B323A),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // Canvas pleine page — même setup que SummaryTab (toolset
          // advanced, freeform, allowPagination, fillParentHeight).
          // Pas de `onExpandToTab` ici (on EST dans la fenêtre détachée
          // déjà — pas besoin d'un 2e bouton agrandir).
          Expanded(
            child: _DrawingCanvasNote(
              key: ValueKey('window-drawing-$patientId-$tabKey'),
              patientId: patientId,
              tabKey: tabKey,
              initialDrawingPages: initialDrawingPages,
            ),
          ),
        ],
      ),
    );
  }
}

/// Viewer lecture seule du dessin Résumé.
///
/// Important : cette fenêtre ne doit jamais modifier la note. Avant, on
/// montait un NotesWidget complet ici, ce qui donnait deux canvas éditables
/// en parallèle et provoquait des courses de sauvegarde. On charge seulement
/// les strokes existants et on les peint avec StrokePainter.
class _DrawingCanvasNote extends StatefulWidget {
  final String patientId;
  final String tabKey;
  final Map<int, String> initialDrawingPages;

  const _DrawingCanvasNote({
    super.key,
    required this.patientId,
    required this.tabKey,
    this.initialDrawingPages = const <int, String>{},
  });

  @override
  State<_DrawingCanvasNote> createState() => _DrawingCanvasNoteState();
}

class _DrawingCanvasNoteState extends State<_DrawingCanvasNote> {
  static const int _maxPages = 20;

  final DataService _dataService = DataService();
  final Map<int, List<Stroke>> _pageStrokes = <int, List<Stroke>>{};
  bool _loading = true;
  String? _error;
  int _currentPage = 0;
  int _totalPages = 1;

  @override
  void initState() {
    super.initState();
    if (widget.initialDrawingPages.isNotEmpty) {
      _hydrateInitialPages(widget.initialDrawingPages);
    } else if (kIsWeb) {
      unawaited(_loadPages());
    } else {
      _showMissingNativePayloadError();
    }
  }

  void _showMissingNativePayloadError() {
    _pageStrokes[0] = const <Stroke>[];
    _totalPages = 1;
    _currentPage = 0;
    _loading = false;
    _error =
        'Le dessin n’a pas été transmis à cette fenêtre. Fermez puis rouvrez depuis le relevé.';
  }

  void _hydrateInitialPages(Map<int, String> pages) {
    final sortedPages = pages.keys.toList()..sort();
    for (final page in sortedPages) {
      _pageStrokes[page] = _parseStrokes(pages[page] ?? '');
    }
    _pageStrokes.putIfAbsent(0, () => const <Stroke>[]);
    _totalPages = _pageStrokes.keys.isEmpty
        ? 1
        : (_pageStrokes.keys.reduce((a, b) => a > b ? a : b) + 1).clamp(
            1,
            _maxPages,
          );
    _loading = false;
  }

  Future<void> _loadPages() async {
    setState(() => _loading = true);
    try {
      var total = 1;
      for (var page = 0; page < _maxPages; page++) {
        final raw = await _dataService
            .fetchNoteDrawingJson(
              patientId: widget.patientId,
              tabKey: widget.tabKey,
              pageNumber: page,
            )
            .timeout(const Duration(seconds: 4));
        if (!mounted) return;
        if (raw == null || raw.isEmpty) {
          if (page == 0) {
            _pageStrokes[0] = const <Stroke>[];
          }
          break;
        }
        _pageStrokes[page] = _parseStrokes(raw);
        total = page + 1;
      }
      if (!mounted) return;
      setState(() {
        _totalPages = total.clamp(1, _maxPages);
        _currentPage = _currentPage.clamp(0, _totalPages - 1);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pageStrokes[0] = const <Stroke>[];
        _totalPages = 1;
        _currentPage = 0;
        _loading = false;
        _error =
            'La note ne peut pas être chargée depuis cette fenêtre. Fermez puis rouvrez depuis le relevé.';
      });
    }
  }

  List<Stroke> _parseStrokes(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <Stroke>[];
      final rawStrokes = decoded['strokes'];
      if (rawStrokes is! List) return const <Stroke>[];
      return rawStrokes
          .whereType<Map>()
          .map((item) => Stroke.fromJson(Map<String, dynamic>.from(item)))
          .whereType<Stroke>()
          .toList(growable: false);
    } catch (_) {
      return const <Stroke>[];
    }
  }

  void _goToPage(int page) {
    if (page < 0 || page >= _totalPages || page == _currentPage) return;
    setState(() => _currentPage = page);
  }

  @override
  Widget build(BuildContext context) {
    final strokes = _pageStrokes[_currentPage] ?? const <Stroke>[];
    return Container(
      color: const Color(0xFFF7F7FA),
      padding: const EdgeInsets.all(16),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE4E7EB)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: BackgroundPainter(
                                mode: NoteCanvasMode.freeform,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: CustomPaint(
                              painter: StrokePainter(
                                strokes: strokes,
                                activeStroke: null,
                              ),
                            ),
                          ),
                          if (_error != null)
                            Center(
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFFB4232F),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          else if (strokes.isEmpty)
                            const Center(
                              child: Text(
                                'Aucun dessin sur cette page.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF8A939D),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ),
          Positioned(top: 12, right: 12, child: _buildPageControls()),
        ],
      ),
    );
  }

  Widget _buildPageControls() {
    if (_loading) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
            spreadRadius: -4,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Page précédente',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: _currentPage > 0
                  ? () => _goToPage(_currentPage - 1)
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              '${_currentPage + 1}/$_totalPages',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF2B323A),
              ),
            ),
            IconButton(
              tooltip: 'Page suivante',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: _currentPage < _totalPages - 1
                  ? () => _goToPage(_currentPage + 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }
}
