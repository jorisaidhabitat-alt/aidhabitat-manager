# Audit de Parité React -> Mobile Offline-First

## Objectif

Ce document fige la référence fonctionnelle et visuelle de l'application actuelle avant migration vers une application mobile offline-first.

Il sert à garantir deux contraintes:

- la connectivité métier ne doit pas régresser pendant la transition
- l'UI perçue par les utilisateurs doit rester strictement équivalente

## Périmètre actuel

L'application de référence est la web app React/Vite située à la racine du dépôt. Le point d'entrée principal est `App.tsx`.

Le dépôt contient aussi une application Flutter (`aid_habitat_app/`), mais elle n'est pas au même niveau de maturité fonctionnelle que la web app. La web app est donc la source de vérité produit à migrer.

## Stack actuelle

### Frontend de référence

- React 19
- Vite
- composants maison dans `components/`
- styles utilitaires via Tailwind chargé par CDN dans `index.html`
- icônes `lucide-react`
- graphiques `recharts`

### Backend de référence

- Express dans `server/index.mjs`
- authentification applicative maison avec session token stocké côté client
- données métier servies par le backend via NocoDB MCP

### Intégrations directes côté client

Le frontend ne passe pas uniquement par l'API Express. Il parle aussi directement à Supabase pour:

- documents
- notes patient
- plans dessinés

Conséquence: la migration mobile devra unifier ou assumer ce double contrat.

## Source de vérité actuelle

### Navigation principale

La navigation est pilotée par un état local `currentView` dans `App.tsx`, pas par un routeur.

Vues principales:

- `dashboard`
- `dossiers`
- `documents`
- `visit`
- `visit-report`
- `admin`
- `settings`
- `wiki`
- `precos`
- `finance`

### Règle produit actuelle

- si l'utilisateur n'est pas authentifié: affichage du login
- si l'utilisateur est authentifié: chargement initial des dossiers
- polling de rafraîchissement des dossiers toutes les 15 secondes
- la sélection du dossier courant pilote les vues secondaires

## Inventaire UI à préserver

### 1. Coque globale

Référence visuelle:

- fond principal bleu/gris `#C5D2D8`
- carte centrale blanche `#FDFDFD`
- couleur d'accent mauve `#907CA1`
- sidebar fixe gauche très étroite
- grand panneau contenu avec coins fortement arrondis

Comportements à préserver:

- sidebar toujours visible après login
- infobulles au survol sur desktop
- avatar utilisateur en bas de sidebar ouvrant les paramètres

### 2. Écran de connexion

Composant: `components/LoginView.tsx`

Éléments à préserver:

- carte centrée sur fond bleu/gris
- icône cadenas dans une tuile mauve
- deux champs: email, mot de passe
- message d'erreur inline
- bouton principal `Se connecter`
- état de chargement `Connexion...`

### 3. Dashboard

Composant: `components/Dashboard.tsx`

Éléments à préserver:

- salutation personnalisée
- date du jour en français
- trois KPI cards
- bloc dossiers récents
- histogramme activité

Remarque importante:

- des valeurs sont encore partiellement mockées ou dérivées localement
- le dashboard tombe sur `snapshot.json` si les dossiers props sont vides

### 4. Dossiers

Composant principal: `components/DossierView.tsx`

Le module couvre deux états:

- liste des dossiers
- détail d'un dossier

#### 4.1 Liste des dossiers

Éléments à préserver:

- titre `Mes dossiers`
- recherche plein champ
- tri `A à Z`, `Z à A`, `Aléatoire`
- barre alphabétique A-Z
- lignes de dossier avec initiales, nom, ville, statut
- bouton flottant de création

Création:

- modal de création bénéficiaire/dossier
- références chargées dynamiquement pour communes et ergos
- contrainte de rôle: l'admin choisit l'ergo, l'ergo simple non

Fallback actuel:

- si aucun dossier n'est chargé, la liste recharge un `snapshot.json`

#### 4.2 Détail d'un dossier

Éléments à préserver:

- en-tête patient
- blocs d'informations synthétiques
- accès vers espace documents
- accès vers visite domicile
- zone de notes libre

