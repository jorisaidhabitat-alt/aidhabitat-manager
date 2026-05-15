import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';

/// Tests de la classification d'erreurs sync — pierre angulaire qui
/// décide si une op tombe en `failed` (bandeau rouge) ou en
/// `transient` (retry silencieux). Une régression silencieuse ici =
/// soit le bandeau spamme à tort, soit des erreurs durables sont
/// cachées à l'utilisateur. Couvre :
///
///   - `isTransientErrorLike` (sync_service.dart) — classification
///     d'une erreur arbitraire au niveau du worker de sync.
///   - `TransientRemoteException` (api_client.dart) — exception
///     levée par `_runWithTransientGuard` quand le serveur renvoie
///     5xx ou que la pile réseau jette.
///   - Les exceptions levées par `RemoteLoginResult.unreachable` vs
///     `RemoteLoginResult.rejected` (api_client.dart).
void main() {
  group('isTransientErrorLike', () {
    test('TimeoutException → transient', () {
      expect(isTransientErrorLike(TimeoutException('boom')), isTrue);
    });

    test('SocketException → transient', () {
      expect(
        isTransientErrorLike(const SocketException('connect refused')),
        isTrue,
      );
    });

    test('HttpException → transient', () {
      expect(isTransientErrorLike(const HttpException('bad header')), isTrue);
    });

    test('http.ClientException → transient', () {
      expect(
        isTransientErrorLike(http.ClientException('TLS handshake failed')),
        isTrue,
      );
    });

    test('Generic Exception with "Load failed" message → transient '
        '(Safari iPad PWA path)', () {
      expect(
        isTransientErrorLike(Exception('Load failed')),
        isTrue,
      );
      expect(
        isTransientErrorLike(Exception('Fetch failed mid-flight')),
        isTrue,
      );
      expect(
        isTransientErrorLike(Exception('Failed to fetch')),
        isTrue,
      );
    });

    test('Exception mentioning ClientException (wrapped) → transient', () {
      expect(
        isTransientErrorLike(
          Exception('rethrown: ClientException with reason X'),
        ),
        isTrue,
      );
    });

    test('HTTP 401 in message → transient (audit P0 #2 refonte 2026-05-15)',
        () {
      // Avant le fix, 401 → markFailed → bandeau rouge spammé pendant
      // que le user reste avec un token expiré. Désormais traité comme
      // transient → l'op reste en queue jusqu'à ce qu'un re-login
      // injecte un token frais. Cf. nocodb_sync_service.dart::_isTransient*.
      expect(
        isTransientErrorLike(
          Exception('Remote dossier update failed (401): unauthorized'),
        ),
        isTrue,
      );
    });

    test('HTTP 403 in message → transient (même rationale que 401)', () {
      expect(
        isTransientErrorLike(
          Exception('Remote logement update failed (403): forbidden'),
        ),
        isTrue,
      );
    });

    test('HTTP 400 in message → NOT transient (4xx fonctionnel = bandeau)',
        () {
      // 400 = payload invalide, validation serveur, etc. Si la même
      // donnée est rejouée elle re-fail → boucle infinie de retry
      // silencieux. On veut le bandeau pour que l'ergo intervienne
      // (corriger la donnée ou ignorer l'op).
      expect(
        isTransientErrorLike(
          Exception(
            'Remote visit recommendations update failed (400): '
            'Chaque préconisation doit être liée à une image de la bibliothèque',
          ),
        ),
        isFalse,
      );
    });

    test('HTTP 404 in message → NOT transient (ressource disparue)', () {
      expect(
        isTransientErrorLike(Exception('Doc upload failed (404)')),
        isFalse,
      );
    });

    test('HTTP 500 in message → NOT transient (mais déjà capté par '
        '`_runWithTransientGuard` upstream)', () {
      // Note : un 500 brut qui arrive ici signifie que `_runWithTransientGuard`
      // n'a pas été utilisé pour la requête correspondante. L'enclos est
      // strict — on n'élargit pas la classification textuelle aux 5xx
      // parce que ces codes peuvent apparaître légitimement dans les
      // payloads d'erreurs métier (ex. "doc count: 500"). Le bon chemin
      // pour traiter les 5xx en silence reste `_runWithTransientGuard`.
      expect(
        isTransientErrorLike(Exception('Server returned 500 oops')),
        isFalse,
      );
    });

    test('Aucune correspondance → NOT transient', () {
      expect(
        isTransientErrorLike(Exception('Random unrelated error')),
        isFalse,
      );
      expect(isTransientErrorLike('plain string error'), isFalse);
    });

    test('TransientRemoteException → transient (déjà classifiée upstream)',
        () {
      expect(
        isTransientErrorLike(
          TransientRemoteException('upstream said 503', statusCode: 503),
        ),
        isTrue,
      );
    });
  });

  group('SessionTokenStatus enum', () {
    test('Les trois valeurs sont distinctes', () {
      expect(SessionTokenStatus.valid, isNot(SessionTokenStatus.rejected));
      expect(SessionTokenStatus.rejected, isNot(SessionTokenStatus.unreachable));
      expect(SessionTokenStatus.valid, isNot(SessionTokenStatus.unreachable));
    });
  });
}
