import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'url_resolver.dart';

/// Downloads remote images once and persists them to the app's documents
/// directory so they keep working fully offline after the first visit.
///
/// - Raster images (png/jpg/jpeg/webp/gif): cached as files
/// - SVG: cached as raw bytes (callers can read via [readBytes])
/// - Cache key = SHA1 of the resolved URL + original extension
///
/// Safe to call concurrently for the same URL — in-flight requests are
/// deduped.
class MediaCacheService {
  MediaCacheService._internal();
  static final MediaCacheService instance = MediaCacheService._internal();
  factory MediaCacheService() => instance;

  final Map<String, Future<File?>> _inFlight = {};
  Directory? _cacheDir;

  Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'media_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  String _cacheKey(String url) {
    final hash = sha1.convert(utf8.encode(url)).toString();
    final ext = _guessExtension(url);
    return '$hash$ext';
  }

  String _guessExtension(String url) {
    final lower = url.toLowerCase().split('?').first;
    for (final ext in ['.svg', '.png', '.jpg', '.jpeg', '.webp', '.gif']) {
      if (lower.endsWith(ext)) return ext;
    }
    return '.bin';
  }

  /// Returns a local [File] for [url]. Downloads it on first call. If the
  /// download fails and no cached copy exists, returns null so the caller can
  /// fall back to a placeholder.
  Future<File?> fetch(String url) async {
    final resolved = resolveMediaUrl(url);
    if (resolved.isEmpty) return null;

    final dir = await _getCacheDir();
    final file = File(p.join(dir.path, _cacheKey(resolved)));

    // Cache hit — serve from disk.
    if (await file.exists()) return file;

    // Dedupe concurrent fetches for the same URL.
    final existing = _inFlight[resolved];
    if (existing != null) return existing;

    final future = _download(resolved, file);
    _inFlight[resolved] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(resolved);
    }
  }

  Future<File?> _download(String url, File target) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(
            const Duration(seconds: 20),
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      // SPA fallback guard: some servers (Vite / Express) return HTTP 200
      // with the HTML index page for any unknown path. We must treat such
      // responses as failures when the caller expected an image.
      final contentType =
          response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.contains('text/html') ||
          contentType.contains('application/xhtml')) {
        return null;
      }
      final bytes = response.bodyBytes;
      if (bytes.isNotEmpty && _looksLikeHtml(bytes)) return null;

      await target.writeAsBytes(bytes, flush: true);
      return target;
    } catch (_) {
      return null;
    }
  }

  /// Heuristic: detects whether the first few bytes look like an HTML document.
  /// Catches misconfigured servers that send HTML with `image/*` content-type.
  bool _looksLikeHtml(List<int> bytes) {
    final sample = bytes.length < 128 ? bytes : bytes.sublist(0, 128);
    final text = String.fromCharCodes(sample).toLowerCase();
    return text.contains('<!doctype html') ||
        text.contains('<html') ||
        text.contains('<head');
  }

  /// Convenience: returns the raw bytes, downloading + caching on first call.
  /// Useful for SVGs that are rendered via SvgPicture.memory.
  Future<List<int>?> readBytes(String url) async {
    final file = await fetch(url);
    if (file == null) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Prefetches a list of URLs in the background (fire-and-forget). Call after
  /// a remote refresh to warm the cache for offline use.
  Future<void> prefetchAll(Iterable<String> urls) async {
    for (final url in urls) {
      if (url.trim().isEmpty) continue;
      // Fire-and-forget — don't await, but catch so one failure doesn't stop
      // the chain.
      unawaited(fetch(url).then((_) {}, onError: (_) {}));
    }
  }

  /// Clears every cached file. Useful for debugging or manual reset.
  Future<void> clear() async {
    final dir = await _getCacheDir();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
    _cacheDir = null;
  }
}
