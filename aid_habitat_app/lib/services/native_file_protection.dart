import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

/// Best-effort iOS file protection for locally persisted offline assets.
///
/// Native iPad builds already keep structured data inside SQLCipher, but
/// previews / caches / annotation sidecars still need filesystem storage.
/// This helper applies iOS Data Protection to those files so they are not
/// left trivially readable at rest inside the app sandbox.
class NativeFileProtection {
  NativeFileProtection._();

  static final NativeFileProtection instance = NativeFileProtection._();

  static const MethodChannel _channel = MethodChannel(
    'aidhabitat/file_protection',
  );

  bool get _supportsNativeProtection =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> protectPath(
    String path, {
    bool recursive = false,
    bool excludeFromBackup = false,
  }) async {
    if (!_supportsNativeProtection || path.trim().isEmpty) return;
    try {
      await _channel.invokeMethod<void>('protectPath', {
        'path': path,
        'recursive': recursive,
        'excludeFromBackup': excludeFromBackup,
      });
    } on MissingPluginException {
      // Best-effort: older native shells can simply skip the extra protection.
    } on PlatformException {
      // Never block the offline workflow on a protection metadata failure.
    }
  }

  Future<Directory> ensureProtectedDirectory(
    String path, {
    bool recursive = false,
    bool excludeFromBackup = false,
  }) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await protectPath(
      dir.path,
      recursive: recursive,
      excludeFromBackup: excludeFromBackup,
    );
    return dir;
  }

  Future<File> writeProtectedBytes(
    String path,
    List<int> bytes, {
    bool excludeFromBackup = false,
  }) async {
    final file = File(path);
    await ensureProtectedDirectory(file.parent.path);
    await file.writeAsBytes(bytes, flush: true);
    await protectPath(file.path, excludeFromBackup: excludeFromBackup);
    return file;
  }

  Future<File> writeProtectedString(
    String path,
    String contents, {
    bool excludeFromBackup = false,
  }) async {
    final file = File(path);
    await ensureProtectedDirectory(file.parent.path);
    await file.writeAsString(contents, flush: true);
    await protectPath(file.path, excludeFromBackup: excludeFromBackup);
    return file;
  }

  Future<File> copyProtectedFile(
    File source,
    String targetPath, {
    bool excludeFromBackup = false,
  }) async {
    final file = File(targetPath);
    await ensureProtectedDirectory(file.parent.path);
    final copied = await source.copy(file.path);
    await protectPath(copied.path, excludeFromBackup: excludeFromBackup);
    return copied;
  }
}
