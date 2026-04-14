export enum UserRole {
  ADMIN = 'ADMIN',
  ERGO = 'ERGO'
}

export interface AppUser {
  email: string;
  displayName: string;
  role: UserRole;
  selectable: boolean;
  profilePhotoUrl?: string;
  establishmentId?: string;
  establishmentLabel?: string;
  ergoRecordId?: string;
  ergoLabel?: string;
}

export interface AdminAccessMember {
  email: string;
  displayName: string;
  role: UserRole;
  selectable: boolean;
  establishmentLabel?: string;
  ergoLabel?: string;
  hasPassword: boolean;
  generatedPassword: string;
  createdAt?: string | null;
}

export interface RetirementFund {
  id: string;
  name: string;
  phone: string;
  audience: string;
  requestMethod: string;
  requestDelay: string;
  aidAmount?: string;
  therapistNote: string;
  website: string;
  logoUrl: string;
  lastEditedAt?: string;
}

export interface NotePage {
  id: string;
  patientId: string;
  dossierId?: string | null;
  patientFirstName?: string;
  patientLastName?: string;
  patientDisplayName?: string;
  dossierLabel?: string;
  scopeType: string;
  scopeId: string;
  tabKey: string;
  pageNumber: number;
  textContent: string;
  drawingJson: string;
  layoutKind?: string;
  updatedAt?: string;
}

export interface AppDocument {
  id: string;
  remoteId?: string;
  patientId: string;
  dossierId?: string | null;
  patientFirstName?: string;
  patientLastName?: string;
  patientDisplayName?: string;
  dossierLabel?: string;
  title: string;
  fileName: string;
  mimeType: string;
  tags: string[];
  createdAt: string;
  updatedAt: string;
  lastSyncedAt?: string | null;
  syncStatus?: 'synced' | 'pending' | 'failed';
  remotePath?: string;
  url: string;
  type: 'image' | 'pdf' | 'doc';
}

export interface AnahStatus {
  available: boolean;
  checkedAt?: string;
  registrationUrl: string;
  publicUrl: string;
  canEmbed: boolean;
  reason?: string;
}

export interface WikiLibraryItem {
  id: string;
  title: string;
  description: string;
  imageUrl: string;
  tags: string[];
  category: string;
  createdAt: string;
  updatedAt: string;
}

export interface VisitRecommendationItem {
  id: string;
  wikiItemId: string;
  wikiTitle: string;
  wikiImageUrl: string;
  wikiTag?: string;
  note: string;
  createdAt: string;
  updatedAt: string;
}

export enum DossierStatus {
  TO_VISIT = 'À visiter',
  IN_PROGRESS = 'En cours',
  VALIDATED = 'Validé',
  CLOSED = 'Clos'
}

export enum HousingType {
  HOUSE = 'Maison',
  APARTMENT = 'Appartement'
}

export enum HeatingMode {
  ELECTRIC = 'Électrique',
  GAS = 'Gaz',
  WOOD = 'Bois',
  HEAT_PUMP = 'Pompe à chaleur',
  OIL = 'Fioul',
  OTHER = 'Autre'
}

export interface OccupantIdentity {
  firstName: string;
  lastName: string;
  birthDate?: string;
  apa?: boolean;
  invalidity?: boolean;
  invalidityTxt?: string;
  homeHelp?: boolean;
  homeHelpTxt?: string;
  dependenceTxt?: string;
  numeroSecuriteSociale?: string;
  caisseRetraitePrincipale?: string;
  caissesRetraiteComplementaires?: string;
}

// Mapped from 'beneficiaires' table
export interface Patient {
  id: string;
  firstName: string; // prenom
  lastName: string; // nom
  secondFirstName?: string; // prenom_occupant_2
  secondLastName?: string; // nom_occupant_2
  occupants?: OccupantIdentity[];

  // Coordonnées
  address: string; // adresse_logement
  city: string; // nom_commune
  cityId?: string; // commune_id
  zipCode: string; // code_postal
  phone: string; // telephone
  email: string; // mail

  // Situation personnelle
  birthDate?: string; // Derived / Primary
  birthDateMr?: string; // date_naissance_monsieur
  birthDateMme?: string; // date_naissance_madame
  familySituation?: string; // situation_beneficiaire
  occupationStatus?: string; // statut_occupation
  numberPeople?: number; // nombre_personnes

