class AppConfig {
  static const _apiBaseUrlBuild = String.fromEnvironment(
    'AIDHABITAT_API_BASE_URL',
    defaultValue: '',
  );

  static const _appSessionTokenBuild = String.fromEnvironment(
    'AIDHABITAT_APP_SESSION_TOKEN',
    defaultValue: '',
  );

  /// Runtime override for the API base URL. Defaults to the compile-time
  /// --dart-define value, otherwise falls back to the local dev server.
  static String _apiBaseUrlRuntime =
      _apiBaseUrlBuild.isNotEmpty ? _apiBaseUrlBuild : 'http://localhost:3001';

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
    _apiBaseUrlRuntime = url;
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
}
