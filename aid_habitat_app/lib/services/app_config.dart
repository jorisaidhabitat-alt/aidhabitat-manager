class AppConfig {
  static const apiBaseUrl = String.fromEnvironment(
    'AIDHABITAT_API_BASE_URL',
    defaultValue: '',
  );

  static const _buildTimeAppSessionToken = String.fromEnvironment(
    'AIDHABITAT_APP_SESSION_TOKEN',
    defaultValue: '',
  );

  static String? _runtimeAppSessionToken;

  static String get appSessionToken =>
      _runtimeAppSessionToken ?? _buildTimeAppSessionToken;

  static void setAppSessionToken(String token) {
    _runtimeAppSessionToken = token;
  }

  static bool get hasRemoteConfig =>
      apiBaseUrl.trim().isNotEmpty && appSessionToken.trim().isNotEmpty;
}