  // Revenus
  incomeCategory?: string; // categorie_revenu_nom
  fiscalRevenue?: number; // revenu_fiscal_reference

  // Autonomie / Santé (Booleans & Texts)
  apa: boolean; // beneficiaire_apa
  invalidity: boolean; // reconnaissance_invalidite_mdph
  invalidityTxt?: string; // reconnaissance_invalidité_mdph_txt
  homeHelp: boolean; // aide_a_domicile
  homeHelpTxt?: string; // aide_a_domicile_txt
  dependenceTxt?: string; // dependance_particuliere_txt

  // Nouveaux champs administratifs
  numeroSecuriteSocialeMonsieur?: string;
  numeroSecuriteSocialeMadame?: string;
  caisseRetraitePrincipale?: string;
  caissesRetraiteComplementaires?: string;

  // Personne de confiance
  trustedPerson?: {
    name: string; // personne_confiance
    phone: string; // telephone_personne_confiance
    email: string; // mail_personne_confiance
  };

  photoUrl?: string; // photo_logement_url
}

// Mapped from 'logements' table
export interface Housing {
  id?: string; // logements.id

  // General
  yearConstruction?: string; // annee_construction
  yearHabitation?: string; // annee_habitation
  surface?: string; // surface_habitable
  levels?: number; // nombre_niveaux
  typology?: HousingType; // derived from type_logement_id

  // Floors / Rooms
  basement: boolean; // sous_sol
  basementDesc?: string; // description_sous_sol
  rdc: boolean; // rdc
  rdcDesc?: string; // description_rdc
  floor: boolean; // etage
  floorDesc?: string; // description_etage

  // Annexes
  garage: boolean;
  veranda: boolean;
  balcon: boolean;
  terrasse: boolean;
  jardin: boolean;

  // Heating
  heatingMain: boolean; // chauffage
  heatingDetails: {
    electric: boolean; // radiateurs_electrique
    gas: boolean; // chaudiere_gaz
    oil: boolean; // chaudiere_fioul
    heatPump: boolean; // pompe_a_chaleur
    collective: boolean; // chaudiere_collective
    wood: boolean; // cheminee_pole_bois
    pellet: boolean; // poele_granules
    other: boolean; // autre_chauffage
  };

  // Volets (NEW)
  voletsRoulantsManuelsLocalisation?: string;
  voletsRoulantsManuelsEntier?: boolean;
  voletsRoulantsElectriquesLocalisation?: string;
  voletsRoulantsElectriquesEntier?: boolean;
  voletsPersiennesLocalisation?: string;
  voletsPersiennesEntier?: boolean;

  // Cheminement d'accès (NEW)
  cheminementEscalierExterieur?: boolean;
  cheminementEscalierInterieur?: boolean;
  cheminementPenteDouce?: boolean;
  cheminementPlat?: boolean;
  cheminementQuelquesMarches?: boolean;
  cheminementParArriere?: boolean;
  cheminementSeuilPorte?: boolean;
  difficultesCirculationInterieure?: boolean;

  // Motorisations — libellé pour affichage dans les selects, id FK pour sauvegarde
  porteGarageId?: string;   // porte_garage_id (FK → porte_de_garage)
  portailId?: string;       // portail_id (FK → portail)
  motorisationPorteGarage?: string; // libellé affiché dans le select
  motorisationPortail?: string;     // libellé affiché dans le select

  // Access
  easyAccess: boolean; // acces_facile_rue
  comments?: string; // commentaire
  accessObservation?: string; // observation_accessibilite

  // Legacy / Compat
  accessibilityNotes?: string;
  heatingMode?: HeatingMode; // Derived summary
}

