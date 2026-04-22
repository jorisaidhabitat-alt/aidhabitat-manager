/// Native-side stub — never invoked (the conditional import in
/// `external_launcher.dart` only picks this file off the web). Here just
/// so the unresolved symbol `openExternalUrlWeb` doesn't break native
/// builds.
Future<bool> openExternalUrlWeb(String url) async => false;
