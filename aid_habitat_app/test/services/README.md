# Tests services — guide rapide

## Que couvrent ces tests

`sync_errors_test.dart` + `nocodb_api_client_test.dart` couvrent la
**classification d'erreurs sync** — chemins par lesquels une op se
retrouve `pending` (transient, retry silencieux) vs `failed` (bandeau
rouge UI) vs `conflict` (auto-résolu via merge LWW).

C'est la pierre angulaire qu'on a refondue le 2026-05-15 (audit P0 #2)
quand `(401)` et `(403)` ont été ajoutés à `isTransientErrorLike` pour
éviter le bandeau rouge sur expiration de token.

**Une régression silencieuse ici** = soit l'utilisateur voit
constamment du rouge à tort, soit une erreur durable est cachée et
l'op reste "pending" éternellement.

## Comment exécuter

```bash
flutter test test/services/
```

### Bug connu — apostrophe dans le path

Le chemin du repo contient `'` (`aid'habitat-manager`) qui **casse**
le test runner Flutter ([erreur "habitat is already declared in this scope"](https://github.com/flutter/flutter/issues)). Symptôme :

```
Error: 'habitat' is already declared in this scope.
```

**Workaround** : copier le projet dans un dossier sans apostrophe et
lancer les tests depuis là.

```bash
rsync -a --exclude='.git' --exclude='build' --exclude='.dart_tool' \
      "/Users/.../aid'habitat-manager/aid_habitat_app/" /tmp/aid_clean/
cd /tmp/aid_clean && flutter pub get && flutter test test/services/
```

Le `flutter analyze test/` lui passe sans souci avec l'apostrophe —
utile pour vérifier que les tests **compilent** même si on ne peut
pas les exécuter en place.

## Ajouter un nouveau test

Pour tester un nouveau code HTTP / classe d'erreur :

1. Si c'est une **fonction privée** dans `lib/services/`, marquer
   `@visibleForTesting` + retirer le préfixe `_` (cf.
   `isTransientErrorLike` dans `nocodb_sync_service.dart`).
2. Sinon, brancher un `MockClient` via le constructeur
   `NocodbApiClient(client: MockClient(...))` (cf. exemples dans
   `nocodb_api_client_test.dart`).
3. Ne PAS toucher à `AppConfig` global sans `tearDown` qui restore
   l'état initial — les tests dans `nocodb_api_client_test.dart`
   tournent en série mais polluer la config peut faire foirer
   d'autres suites futures.
