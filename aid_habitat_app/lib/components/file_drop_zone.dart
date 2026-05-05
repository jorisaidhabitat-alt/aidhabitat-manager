import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../services/file_drop_listener.dart';

/// Widget qui transforme une zone de l'interface Flutter en zone de
/// dépôt pour les fichiers OS (drag-and-drop depuis Finder/Explorer/
/// onglets browser). Réservé au web — sur natif, le widget rend
/// simplement son enfant sans s'abonner au listener.
///
/// Hit-test :
/// 1. À chaque dragover, on récupère le `RenderBox` du widget courant
///    et on regarde si les coordonnées viewport tombent dans son rect
///    global. Si oui → highlight ON, sinon highlight OFF.
/// 2. Au drop, on refait le hit-test : si le drop tombe dans le rect,
///    on appelle `onDrop` avec la liste de fichiers. Sinon on ignore
///    (un autre FileDropZone du même écran ramassera).
///
/// Plusieurs FileDropZone peuvent coexister sur un même écran (ex:
/// `PhotosTab` a un drop zone par section). Les plus profondes (rect
/// le plus petit) gagnent — on l'implémente via un mécanisme de
/// « priorité par taille de rect » : chaque zone se compare aux autres
/// et ne consomme que si elle est la plus petite contenant le point.
///
/// La liste globale `_activeZones` permet la résolution de priorité.
class FileDropZone extends StatefulWidget {
  /// Callback appelé quand un drop tombe dans la zone. Reçoit les
  /// fichiers déjà lus en mémoire.
  final void Function(List<DroppedFile> files) onDrop;

  /// Callback appelé quand l'état highlight change (ON pendant que le
  /// curseur survole la zone avec un drag actif, OFF sinon). Permet à
  /// l'appelant d'animer un border / overlay.
  final ValueChanged<bool>? onHighlight;

  /// Filtre optionnel — si fourni, retourne `true` si la zone accepte
  /// le drop. Permet par exemple d'avoir une zone qui n'accepte que les
  /// images (PhotosTab) vs une autre qui accepte tout (Documents).
  final bool Function(List<DroppedFile> files)? accept;

  /// Enfant à afficher. Le widget enveloppe simplement l'enfant et
  /// installe les listeners — il ne dessine aucun overlay par défaut
  /// (l'appelant gère via `onHighlight`).
  final Widget child;

  const FileDropZone({
    super.key,
    required this.onDrop,
    required this.child,
    this.onHighlight,
    this.accept,
  });

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

/// Liste mondiale des zones actives, utilisée pour résoudre les
/// conflits de hit-test (le rect le plus petit gagne). Ordre
/// d'enregistrement non significatif — la priorité dépend
/// uniquement de la surface.
final List<_FileDropZoneState> _activeZones = [];

class _FileDropZoneState extends State<FileDropZone> {
  StreamSubscription<FileDropOverEvent>? _overSub;
  StreamSubscription<FileDropEvent>? _dropSub;
  bool _highlight = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) return;
    _activeZones.add(this);
    _overSub = FileDropListener.instance.onDragOver.listen(_handleOver);
    _dropSub = FileDropListener.instance.onDrop.listen(_handleDrop);
  }

  @override
  void dispose() {
    _activeZones.remove(this);
    _overSub?.cancel();
    _dropSub?.cancel();
    super.dispose();
  }

  /// Récupère le rect global (dans les coords logiques Flutter) du
  /// widget courant. Retourne null si le widget n'est pas encore monté
  /// ou si son RenderBox n'est pas attached.
  Rect? _globalRect() {
    final ctx = context;
    if (!ctx.mounted) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return null;
    final origin = ro.localToGlobal(Offset.zero);
    return origin & ro.size;
  }

  /// Convertit les coords viewport (CSS pixels) en coords logiques
  /// Flutter. Sur Flutter web, les deux systèmes coïncident pour la
  /// position dans la fenêtre — Flutter applique son devicePixelRatio
  /// en interne sur le canvas mais expose des coords logiques aux
  /// widgets, et `event.client.x/y` sont en CSS pixels (= coords
  /// logiques). Pas de conversion nécessaire.
  Offset _viewportToFlutter(double vx, double vy) => Offset(vx, vy);

  /// Compare ce rect aux autres FileDropZone actives qui contiennent
  /// le même point. Renvoie true si CE widget a la surface la plus
  /// petite (= il est le plus spécifique, par ex. un slot photo
  /// contenu dans le panneau VAD entier).
  bool _isMostSpecificAt(Offset point) {
    final myRect = _globalRect();
    if (myRect == null || !myRect.contains(point)) return false;
    final myArea = myRect.width * myRect.height;
    for (final other in _activeZones) {
      if (other == this) continue;
      final r = other._globalRect();
      if (r == null) continue;
      if (!r.contains(point)) continue;
      final area = r.width * r.height;
      // Si une autre zone est strictement plus petite et contient le
      // point, elle gagne.
      if (area < myArea) return false;
    }
    return true;
  }

  void _handleOver(FileDropOverEvent event) {
    if (!mounted) return;
    if (event.isLeaving) {
      _setHighlight(false);
      return;
    }
    final p = _viewportToFlutter(event.viewportX, event.viewportY);
    _setHighlight(_isMostSpecificAt(p));
  }

  void _handleDrop(FileDropEvent event) {
    if (!mounted) return;
    _setHighlight(false);
    final p = _viewportToFlutter(event.viewportX, event.viewportY);
    if (!_isMostSpecificAt(p)) return;
    final accept = widget.accept;
    if (accept != null && !accept(event.files)) return;
    widget.onDrop(event.files);
  }

  void _setHighlight(bool on) {
    if (_highlight == on) return;
    _highlight = on;
    widget.onHighlight?.call(on);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