### 5. Documents

Composant: `components/DocumentsView.tsx`

Éléments à préserver:

- grille de documents
- recherche
- filtres par tags
- ajout de document via menu contextuel
- variantes d'import: image, photo, scan, import
- upload avec modal de nommage et tag
- visualisation d'un document sélectionné
- renommage
- suppression avec confirmation

Spécificité forte:

- le module dépend directement de Supabase Storage et de la table `patient_documents`

### 6. Démarrage de visite

Vue inline dans `App.tsx`

Éléments à préserver:

- écran intermédiaire de confirmation avant relevé
- rappel adresse / type / motif
- CTA principal `C'est parti !`

### 7. Relevé de visite

Composant: `components/VisitReportView.tsx`

C'est l'écran le plus critique de la migration.

Onglets actuels:

- Bénéficiaire
- Contexte de vie
- Accessibilité
- Salle de bain
- WC
- Équipements lourds
- Synthèse
- Mesures

Comportements à préserver:

- auto-save visuel avec états `saving/saved/error`
- chargement de références métier
- chargement de sous-entités par dossier
- notes paginées par onglet
- dessin libre pour notes
- plan 2D dessiné et enregistré
- sauvegarde partielle par section

Écritures métier actuelles depuis cet écran:

- bénéficiaire
- dossier
- logement
- diagnostic sanitaires
- mesures anthropométriques
- observations de synthèse
- notes patient
- plan image

### 8. Administration

Composant: `components/AdminPanel.tsx`

Éléments à préserver:

- liste des comptes applicatifs
- indicateurs de volume
- copie email + mot de passe
- réinitialisation du mot de passe
- visibilité réservée au rôle `ADMIN`

### 9. Paramètres

Composant: `components/SettingsView.tsx`

Éléments à préserver:

- carte profil utilisateur
- diagnostic de connexion
- bouton de logout

Point à clarifier:

- le libellé parle de NocoDB, mais le test de connexion passe par l'endpoint `/api/health`

### 10. Wiki / Favoris / Finance

Composants:

- `components/WikiView.tsx`
- placeholders dans `App.tsx` pour `precos` et `finance`

État produit actuel:

- `wiki` est local et non branché au backend
- `precos` et `finance` ne sont pas encore livrés

## Contrat de données actuel

## Authentification

Flux actuel:

1. login sur `/api/auth/login`
2. réception d'un token applicatif
3. stockage du token en `localStorage` sous `aidhabitat.app_session`
4. envoi du token via header `X-App-Session`
5. validation de session via `/api/auth/session`

Limite pour mobile offline:

- `localStorage` et session browser doivent être remplacés par un stockage sécurisé mobile

## Endpoints backend utilisés

### Auth et administration

- `POST /api/auth/login`
- `GET /api/auth/session`
- `POST /api/auth/logout`
- `POST /api/profile/photo`
- `POST /api/auth/provision`
- `GET /api/admin/access-members`
- `GET /api/health`

### Métier dossier

- `GET /api/references`
- `GET /api/dossiers`
- `POST /api/beneficiaires`
- `PATCH /api/beneficiaires/:patientId`
- `PATCH /api/dossiers/:dossierId`
- `PATCH /api/logements/by-beneficiary/:beneficiaryId`
- `GET /api/diagnostic-sanitaires/:dossierId`
- `PUT /api/diagnostic-sanitaires/:dossierId`
- `GET /api/mesures/:dossierId`
- `PUT /api/mesures/:dossierId`
- `GET /api/observations/:dossierId`
- `PUT /api/observations/:dossierId`

## Accès directs Supabase depuis le frontend

### Documents

- bucket `documents`
- table `patient_documents`

### Notes et plans

- bucket `notes`
- table `patient_notes`

Conséquence:

- aujourd'hui, le client mélange API backend et accès direct base/storage
- en mobile offline-first, cette séparation doit être réduite ou au minimum encapsulée derrière une couche repository unique

## Comportements de données à figer

### Chargement initial

- authentification
- hydratation initiale avec tentative `fetchLocalSnapshot()` et `fetchDossiers()`
- priorité aux données live si elles sont disponibles

