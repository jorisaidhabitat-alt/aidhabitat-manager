# Sources visuelles des templates

Ce dossier contient les **fichiers d'origine** utilisés pour générer les
PDF templates qu'exploite le serveur. Ne PAS les charger côté serveur ;
ce sont les fichiers de travail pour modifier le rendu visuel.

## Rapport_2025.afpub

Fichier source **Serif Affinity Publisher 2** du rapport de visite
ergothérapeute (« Diagnostic Autonomie de l'Habitat »).

- 19 pages A4 portrait
- 129 champs AcroForm nommés (TextField / Btn / Choice)
- Auteur : Marika Pommier — Aid'Habitat
- Dernière modification source : juillet 2024

### Comment modifier le template visuellement

1. Ouvrir `Rapport_2025.afpub` dans **Affinity Publisher 2**
   (achat unique sur affinity.serif.com — le projet n'a pas besoin
   d'un abonnement).
2. Modifier le contenu graphique (titres, couleurs, logos…).
3. Si on ajoute une **nouvelle variable**, déposer un champ
   `Form Field` (TextField, Checkbox ou Choice) et lui donner un
   **nom unique** (sans accents si possible) — ce nom devient la clé
   utilisée dans `server/templates/visitReport.mapping.json`.
4. Exporter en PDF :
   - **File → Export → PDF**
   - Onglet *Compatibility* : « PDF (for export) » + version 1.7
   - Onglet *Other* : cocher **« Allow advanced features (forms…) »**
5. Remplacer `server/templates/visitReport.template.pdf` par le
   nouveau PDF, puis mettre à jour `visitReport.mapping.json`
   avec les nouveaux champs.

### Pourquoi garder cette source ici

- **Filet de sécurité visuel** : si le `.pdf` est corrompu ou si
  on doit changer de Mac, on peut tout regénérer depuis l'.afpub.
- **Évolutivité** : ajouter un nouveau champ se fait en 30
  secondes côté Affinity au lieu de bidouiller le PDF avec des
  outils tiers.
- **Source de vérité** pour le design — toute modification visuelle
  passe par ce fichier, jamais par édition directe du PDF.
