# Matrice de Parité Écran par Écran

## Objectif

Cette matrice détaille, pour chaque écran de l'application React de référence:

- la structure visible à reproduire
- les actions utilisateur à conserver
- les dépendances de données actuelles
- les états critiques à valider pendant la migration Flutter

Elle complète l'audit global dans `docs/mobile-offline-parity-audit.md`.

## Convention

Chaque écran est décrit selon quatre rubriques:

- `UI`: ce que l'utilisateur voit
- `Actions`: ce que l'utilisateur peut faire
- `Données`: ce qui alimente ou persiste l'écran
- `États`: ce qu'il faudra tester explicitement

## 1. Shell applicatif

Références:

- `App.tsx`
- `components/Sidebar.tsx`

### UI

- sidebar fixe à gauche
- fond général bleu/gris `#C5D2D8`
- grand panneau principal blanc avec coins très arrondis
- contenu principal scrollable

### Actions

- naviguer entre `dashboard`, `dossiers`, `wiki`, `precos`, `finance`
- accéder à `settings` via l'avatar
- accéder à `admin` uniquement si rôle `ADMIN`

### Données

- `currentView`
- utilisateur courant `AppUser`
- dossier sélectionné
- dossiers chargés
- visites dérivées des dossiers

### États

- non authentifié
- authentifié + chargement initial
- authentifié + vue normale
- vue demandant un dossier sans dossier sélectionné
- accès refusé à `admin`

## 2. Login

Référence:

- `components/LoginView.tsx`

### UI

- carte centrée blanche
- logo cadenas dans une tuile mauve
- titre `Aid'Habitat`
- champ email
- champ mot de passe
- bouton principal
- message d'erreur inline

### Actions

- saisir email
- saisir mot de passe
- soumettre le formulaire

### Données

- `loginApp(email, password)`
- récupération du token applicatif
- stockage du token de session
- retour utilisateur complet après login réussi

### États

- formulaire vierge
- loading `Connexion...`
- erreur `Adresse mail non autorisée`
- erreur `Mot de passe incorrect`
- succès avec transition vers le dashboard

## 3. Dashboard

Référence:

- `components/Dashboard.tsx`

### UI

- salutation `Bonjour, {prénom}`
- date du jour en français
- trois KPI cards
- bloc `Dossiers Récents`
- histogramme `Activité`

### Actions

- cliquer sur une KPI pour naviguer vers `dossiers`
- cliquer sur `Voir tout`
- cliquer sur un dossier récent pour ouvrir son détail

### Données

- `dossiers`
- `visits`
- fallback local `snapshot.json` si dossiers absents
- plusieurs indicateurs encore codés en dur ou partiellement dérivés

### États

- dashboard avec dossiers live
- dashboard avec fallback snapshot
- dashboard vide
- dashboard avec nom utilisateur absent

## 4. Liste des dossiers

Référence:

- `components/DossierView.tsx` section `DossierList`

### UI

- titre `Mes dossiers`
- champ de recherche
- bouton de tri
- barre alphabétique A-Z
- liste de lignes de dossier
- bouton flottant de création

### Actions

- rechercher par nom, prénom, ville
- filtrer par lettre
- trier `A à Z`, `Z à A`, `Aléatoire`
- ouvrir un dossier
- ouvrir la création d'un nouveau bénéficiaire/dossier

### Données

- `dossiers` props
- fallback `snapshot.json`
- références `communes`
- références `ergos`
- utilisateur courant pour la logique de rôle

### États

- liste standard
- liste vide
- liste filtrée
- liste sans données live avec fallback snapshot
- ouverture/fermeture du menu de tri

## 5. Création bénéficiaire / dossier

Référence:

- `components/DossierView.tsx` section création dans `DossierList`

### UI

- modal ou panneau de création
- champs identité et contact
- bloc commune avec autocomplétion
- sélection de l'ergo selon le rôle
- message d'erreur éventuel
- état de chargement de création

### Actions

- saisir nom, prénom, adresse, CP, ville, téléphone, email
- choisir une commune suggérée
- choisir un ergo si admin
- lancer la création

### Données

- `fetchReferenceData()`
- `createBeneficiaryWithDossier()`
- contraintes de rôle: un ergo non admin n'assigne pas librement

### États

- modal fermée
- modal ouverte
- création en cours
- erreur de création
- succès avec insertion du nouveau dossier dans la liste

## 6. Détail dossier

Référence:

