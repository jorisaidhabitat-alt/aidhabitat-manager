import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';

/// Couvre le `_runWithTransientGuard` à travers `updateDossier` —
/// méthode représentative qui passe par le même chemin de
/// classification d'erreurs que tous les autres PATCH/PUT (logements,
/// bénéficiaires, mesures, observations, etc.). Si un de ces tests
/// casse, c'est qu'une régression a slipped past la classification :
/// soit un 5xx remonte en hard error (bandeau), soit un 4xx fonctionnel
/// est silencé en transient (sync zombie).
void main() {
  setUp(() {
    AppConfig.setApiBaseUrl('https://fake.test');
    AppConfig.setAppSessionToken('fake-token');
  });

  tearDown(() {
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });

  group('updateDossier — classification HTTP', () {
    test('200 OK avec `updatedAt` → renvoie la nouvelle valeur', () async {
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.method, 'PATCH');
          expect(request.url.path, '/api/dossiers/dos-123');
          return http.Response(
            '{"success":true,"data":{"updatedAt":"2026-05-15T10:00:00Z"}}',
            200,
          );
        }),
      );
      final updated = await client.updateDossier(
        dossierId: 'dos-123',
        updates: {'ergoNote': 'hello'},
      );
      expect(updated, '2026-05-15T10:00:00Z');
    });

    test(
      '200 OK sans `updatedAt` → renvoie null (rétrocompat ancien deploy)',
      () async {
        final client = NocodbApiClient(
          client: MockClient((_) async {
            return http.Response('{"success":true,"data":{}}', 200);
          }),
        );
        final updated = await client.updateDossier(
          dossierId: 'dos-123',
          updates: {'foo': 'bar'},
        );
        expect(updated, isNull);
      },
    );

    test(
      '409 Conflict → lève ConflictException (route vers markConflict)',
      () async {
        final client = NocodbApiClient(
          client: MockClient((_) async {
            return http.Response(
              '{"success":false,"error":"stale","remoteData":{}}',
              409,
            );
          }),
        );
        await expectLater(
          () => client.updateDossier(
            dossierId: 'dos-123',
            updates: {'foo': 'bar'},
          ),
          throwsA(isA<ConflictException>()),
        );
      },
    );

    test('500 → lève TransientRemoteException (retry silencieux, '
        'PAS de bandeau)', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response('Internal Server Error', 500);
        }),
      );
      await expectLater(
        () =>
            client.updateDossier(dossierId: 'dos-123', updates: {'foo': 'bar'}),
        throwsA(isA<TransientRemoteException>()),
      );
    });

    test('502 / 503 / 504 → lève TransientRemoteException (Vercel rollout, '
        'cold start, upstream NocoDB lent)', () async {
      for (final status in [502, 503, 504]) {
        final client = NocodbApiClient(
          client: MockClient((_) async {
            return http.Response('Bad gateway', status);
          }),
        );
        await expectLater(
          () => client.updateDossier(
            dossierId: 'dos-123',
            updates: {'foo': 'bar'},
          ),
          throwsA(isA<TransientRemoteException>()),
          reason: 'status $status should be transient',
        );
      }
    });

    test('400 → lève une Exception générique avec "(400)" dans le message '
        '(le payload est rejeté côté serveur, retry inutile)', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response('{"error":"missing field"}', 400);
        }),
      );
      try {
        await client.updateDossier(
          dossierId: 'dos-123',
          updates: {'foo': 'bar'},
        );
        fail('Expected an Exception to be thrown');
      } catch (e) {
        expect(e, isNot(isA<TransientRemoteException>()));
        expect(e, isNot(isA<ConflictException>()));
        expect(e.toString(), contains('(400)'));
      }
    });

    test('401 → lève une Exception générique avec "(401)" dans le message '
        '(le sync engine la traitera comme transient via '
        '`isTransientErrorLike` côté sync_service, mais l\'api_client ne '
        'la convertit pas en TransientRemoteException — c\'est volontaire '
        'pour laisser un humain inspecter le message si besoin)', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response('{"error":"unauthorized"}', 401);
        }),
      );
      try {
        await client.updateDossier(
          dossierId: 'dos-123',
          updates: {'foo': 'bar'},
        );
        fail('Expected an Exception to be thrown');
      } catch (e) {
        expect(e, isNot(isA<TransientRemoteException>()));
        expect(e, isNot(isA<ConflictException>()));
        expect(e.toString(), contains('(401)'));
      }
    });

    test(
      'TimeoutException de la pile réseau → TransientRemoteException',
      () async {
        final client = NocodbApiClient(
          client: MockClient((_) async {
            throw TimeoutException('simulated');
          }),
        );
        await expectLater(
          () => client.updateDossier(
            dossierId: 'dos-123',
            updates: {'foo': 'bar'},
          ),
          throwsA(isA<TransientRemoteException>()),
        );
      },
    );

    test('SocketException → TransientRemoteException', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          throw const SocketException('connect refused');
        }),
      );
      await expectLater(
        () =>
            client.updateDossier(dossierId: 'dos-123', updates: {'foo': 'bar'}),
        throwsA(isA<TransientRemoteException>()),
      );
    });

    test('http.ClientException ("Load failed" iPad PWA) → '
        'TransientRemoteException', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          throw http.ClientException('Load failed');
        }),
      );
      await expectLater(
        () =>
            client.updateDossier(dossierId: 'dos-123', updates: {'foo': 'bar'}),
        throwsA(isA<TransientRemoteException>()),
      );
    });
  });

  group('mutations JSON groupées', () {
    test(
      'regroupe plusieurs écritures dans un seul POST /api/sync/batch',
      () async {
        var networkCalls = 0;
        final client = NocodbApiClient(
          enableJsonBatching: true,
          client: MockClient((request) async {
            networkCalls += 1;
            expect(request.method, 'POST');
            expect(request.url.path, '/api/sync/batch');
            final payload = jsonDecode(request.body) as Map<String, dynamic>;
            final operations = payload['operations'] as List<dynamic>;
            expect(operations, hasLength(3));
            expect(
              operations.map((op) => (op as Map)['path']),
              containsAll([
                '/api/dossiers/dos-1',
                '/api/beneficiaires/patient-1',
                '/api/observations/dos-1',
              ]),
            );
            return http.Response(
              jsonEncode({
                'success': true,
                'results': operations
                    .map(
                      (raw) => {
                        'id': (raw as Map)['id'],
                        'status': 200,
                        'body': {
                          'success': true,
                          'data': {'updatedAt': '2026-08-05T12:00:00Z'},
                        },
                      },
                    )
                    .toList(),
              }),
              200,
            );
          }),
        );

        final dossierFuture = client.updateDossier(
          dossierId: 'dos-1',
          updates: {'status': 'ok'},
        );
        final beneficiaryFuture = client.updateBeneficiary(
          patientId: 'patient-1',
          updates: {'firstName': 'Alice'},
        );
        final observationsFuture = client.updateObservations(
          dossierId: 'dos-1',
          updates: {'projetSouhaitUsage': 'Rester à domicile'},
        );

        final results = await Future.wait([dossierFuture, beneficiaryFuture]);
        await observationsFuture;

        expect(networkCalls, 1);
        expect(results, everyElement('2026-08-05T12:00:00Z'));
      },
    );

    test('un échec partiel reste attaché à la bonne opération', () async {
      final client = NocodbApiClient(
        enableJsonBatching: true,
        client: MockClient((request) async {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          final operations = payload['operations'] as List<dynamic>;
          return http.Response(
            jsonEncode({
              'success': true,
              'results': operations.map((raw) {
                final operation = raw as Map;
                final isDossier = operation['path'] == '/api/dossiers/dos-1';
                return {
                  'id': operation['id'],
                  'status': isDossier ? 200 : 503,
                  'body': {'success': isDossier},
                };
              }).toList(),
            }),
            200,
          );
        }),
      );

      final dossierFuture = client.updateDossier(
        dossierId: 'dos-1',
        updates: {'status': 'ok'},
      );
      final beneficiaryFuture = client.updateBeneficiary(
        patientId: 'patient-1',
        updates: {'firstName': 'Alice'},
      );

      await expectLater(dossierFuture, completes);
      await expectLater(
        beneficiaryFuture,
        throwsA(isA<TransientRemoteException>()),
      );
    });
  });

  group('loginToRemote — RemoteLoginResult', () {
    test('200 + jetons accès/renouvellement → success', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response(
            '{"success":true,"data":{"token":"jwt-abc",'
            '"refreshToken":"refresh-abc"}}',
            200,
          );
        }),
      );
      final result = await client.loginToRemote(
        email: 'user@test.fr',
        password: 'p',
      );
      expect(result.isSuccess, isTrue);
      expect(result.token, 'jwt-abc');
      expect(result.refreshToken, 'refresh-abc');
    });

    test('401 → rejected (admin a changé le mdp serveur, hash local doit '
        'devenir invalide)', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response('{"error":"bad creds"}', 401);
        }),
      );
      final result = await client.loginToRemote(
        email: 'user@test.fr',
        password: 'wrong',
      );
      expect(result.rejected, isTrue);
      expect(result.isSuccess, isFalse);
      expect(result.isUnreachable, isFalse);
    });

    test('500 → unreachable (serveur en difficulté, on tombera sur le hash '
        'local pour permettre l\'usage offline)', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response('Internal Server Error', 500);
        }),
      );
      final result = await client.loginToRemote(
        email: 'user@test.fr',
        password: 'p',
      );
      expect(result.isUnreachable, isTrue);
      expect(result.rejected, isFalse);
    });

    test('Timeout réseau → unreachable (même rationale que 500)', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          throw TimeoutException('boom');
        }),
      );
      final result = await client.loginToRemote(
        email: 'user@test.fr',
        password: 'p',
      );
      expect(result.isUnreachable, isTrue);
      expect(result.rejected, isFalse);
    });
  });

  group('refreshRemoteSession', () {
    test('renouvelle et fait tourner les deux jetons', () async {
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.url.path, '/api/auth/refresh');
          expect(jsonDecode(request.body), {'refreshToken': 'refresh-old'});
          return http.Response(
            '{"success":true,"data":{"token":"access-new",'
            '"refreshToken":"refresh-new"}}',
            200,
          );
        }),
      );

      final result = await client.refreshRemoteSession('refresh-old');

      expect(result.isSuccess, isTrue);
      expect(result.token, 'access-new');
      expect(result.refreshToken, 'refresh-new');
    });

    test('401 signifie que le renouvellement est réellement rejeté', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async => http.Response('', 401)),
      );

      final result = await client.refreshRemoteSession('refresh-old');

      expect(result.rejected, isTrue);
    });

    test(
      'panne TLS conserve la session pour une tentative ultérieure',
      () async {
        final client = NocodbApiClient(
          client: MockClient((_) async {
            throw HandshakeException('serveur indisponible');
          }),
        );

        final result = await client.refreshRemoteSession('refresh-old');

        expect(result.isUnreachable, isTrue);
      },
    );
  });

  group('validateSessionToken (audit P0 #1, fix 2026-05-15)', () {
    test('200 → valid', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response('{"success":true,"data":{"user":{}}}', 200);
        }),
      );
      expect(await client.validateSessionToken(), SessionTokenStatus.valid);
    });

    test('401 → rejected (signal que le serveur strict est déployé → '
        'restoreRemoteSession doit forcer un re-login)', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response('{"error":"Session invalide"}', 401);
        }),
      );
      expect(await client.validateSessionToken(), SessionTokenStatus.rejected);
    });

    test('403 → rejected', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response('{"error":"Forbidden"}', 403);
        }),
      );
      expect(await client.validateSessionToken(), SessionTokenStatus.rejected);
    });

    test('500 → unreachable (on garde le token, mode offline OK)', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          return http.Response('Internal Server Error', 500);
        }),
      );
      expect(
        await client.validateSessionToken(),
        SessionTokenStatus.unreachable,
      );
    });

    test('Timeout réseau → unreachable', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async {
          throw TimeoutException('boom');
        }),
      );
      expect(
        await client.validateSessionToken(),
        SessionTokenStatus.unreachable,
      );
    });

    test('Token absent (AppConfig vide) → rejected '
        '(rien à valider, force re-login)', () async {
      AppConfig.clearAppSessionToken();
      final client = NocodbApiClient(
        client: MockClient((_) async => http.Response('', 200)),
      );
      expect(await client.validateSessionToken(), SessionTokenStatus.rejected);
    });

    test('apiBaseUrl absent (boot incomplet) → unreachable (pas de '
        'sanction tant qu\'on ne sait pas joindre le serveur)', () async {
      AppConfig.setApiBaseUrl('');
      final client = NocodbApiClient(
        client: MockClient((_) async => http.Response('', 200)),
      );
      expect(
        await client.validateSessionToken(),
        SessionTokenStatus.unreachable,
      );
    });
  });

  group('fetchNotePage — portée dossier', () {
    test('transmet scopeType et scopeId pour éviter les doublons', () async {
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.url.path, '/api/note-pages/patient-69');
          expect(request.url.queryParameters['tabKey'], 'notes_rapides');
          expect(request.url.queryParameters['pageNumber'], '0');
          expect(request.url.queryParameters['scopeType'], 'dossier_detail');
          expect(request.url.queryParameters['scopeId'], 'airtable:dossier-62');
          return http.Response('{"success":true,"data":{"notePages":[]}}', 200);
        }),
      );

      await client.fetchNotePage(
        patientId: 'patient-69',
        tabKey: 'notes_rapides',
        pageNumber: 0,
        scopeType: 'dossier_detail',
        scopeId: 'airtable:dossier-62',
      );
    });
  });
}
