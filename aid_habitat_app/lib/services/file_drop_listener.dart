import 'dart:async';
import 'dart:typed_data';

import 'file_drop_listener_web.dart'
    if (dart.library.io) 'file_drop_listener_io.dart';

/// Un fichier déposé via drag-and-drop depuis le système (Mac Finder,
/// Windows Explorer, Safari/Chrome image-from-tab). Les bytes sont déjà
/// lus en mémoire (FileReader) — l'appelant peut les écrire directement
/// dans SQLite ou faire un upload réseau.
class DroppedFile {
  final String name;
  final Uint8List bytes;
  final String mimeType;
  const DroppedFile({
    required this.name,
    required this.bytes,
    required this.mimeType,
  });

  /// Heuristique simple : « est-ce que ce fichier est une image qu'on
  /// peut router vers `PhotosTab` ou afficher comme vignette ? ». Couvre
  /// JPEG, PNG, GIF, WebP, HEIC, BMP. PDF et autres documents passent à
  /// `false` et iront dans l'espace Documents générique.
  bool get isImage {
    final mt = mimeType.toLowerCase();
    if (mt.startsWith('image/')) return true;
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.heif') ||
        lower.endsWith('.bmp');
  }

  bool get isPdf =>
      mimeType.toLowerCase() == 'application/pdf' ||
      name.toLowerCase().endsWith('.pdf');
}

/// Événement « le user a relâché un (ou plusieurs) fichier(s) sur la
/// fenêtre ». [viewportX/Y] = coordonnées CSS dans la viewport au
/// moment du drop, exploitables par les drop zones Flutter via
/// `RenderBox.globalToLocal` après conversion en device pixels.
class FileDropEvent {
  final List<DroppedFile> files;
  final double viewportX;
  final double viewportY;
  const FileDropEvent({
    required this.files,
    required this.viewportX,
    required this.viewportY,
  });
}

/// Événement de survol — émis pendant qu'un drag traverse la fenêtre.
/// [isLeaving] = true quand le curseur sort de la fenêtre (= dragleave
/// au niveau du document). Utilisé par les drop zones pour désactiver
/// leur état highlight.
class FileDropOverEvent {
  final double viewportX;
  final double viewportY;
  final bool isLeaving;
  const FileDropOverEvent({
    required this.viewportX,
    required this.viewportY,
    required this.isLeaving,
  });
}

/// Singleton global qui écoute les événements drag/drop au niveau
/// `window`. Les drop zones Flutter s'abonnent aux streams et filtrent
/// par hit-test sur leur propre RenderBox.
///
/// Sur web : implémenté via `dart:html` (preventDefault sur dragover
/// pour permettre le drop, FileReader pour lire les bytes). Sur natif :
/// no-op (le drag-and-drop OS passe par d'autres canaux — `desktop_drop`
/// ou DnD natif Flutter, hors-scope).
abstract class FileDropListener {
  static FileDropListener instance = createFileDropListener();

  /// Attache les listeners window-level. Idempotent — appeler plusieurs
  /// fois ne crée pas de doublon. À appeler dans `main()` après le
  /// `runApp` pour démarrer l'écoute.
  void activate();

  /// Stream des drops complétés. Chaque drop dans la fenêtre génère un
  /// événement (qu'il y ait ou non une drop zone Flutter qui claim).
  /// Les drop zones filtrent par hit-test sur leur rect global.
  Stream<FileDropEvent> get onDrop;

  /// Stream du survol. Émet à chaque dragover (~60Hz pendant un drag)
  /// + un événement avec `isLeaving=true` quand le curseur sort de la
  /// fenêtre. Les drop zones l'utilisent pour highlight/un-highlight.
  Stream<FileDropOverEvent> get onDragOver;
}
