import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_config.dart';
import 'feedback_activity_service.dart';
import 'feedback_platform_context.dart'
    if (dart.library.html) 'feedback_platform_context_web.dart';

class FeedbackService {
  FeedbackService._();
  static final FeedbackService instance = FeedbackService._();

  Future<void> sendFeedback({
    required String type,
    required String message,
    required FeedbackContextSnapshot context,
  }) async {
    final apiBase = AppConfig.apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final token = AppConfig.appSessionToken.trim();
    if (apiBase.isEmpty || token.isEmpty) {
      throw Exception('Connexion API indisponible.');
    }

    final platform = feedbackPlatformContext();
    final payload = {
      'type': type,
      'message': message,
      'context': {
        ...context.toJson(),
        ...platform,
        'clientTimestamp': DateTime.now().toIso8601String(),
      },
    };

    final response = await http
        .post(
          Uri.parse('$apiBase/api/feedback'),
          headers: {'Content-Type': 'application/json', 'X-App-Session': token},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String error = 'Envoi impossible (${response.statusCode}).';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          error = decoded['error'] as String;
        }
      } catch (_) {}
      throw Exception(error);
    }
  }
}
