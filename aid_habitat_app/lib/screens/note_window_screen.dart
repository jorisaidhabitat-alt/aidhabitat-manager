import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
// Desktop-only. Sur web/mobile, un stub no-op fait passer la compilation.
import '../services/multi_window_stub.dart'
    if (dart.library.io) 'package:desktop_multi_window/desktop_multi_window.dart';
// Web-only : BroadcastChannel IPC + persistance frame en localStorage.
import '../services/note_window_web_stub.dart'
    if (dart.library.html) '../services/note_window_web.dart' as note_window_web;
import '../components/notes_widget.dart';

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
          seedColor: const Color(0xFF7C6DAA),
          primary: const Color(0xFF7C6DAA),
        ),
        useMaterial3: true,
      ),
      home: mode == 'drawing'
          ? NoteWindowDrawingScreen(
              windowId: windowId,
              patientId: patientId,
              tabKey: tabKey,
              title: title,
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

class _NoteWindowScreenState extends State<NoteWindowScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _sizeReportTimer;
  Size? _lastReportedSize;
  Offset? _lastReportedOrigin;
  StreamSubscription<dynamic>? _webIpcSub;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialText;
    _controller.selection =
        TextSelection.collapsed(offset: widget.initialText.length);

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
      // ignore: avoid_print
      print(
        '[IPC←popup] pushNote received: patient=${args['patientId']} '
        'tabKey=${args['tabKey']} len=${args['text']?.toString().length ?? 0} '
        'me_patient=${widget.patientId} me_tabKey=${widget.tabKey}',
      );
      if (args['patientId'] != widget.patientId ||
          args['tabKey'] != widget.tabKey) return;
      final text = args['text']?.toString() ?? '';
      if (_controller.text == text) return;
      final oldOffset = _controller.selection.baseOffset
          .clamp(0, text.length);
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
  void dispose() {
    _sizeReportTimer?.cancel();
    _webIpcSub?.cancel();
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
    // Sur web : pas de plugin natif pour la frame. On lit
    // `window.outerWidth/Height` + `screenX/Y` côté JS pour récupérer
    // la position de la POPUP (vs `MediaQuery` qui ne donne que le
    // viewport interne). Le helper `persistNoteWindowFrame` écrit en
    // localStorage — la fenêtre principale relira au prochain open
    // pour rouvrir aux mêmes dimensions et position.
    if (kIsWeb) {
      try {
        final size = MediaQuery.of(context).size;
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
        note_window_web.sendNoteIpc(method: 'reportNoteSize', args: {
          'width': size.width,
          'height': size.height,
        });
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
      } catch (_) {/* ignore */}
      return;
    }
    // Native macOS : lit la frame via le plugin Swift local
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
    // ignore: avoid_print
    print(
      '[IPC→app] liveNote sent: tabKey=${widget.tabKey} '
      'len=${text.length} flush=$flush',
    );
    if (kIsWeb) {
      note_window_web.sendNoteIpc(method: 'liveNote', args: {
        'patientId': widget.patientId,
        'tabKey': widget.tabKey,
        'text': text,
        'flush': flush,
      });
      return;
    }
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
                child: CustomPaint(
                  painter: _ResizeHintPainter(),
                ),
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
      ..color = const Color(0xFF94A3B8) // slate-400
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

/// Variante drawing de [NoteWindowScreen] — canvas pleine page avec
/// pagination, sans IPC stroke. Démarrée par [NoteWindowApp] quand
/// `mode == 'drawing'` (cf. branche dans `main.dart` qui init aussi
/// `databaseFactoryFfiWebNoWebWorker` pour que NotesWidget puisse
/// lire/écrire le drawing JSON via DataService → SQLite WASM →
/// IndexedDB partagé avec la fenêtre principale).
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

  const NoteWindowDrawingScreen({
    super.key,
    required this.windowId,
    required this.patientId,
    required this.tabKey,
    required this.title,
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
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
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
          // Canvas pleine page — même setup que SummaryTab (toolset
          // advanced, freeform, allowPagination, fillParentHeight).
          // Pas de `onExpandToTab` ici (on EST dans la fenêtre détachée
          // déjà — pas besoin d'un 2e bouton agrandir).
          Expanded(
            child: _DrawingCanvasNote(
              key: ValueKey('window-drawing-$patientId-$tabKey'),
              patientId: patientId,
              tabKey: tabKey,
            ),
          ),
        ],
      ),
    );
  }
}

/// NotesWidget canvas pleine page pour la fenêtre détachée Résumé.
/// Toolset advanced + freeform + pagination (jusqu'à `maxPages = 20`
/// par défaut). Persistance via DataService.saveNoteDrawingJson →
/// IndexedDB partagé avec la fenêtre principale.
class _DrawingCanvasNote extends StatelessWidget {
  final String patientId;
  final String tabKey;
  const _DrawingCanvasNote({
    super.key,
    required this.patientId,
    required this.tabKey,
  });

  @override
  Widget build(BuildContext context) {
    return NotesWidget(
      key: ValueKey('window-canvas-$patientId-$tabKey'),
      patientId: patientId,
      tabKey: tabKey,
      title: 'Résumé',
      subtitle: 'Notes libres pour préparer les préconisations.',
      toolset: NoteToolset.advanced,
      mode: NoteCanvasMode.freeform,
      allowPagination: true,
      showText: false,
      // Pas de bouton agrandir dans la fenêtre détachée elle-même
      // (on est déjà dans la fenêtre détachée — pas besoin d'un autre
      // niveau d'expansion).
      allowTextModal: false,
      showSaveButton: false,
      fillParentHeight: true,
      embedded: false,
    );
  }
}
