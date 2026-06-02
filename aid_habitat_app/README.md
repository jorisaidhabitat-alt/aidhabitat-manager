# aid_habitat_app

Application Flutter en cours de migration vers une architecture mobile offline-first.

## État actuel

L'application:

- démarre sur une base SQLite locale
- stocke localement les dossiers, documents et notes dessinées
- garde une file de synchronisation locale
- ne dépend plus de Supabase

## Pull distant NocoDB

Le `pull` distant est optionnel et non bloquant au démarrage.

Pour l'activer, fournir:

- `AIDHABITAT_API_BASE_URL`
- `AIDHABITAT_APP_SESSION_TOKEN`

Exemple:

```bash
flutter run \
  --dart-define=AIDHABITAT_API_BASE_URL=http://127.0.0.1:3001 \
  --dart-define=AIDHABITAT_APP_SESSION_TOKEN=VOTRE_TOKEN
```

Sans ces variables, l'application fonctionne uniquement sur son stockage local.

Pour un build natif release (TestFlight / App Store / Play Store), l'URL API
doit être fournie en HTTPS :

```bash
AIDHABITAT_API_BASE_URL=https://api.aid-habitat.fr \
  ./tool/build_native_release.sh ios
```

Le script refuse volontairement les builds natifs release sans URL HTTPS pour
éviter de publier un binaire pointant vers `localhost`.

### Signature Android Play Store

Les builds Android release lisent `android/key.properties`, volontairement
ignoré par Git. Exemple de contenu :

```properties
storeFile=/chemin/absolu/aid-habitat-release.jks
storePassword=...
keyAlias=aid-habitat
keyPassword=...
```

Sans ce fichier, le build Android release échoue volontairement pour éviter de
produire un AAB signé avec la clé debug.

## Synchronisation montante

La synchronisation montante est maintenant branchée côté Flutter:

- bouton manuel de synchronisation dans le dashboard
- exécution de la queue locale
- marquage `synced` / `sync_error` selon le résultat
- push des mises à jour dossiers
- upload des documents locaux
- synchronisation des notes dessinées

Limites actuelles:

- les documents et notes transitent encore par un stockage serveur local derrière l'API Express, pas par des tables NocoDB dédiées
- le `pull` distant ramène aujourd'hui surtout les dossiers; l'import descendant des documents et notes reste à compléter
- la base SQLite mobile reconstruit encore son schéma lors d'un upgrade majeur
