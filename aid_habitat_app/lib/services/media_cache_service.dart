import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'app_config.dart';
import 'local_database.dart';
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
  ///
  /// [headers] is optional and only used for the network fetch on a cache
  /// miss — auth headers don't participate in the cache key so cached bytes
  /// remain readable offline regardless of token freshness. Pass `null` (or
  /// omit) for public URLs ; pass `_authHeaders()` for private API URLs that
  /// need `X-App-Session` (typical: `/api/mobile-documents/<id>/content`).
  Future<File?> fetch(String url, {Map<String, String>? headers}) async {
    final resolved = resolveMediaUrl(url);
    if (resolved.isEmpty) return null;

    final dir = await _getCacheDir();
    final file = File(p.join(dir.path, _cacheKey(resolved)));

    // Cache hit — serve from disk.
    if (await file.exists()) return file;

    // Dedupe concurrent fetches for the same URL. The dedup key includes
    // only the URL (not headers) since the persisted bytes are identical
    // regardless of auth context.
    final existing = _inFlight[resolved];
    if (existing != null) return existing;

    final future = _download(resolved, file, headers: headers);
    _inFlight[resolved] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(resolved);
    }
  }

  /// Builds the same auth headers as `NocoDbApiClient` so private API
  /// endpoints (`/api/mobile-documents/...`) authenticate correctly. Empty
  /// session token (= unauthenticated user) returns no headers — caller is
  /// then on its own to handle 401.
  static Map<String, String> authHeaders() {
    final token = AppConfig.appSessionToken.trim();
    if (token.isEmpty) return const {};
    return {'X-App-Session': token};
  }

  Future<File?> _download(
    String url,
    File target, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await http.get(Uri.parse(url), headers: headers).timeout(
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
  ///
  /// On web, delegates to [webCachedFetch] (SQLite-backed cache). On native
  /// targets, uses [fetch] (filesystem-backed cache).
  ///
  /// [headers] : passed to both web and native fetchers — set
  /// `MediaCacheService.authHeaders()` for private API URLs that need
  /// `X-App-Session` (e.g. patient documents in `nocodb` mode where the
  /// download endpoint is gated by `requireAuth`).
  Future<void> prefetchAll(
    Iterable<String> urls, {
    Map<String, String>? headers,
  }) async {
    for (final url in urls) {
      if (url.trim().isEmpty) continue;
      // Fire-and-forget — don't await, but catch so one failure doesn't stop
      // the chain.
      if (kIsWeb) {
        unawaited(
          webCachedFetch(url, headers: headers).then((_) {}, onError: (_) {}),
        );
      } else {
        unawaited(
          fetch(url, headers: headers).then((_) {}, onError: (_) {}),
        );
      }
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

  // ---------------------------------------------------------------------------
  // Web-only bytes cache (SQLite-backed, survives reloads + offline).
  // ---------------------------------------------------------------------------

  /// Fetches [url] on web with a SQLite-backed cache so wiki + retirement
  /// logos + patient documents keep displaying when the iPad is offline.
  /// Returns raw bytes (raster or SVG) on success, null if neither cache
  /// nor network has the resource.
  ///
  /// [headers] is optional and only used for the network fetch on a cache
  /// miss — it lets callers pass `X-App-Session` for private API URLs.
  /// Auth headers don't participate in the cache key: we want the cached
  /// bytes to be readable offline regardless of token freshness.
  ///
  /// Strategy:
  ///   1. Lookup `web_media_cache` by sha1(resolved url). Cache hit → return.
  ///   2. Miss → http.get (with optional auth headers). On 200, persist
  ///      bytes + return them.
  ///   3. http.get fails / non-200 → return null so the caller can render
  ///      its error widget.
  /// Invalide l'entrée web_media_cache pour [url]. Utilisé quand
  /// l'appelant détecte que les bytes cachés sont corrompus (ex:
  /// PdfDocument.openData échoue) → on supprime l'entrée et on
  /// re-fetch frais. Demande utilisateur 2026-05-05 : un PDF
  /// « synchronisé » sur macOS refusait de s'ouvrir parce qu'une
  /// entrée stale (HTML SPA / 0 byte) trainait dans le cache.
  Future<void> invalidateUrl(String url) async {
    final resolved = resolveMediaUrl(url);
    if (resolved.isEmpty) return;
    final hash = sha1.convert(utf8.encode(resolved)).toString();
    try {
      final db = await LocalDatabase.instance.database;
      await db.delete(
        'web_media_cache',
        where: 'url_hash = ?',
        whereArgs: [hash],
      );
    } catch (_) {/* best-effort, ignore SQLite errors */}
  }

  Future<Uint8List?> webCachedFetch(
    String url, {
    Map<String, String>? headers,
  }) async {
    final resolved = resolveMediaUrl(url);
    if (resolved.isEmpty) return null;
    final hash = sha1.convert(utf8.encode(resolved)).toString();

    final db = await LocalDatabase.instance.database;
    final rows = await db.query(
      'web_media_cache',
      columns: ['bytes'],
      where: 'url_hash = ?',
      whereArgs: [hash],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final raw = rows.first['bytes'];
      if (raw is List<int>) {
        return Uint8List.fromList(raw);
      }
      if (raw is Uint8List) {
        return raw;
      }
    }

    try {
      final response = await http
          .get(Uri.parse(resolved), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // ignore: avoid_print
        print(
          '[media_cache] HTTP ${response.statusCode} on $resolved '
          '(content-type=${response.headers['content-type'] ?? '-'})',
        );
        return null;
      }
      final bytes = response.bodyBytes;
      if (bytes.isEmpty) {
        // ignore: avoid_print
        print('[media_cache] Empty body on $resolved (HTTP 200, 0 bytes)');
        return null;
      }
      // SPA fallback guard (same as native _download).
      final contentType =
          response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.contains('text/html') ||
          contentType.contains('application/xhtml')) {
        // ignore: avoid_print
        print(
          '[media_cache] HTML response (probable SPA fallback) on $resolved',
        );
        return null;
      }
      await db.insert(
        'web_media_cache',
        {
          'url_hash': hash,
          'url': resolved,
          'bytes': bytes,
          'fetched_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return bytes;
    } catch (e) {
      // ignore: avoid_print
      print('[media_cache] Network error on $resolved: $e');
      return null;
    }
  }

  /// Diagnostic helper : retourne un statut HTTP brut (avec body si non-2xx)
  /// pour une URL — utilisé quand l'aperçu d'un doc échoue pour distinguer
  /// 401 (auth), 404 (doc supprimé / corrompu côté serveur), 500 (panne)
  /// d'une erreur réseau pure. N'écrit rien dans le cache.
  Future<MediaFetchDiagnosis?> diagnose(
    String url, {
    Map<String, String>? headers,
  }) async {
    final resolved = resolveMediaUrl(url);
    if (resolved.isEmpty) {
      return const MediaFetchDiagnosis(
        statusCode: 0,
        message: 'URL vide après résolution',
      );
    }
    try {
      final response = await http
          .get(Uri.parse(resolved), headers: headers)
          .timeout(const Duration(seconds: 20));
      String? body;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        try {
          body = response.body.length > 240
              ? '${response.body.substring(0, 240)}…'
              : response.body;
        } catch (_) {}
      }
      return MediaFetchDiagnosis(
        statusCode: response.statusCode,
        bodyLength: response.bodyBytes.length,
        contentType: response.headers['content-type'],
        body: body,
      );
    } catch (e) {
      return MediaFetchDiagnosis(
        statusCode: -1,
        message: e.toString(),
      );
    }
  }
}

/// Résultat d'un diagnostic réseau pour un asset documentaire.
class MediaFetchDiagnosis {
  const MediaFetchDiagnosis({
    required this.statusCode,
    this.bodyLength = 0,
    this.contentType,
    this.body,
    this.message,
  });

  /// HTTP status (-1 = erreur réseau, 0 = URL invalide, sinon code HTTP).
  final int statusCode;
  final int bodyLength;
  final String? contentType;
  final String? body;
  final String? message;

  bool get isAuthError => statusCode == 401 || statusCode == 403;
  bool get isMissing => statusCode == 404;
  bool get isServerError => statusCode >= 500 && statusCode < 600;
  bool get isNetworkError => statusCode == -1;
  bool get isEmptyBody =>
      statusCode >= 200 && statusCode < 300 && bodyLength == 0;
}
