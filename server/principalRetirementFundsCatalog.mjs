// Catalog des caisses de retraite principales (15 entrées NocoDB).
//
// Chaque entrée mappe un nom NocoDB normalisé (lowercase + espaces) vers :
//  • `logoUrl` : chemin statique servi par express (public/ ou dist/)
//  • `primary` / `secondary` : palette pour le fallback SVG si jamais l'asset
//    n'est pas dispo (au cas où le déploiement Vercel ne pousse pas le static).
//
// L'endpoint `/api/retirement-funds-principal` (server/index.mjs) consulte
// ce catalog AVANT de retomber sur la génération SVG auto (initiales + hash
// gradient). Demande utilisateur 2026-05-12 : « ajoute les logos des caisses
// de retraite principale comme ce que tu as fait pour les caisses de retraite
// complémentaire ».
//
// MAJ 2026-05-12 : la plupart des entrées pointent désormais vers les
// VRAIS logos officiels (PNG/JPG/SVG téléchargés depuis Wikimedia Commons
// ou les sites institutionnels — usage informationnel/nominatif fair use).
// Seules les caisses sans logo trouvable publiquement gardent la
// composition typographique d'origine (.svg dans le même dossier).

export const PRINCIPAL_FUNDS_CATALOG = {
  'cnav (assurance retraite / carsat)': {
    displayName: 'CNAV / CARSAT',
    logoUrl: '/retirement-logos/principal/cnav.png',
    primary: '#0055A4',
    secondary: '#003781',
  },
  'msa': {
    displayName: 'MSA',
    logoUrl: '/retirement-logos/principal/msa.svg',
    primary: '#8BC34A',
    secondary: '#5A8E2E',
  },
  'cnracl': {
    displayName: 'CNRACL',
    logoUrl: '/retirement-logos/principal/cnracl.png',
    primary: '#2D4A8A',
    secondary: '#1D3461',
  },
  "sre (retraites de l'état)": {
    displayName: 'SRE',
    logoUrl: '/retirement-logos/principal/sre.svg',
    primary: '#1B2C7D',
    secondary: '#000091',
  },
  'sre': {
    displayName: 'SRE',
    logoUrl: '/retirement-logos/principal/sre.svg',
    primary: '#1B2C7D',
    secondary: '#000091',
  },
  'ssi (sécurité sociale des indépendants)': {
    displayName: 'SSI',
    logoUrl: '/retirement-logos/principal/ssi.png',
    primary: '#A5C742',
    secondary: '#6E9322',
  },
  'ssi': {
    displayName: 'SSI',
    logoUrl: '/retirement-logos/principal/ssi.png',
    primary: '#A5C742',
    secondary: '#6E9322',
  },
  'cnavpl': {
    displayName: 'CNAVPL',
    logoUrl: '/retirement-logos/principal/cnavpl.png',
    primary: '#3E7AB5',
    secondary: '#1E4C7D',
  },
  'cnbf': {
    displayName: 'CNBF',
    logoUrl: '/retirement-logos/principal/cnbf.png',
    primary: '#A33352',
    secondary: '#6B1530',
  },
  'cnieg': {
    displayName: 'CNIEG',
    logoUrl: '/retirement-logos/principal/cnieg.jpg',
    primary: '#F08A1F',
    secondary: '#C5500B',
  },
  'cprp sncf': {
    displayName: 'CPRP SNCF',
    logoUrl: '/retirement-logos/principal/cprp-sncf.jpg',
    primary: '#D6324A',
    secondary: '#9A0F2A',
  },
  'crp ratp': {
    displayName: 'CRP RATP',
    logoUrl: '/retirement-logos/principal/crp-ratp.svg',
    primary: '#5BC047',
    secondary: '#2B7E27',
  },
  'enim': {
    displayName: 'ENIM',
    logoUrl: '/retirement-logos/principal/enim.png',
    primary: '#1A6B9C',
    secondary: '#003B5C',
  },
  'crpcen': {
    displayName: 'CRPCEN',
    logoUrl: '/retirement-logos/principal/crpcen.png',
    primary: '#2A5294',
    secondary: '#13315B',
  },
  'cavimac': {
    displayName: 'CAVIMAC',
    logoUrl: '/retirement-logos/principal/cavimac.svg',
    primary: '#7C6DAA',
    secondary: '#3F2D69',
  },
};

/// Récupère le branding (logoUrl + palette) d'une caisse principale par nom.
/// Tolère les variations de casse, accents et parenthèses (ex. on essaie
/// d'abord le nom brut normalisé, puis le nom court avant la première
/// parenthèse).
export const getPrincipalFundBranding = (name) => {
  const raw = String(name || '').trim().toLowerCase();
  if (!raw) return null;
  if (PRINCIPAL_FUNDS_CATALOG[raw]) return PRINCIPAL_FUNDS_CATALOG[raw];
  // Essai avec la partie avant la première parenthèse (ex. « CNAV »
  // depuis « CNAV (Assurance retraite / CARSAT) »).
  const short = raw.split('(')[0].trim();
  if (short && PRINCIPAL_FUNDS_CATALOG[short]) return PRINCIPAL_FUNDS_CATALOG[short];
  return null;
};