// Mapped from 'diagnostic_sanitaires' table (NEW)
export interface BathroomLevelInstance {
  id: string;
  levelField: string;
  levelLabel: string;
  sdbBaignoire?: boolean;
  sdbBaignoireHauteur?: number;
  sdbBacDouche?: boolean;
  sdbBacDoucheHauteur?: number;
  sdbVasqueSuspendue?: boolean;
  sdbVasqueSuspendueHauteur?: number;
  sdbVasqueColonne?: boolean;
  sdbVasqueColonneHauteur?: number;
  sdbMeubleVasque?: boolean;
  sdbMeubleVasqueHauteur?: number;
  sdbBidet?: boolean;
  sdbBidetHauteur?: number;
  sdbParoiDouche?: boolean;
  sdbParoiDoucheHauteur?: number;
  sdbSolGlissant?: boolean;
  sdbMachineALaver?: boolean;
  sdbMachineALaverHauteur?: number;
  porteSdbLargeurSuffisante?: boolean;
  porteSdbDimension?: number;
  porteSdbSensAdapte?: boolean;
}

export interface WcLevelInstance {
  id: string;
  levelField: string;
  levelLabel: string;
  wcCuvetteBonneHauteur?: boolean;
  wcCuvetteTropBasse?: boolean;
  wcCuvetteHauteur?: number;
  wcBarreRelevement?: boolean;
  porteWcLargeurSuffisante?: boolean;
  porteWcDimension?: number;
  porteWcSensAdapte?: boolean;
  observationEquipementsUtilisation?: string;
}

export interface DiagnosticSanitaires {
  id?: string;
  dossierId?: string;
  sdbInstances?: BathroomLevelInstance[];
  wcInstances?: WcLevelInstance[];

  // Configuration globale
  sdbNiveauPiecesVie?: boolean;
  wcNiveau?: boolean;
  wcEtage?: boolean;

  // Équipements Salle de bain
  sdbBaignoire?: boolean;
  sdbBaignoireHauteur?: number;
  sdbBacDouche?: boolean;
  sdbBacDoucheHauteur?: number;
  sdbVasqueSuspendue?: boolean;
  sdbVasqueSuspendueHauteur?: number;
  sdbVasqueColonne?: boolean;
  sdbVasqueColonneHauteur?: number;
  sdbMeubleVasque?: boolean;
  sdbMeubleVasqueHauteur?: number;
  sdbBidet?: boolean;
  sdbBidetHauteur?: number;
  sdbParoiDouche?: boolean;
  sdbParoiDoucheHauteur?: number;
  sdbSolGlissant?: boolean;
  sdbMachineALaver?: boolean;
  sdbMachineALaverHauteur?: number;

  // Équipements WC
  wcCuvetteBonneHauteur?: boolean;
  wcCuvetteTropBasse?: boolean;
  wcCuvetteHauteur?: number;
  wcBarreRelevement?: boolean;

  // Portes SDB
  porteSdbLargeurSuffisante?: boolean;
  porteSdbDimension?: number;
  porteSdbSensAdapte?: boolean;

  // Portes WC
  porteWcLargeurSuffisante?: boolean;
  porteWcDimension?: number;
  porteWcSensAdapte?: boolean;

  // Observation
  observationEquipementsUtilisation?: string;
}

// Mapped from 'mesures_anthropometriques' table (NEW)
export interface MesuresAnthropometriques {
  id?: string;
  dossierId?: string;
  deboutHauteurCoude?: number;
  assisHauteurAssise?: number;
  assisProfondeurGenoux?: number;
  assisHauteurCoudes?: number;
  observations?: string;
}

// Mapped from 'observations' table (NEW - Synthèse)
export interface ObservationsSynthese {
  id?: string;
  dossierId?: string;
  beneficiaireId?: string;
  observationEquipements?: string;
  projetSouhaitUsage?: string;
  resumePreconisations?: string;
}

export interface WorkItem {
  id: string;
  name: string;
  description: string;
  unit: string;
  priceHT: number;
  tva: number;
}

export interface SelectedWork extends WorkItem {
  quantity: number;
}

export interface FinancialPlan {
  id: string; // PF1, PF2, PF3
  works: SelectedWork[];
  grants: { source: string; amount: number }[];
}

export interface Dossier {
  id: string;
  patient: Patient;
  status: DossierStatus;
  ergoId: string;
  visitDate?: string;

  housing: Housing;

