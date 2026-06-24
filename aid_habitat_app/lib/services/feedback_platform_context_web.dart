// ignore_for_file: deprecated_member_use

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/foundation.dart';

Map<String, String> feedbackPlatformContext() => {
  'platform': defaultTargetPlatform.name,
  'url': html.window.location.href,
  'userAgent': html.window.navigator.userAgent,
};
