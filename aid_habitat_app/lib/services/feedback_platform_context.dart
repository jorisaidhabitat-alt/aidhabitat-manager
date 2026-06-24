import 'package:flutter/foundation.dart';

Map<String, String> feedbackPlatformContext() => {
  'platform': defaultTargetPlatform.name,
  'url': '',
  'userAgent': '',
};