  // Medical Context (JSONB in dossiers.report_data)
  medicalContext?: {
    pathology?: string;
    followUp?: string;
    sensory?: string;
    heightCm?: string;
    weightKg?: string;
    sizeWeight?: string;
    occupants?: Array<{
      medical: {
        pathology?: string;
        followUp?: string;
        sensory?: string;
        heightCm?: string;
        weightKg?: string;
      };
      autonomyDone?: boolean;
      autonomy?: { name: string; checked: boolean }[];
      humanHelp?: { name: string; checked: boolean }[];
    }>;
  };

  // Autonomy Checklist (JSONB in dossiers.report_data)
  autonomy?: {
    done: boolean;
    checklist: { name: string; checked: boolean }[];
    humanHelp?: { name: string; checked: boolean }[];
    occupants?: Array<{
      medical: {
        pathology?: string;
        followUp?: string;
        sensory?: string;
        heightCm?: string;
        weightKg?: string;
      };
      autonomyDone?: boolean;
      autonomy?: { name: string; checked: boolean }[];
      humanHelp?: { name: string; checked: boolean }[];
    }>;
  };

  // Linked sub-entities (loaded on demand)
  diagnosticSanitaires?: DiagnosticSanitaires;
  mesuresAnthropometriques?: MesuresAnthropometriques;
  observationsSynthese?: ObservationsSynthese;

  // Admin fields (NEW)
  compteAnah?: string; // 'Déjà fait', 'A vérifier', 'A faire', 'Mandat'
  natureAccompagnement?: string; // 'Complet', 'Ergo'
  envoiRapport?: string; // 'Mail', 'Courrier'
  personnesPresentesVisite?: string; // 'Bénéficiaire', 'Famille', etc.

  autonomyNotes: string;
  plans: {
    PF1: FinancialPlan;
    PF2: FinancialPlan;
    PF3: FinancialPlan;
  };
  createdAt: string;
}

export interface Visit {
  id: string;
  dossierId: string;
  patientName: string;
  date: string;
  location: string;
  status: 'Done' | 'Upcoming';
}

export interface VisitReportLocation {
  activeTab: string;
  beneficiarySection: 'profile' | 'finance' | 'health' | 'admin';
  contextSection: 'medical' | 'autonomy';
  accessSection: 'general' | 'interior' | 'exterior' | 'shutters';
  bathroomSection: 'equipment' | 'door';
  wcSection: 'main' | 'door';
}

export type VisitReportSectionKey =
  | 'beneficiary'
  | 'context'
  | 'housing'
  | 'sanitaires'
  | 'measurements'
  | 'summary';

export type VisitReportSyncState =
  | 'local_only'
  | 'pending_sync'
  | 'synced'
  | 'sync_error';

export interface VisitReportBeneficiarySection {
  patient: Partial<Patient>;
  dossier: {
    compteAnah?: string;
    natureAccompagnement?: string;
    envoiRapport?: string;
    personnesPresentesVisite?: string;
    ergoId?: string;
    status?: DossierStatus;
    visitDate?: string;
  };
}

export interface VisitReportContextSection {
  medicalContext?: Dossier['medicalContext'];
  autonomy?: Dossier['autonomy'];
}

export interface VisitReportOfflineSections {
  beneficiary: VisitReportBeneficiarySection;
  context: VisitReportContextSection;
  housing: Partial<Housing>;
  sanitaires: Partial<DiagnosticSanitaires>;
  measurements: Partial<MesuresAnthropometriques>;
  summary: Partial<ObservationsSynthese>;
}

export interface VisitReportSectionRecord<TPayload = unknown> {
  sectionKey: VisitReportSectionKey;
  payload: TPayload;
  updatedAt: string;
  syncState: VisitReportSyncState;
  lastSyncedAt?: string;
  lastError?: string | null;
}

export interface VisitReportOfflineSnapshot {
  dossierId: string;
  patientId: string;
  updatedAt: string;
  sections: Partial<{
    [K in VisitReportSectionKey]: VisitReportSectionRecord<VisitReportOfflineSections[K]>;
  }>;
}

export interface VisitReportSyncOperation<TPayload = unknown> {
  id: string;
  dossierId: string;
  patientId: string;
  sectionKey: VisitReportSectionKey;
  entityKey: string;
  operation: 'upsert';
  payload: TPayload;
  status: 'pending' | 'processing' | 'failed';
  createdAt: string;
  updatedAt: string;
  attemptCount: number;
  lastError?: string | null;
}
