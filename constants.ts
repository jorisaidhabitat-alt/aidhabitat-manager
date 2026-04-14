import { Dossier, DossierStatus, HeatingMode, HousingType, Patient, Visit, WorkItem } from './types';

export const MOCK_WORKS_CATALOG: WorkItem[] = [
  { id: 'W1', name: 'Remplacement baignoire par douche', description: 'Douche extra-plate avec siège', unit: 'Forfait', priceHT: 3500, tva: 5.5 },
  { id: 'W2', name: 'Installation monte-escalier', description: 'Rail droit 5m', unit: 'Unité', priceHT: 2800, tva: 5.5 },
  { id: 'W3', name: 'Barre d\'appui coudée', description: 'Inox, 135 degrés', unit: 'Unité', priceHT: 45, tva: 5.5 },
  { id: 'W4', name: 'Motorisation volets', description: 'Volet roulant électrique', unit: 'Fenêtre', priceHT: 400, tva: 10 },
  { id: 'W5', name: 'Élargissement porte', description: 'Passage 90cm', unit: 'Porte', priceHT: 800, tva: 10 },
];

export const MOCK_PATIENTS: Patient[] = [
  { id: 'P1', firstName: 'Jeanne', lastName: 'Moreau', birthDate: '1945-03-12', phone: '06 12 34 56 78', email: 'jeanne.moreau@email.com', address: '12 Rue des Lilas', city: 'Bordeaux', zipCode: '33000', familySituation: 'Veuve', incomeCategory: 'Très modeste', apa: false, invalidity: false, homeHelp: false },
  { id: 'P2', firstName: 'Robert', lastName: 'Dubois', birthDate: '1952-07-22', phone: '06 98 76 54 32', email: 'r.dubois@email.com', address: '5 Avenue de la Liberté', city: 'Mérignac', zipCode: '33700', familySituation: 'Marié', incomeCategory: 'Modeste', apa: false, invalidity: false, homeHelp: false },
  { id: 'P3', firstName: 'Alice', lastName: 'Lefebvre', birthDate: '1938-11-05', phone: '05 56 11 22 33', email: 'alice.l@email.com', address: '8 Impasse du Jardin', city: 'Pessac', zipCode: '33600', familySituation: 'Veuve', incomeCategory: 'Modeste', apa: false, invalidity: false, homeHelp: false },
  { id: 'P4', firstName: 'Michel', lastName: 'Blanc', birthDate: '1960-01-30', phone: '06 44 55 66 77', email: 'm.blanc@email.com', address: '45 Rue de la République', city: 'Talence', zipCode: '33400', familySituation: 'Divorcé', incomeCategory: 'Intermédiaire', apa: false, invalidity: false, homeHelp: false },
  { id: 'P5', firstName: 'Sarah', lastName: 'Connor', birthDate: '1955-05-19', phone: '06 00 00 00 00', email: 's.connor@email.com', address: '102 Bd du Président', city: 'Bègles', zipCode: '33130', familySituation: 'Célibataire', incomeCategory: 'Très modeste', apa: false, invalidity: false, homeHelp: false },
  { id: 'P6', firstName: 'Pierre', lastName: 'Richard', birthDate: '1942-08-14', phone: '07 88 99 66 55', email: 'prichard@email.com', address: '3 Allée des Chênes', city: 'Cenon', zipCode: '33150', familySituation: 'Marié', incomeCategory: 'Supérieur', apa: false, invalidity: false, homeHelp: false },
  { id: 'P7', firstName: 'Thérèse', lastName: 'Martin', birthDate: '1935-02-28', phone: '05 44 33 22 11', email: 'therese.m@email.com', address: '14 Rue Victor Hugo', city: 'Lormont', zipCode: '33310', familySituation: 'Veuve', incomeCategory: 'Très modeste', apa: false, invalidity: false, homeHelp: false },
  { id: 'P8', firstName: 'Bernard', lastName: 'Tapie', birthDate: '1948-12-01', phone: '06 77 88 99 00', email: 'b.tapie@email.com', address: '78 Quai des Chartrons', city: 'Bordeaux', zipCode: '33000', familySituation: 'Marié', incomeCategory: 'Intermédiaire', apa: false, invalidity: false, homeHelp: false },
  { id: 'P9', firstName: 'Monique', lastName: 'Dupont', birthDate: '1951-09-10', phone: '06 11 22 33 44', email: 'm.dupont@email.com', address: '22 Avenue Thiers', city: 'Bordeaux', zipCode: '33100', familySituation: 'Divorcée', incomeCategory: 'Modeste', apa: false, invalidity: false, homeHelp: false },
  { id: 'P10', firstName: 'Gérard', lastName: 'Depardieu', birthDate: '1949-12-27', phone: '06 55 44 33 22', email: 'gg@email.com', address: '1 Château de la Tour', city: 'Saint-Émilion', zipCode: '33330', familySituation: 'Célibataire', incomeCategory: 'Supérieur', apa: false, invalidity: false, homeHelp: false },
  { id: 'P11', firstName: 'Catherine', lastName: 'Deneuve', birthDate: '1943-10-22', phone: '06 22 33 44 55', email: 'c.deneuve@email.com', address: '55 Rue Sainte-Catherine', city: 'Bordeaux', zipCode: '33000', familySituation: 'Célibataire', incomeCategory: 'Intermédiaire', apa: false, invalidity: false, homeHelp: false },
  { id: 'P12', firstName: 'Alain', lastName: 'Delon', birthDate: '1935-11-08', phone: '06 99 88 77 66', email: 'ad@email.com', address: 'Domaine de la Braconne', city: 'Mérignac', zipCode: '33700', familySituation: 'Veuf', incomeCategory: 'Supérieur', apa: false, invalidity: false, homeHelp: false },
];

