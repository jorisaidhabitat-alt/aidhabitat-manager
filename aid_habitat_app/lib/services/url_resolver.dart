import 'package:flutter/foundation.dart' show kIsWeb;

import 'app_config.dart';

/// Resolves a URL from the remote API into a fully-qualified URL the Flutter
/// app can load. Relative paths like `/uploads/...` or `/wiki-offline/...`
/// are prefixed with [AppConfig.apiBaseUrl]. Absolute URLs (http/https/data)
/// are returned unchanged. Empty input returns empty string.
///
/// On web, paths that point to static PWA assets (everything that is not
/// server-bound like `/api/...` or `/uploads/...`) are returned unchanged so
/// the browser resolves them against the current origin — the seeded
/// `/wiki-offline/...` library is copied into the PWA build during deploy.
String resolveMediaUrl(String url) {
  if (url.isEmpty) return '';
  if (url.startsWith('http://') ||
      url.startsWith('https://') ||
      url.startsWith('data:') ||
      url.startsWith('blob:')) {
    return url;
  }
  if (kIsWeb &&
      url.startsWith('/') &&
      !url.startsWith('/api/') &&
      !url.startsWith('/uploads/')) {
    return Uri.base.resolve(url).toString();
  }
  final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
  if (url.startsWith('/')) return '$base$url';
  return '$base/$url';
}

/// Returns true if the URL (resolved or not) points to an SVG file —
/// soit une URL classique `.svg`, soit une data URI inline
/// `data:image/svg+xml;...` (que le serveur émet pour les logos de
/// caisses retraite via `readPrincipalLogoAsDataUri`, et pour d'autres
/// assets brandés).
///
/// Bug fix 2026-05-16 : avant cet ajout, les logos SVG inline (MSA,
/// SRE, CAVIMAC, …) étaient correctement décodés en bytes par
/// `MediaCacheService.webCachedFetch` (qui gère les data URIs depuis
/// 2026-05-06) MAIS routés vers `Image.memory` au lieu de
/// `SvgPicture.memory` parce que `isSvgUrl` ne reconnaissait que les
/// URLs `.svg`. Résultat : `Image.memory` échouait silencieusement
/// sur le XML SVG → fallback initiales. Désormais on accepte aussi le
/// préfixe `data:image/svg+xml`.
bool isSvgUrl(String url) {
  final lower = url.toLowerCase();
  return lower.endsWith('.svg') ||
      lower.contains('.svg?') ||
      lower.startsWith('data:image/svg+xml');
}
