# Transition iPad native - App'Ergo

Etat initial : 2026-07-03.

Objectif : passer progressivement de la PWA `app.aidhabitat.fr` vers une app
iPad native distribuable via TestFlight, puis App Store, sans casser la version
web/EasyPanel existante.

## Pourquoi cette transition

La PWA reste utile pour desktop et accès rapide, mais l'usage terrain iPad a des
besoins que Safari/PWA gère imparfaitement :

- Apple Pencil fiable pour la prise de note dessin.
- Double tap Pencil vers la gomme.
- Scan document avec détection de contours.
- WebView intégrée pour le portail ANAH.
- Meilleure persistance locale chiffrée et permissions natives.

Le code Flutter natif existe déjà et doit devenir la cible principale pour les
visites terrain iPad.

## Etat actuel

| Sujet | Etat | Commentaire |
| --- | --- | --- |
| Cible iOS Flutter | Présente | `aid_habitat_app/ios` existe avec workspace Xcode. |
| Bundle ID | Présent | `com.aidhabitat.manager`. |
| Signature Xcode | Préconfigurée | Team `V933MALQLD` détectée dans le projet iOS. |
| Permissions | Présentes | Caméra, photothèque, documents, URL schemes. |
| Privacy manifest | Présent | `ios/Runner/PrivacyInfo.xcprivacy`. |
| Base locale | Avancée | SQLite natif + SQLCipher via `sqflite_sqlcipher`. |
| Scanner document | Présent | `DocumentScannerPlugin.swift`. |
| Double tap Pencil | Présent | `PencilDoubleTapPlugin.swift`. |
| WebView | Présente | `flutter_inappwebview`. |
| PWA | Active | Sert toujours via EasyPanel. |

## Principe de transition

Ne pas remplacer brutalement la PWA.

1. Garder EasyPanel/API/NocoDB comme backend commun.
2. Garder la PWA en production web.
3. Stabiliser l'iPad natif en parallèle via TestFlight.
4. Faire les tests terrain sur iPad natif.
5. Quand l'iPad natif est validé, le déclarer comme cible terrain officielle.

## Architecture cible

| Couche | Cible terrain iPad | Cible web/desktop |
| --- | --- | --- |
| UI | Flutter iOS natif | Flutter Web PWA |
| Stockage local | SQLite SQLCipher + Keychain | SQLite WASM/IndexedDB |
| Sync | API `https://api.aidhabitat.fr` | API `https://api.aidhabitat.fr` |
| Backend | EasyPanel API + NocoDB | EasyPanel API + NocoDB |
| Notes dessin | Canvas Flutter natif | Canvas Flutter Web fallback |
| Scan document | VisionKit natif | Upload/photo classique |
| Portail ANAH | WebView native ou Safari fallback | Iframe/web fallback |

## Phase 1 - Readiness TestFlight

Objectif : obtenir une archive iOS distribuable.

Actions :

- Vérifier `flutter analyze`.
- Vérifier `flutter build ios --release --no-codesign`.
- Ouvrir `ios/Runner.xcworkspace` dans Xcode.
- Vérifier bundle ID `com.aidhabitat.manager`.
- Vérifier version `1.0.0+build`.
- Créer l'app dans App Store Connect.
- Archiver depuis Xcode.
- Uploader vers TestFlight.

Critère de sortie :

- Une build TestFlight installable sur au moins un iPad de test.

### Préflight local du 2026-07-03

Commande exécutée :

```bash
flutter build ios --release --no-codesign --dart-define=AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr
```

Résultat :

- Build iOS release OK.
- Bundle généré : `build/ios/iphoneos/Runner.app`.
- Taille du bundle : 36 MB.
- Bundle ID : `com.aidhabitat.manager`.
- Version : `1.0.0 (1)`.
- Minimum iOS : 13.0.
- Familles supportées : iPhone + iPad.
- API cible intégrée : `https://api.aidhabitat.fr`.

Conclusion : le code natif est prêt pour l'étape archive/signature Xcode. Le
blocage restant n'est pas du code, mais la distribution Apple : compte Apple
Developer, App Store Connect, certificats/profils et upload TestFlight.

