import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';

import 'external_launcher_web.dart'
    if (dart.library.io) 'external_launcher_io.dart';

/// Opens [url] in the OS's default browser.
///
/// On **native** targets (macOS, iPadOS native, Android), delegates to
/// `url_launcher` in external-application mode → opens Safari/Chrome.
///
/// On **web** PWA (especially iPad Safari standalone), `url_launcher` uses
/// `window.open` under the hood, which iOS sometimes flags as a fake
/// phishing warning ("ce site tente de se faire passer pour …") even for
/// legitimate gouv.fr URLs. Workaround: inject a real `<a target="_blank">`
/// into the DOM and click it programmatically — that's the "trusted user
/// navigation" pattern iOS doesn't block.
Future<bool> openExternalUrl(String url) async {
  if (kIsWeb) {
    return openExternalUrlWeb(url);
  }
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
