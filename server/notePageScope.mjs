const CANONICAL_DOSSIER_TABS = new Set([
  'Bénéficiaire-Notes',
  'notes_rapides',
]);

const stringValue = (value) => String(value ?? '').trim();

export const normalizeNotePageScope = ({
  patientId,
  dossierId,
  scopeType,
  scopeId,
  tabKey,
}) => {
  const normalizedPatientId = stringValue(patientId);
  const normalizedDossierId = stringValue(dossierId);
  const normalizedScopeType = stringValue(scopeType) || 'legacy';
  const normalizedScopeId = stringValue(scopeId);
  const normalizedTabKey = stringValue(tabKey);

  if (
    normalizedScopeType === 'dossier_detail'
    && CANONICAL_DOSSIER_TABS.has(normalizedTabKey)
    && normalizedDossierId
  ) {
    return {
      scopeType: 'dossier_detail',
      scopeId: normalizedDossierId,
    };
  }

  return {
    scopeType: normalizedScopeType,
    scopeId: normalizedScopeId || normalizedDossierId || normalizedPatientId,
  };
};

const logicalKey = (notePage) => [
  stringValue(notePage?.tabKey),
  stringValue(notePage?.subTabKey),
  Number(notePage?.pageNumber) || 0,
].join('|');

const updatedAtMillis = (notePage) => {
  const parsed = Date.parse(stringValue(notePage?.updatedAt));
  return Number.isFinite(parsed) ? parsed : 0;
};

export const selectCanonicalNotePages = (
  notePages,
  { patientId, dossierId } = {},
) => {
  const pages = Array.isArray(notePages) ? notePages : [];
  const canonicalDossierId = stringValue(dossierId);
  if (!canonicalDossierId) return pages;

  const protectedGroups = new Map();
  const untouched = [];

  for (const notePage of pages) {
    if (!CANONICAL_DOSSIER_TABS.has(stringValue(notePage?.tabKey))) {
      untouched.push(notePage);
      continue;
    }
    const key = logicalKey(notePage);
    const group = protectedGroups.get(key) ?? [];
    group.push(notePage);
    protectedGroups.set(key, group);
  }

  for (const group of protectedGroups.values()) {
    const canonical = group.filter((notePage) => {
      const normalized = normalizeNotePageScope({
        patientId,
        dossierId: canonicalDossierId,
        scopeType: notePage?.scopeType,
        scopeId: notePage?.scopeId,
        tabKey: notePage?.tabKey,
      });
      return (
        stringValue(notePage?.scopeType) === normalized.scopeType
        && stringValue(notePage?.scopeId) === normalized.scopeId
      );
    });
    const candidates = canonical.length > 0 ? canonical : group;
    candidates.sort((a, b) => updatedAtMillis(b) - updatedAtMillis(a));
    untouched.push(candidates[0]);
  }

  return untouched.sort((a, b) => {
    const tabCompare = stringValue(a?.tabKey).localeCompare(
      stringValue(b?.tabKey),
      'fr',
    );
    if (tabCompare !== 0) return tabCompare;
    return (Number(a?.pageNumber) || 0) - (Number(b?.pageNumber) || 0);
  });
};
