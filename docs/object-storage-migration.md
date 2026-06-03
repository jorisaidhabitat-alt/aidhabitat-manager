# Migration progressive des fichiers vers stockage objet

Objectif : sortir les PDF/images/scans de NocoDB à moyen terme, sans casser
App'Ergo et sans perdre la compatibilité offline actuelle.

## Pourquoi

Aujourd'hui les documents sont stockés dans `mobile_document_chunks`. Cette
solution fonctionne pour l'usage interne actuel, mais elle fait grossir NocoDB
avec des données binaires encodées en base64.

Pour une commercialisation, NocoDB doit rester la base métier. Les fichiers
lourds doivent aller dans un stockage objet compatible S3.

## Principe sans risque

Ne pas remplacer brutalement le stockage actuel.

Ordre recommandé :

1. Garder `mobile_document_chunks` comme source existante.
2. Ajouter des métadonnées objet dans `mobile_documents`.
3. Copier les fichiers vers S3 en tâche de fond.
4. Lire d'abord depuis S3 si `object_key` existe.
5. Garder un fallback vers les chunks NocoDB.
6. Supprimer les chunks uniquement après plusieurs sauvegardes vérifiées.

## Colonnes à ajouter dans `mobile_documents`

- `storage_provider`
- `object_key`
- `object_size_bytes`
- `object_sha256`
- `object_synced_at`
- `legacy_nocodb_chunks_kept`

Ces colonnes permettent une migration progressive. Tant qu'elles sont vides,
l'app continue à fonctionner comme aujourd'hui.

## Audit du volume

Utiliser un backup vérifié :

```bash
npm run storage:readiness -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz
```

Le script ne contacte pas NocoDB. Il indique :

- nombre de fichiers à migrer ;
- volume binaire estimé ;
- nombre de chunks ;
- uploads temporaires ;
- chunks sans métadonnées ;
- plus gros fichiers.

## Invariants à préserver

- Une création de document doit rester instantanée côté app.
- Le fichier doit être sauvegardé localement avant synchronisation réseau.
- Une perte réseau ne doit pas empêcher la consultation des fichiers déjà en cache.
- NocoDB conserve les métadonnées métier.
- Le stockage objet conserve uniquement les fichiers lourds.
- En cas d'échec S3, l'app doit pouvoir relire l'ancien stockage NocoDB.

## Choix fournisseur

Critères importants :

- compatible S3 ;
- région UE si possible ;
- chiffrement au repos ;
- lifecycle/rétention ;
- coût faible sur stockage durable ;
- accès API stable ;
- possibilité de clés séparées production/staging.

Options cohérentes :

- Hetzner Object Storage si disponible sur votre offre ;
- Backblaze B2 ;
- Scaleway Object Storage ;
- AWS S3 si besoin d'un standard très établi.

## Ce qu'il ne faut pas faire

- Ne pas migrer les fichiers directement en production sans staging.
- Ne pas supprimer les chunks NocoDB au premier upload S3 réussi.
- Ne pas stocker les clés S3 côté frontend.
- Ne pas mélanger documents production et staging dans le même bucket sans préfixes stricts.
- Ne pas considérer la migration terminée sans test PDF/images/preview.

## Critère de réussite

La migration est prête seulement quand :

- l'audit storage est propre ;
- une base staging lit les fichiers via S3 ;
- le fallback NocoDB fonctionne ;
- la génération PDF retrouve les images ;
- un backup NocoDB reste vérifié ;
- un backup du bucket objet est défini ;
- les flux critiques de l'app passent.