### Archive/TestFlight du 2026-07-03

Commande exécutée :

```bash
flutter build ipa --release --dart-define=AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr
```

Résultat :

- Archive Xcode OK : `build/ios/archive/Runner.xcarchive`.
- Taille archive : 215 MB.
- Validation settings OK : version `1.0.0`, build `1`, bundle
  `com.aidhabitat.manager`, deployment target iOS 13.0.
- Export IPA App Store échoué.

Blocage Apple exact :

- Certificat `iOS Distribution` absent.
- Aucun provisioning profile App Store pour `com.aidhabitat.manager`.
- La team Apple `Joris Balluais` n'a pas la permission de créer les profils
  `iOS App Store`.

Conclusion : l'application est archivable, mais pas encore exportable pour
TestFlight. Il faut activer ou utiliser un compte Apple Developer Program avec
les droits Certificates, Identifiers & Profiles, puis créer l'app dans App Store
Connect.

## Phase 2 - Validation terrain iPad

Objectif : vérifier les flux métier réels en natif.

Parcours minimum :

- Connexion Coralie.
- Liste dossiers.
- Ouverture dossier.
- Relevé à domicile.
- Notes texte.
- Notes dessin Apple Pencil.
- Mini-traits rapides Apple Pencil.
- Changement gomme via double tap Pencil.
- Ajout photo.
- Scan document.
- Ajout document.
- Génération PDF.
- Mode offline puis resynchronisation.

Critère de sortie :

- Aucun blocage P0 sur visite complète.
- Notes dessin utilisables en conditions terrain.
- Données conservées après fermeture/reprise de l'app.

## Phase 3 - Stabilisation native

Objectif : corriger uniquement les écarts natifs constatés.

Priorités :

- Apple Pencil et latence dessin.
- Clavier iPad et zones masquées.
- Permissions photo/caméra/documents.
- WebView ANAH ou fallback Safari clair.
- Gestion offline et conflits.
- Taille de bundle et assets offline.

Ne pas faire dans cette phase :

- Refonte UI large.
- Migration backend.
- Nouvelle logique métier majeure.

## Phase 4 - Préparation App Store

Objectif : passer de TestFlight interne à distribution publique/contrôlée.

A fournir dans App Store Connect :

- Nom app.
- Sous-titre.
- Description.
- Icône finale.
- Captures iPad.
- Coordonnées support.
- URL politique de confidentialité.
- Privacy labels alignés avec `PrivacyInfo.xcprivacy`.
- Déclaration chiffrement : `ITSAppUsesNonExemptEncryption = false`, si usage
  limité au chiffrement standard HTTPS/Apple.

Critère de sortie :

- Build soumise à Apple sans rejet technique bloquant.

## Risques principaux

| Risque | Mitigation |
| --- | --- |
| Apple Pencil PWA instable | Basculer usage terrain sur iPad natif. |
| WebView ANAH refusée/certificat | Prévoir bouton Safari fallback validé. |
| Données offline divergentes | Tests terrain avec sync forcée avant PDF. |
| Privacy labels incomplets | Vérifier avec données réellement collectées. |
| Certificats/profils Apple | Utiliser Apple Developer Program payant. |
| App Store review | Commencer par TestFlight interne avant revue publique. |

## Ce qui reste compatible EasyPanel

La transition iPad native ne nécessite pas de changer immédiatement :

- API EasyPanel.
- NocoDB.
- Sync existante.
- PWA existante.
- Génération PDF backend.
- Images/assets déjà intégrés localement.

## Décision recommandée

Priorité immédiate : créer une build TestFlight interne, puis tester l'Apple
Pencil en natif sur les notes dessin.

Si le Pencil fonctionne correctement en TestFlight, la cible terrain doit
devenir l'app iPad native. La PWA reste la cible desktop/web.

Si le Pencil présente encore des bugs en natif, le problème est dans le widget
Flutter lui-même et non dans Safari/PWA ; il faudra alors profiler le widget
native avec une instrumentation dédiée.
