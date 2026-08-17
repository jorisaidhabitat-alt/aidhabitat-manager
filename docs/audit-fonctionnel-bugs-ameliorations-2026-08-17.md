# Audit fonctionnel, bugs et améliorations

Date : 17 août 2026  
Version auditée : `1.0.0+6`  
Cibles actuelles : iPad natif via TestFlight et application web sur ordinateur  
Cible secondaire vérifiée : écran de connexion sur téléphone

## Lecture des statuts

- **Terminé** : fonction présente et couverte par un contrôle automatisé ou un contrôle réel de production.
- **En cours** : code présent localement et contrôles verts, mais pas encore consolidé, livré et validé en situation réelle.
- **Restant** : fonction absente, incomplète ou validation indispensable non réalisée.
- **Hors périmètre** : plateforme non ciblée par la version terrain actuelle.

## Synthèse

| Indicateur | Résultat |
| --- | --- |
| Bug métier bloquant reproduit | 0 |
| Blocages techniques corrigés localement | 2 |
| Tests Flutter | 123 réussis |
| Tests de contrat de synchronisation | 10 réussis |
| Parcours critiques statiques | 17 réussis |
| Tests Node ciblés après correction | 13 réussis |
| Vulnérabilités npm connues | 0 après mise à jour locale |
| Secrets suivis détectés | 0 après clarification des faux positifs |
| Contrôles de cohérence production | 40 réussis |
| Build web Flutter | Réussi |
| État production au moment de l'audit | Application, API, CORS, CSP et NocoDB opérationnels |

Conclusion : aucun blocage métier n'est reproduit par les contrôles exécutés. La reprise de synchronisation après une longue période hors ligne est renforcée et testée localement, mais reste **en cours** tant que les changements locaux n'ont pas été relus, livrés et validés sur iPad avec un vrai aller-retour hors ligne. Deux limites de restitution restent prioritaires : les annotations PDF par page sont locales uniquement et un rapport ne restitue pas plus de huit préconisations.

## Tableau fonctionnel

