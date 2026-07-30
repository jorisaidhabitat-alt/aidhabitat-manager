import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'app_config.dart';

class AiRewriteService {
  AiRewriteService({http.Client? client, MethodChannel? nativeChannel})
    : _client = client ?? http.Client(),
      _nativeChannel =
          nativeChannel ??
          const MethodChannel('aidhabitat/apple_intelligence_rewrite');

  static final AiRewriteService instance = AiRewriteService();

  final http.Client _client;
  final MethodChannel _nativeChannel;
  Future<bool>? _availability;

  bool get _usesAppleModel =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<bool> isAvailable({bool refresh = false}) {
    if (!_usesAppleModel) return Future<bool>.value(false);
    if (refresh || _availability == null) {
      _availability = _readNativeAvailability();
    }
    return _availability!;
  }

  Future<bool> _readNativeAvailability() async {
    try {
      return await _nativeChannel
              .invokeMethod<bool>('isAvailable')
              .timeout(const Duration(seconds: 3)) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

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
    if (sourceText.length > 8000) {
      throw Exception('La note ne doit pas dépasser 8000 caractères.');
    }

    if (apiBaseUrl != null || sessionToken != null) {
      return _rewriteRemotely(
        text: sourceText,
        mode: mode,
        apiBaseUrl: apiBaseUrl,
        sessionToken: sessionToken,
      );
    }

    if (!await isAvailable(refresh: true)) {
      throw Exception(
        "La reformulation Apple n'est pas disponible sur cet iPad.",
      );
    }

    final protectedText = _protect(sourceText);
    try {
      final response = await _nativeChannel
          .invokeMethod<String>('rewrite', {
            'text': protectedText.text,
            'mode': _normalizeMode(mode),
          })
          .timeout(const Duration(seconds: 130));
      final rewrittenText = response?.trim() ?? '';
      if (rewrittenText.isEmpty) {
        throw Exception("Apple Intelligence n'a renvoyé aucun texte.");
      }
      return protectedText.restore(rewrittenText);
    } on PlatformException catch (error) {
      final message = error.message?.trim() ?? '';
      throw Exception(
        message.isEmpty ? 'La reformulation locale a échoué.' : message,
      );
    } on MissingPluginException {
      throw Exception(
        "La reformulation Apple n'est pas disponible sur cet iPad.",
      );
    } on TimeoutException {
      throw Exception(
        "Apple Intelligence met trop de temps à répondre. Réessayez dans un instant.",
      );
    }
  }

  Future<String> _rewriteRemotely({
    required String text,
    required String mode,
    required String? apiBaseUrl,
    required String? sessionToken,
  }) async {
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
          body: jsonEncode({'text': text, 'mode': _normalizeMode(mode)}),
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

  String _normalizeMode(String mode) {
    return const {'professional', 'concise', 'correct'}.contains(mode)
        ? mode
        : 'professional';
  }

  _ProtectedText _protect(String source) {
    final patterns = [
      RegExp(
        r"\b(?:M(?:me|lle)?\.?|Mme|Mlle|Monsieur|Madame|Docteur|Dr\.?)\s+[A-ZÀ-ÖØ-Þ][A-Za-zÀ-ÖØ-öø-ÿ'’\-]+(?:\s+[A-ZÀ-ÖØ-Þ][A-Za-zÀ-ÖØ-öø-ÿ'’\-]+)?",
        unicode: true,
      ),
      RegExp(r'\bGIR\s*[1-6]\b', caseSensitive: false, unicode: true),
      RegExp(
        r'\b\d+(?:[.,]\d+)?(?:\s*(?:mm|cm|m|kg|ans?|heures?|h|min|minutes?|%|€))?(?=\s|[.,;:!?)]|$)',
        caseSensitive: false,
        unicode: true,
      ),
    ];

    final candidates = <_ProtectedFragment>[];
    final seenRanges = <String>{};
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(source)) {
        final value = match.group(0);
        final rangeKey = '${match.start}:${match.end}';
        if (value == null || value.isEmpty || !seenRanges.add(rangeKey)) {
          continue;
        }
        candidates.add(
          _ProtectedFragment(start: match.start, end: match.end, value: value),
        );
      }
    }

    candidates.sort((a, b) {
      final startOrder = a.start.compareTo(b.start);
      if (startOrder != 0) return startOrder;
      return (b.end - b.start).compareTo(a.end - a.start);
    });

    final selected = <_ProtectedFragment>[];
    var protectedUntil = -1;
    for (final candidate in candidates) {
      if (candidate.start < protectedUntil) continue;
      selected.add(candidate);
      protectedUntil = candidate.end;
    }

    final buffer = StringBuffer();
    var cursor = 0;
    final fragments = <_ProtectedFragment>[];
    for (var index = 0; index < selected.length; index++) {
      final fragment = selected[index];
      final token = 'AIDHABITAT_DATA_${index.toString().padLeft(3, '0')}';
      buffer
        ..write(source.substring(cursor, fragment.start))
        ..write(token);
      fragments.add(fragment.withToken(token));
      cursor = fragment.end;
    }
    buffer.write(source.substring(cursor));

    return _ProtectedText(text: buffer.toString(), fragments: fragments);
  }
}

class _ProtectedText {
  const _ProtectedText({required this.text, required this.fragments});

  final String text;
  final List<_ProtectedFragment> fragments;

  String restore(String rewrittenText) {
    var restored = rewrittenText;
    for (final fragment in fragments) {
      if (!restored.contains(fragment.token)) {
        throw Exception(
          "La proposition n'était pas assez fidèle à la note originale. "
          'La note a été conservée.',
        );
      }
      restored = restored.replaceAll(fragment.token, fragment.value);
    }
    if (restored.contains('AIDHABITAT_DATA_')) {
      throw Exception(
        "La proposition n'était pas assez fidèle à la note originale. "
        'La note a été conservée.',
      );
    }
    return restored.trim();
  }
}

class _ProtectedFragment {
  const _ProtectedFragment({
    required this.start,
    required this.end,
    required this.value,
    this.token = '',
  });

  final int start;
  final int end;
  final String value;
  final String token;

  _ProtectedFragment withToken(String value) {
    return _ProtectedFragment(
      start: start,
      end: end,
      value: this.value,
      token: value,
    );
  }
}
