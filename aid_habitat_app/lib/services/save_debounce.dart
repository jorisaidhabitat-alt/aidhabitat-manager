/// Constantes de debounce des saves côté visit-report et dossier_screen.
///
/// **Pourquoi centraliser** : avant cette unification, chaque onglet
/// définissait sa propre valeur (100ms / 150ms / 400ms / 2000ms), ce
/// qui créait des races offline quand 2 onglets éditaient des champs
/// chevauchants (ex: Nom dans Bénéficiaire **et** Nom dans
/// dossier_screen).
///
/// **Règle finale (révisée 2026-04-28)** :
///   - Texte saisi (Nom, Prénom, Adresse, observations…) → **400 ms**.
///     L'ancien réglage `Duration.zero` provoquait des pertes de
///     données type « Foyer Yanis » → « F » ou « Bro » → « B » dans
///     NocoDB, à cause de races entre les PATCH HTTP successifs (un
///     PATCH avec le préfixe court qui arrive APRÈS un PATCH avec le
///     texte complet, et écrase la valeur correcte par last-write-wins).
///     Avec 400 ms, l'utilisateur finit de taper son mot AVANT qu'un
///     PATCH parte → un seul PATCH avec la valeur finale. Couche
///     complémentaire dans `sync_repository.markCompleted` qui gate
///     les transitions sur `status='running'` pour le 1% restant.
///   - Toggle / pills / dropdowns → 2000 ms (NB: alias kSaveDebouncePills
///     reste à zéro car les clics sont délibérés et espacés, pas de
///     race possible sur un même champ).
library;

import 'dart:async';

/// Debounce pour les champs où l'utilisateur tape du texte au clavier.
///
/// **400 ms** : suffisamment long pour absorber une saisie rapide
/// (mot entier sans risque d'un PATCH partiel), suffisamment court
/// pour rester perçu comme « immédiat » par l'utilisateur. Cette
/// valeur, combinée au verrou par status='running' dans le sync
/// engine, élimine les pertes de données type « Foyer Yanis » → « F »
/// observées en avril 2026.
const Duration kSaveDebounceText = Duration(milliseconds: 400);

/// Debounce pour les onglets de toggles / dropdowns. Reste à zéro :
/// les clics sont délibérés et espacés, et chaque clic touche un champ
/// distinct (pas de race sur le même champ). Le SyncEngine.notify()
/// debounce déjà à 200 ms en interne pour mutualiser plusieurs clics
/// proches en un seul push réseau.
const Duration kSaveDebouncePills = Duration.zero;

/// Helper pour redémarrer un timer de save sans dupliquer le pattern
/// dans chaque onglet. Annule le timer précédent puis en démarre un
/// nouveau avec la durée donnée. Renvoie le nouveau timer pour que
/// l'appelant puisse le stocker (et l'annuler dans dispose).
Timer scheduleDebouncedSave({
  Timer? previous,
  required void Function() onFire,
  Duration delay = kSaveDebounceText,
}) {
  previous?.cancel();
  return Timer(delay, onFire);
}