- `components/DossierView.tsx` section `DossierDetail`

### UI

- en-tête dossier avec nom complet
- statut `Dossier actif`
- date de création
- deux cartes d'accès rapide
- carte `Informations Bénéficiaire`
- bloc `Personne de confiance`
- panneau `Notes Rapides`

### Actions

- revenir à la liste
- ouvrir `Espace Documents`
- ouvrir `Visite Domicile`
- basculer en mode édition bénéficiaire
- modifier identité et coordonnées
- sauvegarder les modifications
- naviguer entre pages de notes
- ajouter une page de note
- saisir texte et dessin libre

### Données

- lecture note via `fetchPatientNote(patientId, page)`
- comptage via `fetchPatientNotesCount`
- sauvegarde note via `savePatientNote`
- mise à jour bénéficiaire via `updateBeneficiary`
- références communes pour le champ ville/CP

### États

- mode lecture
- mode édition
- note vide
- note existante avec dessin
- plusieurs pages de note
- erreur de sauvegarde bénéficiaire

## 7. Documents

Référence:

- `components/DocumentsView.tsx`

### UI

- en-tête dossier + bouton retour
- barre de recherche
- filtres par tags
- grille de cartes document
- tuile `+` pour ajout
- menu d'ajout contextuel
- modal de renommage
- modal de suppression
- modal d'upload avec nom + tag

### Actions

- rechercher un document
- filtrer par tag
- ajouter image
- prendre une photo
- scanner un document
- importer un fichier
- nommer et tagger un fichier avant upload
- ouvrir un document
- renommer un document
- supprimer un document

### Données

- `fetchDocuments(patientId)`
- `uploadDocument(patientId, file, patientName, customName, tags)`
- `renameDocument(documentId, newTitle)`
- `deleteDocument(documentId)`
- dépendance directe à Supabase Storage bucket `documents`
- dépendance directe à la table `patient_documents`

### États

- grille vide
- grille avec documents mixtes image/pdf/doc
- upload en cours
- erreur d'upload
- renommage réussi
- suppression optimiste puis rollback si erreur

## 8. Démarrage de visite

Référence:

- `App.tsx` composant inline `VisitStartView`

### UI

- écran centré de confirmation
- icône bâtiment
- titre `Visite chez {prénom}`
- trois cartes infos: adresse, type, motif
- bouton `Annuler`
- bouton `C'est parti !`

### Actions

- annuler
- démarrer le relevé

### Données

- dossier courant
- champs affichés venant du dossier et du logement

### États

- dossier complet
- dossier incomplet avec `Non renseigné`

## 9. Relevé de visite: shell

Référence:

- `components/VisitReportView.tsx`

### UI

- bouton retour
- barre d'onglets horizontale
- badge de statut de sauvegarde
- bouton manuel `Enregistrer`
- panneau formulaire à gauche
- panneau `Notes — {onglet}` à droite

### Actions

- changer d'onglet
- revenir à l'écran précédent
- lancer une sauvegarde manuelle
- naviguer entre pages de notes d'onglet
- ajouter une page de note

### Données

- dossier courant
- références métier
- sous-entités chargées au montage
- notes paginées liées à l'onglet

### États

- chargement initial références
- chargement initial sous-entités
- save status `idle`
- save status `saving`
- save status `saved`
- save status `error`

## 10. Relevé de visite: onglet Bénéficiaire

Référence:

- `components/VisitReportView.tsx` composant `BeneficiaryForm`

### UI

- sections:
- `Identité`
- `Coordonnées`
- `Situation`
- `Revenus`
- `Santé / Autonomie`
- `Personne de Confiance`
- `Informations Administratives (Dossier)`
- `Renseignements sur la visite`

### Actions

- modifier nom, prénom, dates de naissance Mr/Mme
- modifier adresse, CP, ville, commune
- modifier téléphone et email
- choisir situation familiale
- choisir nombre de personnes
- choisir occupation
- saisir revenu fiscal
- cocher APA, invalidité, aide à domicile
- saisir les détails conditionnels
- modifier personne de confiance
- modifier compte Anah, nature accompagnement
- saisir numéros de sécurité sociale
- saisir caisses retraite
- choisir mode d'envoi du rapport
- choisir ergothérapeute
- visualiser établissement déduit
- saisir personnes présentes à la visite

### Données

- `updateBeneficiary`
- `updateDossier`
- références `situations`
- références `dependances`
- références `ergos`
- références `etablissements`
- références `communes`

