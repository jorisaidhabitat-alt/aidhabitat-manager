class AppConfig {
  static const apiBaseUrl = String.fromEnvironment(
    'AIDHABITAT_API_BASE_URL',
    defaultValue: '',
  );

  static const appSessionToken = String.fromEnvironment(
    'AIDHABITAT_APP_SESSION_TOKEN',
    defaultValue: '',
  );

  static bool get hasRemoteConfig =>
      apiBaseUrl.trim().isNotEmpty && appSessionToken.trim().isNotEmpty;
}
