// Génère un PDF de rapport de visite localement avec un dossier
// fictif, pour valider visuellement les corrections sans devoir
// déployer + générer un vrai rapport via NocoDB.
//
// Usage :
//   node tools/generate-test-report.mjs
//   open tmp/test-report.pdf
//
// 3 versions sont produites pour tester les variantes :
//   - tmp/test-report-empty-occupation.pdf (rien coché en occupation)
//   - tmp/test-report-locataire.pdf       (Locataire coché)
//   - tmp/test-report-proprietaire.pdf    (Propriétaire coché)
//
// Aucune dépendance NocoDB / réseau — tout est mocké.

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { generateVisitReport, buildReportFileName } from '../server/reports/generateVisitReport.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OUT_DIR = path.resolve(__dirname, '../tmp');

const baseDossier = {
  id: 'test-dossier-1',
  ergoId: 'Christelle',
  visitDate: '2026-04-28',
  natureAccompagnement: 'complet',
  personnesPresentesVisite: 'Mme Dupont (fille du bénéficiaire)',
  envoiRapport: 'A faire',
  compteAnah: 'A vérifier',
  patient: {
    id: 'test-patient-1',
    firstName: 'Paul',
    lastName: 'DENA',
    birthDate: '1948-06-15',
    secondFirstName: '',
    secondLastName: '',
    phone: '06 12 34 56 78',
    email: 'paul.dena@example.com',
    address: '12 rue des Lilas',
    city: 'Vitré',
    zipCode: '35500',
    cityId: '',
    familySituation: 'Veuf(ve)',
    occupationStatus: '', // par défaut : rien sélectionné
    incomeCategory: 'Modeste',
    fiscalRevenue: 18500,
    numberPeople: 1,
    apa: true,
    apaGir: '',
    invalidity: true,
    invalidityTxt: 'Entre 50 et 79%',
    homeHelp: true,
    homeHelpTxt: 'aide-ménagère 2h/sem (ADMR), portage repas (Aid\'Habitat)',
    dependenceTxt: 'Canne en intérieur, déambulateur en extérieur',
    occupants: [],
    trustedPerson: {
      name: 'Marie Dupont',
      phone: '06 98 76 54 32',
      email: 'marie.dupont@example.com',
    },
  },
  housing: {
    type: { name: 'house' },
    typology: 'Maison',
    yearConstruction: '1972',
    yearHabitation: '2003',
    surface: 95,
    levels: 2,
    heating: { name: 'electric' },
    heatingDetails: { electric: true, wood: false, gas: false, heatPump: false, collective: false, oil: false, pellet: false, other: false },
    accessibilityNotes: '',
    basement: false, basementDesc: '',
    rdc: true, rdcDesc: 'Cuisine, salon, salle à manger, WC, SDB, chambre',
    floor: true, floorDesc: '2 chambres + 1 SDB',
    secondFloor: false, secondFloorDesc: '',
    thirdFloor: false, thirdFloorDesc: '',
    garage: true, veranda: false, balcon: false, terrasse: true, jardin: true,
  },
  // Pas de medicalContext / autonomy — les notes de Contexte de vie
  // (textContent) seront utilisées à la place via contexteNotes.
};

const sanitaires = {
  sdbAuNiveauPieceVie: true,
  wcAuNiveau: true,
  wcEtage: false,
  sdbBaignoire: true, sdbBaignoireHauteurFr: '50 cm',
  sdbBacDouche: false,
  sdbVasqueSuspendue: false, sdbVasqueColonne: true, sdbMeubleVasque: false,
  sdbBidet: false, sdbParoiDouche: false, sdbSolGlissant: true,
  sdbMachineALaver: true,
  wcCuvetteBonneHauteur: false, wcCuvetteTropBasse: true, wcCuvetteHauteurFr: '38 cm',
  wcBarreRelevement: false,
  porteSdbLargeurSuffisante: true, porteWcLargeurSuffisante: false,
  porteSdbSensInterieur: true, porteSdbSensExterieur: false,
  porteWcSensInterieur: false, porteWcSensExterieur: true,
  porteSdbDimensionFr: '70 cm', porteWcDimensionFr: '60 cm',
  observationsEquipements: 'Baignoire avec siphon bas, difficile d\'accès. Pas de barre d\'appui.',
};

const observations = {
  projetSouhaitUsage: 'Pouvoir continuer à vivre à domicile en sécurité, avec une douche accessible.',
  resumePreconisations: 'Remplacement baignoire par douche extra-plate, pose barres d\'appui SDB+WC, élargissement porte WC.',
};

const contexteNotes = [
  {
    tabKey: 'Contexte de vie-Médical',
    pageNumber: 0,
    textContent:
      'Pathologies : insuffisance cardiaque sévère (NYHA III), arthrose du genou droit. ' +
      'Suivi médical : cardiologue tous les 3 mois, kinésithérapeute 2×/semaine. ' +
      'Atteintes sensorielles : presbytie (port de lunettes), légère hypoacousie côté gauche.',
  },
  {
    tabKey: 'Contexte de vie-Autonomie',
    pageNumber: 0,
    textContent:
      'Autonome pour la toilette, l\'habillage, les repas. ' +
      'Difficulté pour entrer/sortir de la baignoire (besoin d\'appui). ' +
      'Aide humaine pour les courses (1 fois/sem, fille) et le ménage hebdomadaire.',
  },
];

async function generate(filename, occupationStatus) {
  const dossier = {
    ...baseDossier,
    patient: { ...baseDossier.patient, occupationStatus },
  };
  const { bytes, stats } = await generateVisitReport({
    dossier,
    sanitaires,
    observations,
    documents: [],
    notePages: [],
    contexteNotes,
    recommendations: [],
    fetchImageBytes: async () => null,
  });
  const outPath = path.resolve(OUT_DIR, filename);
  await fs.mkdir(OUT_DIR, { recursive: true });
  await fs.writeFile(outPath, bytes);
  const finalName = buildReportFileName(dossier);
  console.log(`✅ ${filename}  (${(bytes.length / 1024).toFixed(1)} KB) — applied=${stats.applied} missing=${stats.missingValue}`);
  console.log(`   filename serveur : « ${finalName} »`);
  return outPath;
}

(async () => {
  console.log('🛠  Génération de 3 versions test du PDF rapport...\n');
  const empty = await generate('test-report-empty-occupation.pdf', '');
  const locat = await generate('test-report-locataire.pdf', 'Locataire');
  const prop  = await generate('test-report-proprietaire.pdf', 'Propriétaire');
  console.log('\nFichiers prêts dans :');
  console.log(`  ${empty}`);
  console.log(`  ${locat}`);
  console.log(`  ${prop}`);
  console.log('\nOuvrir avec : open tmp/test-report-empty-occupation.pdf');
})();