| Priorité | Domaine | Fonctionnalité | Statut | Vérification réalisée | Reste à faire |
| --- | --- | --- | --- | --- | --- |
| P0 | Connexion | Connexion locale après une première authentification serveur | Terminé | Tests Flutter d'authentification et de persistance réussis | Refaire un test terrain par profil après la prochaine livraison |
| P0 | Connexion | Ne pas déconnecter l'utilisateur lors d'une panne réseau, TLS, API ou NocoDB | En cours | Tests de session distante et erreurs transitoires réussis localement | Livrer puis simuler une panne API sur iPad sans quitter le dossier |
| P0 | Connexion | Renouvellement silencieux de la session distante | En cours | Refresh token, stockage sécurisé et tests de reprise présents localement | Valider expiration réelle du jeton sur une session terrain |
| P0 | Synchronisation | Sauvegarde locale immédiate des formulaires et notes | Terminé | Tests de persistance hors ligne et redémarrage réussis | Conserver le test terrain d'une journée dans la checklist de release |
| P0 | Synchronisation | Push local avant pull distant pour éviter l'écrasement des saisies | En cours | Contrat et tests automatisés réussis localement | Livrer et comparer iPad, NocoDB et web après une journée hors ligne |
| P0 | Synchronisation | Regroupement des petites écritures en lots API | En cours | Endpoint `/api/sync/batch`, tests partiels et contrats réussis | Déployer API et app depuis le même commit, puis surveiller les appels au retour en ligne |
| P0 | Synchronisation | Conservation des opérations après erreurs transitoires | En cours | Tests de file locale et reprise automatique réussis | Confirmer qu'aucun bandeau rouge n'apparaît pour une simple indisponibilité réseau |
| P0 | Données | Bénéficiaires, dossiers, logements, contexte, autonomie, mesures et sanitaires | Terminé | Contrats de champs, 40 contrôles NocoDB et 123 tests Flutter réussis | Refaire un échantillon manuel Coralie, Christelle et Renan après livraison |
| P0 | Données | Protection des modifications `pendingSync` contre un pull plus ancien | Terminé | Tests de fusion et de persistance réussis | Ajouter à terme un scénario E2E automatisé multi-appareils |
| P0 | Rapports | Génération PDF différée tant que les données ne sont pas distantes | Terminé | Parcours critique contrôlé et service de génération différée présent | Revalider sur un dossier modifié hors ligne avec plusieurs notes et photos |
| P1 | Documents | Import, photo, scan natif et aperçu des documents | Terminé | Build, tests, configuration iOS et scanner natif contrôlés | Faire un essai matériel après chaque changement de plugin iOS |
| P1 | Documents | Annotation d'une page PDF sans dupliquer le dessin sur les autres pages | Terminé localement | Stockage par numéro de page et tests de comportement présents | Voir la ligne suivante pour la synchronisation multi-appareils |
| P1 | Documents | Synchronisation serveur des annotations PDF par page | Restant | Le dépôt indique explicitement `local-only` dans `document_repository.dart` | Ajouter une opération `update_annotations`, son endpoint, ses tests de conflit et sa persistance NocoDB |
| P1 | Rapports | Plus de huit préconisations dans le PDF | Restant | Le générateur incrémente `recoOverflow` puis ignore les éléments supplémentaires | Générer des pages supplémentaires ou bloquer explicitement l'ajout au huitième élément |
| P1 | Dessin | Notes dessin, gomme, pages, plans et Apple Pencil | Terminé | Tests Flutter, bridge Pencil et build iPad contrôlés | Test matériel rapide, double-tap et traits courts avant chaque build TestFlight |
| P1 | Notes | Notes écrites, pagination, dictée native iPad | Terminé | Tests Flutter et configuration native présents | Test matériel dictée française et sauvegarde après retour en ligne |
| P1 | Photos | Photos de visite, cache local et reprise d'upload | Terminé | Parcours critique et cache hors ligne présents | Tester un lot volumineux sur réseau faible |
| P1 | Visite | Onglets bénéficiaire, contexte, mesures, accessibilité, salle de bain, WC, plans, photos, résumé et préconisations | Terminé côté code | Build et tests de modèles/services réussis | Parcours manuel authentifié complet non rejoué pendant cet audit |
| P1 | Dossiers | Filtrage des dossiers selon l'ergothérapeute et accès global admin | Terminé côté code | Contrats d'authentification et contrôles d'accès présents | Revalider les trois profils après déploiement de l'authentification modifiée |
| P1 | Référentiels | Communes, EPCI, caisses principales et complémentaires | Terminé | Données distantes disponibles et cache hors ligne implémenté | Contrôle visuel authentifié des sélecteurs sur iPad |
| P1 | Bibliothèque | Wiki, filtres, images locales et préconisations | Terminé | Assets intégrés au build et cache hors ligne implémenté | Contrôle visuel authentifié des 54 images après chaque changement d'assets |
| P1 | ANAH | Portail intégré sur iPad et ouverture externe de secours | Terminé côté code | Configuration native et build valides | Revalider le certificat et le chargement réel du portail sur iPad |
| P1 | Distribution | Nouveau build iPad signé depuis ce Mac | Restant | Précontrôle iOS valide sauf certificat Apple Distribution absent du trousseau | Installer ou renouveler le certificat avant le prochain upload TestFlight |
| P1 | Sécurité | Vulnérabilités Node de sévérité haute | Corrigé localement | `npm audit` retourne zéro vulnérabilité | Consolider et livrer le nouveau verrou npm |
| P1 | Sécurité | Audit des secrets suivis par Git | Corrigé localement | Zéro secret détecté après correction des trois faux positifs | Révoquer et purger séparément tout ancien jeton réellement exposé dans l'historique Git |
| P2 | Web | Application, API, CSP, CORS et accès NocoDB | Terminé | Contrôles live et release réussis sur les URL de production | Conserver les checks dans la CI et après chaque déploiement EasyPanel |
| P2 | Web | Taille du bundle Vite historique | Restant | Build réussi, chunk principal d'environ 547 kB | Découper le bundle seulement si cette interface React reste utilisée |
| P2 | Stockage | Vérification de capacité et d'orphelins depuis un backup | Restant | Outil présent mais inutilisable sans fichier de sauvegarde | Fournir un export `.json` ou `.json.gz`, puis lancer `npm run storage:readiness` |
| P2 | Sécurité | Verrouillage après inactivité et biométrie | Restant | Non implémenté | Définir la durée de verrouillage et le comportement hors ligne avant développement |
| P2 | Conformité | Registre RGPD, conservation, sous-traitants et adéquation HDS | Restant | Hors du contrôle technique automatique | Validation juridique et organisationnelle dédiée |
| P2 | Documentation | Anciens documents d'architecture encore rédigés au futur | Restant | Plusieurs audits décrivent l'offline-first comme non réalisé | Archiver ou mettre à jour ces documents pour éviter les décisions basées sur un état obsolète |
| P3 | Téléphone | Utilisation métier complète sur petit écran | Hors périmètre | Écran de connexion vérifié à 390 x 844 uniquement | Définir si le téléphone devient une cible avant d'adapter toutes les vues |
| P3 | Android | Build Play Store | Hors périmètre | SDK présent, mais Java et signature release non prêts | Préparer Java 21, keystore et campagne UI Android uniquement si la cible est retenue |
| P3 | Dépendances | Mises à jour majeures Flutter | Restant | 71 versions plus récentes mais incompatibles sont signalées | Mettre à jour par lots avec tests de régression, pas pendant la stabilisation terrain |

