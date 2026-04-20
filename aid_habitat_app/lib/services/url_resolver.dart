import 'app_config.dart';

/// Resolves a URL from the remote API into a fully-qualified URL the Flutter
/// app can load. Relative paths like `/uploads/...` or `/wiki-offline/...`
/// are prefixed with [AppConfig.apiBaseUrl]. Absolute URLs (http/https/data)
/// are returned unchanged. Empty input returns empty string.
String resolveMediaUrl(String url) {
  if (url.isEmpty) return '';
  if (url.startsWith('http://') ||
      url.startsWith('https://') ||
      url.startsWith('data:') ||
      url.startsWith('blob:')) {
    return url;
  }
  final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
  if (url.startsWith('/')) return '$base$url';
  return '$base/$url';
}

/// Returns true if the URL (resolved or not) points to an SVG file.
bool isSvgUrl(String url) {
  final lower = url.toLowerCase();
  return lower.endsWith('.svg') || lower.contains('.svg?');
}
