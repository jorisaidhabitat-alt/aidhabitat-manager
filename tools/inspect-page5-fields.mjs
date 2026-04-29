// Inspecte les positions et tailles des champs AcroForm de la page 5
// du template PDF (`Étage`, `etage`, `Observations1`, …) pour
// préparer le rendu dynamique des étages multiples.

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PDFDocument } from 'pdf-lib';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TEMPLATE_PATH = path.resolve(
  __dirname,
  '../server/templates/visitReport.template.pdf',
);

const bytes = await fs.readFile(TEMPLATE_PATH);
const doc = await PDFDocument.load(bytes);
const form = doc.getForm();
const pages = doc.getPages();

const FIELDS_OF_INTEREST = [
  'Soussol', 'Sous sol', 'sous_sol',
  'RDC', 'rdc',
  'Étage', 'etage',
  'Maison', 'Appartement',
  'Garage', 'Véranda', 'Balcon', 'Terrasse', 'Jardin',
  'Observations1',
  'nombre d\'étage',
  'Check Box9', 'Check Box10', 'Check Box11', 'Check Box12', 'Check Box13',
  'Check Box14', 'Check Box15', 'Check Box16', 'Check Box17',
];

console.log('📐 Champs page 5 (logement) :\n');
for (const fieldName of FIELDS_OF_INTEREST) {
  let field;
  try {
    field = form.getField(fieldName);
  } catch {
    console.log(`  ❌ "${fieldName}" introuvable`);
    continue;
  }
  const widgets = field.acroField.getWidgets?.() || [];
  for (const w of widgets) {
    const rect = w.getRectangle();
    if (!rect) continue;
    // Trouve la page de ce widget.
    let pageIdx = -1;
    const wDict = w.dict;
    for (let i = 0; i < pages.length; i++) {
      const page = pages[i];
      const annots = page.node.Annots();
      if (!annots) continue;
      const arr = annots.asArray ? annots.asArray() : [];
      for (let j = 0; j < arr.length; j++) {
        const ann = arr[j];
        if (ann?.toString && wDict.toString && ann.toString() === wDict.toString()) {
          pageIdx = i;
          break;
        }
      }
      if (pageIdx >= 0) break;
    }
    console.log(
      `  ✅ "${fieldName}".padEnd(20)} type=${field.constructor.name.padEnd(15)} ` +
      `page=${pageIdx + 1 || '?'} ` +
      `x=${rect.x.toFixed(0).padStart(4)} y=${rect.y.toFixed(0).padStart(4)} ` +
      `w=${rect.width.toFixed(0).padStart(4)} h=${rect.height.toFixed(0).padStart(4)}`,
    );
  }
}

// Info pages
console.log(`\n📄 Pages : ${pages.length} pages au total.`);
for (let i = 0; i < pages.length; i++) {
  const p = pages[i];
  const { width, height } = p.getSize();
  console.log(`  Page ${i + 1} : ${width.toFixed(0)} × ${height.toFixed(0)}`);
}