## Parcours utilisateurs testés

| Parcours | Automatisé | Visuel ou production | Résultat | Réserve |
| --- | --- | --- | --- | --- |
| Ouverture de l'application web | Oui | Oui, production | Conforme | Aucune erreur initiale observée |
| Connexion | Oui | Oui sur ordinateur, iPad paysage et téléphone | Conforme | Connexion visuelle testée sans soumettre de mot de passe réel |
| Restauration de session et connexion hors ligne | Oui | Non rejouée manuellement | Conforme dans les tests | Validation terrain après livraison requise |
| Chargement des dossiers | Oui indirectement | API et NocoDB contrôlés | Conforme | Pas de session authentifiée utilisée pendant cet audit |
| Modification bénéficiaire et contexte de vie | Oui | Cohérence production contrôlée | Conforme | Test multi-appareils à refaire après livraison |
| Notes écrites et dessin | Oui | Non rejoué avec Apple Pencil | Conforme dans les tests | Validation matérielle iPad nécessaire |
| Ajout, suppression et réordonnancement des préconisations | Oui indirectement | Non rejoué manuellement | Conforme côté données | PDF limité à huit éléments |
| Photos, documents et scan | Oui indirectement | Configuration iOS contrôlée | Conforme côté code | Test scanner matériel non rejoué |
| Annotation PDF | Partiel | Non rejouée | Fonction locale conforme | Synchronisation distante absente |
| Génération PDF en ligne | Oui indirectement | API prête | Conforme côté service | Parcours authentifié non rejoué |
| Génération demandée hors ligne puis reprise | Oui | Non rejouée pendant cet audit | Conforme dans les tests | Test terrain prioritaire |
| Wiki et caisses de retraite | Oui indirectement | Assets présents dans le build | Conforme côté code | Contrôle visuel authentifié non rejoué |
| Portail ANAH | Build uniquement | Non rejoué pendant cet audit | À revalider | Dépend du site et de son certificat |
| Paramètres et gestion des accès | Oui indirectement | Non rejoué manuellement | Conforme côté code | Tester avec un compte admin dédié |

## Affichages par appareil

| Appareil | Taille vérifiée | Résultat | Niveau de support |
| --- | --- | --- | --- |
| Ordinateur web | 1440 x 900 | Connexion lisible, centrée et sans débordement | Cible supportée |
| iPad paysage | 1180 x 820 | Connexion lisible, centrée et sans débordement | Cible principale |
| Téléphone | 390 x 844 | Connexion lisible et sans débordement | Connexion seulement, vues métier non garanties |
| macOS natif | Précontrôle de projet seulement | Configuration présente, pas de campagne visuelle complète | Secondaire, le web reste recommandé |
| Android | Non vérifié visuellement | Build release non prêt | Hors périmètre actuel |

## Corrections appliquées pendant l'audit

1. Mise à jour compatible du verrou npm afin de supprimer les vulnérabilités connues de `fast-uri`, `hono`, `ip-address`, `nanoid`, `postcss` et `shell-quote`.
2. Renommage de trois variables de test ou temporaires afin que l'audit de secrets ne confonde plus des valeurs fictives avec de vrais identifiants.
3. Aucun changement métier ou aucune donnée NocoDB n'a été écrit pendant cet audit.

Ces corrections sont locales dans l'arbre de travail actuel. Elles ne doivent être considérées comme livrées qu'après revue du diff global, commit, push et déploiement coordonné.

## Ordre recommandé

1. Relire et consolider le lot local de synchronisation, d'authentification et de batching API.
2. Déployer API et Flutter Web depuis le même commit.
3. Exécuter les checks live, puis un test authentifié Coralie, Christelle et Renan.
4. Tester sur iPad : travail hors ligne, fermeture/réouverture, retour en ligne, comparaison NocoDB et web, puis génération PDF.
5. Câbler la synchronisation des annotations PDF par page.
6. Décider du comportement au-delà de huit préconisations dans le rapport.
7. Installer le certificat Apple Distribution avant le prochain build TestFlight.
8. Vérifier un backup réel et le stockage documentaire.

## Commandes de contrôle

```bash
npm run test:flutter
npm run test:sync-contract
npm run check:critical
npm run build
npm run build:pwa
npm run data:stability-check
npm run release:web-check -- --url https://app.aidhabitat.fr
npm run release:live-check
npm run secrets:audit
npm audit --audit-level=high
```

