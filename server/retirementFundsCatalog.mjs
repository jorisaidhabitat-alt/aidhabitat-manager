// Exporté pour pouvoir générer à la volée un logo SVG pour les caisses
// principales (sans entrée dédiée dans ce catalog) — cf.
// `/api/retirement-funds-principal` dans server/index.mjs.
//
// MAJ 2026-05-12 : suppression du gradient (qui causait des collisions
// d'ID `g` quand plusieurs SVG inline étaient montés simultanément dans
// flutter_svg) → fond uni `primary`. `rgba(...)` remplacé par
// `fill="#ffffff" fill-opacity="x"` (compatible flutter_svg, contrairement
// à `rgba()` qui était parfois ignoré côté Flutter). `font-family` ne
// liste plus que Helvetica/Arial standard (pas de « Arial Black » qui
// n'existe pas sur toutes les plateformes).
export const buildLogoDataUri = ({ initials, primary, name }) => {
  const svg = `
    <svg xmlns="http://www.w3.org/2000/svg" width="240" height="240" viewBox="0 0 240 240" role="img" aria-label="${name}">
      <rect width="240" height="240" rx="44" fill="${primary}" />
      <circle cx="188" cy="52" r="18" fill="#ffffff" fill-opacity="0.18" />
      <circle cx="48" cy="194" r="24" fill="#ffffff" fill-opacity="0.12" />
      <text x="120" y="134" text-anchor="middle" font-family="Helvetica, Arial, sans-serif" font-size="72" font-weight="700" fill="#ffffff">${initials}</text>
    </svg>
  `.trim();

  return `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`;
};

const withLogo = (entry) => ({
  ...entry,
  logoUrl: entry.logoUrl || buildLogoDataUri({
    initials: entry.initials,
    primary: entry.primary,
    secondary: entry.secondary,
    name: entry.displayName,
  }),
});

