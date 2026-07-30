import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_config.dart';

class AiRewriteService {
  AiRewriteService({http.Client? client}) : _client = client ?? http.Client();

  static final AiRewriteService instance = AiRewriteService();

  final http.Client _client;

  Future<String> rewrite({
    required String text,
    String mode = 'professional',
    String? apiBaseUrl,
    String? sessionToken,
  }) async {
    final sourceText = text.trim();
    if (sourceText.length < 3) {
      throw Exception('La note est trop courte pour être reformulée.');
    }

    final apiBase = (apiBaseUrl ?? AppConfig.apiBaseUrl).trim().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final token = (sessionToken ?? AppConfig.appSessionToken).trim();
    if (apiBase.isEmpty || token.isEmpty) {
      throw Exception(
        'La reformulation nécessite une connexion à votre session.',
      );
    }

    final response = await _client
        .post(
          Uri.parse('$apiBase/api/ai/rewrite'),
          headers: {'Content-Type': 'application/json', 'X-App-Session': token},
          body: jsonEncode({'text': sourceText, 'mode': mode}),
        )
        .timeout(const Duration(seconds: 130));

    if (response.statusCode == 401) {
      await AppConfig.notifyUnauthorized();
    }

    dynamic payload;
    try {
      payload = jsonDecode(response.body);
    } catch (_) {
      payload = null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final serverError = payload is Map && payload['error'] is String
          ? (payload['error'] as String).trim()
          : '';
      throw Exception(
        serverError.isNotEmpty
            ? serverError
            : 'Reformulation impossible (${response.statusCode}).',
      );
    }

    final data = payload is Map ? payload['data'] : null;
    final rewrittenText = data is Map
        ? data['text']?.toString().trim() ?? ''
        : '';
    if (rewrittenText.isEmpty) {
      throw Exception("L'IA n'a renvoyé aucun texte.");
    }
    return rewrittenText;
  }
}
