// Contrat unique partagé par l'API et l'interface Web.
// Flutter possède la même liste en Dart et un test de contrat vérifie
// automatiquement qu'elle reste strictement identique.
export const AUTONOMY_ITEMS = Object.freeze([
  'Déplacements/transferts',
  'Escaliers',
  'Conduite automobile',
  'Transports en commun',
  'Toilette/habillage',
  'Continence',
  'Repas (y compris courses)',
  'Tâches ménagères',
  'Démarches admin',
  'Cognition',
  'Communication',
]);

const AUTONOMY_ITEM_ALIASES = new Map([
  ['Tâches ménagères.domestiques', 'Tâches ménagères'],
]);

export const canonicalAutonomyItemName = (value) => {
  const name = String(value ?? '').trim();
  return AUTONOMY_ITEM_ALIASES.get(name) || name;
};

export const normalizeAutonomyChecklist = (items) => {
  const source = Array.isArray(items) ? items : [];
  const byName = new Map();

  for (const item of source) {
    const name = canonicalAutonomyItemName(item?.name);
    if (AUTONOMY_ITEMS.includes(name)) {
      byName.set(name, Boolean(item?.checked));
    }
  }

  // Les très anciennes données ne contenaient parfois aucun nom. Le
  // fallback par position ne s'active que dans ce cas précis; dès qu'un
  // libellé reconnu existe, les valeurs sont exclusivement reliées par nom.
  const hasRecognizedName = byName.size > 0;
  return AUTONOMY_ITEMS.map((name, index) => ({
    name,
    checked: byName.has(name)
      ? byName.get(name)
      : !hasRecognizedName && !canonicalAutonomyItemName(source[index]?.name)
        ? Boolean(source[index]?.checked)
        : false,
  }));
};

export const autonomyChecklistToMap = (items) => new Map(
  normalizeAutonomyChecklist(items).map((item) => [item.name, item.checked]),
);