export const RETIREMENT_FUNDS_CATALOG = {
  'agirc-arrco': withLogo({
    displayName: 'Agirc-Arrco',
    logoUrl: '/retirement-logos/agirc-arrco.svg',
    website: 'https://www.agirc-arrco.fr',
    audience: 'Retraités et anciens salariés du privé affiliés au régime.',
    location: 'Espace personnel Agirc-Arrco ou réseau conseil retraite / CICAS.',
    requestMethod: 'Appel ou dépôt via l’espace personnel, puis orientation vers le bon service.',
    requestDelay: 'Variable selon le service saisi.',
    aidAmount: 'Montant variable selon le dossier.',
    therapistNote: 'Vérifier d’abord que le bénéficiaire relève bien du régime Agirc-Arrco.',
    contactPhone: '0 970 660 660',
    initials: 'AA',
    primary: '#0E7C86',
    secondary: '#123C5A',
  }),
  'klesia retraite': withLogo({
    displayName: 'Klésia',
    logoUrl: '/retirement-logos/klesia.svg',
    website: 'https://www.klesia.fr/asop-depot-documents',
    audience: 'Bénéficiaires affiliés Klésia.',
    location: 'Dépôt en ligne ou envoi courrier à Klésia Action Sociale.',
    requestMethod: 'Appeler le 09 69 39 00 54. Si l’affiliation est confirmée, Klésia envoie le formulaire au ménage. Le dossier complet est ensuite téléversé avec formulaire, relevés bancaires, avis d’imposition, justificatifs de ressources, devis, plan de financement, notification ANAH et RIB entreprise.',
    requestDelay: 'Après confirmation d’affiliation, le formulaire est transmis directement au ménage.',
    aidAmount: 'Reste à charge après aides, jusqu’à 2 000 €.',
    therapistNote: 'Il est possible d’initier le dossier, nous même si l’usager est isolé.\nL’aide est directement versée à l’entreprise.',
    contactPhone: '09 69 39 00 54',
    initials: 'KL',
    primary: '#E84F3D',
    secondary: '#6E1E45',
  }),
  'malakoff humanis': withLogo({
    displayName: 'Malakoff Humanis',
    logoUrl: '/retirement-logos/malakoff-humanis.png',
    website: 'https://www.malakoffhumanis.com',
    audience: 'Bénéficiaires affiliés Malakoff Humanis avec déséquilibre financier avéré.',
    location: 'Entrée par téléphone auprès de l’action sociale.',
    requestMethod: 'La famille appelle le 3996 avec le devis retenu et le plan de financement. Les ressources, charges et épargne sont étudiées au téléphone avant envoi éventuel d’un dossier.',
    requestDelay: 'Dossier envoyé uniquement si l’analyse téléphonique laisse envisager une aide.',
    aidAmount: 'Exceptionnel et limité, selon étude.',
    therapistNote: 'Aide possible uniquement en cas de déséquilibre financier avéré mais exceptionnelle et limitée.',
    contactPhone: '3996',
    initials: 'MH',
    primary: '#A1005B',
    secondary: '#D5428B',
  }),
  'ag2r la mondiale': withLogo({
    displayName: 'AG2R',
    logoUrl: '/retirement-logos/ag2r.svg',
    website: 'https://www.ag2rlamondiale.fr',
    audience: 'Bénéficiaires affiliés AG2R avec refus ANAH ou reste à charge trop important.',
    location: 'Entrée par téléphone auprès de l’action sociale AG2R.',
    requestMethod: 'Appeler le 09 69 36 10 43. Si l’affiliation est confirmée, AG2R rappelle pour valider l’éligibilité puis envoie un formulaire papier à retourner avec les justificatifs.',
    requestDelay: 'Rappel possible sous 3 mois, envoi du formulaire sous 15 jours, passage en commission sous 40 jours ouvrés après réception.',
    aidAmount: 'Montant variable après commission.',
    therapistNote: 'Il est possible d’initier le dossier nous même si l’usager est isolé.',
    contactPhone: '09 69 36 10 43',
    initials: 'AG',
    primary: '#C50F2F',
    secondary: '#5C1021',
  }),
  'pro btp': withLogo({
    displayName: 'Pro BTP',
    logoUrl: '/retirement-logos/pro-btp.svg',
    website: 'https://www.probtp.com',
    audience: 'Bénéficiaires affiliés Pro BTP, principalement issus du bâtiment et des travaux publics.',
    location: 'Action sociale Pro BTP.',
    requestMethod: 'Appeler le 02 40 38 15 22, menu 3 puis 3. Si l’appartenance est confirmée, un courrier est transmis au ménage. Le bénéficiaire renvoie ensuite formulaire, taxe foncière, dernier avis d’impôts, 3 relevés bancaires, devis d’entreprises et plan de financement.',
    requestDelay: 'Accord transmis après examen du dossier complet par Pro BTP.',
    aidAmount: 'Tranches 1 et 2: 60% du reste à charge jusqu’à 4 000 €.\nTranche 3: 45% du reste à charge, max 2 000 €.\nTranche 4: 25% du reste à charge, max 1 000 €.',
    therapistNote: 'Il est possible d’initier le dossier nous même si l’usager est isolé.',
    contactPhone: '02 40 38 15 22',
    initials: 'PB',
    primary: '#0B5FFF',
    secondary: '#061F66',
  }),
  'agrica': withLogo({
    displayName: 'Agrica',
    logoUrl: '/retirement-logos/agrica.png',
    website: 'https://www.groupagrica.com',
    audience: 'Retraités, salariés ou anciens salariés du monde agricole affiliés au groupe.',
    location: 'Conseillers action sociale AGRICA.',
    requestMethod: 'Appeler le 0800 944 333. Les conseillers indiquent ensuite les justificatifs à transmettre selon l’aide recherchée.',
    requestDelay: 'Horaires de contact: lundi, mardi, mercredi et vendredi de 10h à 12h puis de 13h30 à 15h30.',
    aidAmount: 'Variable selon l’aide mobilisée.',
    therapistNote: 'Aides possibles pour adaptation du logement, téléassistance, aide à domicile ou petits matériels.',
    contactPhone: '0800 944 333',
    initials: 'AR',
    primary: '#256B2A',
    secondary: '#133818',
  }),
  'apicil': withLogo({
    displayName: 'Apicil',
    logoUrl: '/retirement-logos/apicil.svg',
    website: 'https://www.apicil.com',
    audience: 'Bénéficiaires affiliés APICIL.',
    location: 'Courrier au service compétent APICIL.',
    requestMethod: 'Envoyer un courrier avec les coordonnées du propriétaire, le numéro de sécurité sociale, l’avis d’impôts et les devis des entreprises.',
    requestDelay: 'À confirmer selon le service saisi.',
    aidAmount: 'Étude au cas par cas.',
    therapistNote: 'Prévoir un dossier simple et complet dès le premier envoi.',
    contactPhone: '',
    initials: 'AP',
    primary: '#5A3EC8',
    secondary: '#2B1B66',
  }),
  'cipav': withLogo({
    displayName: 'CIPAV',
    logoUrl: '/retirement-logos/cipav.svg',
    website: 'https://www.lacipav.fr',
    audience: 'Professions libérales affiliées à la CIPAV.',
    location: 'Espace affilié ou service compétent CIPAV.',
    requestMethod: 'Vérifier l’affiliation puis demander le bon circuit de demande.',
    requestDelay: 'À confirmer selon le service saisi.',
    aidAmount: 'Étude au cas par cas.',
    therapistNote: 'Repère utile pour les indépendants hors régime salarié.',
    contactPhone: '01 44 95 68 20',
    initials: 'CI',
    primary: '#1D7F49',
    secondary: '#11412A',
  }),
  'ircantec': withLogo({
    displayName: 'IRCANTEC',
    logoUrl: '/retirement-logos/ircantec.png',
    website: 'https://www.ircantec.retraites.fr',
    audience: 'Agents non titulaires de la fonction publique et contractuels affiliés.',
    location: 'Espace usager Ircantec / service relation usagers.',
    requestMethod: 'Vérifier l’affiliation puis utiliser l’espace usager ou le service relation usagers.',
    requestDelay: 'À confirmer selon le dossier.',
    aidAmount: 'Selon dispositif mobilisé.',
    therapistNote: 'Repère utile pour les profils du secteur public non titulaire.',
    contactPhone: '02 41 05 25 25',
    initials: 'IR',
    primary: '#00697A',
    secondary: '#003B4A',
  }),
  'cavec': withLogo({
    displayName: 'CAVEC',
    logoUrl: '/retirement-logos/cavec.png',
    website: 'https://www.cavec.fr',
    audience: 'Experts-comptables et commissaires aux comptes affiliés.',
    location: 'Service de la caisse CAVEC.',
    requestMethod: 'Vérifier l’affiliation puis demander le bon format de dossier.',
    requestDelay: 'À confirmer selon le service saisi.',
    aidAmount: 'Étude au cas par cas.',
    therapistNote: 'Repère pour les professions comptables libérales.',
    contactPhone: '01 80 49 25 25',
    initials: 'CV',
    primary: '#1F5A94',
    secondary: '#0C2B4B',
  }),
  'carpimko': withLogo({
    displayName: 'CARPIMKO',
    logoUrl: '/retirement-logos/carpimko.svg',
    website: 'https://www.carpimko.com',
    audience: 'Auxiliaires médicaux libéraux affiliés à la CARPIMKO.',
    location: 'Service affiliés CARPIMKO.',
    requestMethod: 'Vérifier l’affiliation puis demander le circuit de dépôt adapté.',
    requestDelay: 'À confirmer selon le service saisi.',
    aidAmount: 'Étude au cas par cas.',
    therapistNote: 'Repère pour les professions paramédicales libérales.',
    contactPhone: '01 30 48 10 00',
    initials: 'CK',
    primary: '#0E8F9A',
    secondary: '#084B52',
  }),
  'cavp': withLogo({
    displayName: 'CAVP',
    logoUrl: '/retirement-logos/cavp.png',
    website: 'https://www.cavp.fr',
    audience: 'Pharmaciens affiliés à la CAVP.',
    location: 'Service de la caisse CAVP.',
    requestMethod: 'Confirmer l’affiliation puis demander la procédure adaptée.',
    requestDelay: 'À confirmer selon le service saisi.',
    aidAmount: 'Étude au cas par cas.',
    therapistNote: 'Repère pour les bénéficiaires pharmaciens.',
    contactPhone: '01 42 66 90 37',
    initials: 'CP',
    primary: '#3C58A6',
    secondary: '#1F2F63',
  }),
  'cavamac': withLogo({
    displayName: 'CAVAMAC',
    logoUrl: '/retirement-logos/cavamac.png',
    website: 'https://www.cavamac.fr',
    audience: 'Agents généraux d’assurance affiliés à la CAVAMAC.',
    location: 'Service compétent CAVAMAC.',
    requestMethod: 'Vérifier l’affiliation puis demander le bon circuit de dépôt.',
    requestDelay: 'À confirmer selon le service saisi.',
    aidAmount: 'Étude au cas par cas.',
    therapistNote: 'Repère pour les profils assurance.',
    contactPhone: '',
    initials: 'CA',
    primary: '#9B6C00',
    secondary: '#5C3D00',
  }),
};

export const getRetirementFundMeta = (name) => {
  const normalized = String(name || '').trim().toLowerCase();
  return RETIREMENT_FUNDS_CATALOG[normalized]
    || Object.values(RETIREMENT_FUNDS_CATALOG).find((entry) => entry.displayName.trim().toLowerCase() === normalized)
    || null;
};
