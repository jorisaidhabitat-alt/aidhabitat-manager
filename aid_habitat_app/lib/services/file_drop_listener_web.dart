// Implémentation web du drag-and-drop OS → Flutter. Utilise `dart:html`
// pour intercepter les événements `dragover` / `drop` au niveau
// `document` et lire les fichiers via FileReader. Les zones de dépôt
// Flutter (DocumentsScreen, PhotosTab) s'abonnent aux streams et
// filtrent par hit-test sur leur propre RenderBox.
//
// Pourquoi `document` et pas `window` :
//   - Le document body couvre la viewport entière, donc tout drop dans
//     la zone visible est intercepté.
//   - Sans `preventDefault` sur `dragover`, le browser refuse le drop
//     (comportement par défaut = navigation vers le fichier dropé).
//   - Safari macOS et Chrome écoutent les deux ; Firefox aussi.
//
// Demande utilisateur 2026-05-05 : « sur Mac, le drag and drop ne
// fonctionne pas quand je souhaite prendre un document ou une image et
// le mettre direct dans une des parties photos de la VAD ou dans
// l'espace document. Cela doit être possible ».

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'file_drop_listener.dart';

class _WebFileDropListener implements FileDropListener {
  bool _activated = false;

  final StreamController<FileDropEvent> _dropCtrl =
      StreamController<FileDropEvent>.broadcast();
  final StreamController<FileDropOverEvent> _overCtrl =
      StreamController<FileDropOverEvent>.broadcast();

  @override
  Stream<FileDropEvent> get onDrop => _dropCtrl.stream;

  @override
  Stream<FileDropOverEvent> get onDragOver => _overCtrl.stream;

  @override
  void activate() {
    if (_activated) return;
    _activated = true;
    _attach();
  }

  void _attach() {
    final doc = html.document;

    // dragenter / dragover : préviennent l'action par défaut du browser
    // (= ouvrir le fichier dans un nouvel onglet) sinon le drop ne sera
    // jamais émis. On émet aussi l'event `onDragOver` pour permettre
    // le highlight live des drop zones Flutter.
    doc.addEventListener('dragenter', (event) {
      final e = event as html.MouseEvent;
      e.preventDefault();
    });

    doc.addEventListener('dragover', (event) {
      final e = event as html.MouseEvent;
      e.preventDefault();
      // On force `effectAllowed = 'copy'` pour que le curseur OS
      // affiche un + (Mac/Win) → feedback visuel cohérent avec l'idée
      // « je vais déposer une copie ».
      try {
        final dt = (e as dynamic).dataTransfer;
        if (dt != null) dt.dropEffect = 'copy';
      } catch (_) {}
      _overCtrl.add(FileDropOverEvent(
        viewportX: e.client.x.toDouble(),
        viewportY: e.client.y.toDouble(),
        isLeaving: false,
      ));
    });

    doc.addEventListener('dragleave', (event) {
      // dragleave est tiré aussi quand on traverse une frontière interne
      // (ex: passe d'un div à son parent). On ne peut pas distinguer un
      // « vrai » leave d'un cross-boundary intra-document sans tracker
      // les coords. Heuristique : on émet seulement un leave si la
      // position est hors de la viewport (relatedTarget == null suffit
      // sur la plupart des browsers).
      final e = event as html.MouseEvent;
      final related = (e as dynamic).relatedTarget;
      if (related != null) return;
      _overCtrl.add(FileDropOverEvent(
        viewportX: e.client.x.toDouble(),
        viewportY: e.client.y.toDouble(),
        isLeaving: true,
      ));
    });

    doc.addEventListener('drop', (event) async {
      final e = event as html.MouseEvent;
      e.preventDefault();
      _overCtrl.add(FileDropOverEvent(
        viewportX: e.client.x.toDouble(),
        viewportY: e.client.y.toDouble(),
        isLeaving: true,
      ));

      // Lecture des fichiers : `dataTransfer.files` (FileList) couvre
      // 99% des cas (drop depuis Finder/Explorer ou onglet image). Les
      // drops de URLs / texte sont ignorés (pas notre use-case ici).
      final dt = (e as dynamic).dataTransfer;
      if (dt == null) return;
      final files = dt.files;
      if (files == null || files.length == 0) return;

      final dropped = <DroppedFile>[];
      for (var i = 0; i < files.length; i++) {
        final file = files[i] as html.File;
        final bytes = await _readFileBytes(file);
        if (bytes == null) continue;
        dropped.add(DroppedFile(
          name: file.name,
          bytes: bytes,
          mimeType: file.type.isNotEmpty ? file.type : _guessMime(file.name),
        ));
      }
      if (dropped.isEmpty) return;
      _dropCtrl.add(FileDropEvent(
        files: dropped,
        viewportX: e.client.x.toDouble(),
        viewportY: e.client.y.toDouble(),
      ));
    });
  }

  Future<Uint8List?> _readFileBytes(html.File file) async {
    try {
      final reader = html.FileReader();
      reader.readAsArrayBuffer(file);
      await reader.onLoadEnd.first;
      final result = reader.result;
      if (result is Uint8List) return result;
      if (result is List<int>) return Uint8List.fromList(result);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Devine le MIME quand le browser ne le fournit pas (rare — Mac
  /// Finder met toujours quelque chose, mais des drops cross-tab parfois
  /// arrivent vides). Fallback heuristique sur l'extension.
  String _guessMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
      return 'image/heic';
    }
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'application/octet-stream';
  }
}

FileDropListener createFileDropListener() => _WebFileDropListener();