### États

- champs remplis
- champs vides
- champs conditionnels affichés ou non
- établissement recalculé depuis l'ergo
- revenu fiscal en édition puis commit au blur

## 11. Relevé de visite: onglet Contexte de vie

Référence:

- `components/VisitReportView.tsx` composant `ContextForm`

### UI

- section `Informations Médicales`
- section `Autonomie (ADL/IADL)`
- liste d'items d'autonomie avec coche
- indicateur `Autonomie évaluée ?`

### Actions

- modifier pathologie
- modifier suivi
- modifier sensoriel
- modifier taille / poids
- basculer `Autonomie évaluée ?`
- cocher/décocher chaque item d'autonomie

### Données

- `updateDossier` pour la partie contexte/autonomie

### États

- autonomie non évaluée
- autonomie évaluée
- aucune case cochée
- plusieurs cases cochées

## 12. Relevé de visite: onglet Accessibilité

Référence:

- `components/VisitReportView.tsx` composant `AccessForm`

### UI

- sections:
- `Général`
- `Accessibilité Extérieure`
- `Cheminement d'accès`
- `Niveaux & Pièces`
- `Annexes & Motorisations`
- `Chauffage`

### Actions

- modifier année construction / habitation
- modifier surface
- choisir nombre de niveaux
- choisir type `Maison` ou `Appartement`
- cocher `Accès facile rue`
- saisir observation accessibilité
- cocher les options de cheminement
- cocher difficultés circulation intérieure
- cocher sous-sol / RDC / étage
- saisir leurs descriptions conditionnelles
- cocher garage / véranda / balcon / terrasse / jardin
- choisir porte de garage
- choisir portail
- cocher chauffage principal
- cocher les types de chauffage

### Données

- `updateHousing`
- références `porteGarage`
- références `portail`

### États

- logement minimal
- logement complet
- descriptions conditionnelles affichées
- chauffage principal absent
- plusieurs sous-types de chauffage cochés

## 13. Relevé de visite: onglet Salle de bain

Référence:

- `components/VisitReportView.tsx` composant `SalleDeBainForm`

### UI

- section `Configuration`
- section `Équipements Salle de Bain`
- section `Porte Salle de Bain`

### Actions

- cocher `SDB au niveau des pièces de vie`
- cocher baignoire et saisir hauteur conditionnelle
- cocher bac à douche et saisir hauteur conditionnelle
- cocher vasque suspendue / colonne / meuble
- cocher bidet, paroi douche, sol glissant
- cocher machine à laver
- cocher largeur suffisante
- saisir dimension de porte
- cocher sens d'ouverture adapté

### Données

- `fetchDiagnosticSanitaires`
- `upsertDiagnosticSanitaires`

### États

- formulaire vide
- hauteurs conditionnelles visibles
- retour de données existantes

## 14. Relevé de visite: onglet WC

Référence:

- `components/VisitReportView.tsx` composant `WCForm`

### UI

- section `Configuration WC`
- section `Équipements WC`
- section `Porte WC`
- section `Observation équipements`

### Actions

- cocher WC à niveau
- cocher WC à l'étage
- cocher bonne hauteur / trop basse
- saisir hauteur cuvette
- cocher barre de relèvement
- cocher largeur suffisante
- saisir dimension largeur
- cocher sens d'ouverture adapté
- saisir le texte d'observation

### Données

- `fetchDiagnosticSanitaires`
- `upsertDiagnosticSanitaires`

### États

- WC simple
- WC documenté avec mesures
- observation vide / remplie

## 15. Relevé de visite: onglet Équipements lourds

Référence:

- `components/VisitReportView.tsx` composant `EquipementsLourdsForm`

### UI

- section volets roulants manuels
- section volets roulants électriques
- section persiennes

### Actions

- cocher `logement entier`
- saisir localisation pour chaque famille d'équipement

### Données

- `updateHousing`

### États

- aucune famille renseignée
- une famille renseignée
- plusieurs familles renseignées

## 16. Relevé de visite: onglet Synthèse

Référence:

- `components/VisitReportView.tsx` composant `SyntheseForm`

### UI

- section `Observation sur les équipements`
- section `Plan 2D du logement`
- section `Projet ou souhait de l'usager`
- section `Résumé des préconisations`

### Actions

- saisir l'observation équipements
- dessiner le plan 2D
- effacer / redessiner le plan
- saisir le projet de l'usager
- saisir le résumé des préconisations

