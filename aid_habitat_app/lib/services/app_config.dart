import 'package:flutter/foundation.dart' show kReleaseMode;

class AppConfig {
  static const _devApiBaseUrl = 'http://localhost:3001';

  static const _apiBaseUrlBuild = String.fromEnvironment(
    'AIDHABITAT_API_BASE_URL',
    defaultValue: '',
  );

  static const _appSessionTokenBuild = String.fromEnvironment(
    'AIDHABITAT_APP_SESSION_TOKEN',
    defaultValue: '',
  );

  /// Runtime override for the API base URL.
  ///
  /// Debug/profile keep the local fallback for developer convenience.
  /// Release builds must be configured with an HTTPS backend via
  /// `--dart-define=AIDHABITAT_API_BASE_URL=...`; otherwise the app stays in
  /// local/offline mode instead of accidentally calling localhost in
  /// production.
  static String _apiBaseUrlRuntime = _initialApiBaseUrl();

  /// Runtime token obtained by logging into the Express API. Persisted in
  /// SQLite and restored at app startup by AuthService.
  static String _appSessionTokenRuntime = _appSessionTokenBuild;

  static String get apiBaseUrl => _apiBaseUrlRuntime;

  /// Token de session **envoyé au serveur**. Filtre automatiquement les
  /// tokens `local-auth:<base64-email>` (placeholder offline) qui ne
  /// sont plus honorés côté serveur depuis le fix audit P0 #1 du
  /// 2026-05-15. Le but : éviter d'envoyer un token inutile qui
  /// retournerait 401 systématiquement → meilleur signal pour la
  /// couche réseau (`hasRemoteConfig` devient `false` en mode offline,
  /// donc les requêtes sont gatées en amont au lieu d'échouer en aval).
  static String get appSessionToken {
    final raw = _appSessionTokenRuntime;
    if (raw.startsWith('local-auth:')) return '';
    return raw;
  }

  static void setApiBaseUrl(String url) {
    _apiBaseUrlRuntime = _sanitizeApiBaseUrl(url);
  }

  static void setAppSessionToken(String token) {
    _appSessionTokenRuntime = token;
  }

  static void clearAppSessionToken() {
    _appSessionTokenRuntime = '';
  }

  static bool get hasRemoteConfig =>
      apiBaseUrl.trim().isNotEmpty && appSessionToken.trim().isNotEmpty;

  /// Whether we have a base URL but no session token. Useful to decide if we
  /// should try to log in to the remote API.
  static bool get canAttemptRemoteLogin =>
      apiBaseUrl.trim().isNotEmpty && appSessionToken.trim().isEmpty;

  static String _initialApiBaseUrl() {
    final buildUrl = _apiBaseUrlBuild.trim();
    if (buildUrl.isEmpty) return kReleaseMode ? '' : _devApiBaseUrl;
    return _sanitizeApiBaseUrl(buildUrl);
  }

  static String _sanitizeApiBaseUrl(String url) {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return '';
    if (kReleaseMode && !_isHttpsUrl(trimmed)) return '';
    return trimmed;
  }

  static bool _isHttpsUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }
}
