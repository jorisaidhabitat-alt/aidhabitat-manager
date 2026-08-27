# Protocole de version stable

## Référence gelée

- Version applicative : `1.0.0+10`
- Commit applicatif validé : `50d6e59`
- Plateformes : iPad TestFlight et web Mac
- API : `https://api.aidhabitat.fr`
- Web : `https://app.aidhabitat.fr`

Cette référence est la base stable. Toute modification de l'authentification, de la synchronisation, du stockage local, des documents ou des notes doit être isolée, testée et validée avant diffusion.

## Règles obligatoires

1. Ne jamais modifier simultanément l'authentification et la synchronisation.
2. Ne jamais déployer une modification critique sans tests automatisés réussis.
3. Déployer l'API et le web depuis le même commit applicatif.
4. Ne jamais utiliser Vercel pour cette application. La production web passe uniquement par EasyPanel.
5. Ne jamais supprimer ou abandonner une opération locale tant que sa récupération n'est pas confirmée.
6. Ne jamais diffuser un build TestFlight avant validation complète du dossier témoin.
7. Conserver un moyen de retour vers la dernière version stable.

## Dossier témoin

Le dossier témoin doit contenir au minimum :

- des informations bénéficiaire et logement ;
- deux occupants avec autonomie et contexte de vie ;
- une note écrite et deux pages de note dessin ;
- des données d'accessibilité, salle de bain et WC ;
- une photo, une préconisation et un document ;
- un rapport PDF généré.

Le dossier témoin ne doit contenir aucune donnée réelle de bénéficiaire.

## Validation avant diffusion

### 1. Contrôles automatiques

- `npm run test:sync-contract`
- `npm run check:critical`
- `bash aid_habitat_app/tool/test_sync_critical.sh`
- API `live` et `ready`
- web disponible sans erreur de chargement

### 2. Test iPad hors ligne

1. Ouvrir le dossier témoin en ligne et attendre la fin du chargement.
2. Passer l'iPad en mode avion.
3. Modifier plusieurs champs, les notes, un dessin et une préconisation.
4. Ajouter un document et une photo.
5. Fermer puis rouvrir l'application hors ligne.
6. Vérifier que toutes les données locales sont encore présentes.
7. Demander la génération du PDF hors ligne.

### 3. Retour en ligne

1. Réactiver la connexion sans forcer la synchronisation.
2. Vérifier que l'utilisateur n'est pas déconnecté.
3. Attendre la fin naturelle des opérations en attente.
4. Vérifier l'absence d'opération en échec ou encore en attente.
5. Vérifier que le PDF demandé hors ligne est généré.

### 4. Contrôle croisé Mac

1. Ouvrir le même dossier dans la web app.
2. Comparer les champs, notes, dessins, photos, préconisations et documents.
3. Vérifier que les statuts de visite sont identiques.
4. Vérifier qu'aucune donnée n'a été dupliquée ou remplacée par une ancienne valeur.

### 5. Authentification

Tester séparément les comptes Coralie, Christelle et Renan sur la version candidate. Les mots de passe ne doivent jamais être inscrits dans ce document, les journaux ou le dépôt Git.

## Critères d'acceptation

La diffusion est autorisée uniquement si :

- tous les contrôles automatiques réussissent ;
- les trois comptes peuvent se connecter ;
- aucune opération de synchronisation n'est en échec ou en attente ;
- les données iPad et Mac sont identiques ;
- tous les documents sont visibles sur les deux plateformes ;
- la génération PDF aboutit après un cycle hors ligne ;
- aucun doublon ni retour à une ancienne valeur n'est constaté.

En cas d'échec, la version n'est pas diffusée. Les données locales sont conservées et la dernière version stable reste la référence.

## Registre de validation

Pour chaque future version, enregistrer : version, commit, date, testeur, dossier témoin, résultats iPad/Mac, état API, résultat PDF et décision de diffusion.
