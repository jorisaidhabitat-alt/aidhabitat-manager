# Preparation distribution Apple - App'Ergo

Objectif : rendre l'application Flutter prete pour une installation propre sur
iPad/Mac, puis pour une soumission future via TestFlight, App Store ou
distribution macOS notarisee.

Etat valide le 2026-06-08.

## Etat actuel

| Sujet | Etat | Commentaire |
| --- | --- | --- |
| Build iOS release | Pret cote code | `flutter build ios --release --no-codesign` passe. La signature de distribution reste a faire avec le compte Apple Developer. |
| Build macOS release | Pret cote code | `flutter build macos --release` passe. Le bundle local est encore signe ad hoc, donc non distribuable tel quel. |
| Bundle identifier | Pret | iOS/macOS utilisent `com.aidhabitat.manager`. A conserver si on veut une app multi-plateforme unique dans App Store Connect. |
| Permissions iOS | Pret | Camera, phototheque, documents, telephone, SMS, mail et URLs declares dans `Info.plist`. |
| Permissions macOS | Pret | Camera, phototheque, fichiers selectionnes par l'utilisateur et reseau declares via entitlements. |
| Privacy manifest iOS | Pret | `PrivacyInfo.xcprivacy` present et valide. |
| Privacy manifest macOS | Pret | `PrivacyInfo.xcprivacy` ajoute aux ressources macOS et valide. |
| Hardened Runtime macOS | Pret | Active en Release pour preparer la notarisation. |
| Gatekeeper macOS | En attente Apple | Rejet normal tant que l'app est signee ad hoc et non notarisee. |
| Certificats locaux | En attente Apple | Le Mac contient seulement un certificat `Apple Development`. Il manque `Apple Distribution` et/ou `Developer ID Application`. |

## Installation iPad propre aujourd'hui

1. Garder Xcode installe et connecte au compte Apple.
2. Brancher l'iPad au Mac et activer le mode developpeur sur l'iPad.
3. Ouvrir `aid_habitat_app/ios/Runner.xcworkspace`.
4. Selectionner la cible `Runner`.
5. Dans `Signing & Capabilities`, choisir la team Apple.
6. Lancer sur l'iPad avec Xcode ou Flutter.

Cette installation reste une installation de developpement. Pour une
installation stable chez plusieurs testeurs, il faudra TestFlight.

## TestFlight iPad

1. Souscrire a l'Apple Developer Program.
2. Creer l'app dans App Store Connect avec le bundle id
   `com.aidhabitat.manager`.
3. Verifier que `ITSAppUsesNonExemptEncryption` reste a `false` si l'app
   utilise uniquement le chiffrement standard HTTPS/Apple.
4. Archiver l'app iOS dans Xcode.
5. Distribuer l'archive vers App Store Connect.
6. Remplir les informations TestFlight : description beta, email de feedback,
   consignes de test.
7. Ajouter les testeurs internes, puis externes si besoin.

Point Apple important : les builds TestFlight sont utilisables pour une duree
limitee et les testeurs externes peuvent necessiter une validation beta.

## Distribution macOS

Deux chemins sont possibles.

### Mac App Store

1. Utiliser le meme bundle id si l'app reste multi-plateforme.
2. Creer la plateforme macOS dans App Store Connect.
3. Signer avec les certificats/profils Mac App Store.
4. Archiver avec Xcode.
5. Envoyer a App Store Connect.

### Distribution hors Mac App Store

1. Obtenir un certificat `Developer ID Application`.
2. Signer l'app avec ce certificat.
3. Conserver le Hardened Runtime actif.
4. Creer un `.dmg` ou `.pkg`.
5. Notariser avec Apple.
6. Stapler le ticket de notarisation.
7. Verifier Gatekeeper avec `spctl`.

Sans `Developer ID Application`, une app macOS distribuee hors App Store sera
refusee par Gatekeeper ou demandera des manipulations manuelles au client.

## Privacy labels App Store Connect

Les labels App Store Connect doivent correspondre au manifest present dans
l'app.

| Donnee | Liee a l'utilisateur | Tracking | Usage |
| --- | --- | --- | --- |
| Nom | Oui | Non | Fonctionnalite de l'app |
| Email | Oui | Non | Fonctionnalite de l'app, authentification |
| Telephone | Oui | Non | Fonctionnalite de l'app |
| Adresse physique | Oui | Non | Fonctionnalite de l'app |
| Donnees de sante | Oui | Non | Fonctionnalite de l'app |
| Photos ou videos | Oui | Non | Fonctionnalite de l'app |
| Informations financieres | Oui | Non | Fonctionnalite de l'app |
| Contenu utilisateur | Oui | Non | Fonctionnalite de l'app |
| Identifiant utilisateur | Oui | Non | Fonctionnalite de l'app, authentification |
| Donnees de crash | Non | Non | Fonctionnalite de l'app, analytics si un outil de crash est actif |

Si aucun outil de crash analytics n'est active dans la version finale, retirer
ou ajuster la ligne `CrashData` avant soumission pour eviter de sur-declarer.

## Controle local avant archive

Depuis `aid_habitat_app` :

```bash
flutter analyze
flutter build ios --release --no-codesign --dart-define=AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr
flutter build macos --release --dart-define=AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr
```

Controle macOS apres build :

```bash
codesign -dvvv --entitlements :- "build/macos/Build/Products/Release/App'Ergo.app"
spctl -a -vv "build/macos/Build/Products/Release/App'Ergo.app"
```

Le resultat attendu aujourd'hui est :

- `codesign` montre `runtime` actif et les entitlements Release.
- `spctl` rejette encore le bundle local car il est signe ad hoc.
- Apres signature Developer ID + notarisation, `spctl` devra accepter le bundle.

## References Apple

- Privacy manifests : https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk
- App privacy labels : https://developer.apple.com/app-store/app-privacy-details/
- TestFlight : https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- Notarisation macOS : https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Hardened Runtime : https://developer.apple.com/documentation/security/hardened-runtime
