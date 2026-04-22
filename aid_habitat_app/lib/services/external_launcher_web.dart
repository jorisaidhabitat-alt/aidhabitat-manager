// This file is only picked up by the web target (see the conditional
// import in `external_launcher.dart`). `dart:html` is safe here.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

/// Opens [url] in a new browser tab by injecting an anchor element and
/// synthesising a click on it. This mimics a regular user-triggered
/// navigation, which iOS Safari trusts — unlike `window.open`, which
/// occasionally triggers a false "cette connexion n'est pas sécurisée"
/// prompt when fired from a PWA in standalone mode (known bug on
/// iOS 16+).
Future<bool> openExternalUrlWeb(String url) async {
  if (url.isEmpty) return false;
  final anchor = html.AnchorElement(href: url)
    ..target = '_blank'
    ..rel = 'noopener noreferrer';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  return true;
}
