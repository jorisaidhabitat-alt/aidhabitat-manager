import 'dart:async';

import 'file_drop_listener.dart';

/// Stub natif — sur iPad/iOS/macOS standalone, le drag-and-drop OS
/// n'arrive pas via `dart:html`. Si on voulait le supporter, il faudrait
/// `desktop_drop` (macOS/Win/Linux) ou les API natives Flutter — mais
/// l'usage principal de l'app est web (PWA Mac/iPad), donc on se
/// contente d'un no-op ici.
class _NoopFileDropListener implements FileDropListener {
  @override
  void activate() {/* no-op */}

  @override
  Stream<FileDropEvent> get onDrop => const Stream.empty();

  @override
  Stream<FileDropOverEvent> get onDragOver => const Stream.empty();
}

FileDropListener createFileDropListener() => _NoopFileDropListener();