const createDossier = (patient: Patient, id: string, status: DossierStatus, heating: HeatingMode): Dossier => ({
  id,
  patient,
  status,
  ergoId: 'E1',
  visitDate: '2023-11-15',
  housing: {
    typology: Math.random() > 0.5 ? HousingType.HOUSE : HousingType.APARTMENT,
    yearConstruction: String(1960 + Math.floor(Math.random() * 40)),
    surface: String(50 + Math.floor(Math.random() * 100)),
    heatingMode: heating,
    basement: false, rdc: true, floor: false,
    garage: false, veranda: false, balcon: false, terrasse: false, jardin: false,
    heatingMain: true,
    heatingDetails: { electric: false, gas: false, oil: false, heatPump: false, collective: false, wood: false, pellet: false, other: false },
    easyAccess: true,
    accessibilityNotes: 'Notes standard.'
  },
  autonomyNotes: 'Autonomie correcte.',
  plans: {
    PF1: { id: 'PF1', works: [], grants: [] },
    PF2: { id: 'PF2', works: [], grants: [] },
    PF3: { id: 'PF3', works: [], grants: [] }
  },
  createdAt: '2023-10-01'
});

export const MOCK_DOSSIERS: Dossier[] = [
  { ...createDossier(MOCK_PATIENTS[0], 'D1', DossierStatus.IN_PROGRESS, HeatingMode.GAS), autonomyNotes: 'Difficultés marche.' },
  { ...createDossier(MOCK_PATIENTS[1], 'D2', DossierStatus.TO_VISIT, HeatingMode.ELECTRIC), visitDate: '2023-10-28' },
  createDossier(MOCK_PATIENTS[2], 'D3', DossierStatus.TO_VISIT, HeatingMode.GAS),
  createDossier(MOCK_PATIENTS[3], 'D4', DossierStatus.VALIDATED, HeatingMode.HEAT_PUMP),
  createDossier(MOCK_PATIENTS[4], 'D5', DossierStatus.CLOSED, HeatingMode.ELECTRIC),
  createDossier(MOCK_PATIENTS[5], 'D6', DossierStatus.IN_PROGRESS, HeatingMode.WOOD),
  createDossier(MOCK_PATIENTS[6], 'D7', DossierStatus.TO_VISIT, HeatingMode.GAS),
  createDossier(MOCK_PATIENTS[7], 'D8', DossierStatus.VALIDATED, HeatingMode.HEAT_PUMP),
  createDossier(MOCK_PATIENTS[8], 'D9', DossierStatus.IN_PROGRESS, HeatingMode.ELECTRIC),
  createDossier(MOCK_PATIENTS[9], 'D10', DossierStatus.TO_VISIT, HeatingMode.WOOD),
  createDossier(MOCK_PATIENTS[10], 'D11', DossierStatus.VALIDATED, HeatingMode.GAS),
  createDossier(MOCK_PATIENTS[11], 'D12', DossierStatus.CLOSED, HeatingMode.HEAT_PUMP),
];

export const MOCK_VISITS: Visit[] = [
  { id: 'V1', dossierId: 'D1', patientName: 'Jeanne Moreau', date: '2023-10-15 14:00', location: 'Bordeaux', status: 'Done' },
  { id: 'V2', dossierId: 'D2', patientName: 'Robert Dubois', date: '2023-10-28 10:00', location: 'Mérignac', status: 'Upcoming' },
  { id: 'V3', dossierId: 'D3', patientName: 'Alice Lefebvre', date: '2023-11-02 09:30', location: 'Pessac', status: 'Upcoming' },
];