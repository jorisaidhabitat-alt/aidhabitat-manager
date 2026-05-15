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
        isTransientErrorLike(Exception('Resource not found (404)')),
        isFalse,
      );
    });

    test('HTTP 413 in message → NOT transient (audit P0 #11 refonte '
        '2026-05-15 17h : upload photo trop grosse, retry inutile)', () {
      // Bug reproduit en prod : POST /api/profile/photo 413 (image > 95 KB
      // base64) était reclassé en transient à cause du faux-positif
      // "upload failed" ⊂ "load failed". Désormais : short-circuit sur
      // les codes 4xx permanents. L'op doit aller en markFailed et le
      // user doit la voir dans le bottom sheet des ops en échec.
      expect(
        isTransientErrorLike(
          Exception('Profile photo upload failed (413): too big'),
        ),
        isFalse,
      );
    });

    test('Message photo profil formaté "limite serveur (413)" → '
        'NOT transient (audit code review 2026-05-16)', () {
      // Le message custom dans `uploadProfilePhoto` (nocodb_api_client)
      // ne contient pas "Profile photo upload failed (413)" textuel —
      // il a été reformulé pour l'UI. On vérifie que le `(413)` reste
      // détectable.
      expect(
        isTransientErrorLike(
          Exception(
            'Photo trop volumineuse — limite serveur (413) (>4.5 Mo après '
            'compression). Choisis une image plus petite.',
          ),
        ),
        isFalse,
      );
    });

    test('Codes ressemblants à 401/403 mais plus longs → NOT transient '
        '(audit code review 2026-05-16 : regex strict vs substring)', () {
      // Avant la regex `_kAuthFailureStatusPattern`, `s.contains("(401)")`
      // matchait aussi `(4015)`, `(4019)`. Improbable en pratique car les
      // status HTTP Dart sont à 3 chiffres mais le pattern était fragile.
      expect(
        isTransientErrorLike(Exception('Custom error code (4015)')),
        isFalse,
      );
      expect(
        isTransientErrorLike(Exception('Some message with (40130)')),
        isFalse,
      );
      // Vrais 401/403 → toujours transient.
      expect(
        isTransientErrorLike(Exception('Auth check failed (401)')),
        isTrue,
      );
      expect(
        isTransientErrorLike(Exception('Forbidden (403)')),
        isTrue,
      );
    });

    test('HTTP 422 in message → NOT transient (validation NocoDB)', () {
      expect(
        isTransientErrorLike(
          Exception('Remote update failed (422): invalid value'),
        ),
        isFalse,
      );
    });

    test('"upload failed" sans code 4xx → encore considéré transient via '
        'wording réseau (mais on ne devrait jamais arriver là avec un '
        'vrai serveur — il met TOUJOURS un code de status)', () {
      // Cas pathologique : message brut sans status code. On reste
      // permissif parce qu'on ne peut pas distinguer "upload failed"
      // ClientException Safari d'un upload qui a vraiment foiré.
      // Note : avant le fix word-boundary (regex `\bload failed\b`),
      // "upload failed" matchait `load failed` par sous-chaîne. Plus
      // maintenant : `\b` exige une frontière de mot avant `load`.
      expect(
        isTransientErrorLike(Exception('upload failed mid-flight')),
        isFalse,
        reason: '"upload" et "load" partagent leur début, mais \\b '
            'exclut maintenant ce match',
      );
    });

    test('"download failed" → NOT transient (même raison)', () {
      expect(
        isTransientErrorLike(Exception('download failed at byte 1234')),
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

    test('TransientRemoteException → NON détecté par `isTransientErrorLike` '
        '(géré séparément par un `on TransientRemoteException` upstream)', () {
      // `_processGroup` capture `TransientRemoteException` AVANT le
      // catch-all qui appelle `isTransientErrorLike`. Donc cette fonction
      // n'est jamais appelée avec ce type — on documente le contrat ici
      // pour qu'un futur refactor ne se trompe pas en pensant qu'il faut
      // ajouter une `is TransientRemoteException` check.
      expect(
        isTransientErrorLike(
          TransientRemoteException('upstream said 503', statusCode: 503),
        ),
        isFalse,
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