### Rafraîchissement

- polling toutes les 15 secondes après authentification

### Fallbacks existants

- `snapshot.json` local pour dashboard et dossiers

### Identifiants

Le code manipule plusieurs types d'identifiants:

- ids NocoDB numériques
- `uuid_source`
- identifiants applicatifs synthétiques
- ids temporaires préfixés par `temp-`

Cette partie est critique pour une future synchronisation offline.

## Points de risque pour la migration

### 1. Double source réseau

Le client actuel dépend de deux chemins techniques:

- API Express/NocoDB
- accès direct Supabase

Sans consolidation, l'offline-first sera fragile.

### 2. Fallbacks non métier

Le recours à `snapshot.json` aide le web à démarrer, mais ne constitue pas une vraie stratégie offline.

### 3. Auto-save actuel non transactionnel

Le relevé de visite envoie plusieurs écritures séparées selon les sections.

En mobile offline-first, il faudra:

- écrire localement d'abord
- stocker les opérations de sync
- réémettre dans le bon ordre

### 4. Identité des enregistrements

La coexistence de `temp-`, `uuid_source` et ids backend implique un mapping local explicite dans la future app mobile.

### 5. Dépendances navigateur

Le code actuel s'appuie sur:

- `localStorage`
- upload fichier HTML
- `navigator.clipboard`
- rendu web des modales et hover

Tout cela devra être re-spécifié pour mobile.

## Exigences de parité pour la future app mobile

## UI

Doivent rester identiques ou quasi identiques:

- structure sidebar + panneau principal
- hiérarchie visuelle générale
- couleurs de marque
- libellés métier principaux
- organisation des écrans
- ordre des onglets du relevé
- logique des CTA

Peuvent changer en implémentation interne:

- moteur de navigation
- moteur de formulaire
- composants natifs utilisés
- gestion interne des modales et sélecteurs

## Données

Doivent rester équivalents:

- champs métier affichés
- règles de mapping des dossiers/bénéficiaires/logements
- autorisations par rôle
- gestion des documents
- gestion des notes et du plan

Doivent évoluer:

- authentification stockée de façon sécurisée sur mobile
- persistance locale SQLite
- file de synchronisation
- stratégie de reprise après erreur

## Décisions de migration recommandées

### Décision 1

La web app React reste la référence de parité jusqu'à validation fonctionnelle complète de la version Flutter.

### Décision 2

La future app mobile ne doit plus appeler directement l'UI distante pour chaque saisie. Toute saisie doit d'abord être persistée localement.

### Décision 3

Les intégrations Supabase et API Express doivent être encapsulées derrière une couche d'accès unique dans la future app mobile.

### Décision 4

La migration doit se faire par parité d'écran, pas par réinvention produit.

## Backlog immédiat avant migration

### Bloc A. Geler la référence

- capturer tous les écrans de référence
- figer les états critiques: vide, chargement, erreur, succès
- lister précisément les champs visibles par écran

### Bloc B. Geler le contrat de données

- documenter le modèle `Dossier`, `Patient`, `Housing`, `DiagnosticSanitaires`, `MesuresAnthropometriques`, `ObservationsSynthese`
- documenter les identifiants réels utilisés par écran
- définir un contrat de synchronisation futur

### Bloc C. Préparer Flutter

- reproduire la coque visuelle
- reproduire login, dashboard, liste dossiers, détail dossier en lecture seule
- valider la parité visuelle avant les écritures

### Bloc D. Préparer l'offline-first

- base locale SQLite
- file d'actions à synchroniser
- cache local des pièces jointes
- statut de sync visible dans l'UI

## Conclusion

La migration est faisable sans casser l'expérience, mais seulement si la web app actuelle est traitée comme baseline contractuelle.

Le principal risque technique n'est pas l'UI. Le principal risque est le modèle de données hybride actuel:

- une partie passe par l'API Express/NocoDB
- une autre partie passe directement par Supabase

Le chantier suivant devra donc poursuivre sur deux axes simultanés:

- parité écran par écran
- normalisation du contrat de persistance en vue d'un vrai offline-first
