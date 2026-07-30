import 'dart:convert';

import 'package:aid_habitat_app/services/ai_rewrite_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeChannel = MethodChannel(
    'aidhabitat/apple_intelligence_rewrite_test',
  );

  setUp(() {
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
  });

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

  test('hides on-device rewriting outside iOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final service = AiRewriteService(nativeChannel: nativeChannel);

    expect(await service.isAvailable(), isFalse);
  });

  test('rewrites on device and restores protected note data', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    late String protectedText;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'rewrite') {
            final arguments = call.arguments as Map<Object?, Object?>;
            protectedText = arguments['text']! as String;
            return protectedText.replaceFirst(
              'a du mal à entrer',
              'rencontre des difficultés pour entrer',
            );
          }
          return null;
        });

    final service = AiRewriteService(nativeChannel: nativeChannel);
    final result = await service.rewrite(
      text:
          'Mme Jeanne Dupont a du mal à entrer dans la douche de 72 cm. '
          'Elle est classée GIR 3.',
    );

    expect(protectedText, isNot(contains('Mme Jeanne Dupont')));
    expect(protectedText, isNot(contains('72 cm')));
    expect(protectedText, isNot(contains('GIR 3')));
    expect(protectedText, contains('AIDHABITAT_DATA_000'));
    expect(
      result,
      'Mme Jeanne Dupont rencontre des difficultés pour entrer dans la '
      'douche de 72 cm. Elle est classée GIR 3.',
    );
  });

  test('rejects an on-device response that drops protected data', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'rewrite') {
            return 'La personne rencontre des difficultés.';
          }
          return null;
        });

    final service = AiRewriteService(nativeChannel: nativeChannel);

    expect(
      () => service.rewrite(
        text: 'Mme Jeanne Dupont rencontre des difficultés depuis 2 ans.',
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains("n'était pas assez fidèle"),
        ),
      ),
    );
  });
}
