# Rotation du mot de passe bootstrap local

Objectif : retirer le mot de passe bootstrap du code sans casser le login local
offline existant.

## Pourquoi ne pas le changer brutalement

Le login App'Ergo fonctionne en local. Les utilisateurs doivent pouvoir ouvrir
l'application sans réseau.

Le mot de passe bootstrap sert aux installations ou profils locaux initialisés
avant synchronisation complète. Le remplacer sans préparation peut bloquer une
nouvelle installation ou empêcher l'audit de reconnaître un compte encore sur le
mot de passe initial.

## Stratégie recommandée

1. Garder le comportement actuel tant que l'app est utilisée en production.
2. Ajouter un secret de build `AIDHABITAT_BOOTSTRAP_PASSWORD` dans GitHub Actions,
   Easypanel et les builds natifs.
3. Générer une version staging qui lit ce secret avec `--dart-define`.
4. Tester le login offline sur un poste neuf et sur un poste déjà synchronisé.
5. Une fois validé, supprimer la valeur codée en dur.
6. Forcer ou accompagner le changement du mot de passe initial côté équipe.

## Tests obligatoires

- ouverture de l'app sans réseau ;
- login d'un utilisateur déjà existant ;
- première initialisation locale ;
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

Le preflight accepte ce point comme avertissement, pas comme échec bloquant.

C'est volontaire : la sécurité doit progresser, mais pas au prix d'un blocage du
login local/offline.
