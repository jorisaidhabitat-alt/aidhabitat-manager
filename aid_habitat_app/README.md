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

Avant de tenter une archive store, lancer le preflight :

```bash
AIDHABITAT_API_BASE_URL=https://api.aid-habitat.fr \
  ./tool/release_preflight.sh
```

Le preflight vérifie les prérequis locaux sans afficher les secrets :
Xcode/SDK iOS, certificat Apple Distribution, signature Android, SDK Android,
Java, manifestes iOS et URL API HTTPS.

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

## Easypanel et apps stores

Le backend actuel sur Easypanel est compatible avec une publication App Store
/ Play Store, tant que l'application mobile pointe vers une API HTTPS stable.

En pratique:

- la migration mobile ne force pas de changement d'hebergement
- l'app Flutter native peut continuer a consommer l'API Aid'Habitat
  derriere Easypanel
- les vrais sujets "store" sont surtout la signature, la qualite mobile,
  les metadonnees de publication et les prerequis Apple / Google

## Cible actuelle: iPad d'abord

Le projet est actuellement prepare en priorite pour un usage iPad:

- mode offline-first
- saisie longue et prise de notes pendant visite
- support clavier/trackpad iPadOS
- multitache iPad (Split View / Stage Manager)
- support Apple Pencil natif

La sortie Android/Play Store reste possible plus tard, mais ne pilote pas
les decisions de structure a court terme.

## Blocages release constates localement

Au 2026-06-03, le preflight natif (`tool/release_preflight.sh`) remonte
encore les points suivants avant une vraie archive TestFlight / Play Store:

- espace disque local insuffisant pour les archives iOS/Android
- certificat Apple Distribution absent du trousseau
- `DEVELOPMENT_TEAM` non configure dans le projet iOS
- Java 25 installe localement au lieu d'un JDK 17/21 recommande
- `android/key.properties` absent, donc pas de signature Android release

Ces points ne remettent pas en cause l'architecture mobile. Ils bloquent
simplement la production d'un binaire store signe depuis cette machine.