### Données

- `fetchObservationsSynthese`
- `upsertObservationsSynthese`
- upload plan dans Supabase Storage bucket `notes`

### États

- synthèse vide
- synthèse texte seule
- synthèse avec plan chargé
- sauvegarde plan réussie / échouée

## 17. Relevé de visite: onglet Mesures

Référence:

- `components/VisitReportView.tsx` composant `MesuresForm`

### UI

- section `Position debout`
- section `Position assise`
- section `Observations`

### Actions

- saisir hauteur coude fléchi
- saisir hauteur d'assise
- saisir profondeur genoux
- saisir hauteur coudes assis
- saisir observations

### Données

- `fetchMesuresAnthropometriques`
- `upsertMesuresAnthropometriques`

### États

- mesures vides
- mesures partielles
- mesures complètes

## 18. NotesCanvas

Référence:

- `components/NotesCanvas.tsx`

### UI

- zone texte
- zone dessin
- pagination de pages
- bouton ajout de page
- outils `pen`, `eraser`, `highlighter`
- réglages couleur / taille selon outil

### Actions

- saisir du texte
- dessiner à main levée
- surligner
- gommer
- changer de page
- ajouter une page

### Données

- `initialText`
- `initialDrawingUrl`
- `onSave(text, blob)`
- auto-save debounce 800 ms

### États

- page vierge
- page avec texte
- page avec dessin
- changement de page
- auto-save après modification

## 19. PlanCanvas

Référence:

- `components/PlanCanvas.tsx`

### UI

- grille avec règles graduées
- outils `pen`, `eraser`, `line`, `rect`
- canevas de prévisualisation

### Actions

- dessiner librement
- tracer une ligne
- tracer un rectangle
- effacer
- exporter / sauvegarder

### Données

- `initialDrawingUrl`
- `onSave(blob)`
- auto-save debounce 1 seconde

### États

- canevas vide
- canevas avec plan existant
- redimensionnement du canevas
- sauvegarde après dessin

## 20. Administration

Référence:

- `components/AdminPanel.tsx`

### UI

- en-tête page admin
- bouton `Actualiser`
- quatre cartes statistiques
- liste détaillée des membres
- boutons `Copier` et `Réinitialiser`

### Actions

- recharger la liste
- copier email + mot de passe
- réinitialiser un mot de passe

### Données

- `fetchAdminAccessMembers()`
- `regenerateAccessPassword(email)`
- dépendance `navigator.clipboard`

### États

- chargement initial
- rafraîchissement
- erreur de chargement
- copie réussie
- reset en cours

## 21. Paramètres

Référence:

- `components/SettingsView.tsx`

### UI

- carte utilisateur
- bouton déconnexion
- bloc `Diagnostic Connexion`
- bloc d'information textuelle

### Actions

- relancer un test de connexion
- se déconnecter

### Données

- `checkSupabaseConnection()` qui appelle `/api/health`
- `onLogout()`

### États

- test en cours
- connecté
- erreur de connexion
- utilisateur absent

## 22. Wiki

Référence:

- `components/WikiView.tsx`

### UI

- galerie d'images
- filtres par tags
- ajout image locale
- panneau de détail image

### Actions

- filtrer par tag
- ouvrir une image
- modifier titre, description, tags
- supprimer une image
- ajouter une image locale

### Données

- état local uniquement
- pas de backend

### États

- galerie initiale
- ajout local
- détail ouvert
- filtre appliqué

## 23. Placeholder Favoris / Finance

Référence:

- `App.tsx`

### UI

- écran centré
- titre `Module en construction`

### Actions

- aucune action métier

### Données

- aucune

### États

- simple affichage placeholder

## 24. États transverses obligatoires à valider

Ces cas ne sont pas un écran unique mais doivent être inclus dans la campagne de parité:

- session non résolue au démarrage
- authentification invalide
- dossier courant perdu lors d'une navigation
- erreur de chargement du relevé avec `ViewErrorBoundary`
- absence de données live et fallback snapshot
- formulaire avec données partielles
- autosave en succès
- autosave en erreur
- rôle `ERGO` vs rôle `ADMIN`

## Conclusion

Cette matrice constitue le niveau minimal de détail à conserver pendant le portage Flutter.

La règle de migration recommandée est la suivante:

- reproduire d'abord la structure et les interactions visibles
- brancher ensuite les mêmes contrats de données
- seulement après introduire la persistance locale et la synchronisation offline-first
