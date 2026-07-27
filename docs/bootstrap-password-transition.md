# Rotation du mot de passe bootstrap local

Objectif : garder le login offline après une première connexion valide, sans
conserver de mot de passe bootstrap visible dans le code.

## Pourquoi ne pas le changer brutalement

Le login App'Ergo fonctionne en local. Les utilisateurs doivent pouvoir ouvrir
l'application sans réseau.

Le mot de passe bootstrap sert aux installations ou profils locaux initialisés
avant synchronisation complète. Le remplacer sans préparation peut bloquer une
nouvelle installation ou empêcher l'audit de reconnaître un compte encore sur le
mot de passe initial.

## Stratégie recommandée

1. Ne pas embarquer de mot de passe bootstrap par défaut.
2. Pour chaque iPad neuf : faire une première connexion en ligne avec le vrai
   mot de passe serveur du membre.
3. L'app stocke ensuite le hash local dans la base SQLite chiffrée, ce qui
   permet le login offline sur cet appareil.
4. Si un bootstrap temporaire est absolument nécessaire pour une campagne
   d'installation, l'injecter uniquement au build via
   `AIDHABITAT_BOOTSTRAP_PASSWORD`, puis le retirer dès la campagne terminée.
5. Changer les mots de passe serveur via l'admin d'accès et vérifier que la
   reconnexion online met à jour le hash local de l'iPad.

## Tests obligatoires

- ouverture de l'app sans réseau ;
- login d'un utilisateur déjà existant ;
- première initialisation locale avec réseau ;
- changement de mot de passe local ;
- synchronisation NocoDB après reconnexion ;
- build web GitHub Actions ;
- build Easypanel ;
- build natif macOS/iPad à terme.

## Commandes utiles

Audit non destructif :

```bash
npm run secrets:audit -- tmp/env-secrets-audit.md
```

Preflight global :

```bash
npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```

## Statut actuel

Le mot de passe bootstrap n'est plus codé en dur dans l'application. Sans
`AIDHABITAT_BOOTSTRAP_PASSWORD`, un profil local fraîchement installé ne peut
pas s'authentifier offline avant une première connexion serveur réussie.
