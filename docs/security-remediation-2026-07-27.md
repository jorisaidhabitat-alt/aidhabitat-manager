# Durcissement sécurité du 27 juillet 2026

## Périmètre traité

- Les mots de passe des membres ne sont plus conservés en clair dans NocoDB.
  Le serveur les migre vers une enveloppe `scrypt` au premier chargement après
  déploiement, sans changer le mot de passe connu de l'utilisateur.
- Les mots de passe de secours locaux passent de SHA-256 à
  PBKDF2-HMAC-SHA256. Les anciens appareils restent compatibles et mettent leur
  hash à niveau après une connexion serveur réussie.
- Les signatures de session sont comparées en temps constant.
- Les jetons de session dans les paramètres d'URL des médias sont refusés.
- L'API ne révèle plus si une adresse existe lors d'un échec de connexion.
- La limitation des connexions couvre le couple IP/compte et l'adresse IP.
- Les origines Vercel historiques ne sont plus autorisées par CORS.
- Les en-têtes HSTS, `nosniff`, Referrer-Policy, X-Frame-Options et
  Permissions-Policy sont ajoutés à l'API et au frontal.
- L'en-tête Express `X-Powered-By` est supprimé.
- Les dépendances Node auditées ne présentent plus de vulnérabilité connue.

## Ordre de mise en production

1. Vérifier qu'un export récent de NocoDB et des documents existe.
2. Rendre le dépôt GitHub privé si ce n'est pas déjà fait.
3. Révoquer le jeton MCP NocoDB présent dans l'ancien historique Git et en
   créer un nouveau.
4. Remplacer `NOCODB_MCP_TOKEN` dans EasyPanel s'il est configuré, puis dans le
   fichier local `.env.local`. Ne jamais publier ce fichier.
5. Vérifier dans EasyPanel que `NOCODB_API_TOKEN` est un jeton distinct et que
   `AUTH_SESSION_SECRET` contient au moins 32 caractères aléatoires.
6. Vérifier `APP_PUBLIC_BASE_URL=https://app.aidhabitat.fr` et retirer toute
   origine Vercel de `CORS_EXTRA_ORIGIN`.
7. Déployer l'API et le frontal issus du même commit.
8. Tester immédiatement les trois connexions, les périmètres utilisateurs et
   une lecture/écriture de dossier.
9. Vérifier dans NocoDB que `mot_de_passe` commence par `scrypt$v1$` pour les
   membres actifs. Ne jamais modifier manuellement cette valeur.

La migration NocoDB est effectuée par la nouvelle API. Une restauration de
l'ancienne API après cette migration casserait la connexion. En cas de retour
arrière, il faut aussi restaurer la colonne des mots de passe depuis le backup
ou réinitialiser les accès avec la nouvelle API.

## Contrôles à réaliser après déploiement

- Une requête sans session vers `/api/dossiers` retourne `401`.
- Coralie et Christelle ne voient que leurs dossiers ; Renan voit l'ensemble.
- Une tentative d'accès croisé à un document retourne `403`.
- Une origine web non autorisée ne reçoit pas
  `Access-Control-Allow-Origin`.
- Les réponses de `app.aidhabitat.fr` et de l'API incluent les en-têtes de
  sécurité prévus.
- Les mots de passe restent inchangés du point de vue des utilisateurs, mais
  une reconnexion peut être demandée après la migration.

## Risques restant à traiter

- Purger le secret de l'historique Git exige une réécriture coordonnée de
  l'historique et un nouveau clone pour chaque intervenant. La révocation du
  jeton doit être faite avant cette opération.
- Une Content-Security-Policy stricte nécessite une validation spécifique du
  build Flutter, de PDF.js et de la WebView ANAH.
- Ajouter un verrouillage applicatif après inactivité et, si retenu par
  l'équipe, un déverrouillage biométrique sur iPad/macOS.
- Vérifier les contrats de sous-traitance, la localisation des sauvegardes,
  l'habilitation des administrateurs et l'adéquation HDS avec le prestataire
  d'hébergement pour les données de santé.
- Finaliser le registre de traitements, les durées de conservation, la
  procédure d'exercice des droits et la procédure de notification d'incident.

Ce durcissement réduit les risques techniques identifiés, mais ne constitue
pas à lui seul une certification de conformité RGPD ou HDS.
