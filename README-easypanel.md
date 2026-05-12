# Migration Vercel → Easypanel

Guide étape par étape pour déployer `aid'habitat-manager` sur Easypanel
(le même serveur qui héberge déjà NocoDB).

## Pourquoi migrer

- **Économie quota** : Vercel free tier (10 GB/mois) saturé en 4 jours
  d'usage intensif. Easypanel = bande passante illimitée (selon ton VPS).
- **Perf** : co-localisation avec NocoDB → latence requête ~30-80 ms
  (vs 200-500 ms via Vercel). Génération PDF passe potentiellement de
  60 s à 10 s.
- **Pas de cold start** : container toujours up.
- **Filesystem persistant** : plus besoin de tout encoder en base64
  côté NocoDB pour survivre à un redéploiement.

## Pré-requis

- Accès SSH à ton VPS Easypanel
- NocoDB déjà déployé sur Easypanel et accessible
- Domaines DNS configurables (idéalement 2 sous-domaines :
  `api.aidhabitat.fr` + `app.aidhabitat.fr`)
- Flutter SDK installé en local (déjà le cas) pour compiler le web
- Docker installé en local pour build/tester les images (optionnel —
  Easypanel peut builder à partir du Git directement)

## Architecture cible

```
Internet → Easypanel VPS
              ├─ Container "aidhabitat-web"  (nginx, sert le bundle Flutter web)
              │     domaine : https://app.aidhabitat.fr
              ├─ Container "aidhabitat-api"  (Node 20 + Express)
              │     domaine : https://api.aidhabitat.fr
              │     volume  : /data → persistence (auth-store, chunks)
              └─ Container "nocodb"          (déjà en place)
                    interne : http://nocodb:8080
```

L'API parle à NocoDB via le réseau Docker interne d'Easypanel
(latence ~1 ms). Le frontend parle à l'API via Internet (HTTPS public).

---

## Étape 1 — Build le bundle Flutter web (local)

```bash
cd "/Users/aidhabitat/Downloads/aid'habitat-manager/aid_habitat_app"

# Compile en pointant vers l'API Easypanel (sous-domaine futur).
# Si tu testes d'abord en staging, remplace par api-staging.aidhabitat.fr.
AIDHABITAT_API_BASE_URL=https://api.aidhabitat.fr ./tool/build_web.sh
```

Le bundle se retrouve dans `aid_habitat_app/build/web/`. Vérifie sa
taille — ~5-8 MB attendu.

## Étape 2 — Build les images Docker (local, pour tester)

```bash
cd "/Users/aidhabitat/Downloads/aid'habitat-manager"

# Image backend
docker build -f Dockerfile.api -t aidhabitat-api:latest .

# Image frontend (depuis le dossier aid_habitat_app)
cd aid_habitat_app
docker build -f Dockerfile.web -t aidhabitat-web:latest .
```

Test local optionnel :
```bash
docker run --rm -p 8080:80 aidhabitat-web:latest
# → ouvre http://localhost:8080 dans Safari/Chrome
```

## Étape 3 — Configuration Easypanel

### 3a. Service "aidhabitat-api"

Dans Easypanel UI :
1. **Create Service** → **App** → nom : `aidhabitat-api`
2. **Source** : 2 options
   - **Build from Git** : pointe vers ton repo GitHub, Dockerfile path :
     `Dockerfile.api`. Easypanel build à chaque push.
   - **Docker image** : push manuellement l'image vers un registry
     (Docker Hub privé, ou registry Easypanel intégré si disponible).
