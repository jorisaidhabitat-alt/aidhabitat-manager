// Génère un PDF preview du rapport de visite avec un dataset
// synthétique pour vérifier visuellement les pages bonus + label
// « Projet N » + overlay titres. Sortie : /tmp/visit-report-preview.pdf
//
// Usage : node tools/preview-visit-report.mjs

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { generateVisitReport } from '../server/reports/generateVisitReport.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ---- Image placeholder (utilise une image réelle du repo) -----------
// Note : `dist/retirement-logos/agirc-arrco.jpg` est en fait du HTML
// (404 page renommée), donc on utilise un vrai PNG du repo.
const PLACEHOLDER_PATH = path.resolve(
  __dirname,
  '../dist/measurements/standing-figure.png',
);
const PLACEHOLDER_BYTES = await fs.readFile(PLACEHOLDER_PATH);
const PLACEHOLDER_MIME = 'image/png';

// ---- Dataset synthétique -------------------------------------------

function makePhoto(id, title, tags) {
  return {
    id,
    title,
    fileName: `${id}.png`,
    mimeType: PLACEHOLDER_MIME,
    tags,
    type: 'image',
    _source: 'document',
  };
}

const documents = [
  // Logement : 4 photos → 2 sur page 8 + 2 surplus sur page bonus
  makePhoto('log-1', 'Logement 1', ['Visite - Logement']),
  makePhoto('log-2', 'Logement 2', ['Visite - Logement']),
  makePhoto('log-3', 'Logement 3', ['Visite - Logement']),
  makePhoto('log-4', 'Logement 4 (avec __pdf_no_label)', [
    'Visite - Logement',
    '__pdf_no_label',
  ]),

  // Accessibilité : 5 photos → 3 sur page 8 + 2 surplus (rangée incomplète)
  makePhoto('acc-1', 'Accessibilité 1', ['Visite - Accessibilité']),
  makePhoto('acc-2', 'Accessibilité 2', ['Visite - Accessibilité']),
  makePhoto('acc-3', 'Accessibilité 3', ['Visite - Accessibilité']),
  makePhoto('acc-4', 'Accessibilité 4', ['Visite - Accessibilité']),
  makePhoto('acc-5', 'Accessibilité 5', ['Visite - Accessibilité']),

  // Sanitaires : 3 photos exactement → pas de surplus
  makePhoto('san-1', 'Sanitaires 1', ['Visite - Sanitaires']),
  makePhoto('san-2', 'Sanitaires 2', ['Visite - Sanitaires']),
  makePhoto('san-3', 'Sanitaires 3', ['Visite - Sanitaires']),

  // Plan avant : 4 photos → 2 sur page 9 + 2 surplus sur page bonus
  makePhoto('plav-1', 'Plan avant 1', ['Visite - Plan avant']),
  makePhoto('plav-2', 'Plan avant 2', ['Visite - Plan avant']),
  makePhoto('plav-3', 'Plan avant 3', ['Visite - Plan avant']),
  makePhoto('plav-4', 'Plan avant 4', ['Visite - Plan avant']),

  // Plan après : 2 sections (= 2 projets) → label « Projet 1/2 »
  // Section base
  makePhoto('plap-1', 'Cuisine adaptée', ['Visite - Plan après']),
  makePhoto('plap-2', 'SDB sécurisée', ['Visite - Plan après']),
  // Section extra (#1)
  makePhoto('plap-1b', 'Variante salon', ['Visite - Plan après (#1)']),
  makePhoto('plap-2b', 'Variante chambre', ['Visite - Plan après (#1)']),
];

const dossier = {
  id: 'preview-dossier',
  patient: {
    id: 'preview-patient',
    firstName: 'Jean',
    lastName: 'Dupont',
    dateOfBirth: '1955-03-14',
    address: '12 rue de la Préview',
    city: 'Préviewville',
    postalCode: '75000',
    homeHelp: false,
    invalidity: false,
  },
  housing: {
    type: 'Maison',
    surface: 80,
  },
};

async function fetchImageBytes(/* descriptor */) {
  // Toutes les photos prennent le même placeholder PNG.
  return { buffer: PLACEHOLDER_BYTES, mimeType: PLACEHOLDER_MIME };
}

const result = await generateVisitReport({
  dossier,
  documents,
  notePages: [],
  recommendations: [],
  fetchImageBytes,
  flatten: true,
});

const { bytes: pdfBytes, stats } = result;

const outPath = '/tmp/visit-report-preview.pdf';
await fs.writeFile(outPath, pdfBytes);

console.log(`OK → PDF généré : ${outPath}`);
console.log(`Stats :`, JSON.stringify(stats, null, 2));
console.log(`Taille : ${(pdfBytes.length / 1024).toFixed(1)} KB`);
