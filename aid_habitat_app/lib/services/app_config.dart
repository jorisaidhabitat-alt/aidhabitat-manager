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
  static String get appSessionToken => _appSessionTokenRuntime;

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
