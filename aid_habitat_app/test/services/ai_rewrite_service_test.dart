import 'dart:convert';

import 'package:aid_habitat_app/services/ai_rewrite_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('returns the rewritten note from the authenticated endpoint', () async {
    late http.Request capturedRequest;
    final service = AiRewriteService(
      client: MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'text':
                  'Mme Test rencontre des difficultés pour accéder à la douche.',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await service.rewrite(
      text: 'Mme Test a du mal à rentrer dans la douche.',
      apiBaseUrl: 'http://127.0.0.1:3001/',
      sessionToken: 'session-test',
    );

    expect(
      capturedRequest.url.toString(),
      'http://127.0.0.1:3001/api/ai/rewrite',
    );
    expect(capturedRequest.headers['X-App-Session'], 'session-test');
    expect(jsonDecode(capturedRequest.body), {
      'text': 'Mme Test a du mal à rentrer dans la douche.',
      'mode': 'professional',
    });
    expect(
      result,
      'Mme Test rencontre des difficultés pour accéder à la douche.',
    );
  });

  test('surfaces a safe server error', () async {
    final service = AiRewriteService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'success': false,
            'error': "La proposition n'était pas assez fidèle.",
          }),
          422,
        ),
      ),
    );

    expect(
      () => service.rewrite(
        text: 'Texte à reformuler.',
        apiBaseUrl: 'http://127.0.0.1:3001',
        sessionToken: 'session-test',
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains("La proposition n'était pas assez fidèle."),
        ),
      ),
    );
  });
}