3. **Port** : `3001`
4. **Domains** : ajoute `api.aidhabitat.fr` (HTTPS auto via Let's Encrypt)
5. **Volumes** : monte un volume nommé `aidhabitat-data` sur `/data`
6. **Environment Variables** (CRITIQUES — à copier exactement
   depuis ton `.env.local` ou tes vars Vercel actuelles) :

   | Variable | Valeur exemple | Notes |
   |---|---|---|
   | `NODE_ENV` | `production` | |
   | `API_PORT` | `3001` | (déjà dans Dockerfile) |
   | `AIDHABITAT_DATA_DIR_PATH` | `/data` | (déjà dans Dockerfile) |
   | `NOCODB_API_URL` | `http://nocodb:8080/` | URL **interne** Docker (1ms) au lieu de l'URL publique |
   | `NOCODB_API_TOKEN` | `eyJhbGc...` | depuis NocoDB UI → Settings → API Tokens |
   | `NOCODB_BASE_ID` | `pskgbjythubfzv9` | depuis `.env.local` |
   | `NOCODB_FORCE_REST` | `1` | (force le mode REST, pas MCP) |
   | `MOBILE_SYNC_REQUIRE_NOCODB` | `1` | (refus du fallback FS sur ce path) |
   | `AUTH_SESSION_SECRET` | (long secret aléatoire) | copie depuis Vercel ou regénère |
   | `JWT_SECRET` | (long secret aléatoire) | idem |
   | `APP_PUBLIC_BASE_URL` | `https://api.aidhabitat.fr` | URL publique de l'API |
   | `CORS_EXTRA_ORIGIN` | `https://app.aidhabitat.fr` | Origine front autorisée |

   Pour copier depuis Vercel facilement :
   ```bash
   cd "/Users/aidhabitat/Downloads/aid'habitat-manager"
   vercel env pull /tmp/.env.vercel --environment=production
   # ouvre /tmp/.env.vercel et copie les valeurs critiques dans Easypanel UI
   ```

7. **Resources** : 512 MB RAM minimum (1 GB recommandé pour la
   génération PDF qui peut consommer de la mémoire en pic). 0.5 CPU.

8. **Deploy** : Easypanel pull/build/run. Vérifie les logs.

### 3b. Service "aidhabitat-web"

1. **Create Service** → **App** → nom : `aidhabitat-web`
2. **Source** : 2 options selon le workflow :
   - **(recommandé) Pull depuis GitHub Container Registry** :
     - Source type : `Docker image`
     - Image : `ghcr.io/jorisaidhabitat-alt/aidhabitat-web:latest`
     - Authentification au registry : si ton repo GitHub est privé, crée
       un Personal Access Token avec scope `read:packages` et configure-le
       comme credentials Docker registry dans Easypanel UI
     - Le workflow GitHub Actions (cf. § 4) build et push l'image à chaque
       push sur main → tu n'as rien à faire manuellement
   - **(alternative) Build from Git** : Easypanel clone ton repo et build.
     ⚠️ nécessite que Easypanel ait Flutter SDK dans son environment de
     build (peu probable par défaut → préférer l'option ghcr.io ci-dessus)
3. **Port** : `80`
4. **Domains** : ajoute `app.aidhabitat.fr`
5. Pas de volume nécessaire (frontend 100 % statique)
6. Pas de variables d'env
7. **Resources** : 128 MB RAM, 0.1 CPU (nginx est ultra-léger)
8. **Deploy webhook** : dans Settings → Deploy, **copie l'URL du webhook**
   et garde-la pour la configurer côté GitHub (§ 4).

## Étape 3c — GitHub Actions (CI/CD automatique)

Deux workflows sont préparés dans `.github/workflows/` :

| Workflow | Trigger | Que fait |
|---|---|---|
| `build-deploy-web.yml` | push sur main qui touche `aid_habitat_app/**` | Build Flutter web + push image Docker `aidhabitat-web` sur ghcr.io + trigger redéploiement Easypanel |
| `build-deploy-api.yml` | push sur main qui touche `server/**` ou `shared/**` | Build image Docker `aidhabitat-api` sur ghcr.io + trigger redéploiement Easypanel |

### Secrets GitHub à configurer

Va sur **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**.

| Secret | Valeur | Description |
|---|---|---|
| `AIDHABITAT_API_BASE_URL` | `https://api.aidhabitat.fr` | URL publique de l'API, injectée comme `--dart-define` au build Flutter |
| `EASYPANEL_WEB_WEBHOOK` | (URL fournie par Easypanel UI) | Webhook trigger redéploiement du service `aidhabitat-web` (Settings → Deploy → Webhook URL) |
| `EASYPANEL_API_WEBHOOK` | (URL fournie par Easypanel UI) | Webhook trigger redéploiement du service `aidhabitat-api` (idem côté service api) |

Si tu omets les 2 webhooks Easypanel, le build/push réussit quand même —
tu devras juste cliquer "Deploy" manuellement dans Easypanel UI pour pull
la dernière image. Avec les webhooks, c'est full auto.

### Visibilité du package ghcr.io

Par défaut les packages ghcr.io sont **privés** (héritent de la visibilité
du repo). Si ton repo est privé, Easypanel doit avoir des credentials pour
pull. 2 options :

1. **Rendre le package public** (le code reste privé, juste l'image binaire
   est publique — pas de secrets dedans, juste le bundle Flutter compilé) :
   GitHub → Profile → Packages → `aidhabitat-web` → Settings → Change
   visibility → Public.
2. **Garder privé** + configurer Easypanel avec un Personal Access Token :
   Generate un PAT avec scope `read:packages`, ajouter dans Easypanel UI
   → Settings → Registries → `ghcr.io` username `<ton-username>` password
   `<PAT>`.

L'option 1 est plus simple ; l'option 2 plus sécurisée.

### Vérifier que tout marche

1. Configure les 3 secrets ci-dessus dans GitHub
2. Push un commit sur main qui touche `aid_habitat_app/` (ex. modifie un
   commentaire) → vérifie sur GitHub → Actions que le workflow tourne
3. Une fois fini (~5-7 min), check sur Easypanel que le service a redéployé
4. Ouvre `https://app.aidhabitat.fr` → ta modif devrait être visible

### Trigger manuel (sans push)

Si tu veux re-déployer sans commit : GitHub → Actions → choisis le workflow
→ bouton **Run workflow** sur la branche main.

---

## Étape 4 — DNS

Sur ton registrar DNS (Gandi, OVH, Cloudflare…) :

```
api.aidhabitat.fr   A      <IP de ton VPS Easypanel>
app.aidhabitat.fr   A      <IP de ton VPS Easypanel>
```

Ou si Easypanel donne déjà un domaine type `xxx.easypanel.host`, tu peux
faire un CNAME :

```
api.aidhabitat.fr   CNAME  aidhabitat-api.z5avx1.easypanel.host
app.aidhabitat.fr   CNAME  aidhabitat-web.z5avx1.easypanel.host
```

TTL recommandé : 300 s (5 min) pendant la migration pour pouvoir revert
vite si problème, puis 3600 s (1 h) une fois stabilisé.

## Étape 5 — Validation staging

Avant de basculer la prod, teste en staging :
1. Ouvre `https://app.aidhabitat.fr` sur Safari Mac
2. Login avec ton compte
3. Ouvre un dossier (par ex. Pommier Marie)
4. Génère un PDF — chronomètre, devrait être 3-5× plus rapide
5. Modifie une note, vérifie qu'elle est sync sur l'autre device
6. Importe une photo dans Documents

Si tout passe → bascule prod.

## Étape 6 — Bascule prod

1. Si tu veux du zero-downtime :
   - Garde les déploiements Vercel ACTIFS
   - Ajoute des CNAMEs `app.aidhabitat.fr` et `api.aidhabitat.fr` sur
     Easypanel
   - Modifie le DNS principal pour pointer vers Easypanel
   - Le DNS prend 5-60 min à se propager — pendant ce temps les utilisateurs
     finissent sur l'un ou l'autre selon leur cache DNS local
2. Si tu acceptes 5 min de downtime contrôlé :
   - Pause les projets Vercel via Dashboard
   - Bascule DNS vers Easypanel
   - Vérifie en navigation privée que l'app charge

## Étape 7 — Décommission Vercel (J+7)

Après 7 jours sans incident :
1. Vercel Dashboard → projet `aid-habitat-manager` → Settings → Delete
2. Vercel Dashboard → projet `aid-habitat-app` → Settings → Delete
3. Dans le code, supprime :
   - `vercel.json` (racine)
   - `aid_habitat_app/vercel.json`
   - `aid_habitat_app/vercel-build.sh`
   - `api/index.mjs`
   - `.vercel/` (racine + aid_habitat_app)
4. Dans `package.json`, retire `@vercel/blob` s'il est encore présent

## Plan de rollback

Si problème grave sur Easypanel pendant la migration :
1. **DNS revert** : remettre les sous-domaines `app/api` sur Vercel
   (5-60 min de propagation)
2. **Données runtime** : si tu as modifié des dossiers pendant que
   Easypanel était actif et que tu reverts, certaines modifs peuvent
   ne pas être propagées. NocoDB est commun aux deux donc la majorité
   des données est intacte. Seul l'`auth-store.json` (sessions
   utilisateurs) est divergent — recommande à tes ergos de se
   re-logger.

## Variables d'env récap (checklist)

À avoir dans Easypanel pour `aidhabitat-api` :

- [ ] `NOCODB_API_URL`
- [ ] `NOCODB_API_TOKEN`
- [ ] `NOCODB_BASE_ID`
- [ ] `NOCODB_FORCE_REST=1`
- [ ] `NOCODB_MCP_URL` (si tu utilises encore le MCP — sinon vide)
- [ ] `NOCODB_MCP_TOKEN` (idem)
- [ ] `MOBILE_SYNC_REQUIRE_NOCODB=1`
- [ ] `AUTH_SESSION_SECRET`
- [ ] `JWT_SECRET`
- [ ] `APP_PUBLIC_BASE_URL=https://api.aidhabitat.fr`
- [ ] `CORS_EXTRA_ORIGIN=https://app.aidhabitat.fr`
- [ ] `AIDHABITAT_DATA_DIR_PATH=/data` (déjà dans Dockerfile mais
  surchargeable)

## Vérifications post-déploiement

```bash
# Backend répond
curl -s https://api.aidhabitat.fr/api/dossiers -H "X-App-Session: invalid"
# → attendu : {"success":false,"error":"Session invalide ou expirée"}

# Frontend répond
curl -sI https://app.aidhabitat.fr/
# → attendu : HTTP/2 200, content-type: text/html

# Latence API → NocoDB (depuis le container API)
# (à exécuter via "Exec" dans Easypanel UI)
time wget -q -O - http://nocodb:8080/api/v2/health
# → devrait être < 50 ms
```

## Coûts

- VPS Easypanel : déjà payé (NocoDB tourne dessus)
- Bande passante : illimitée selon la config du VPS
- Le seul coût supplémentaire pourrait être un upgrade VPS si la RAM est
  juste — surveille pendant la 1ère semaine.

## Questions / problèmes

Si quelque chose coince pendant la migration, retiens :
- Les **logs runtime** Easypanel sont accessibles dans l'UI service
  → onglet "Logs" — pas de limitation contrairement à Vercel
- Tu peux **exec dans le container** depuis Easypanel UI pour debugger
- Le code reste **100 % compatible Vercel** pendant toute la migration —
  tu peux toujours faire `vercel --prod` depuis le dossier qui était
  configuré pour ça (juste l'image Docker ne se déploie pas sur Vercel)
