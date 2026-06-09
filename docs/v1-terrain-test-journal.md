# Journal tests terrain v1 PWA

Version cible : PWA `https://app.aidhabitat.fr/`
Commit release : `6ff363a`
Statut initial : GO terrain controle

## Objectif

Tracer les essais reels iPad/Mac sans relancer de gros chantier de dev.

Chaque anomalie doit etre qualifiee avant correction :

- `bloquant` : empeche une visite ou fait perdre des donnees.
- `majeur` : gene fortement, mais contournement possible.
- `mineur` : inconfort, affichage, lenteur ponctuelle.
- `idee` : amelioration non urgente.

## Regle de stabilisation

- Pas de gros commit global.
- Pas de refonte pendant les tests terrain.
- Corriger uniquement les bugs bloquants ou majeurs verifies.
- Garder les ameliorations mineures pour une v1.1.

## Checklist par session

Copier ce bloc pour chaque test terrain.

```md
### Session YYYY-MM-DD HH:mm

Testeur :
Appareil :
Navigateur/PWA :
Connexion :
Dossier teste :

Actions :
- [ ] Ouvrir l'app
- [ ] Se connecter
- [ ] Ouvrir un dossier
- [ ] Consulter/modifier une information simple
- [ ] Ajouter/verifier une photo
- [ ] Generer un PDF
- [ ] Verifier le PDF dans Documents
- [ ] Ouvrir le PDF
- [ ] Couper le reseau 30 secondes
- [ ] Naviguer offline
- [ ] Remettre le reseau
- [ ] Verifier reprise sync

Resultat global :

Anomalies :
- Severite :
  Ecran :
  Etapes pour reproduire :
  Resultat obtenu :
  Resultat attendu :
  Capture/log :

Decision :
- [ ] OK terrain
- [ ] OK avec reserve
- [ ] A corriger avant prochaine visite
```

## Sessions

### Session 2026-06-08

Testeur : Joris
Appareil : iPad
Navigateur/PWA : app.aidhabitat.fr
Connexion : fluide
Dossier teste : BALLUAIS Joris

Actions :
- [x] Ouvrir l'app
- [x] Generer un PDF
- [x] Verifier le PDF dans Documents

Resultat global :

Tout semble fonctionner parfaitement bien.

Anomalies :

Aucune anomalie signalee.

Decision :
- [x] OK terrain
- [ ] OK avec reserve
- [ ] A corriger avant prochaine visite
