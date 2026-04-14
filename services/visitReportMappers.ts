import {
  DiagnosticSanitaires,
  Dossier,
  Housing,
  MesuresAnthropometriques,
  ObservationsSynthese,
  Patient,
  VisitReportBeneficiarySection,
  VisitReportContextSection,
  VisitReportOfflineSections,
  VisitReportSectionKey,
} from '../types';

const pickDefined = <T extends Record<string, unknown>>(value: T): Partial<T> => Object.fromEntries(
  Object.entries(value).filter(([, entry]) => entry !== undefined)
) as Partial<T>;

export const VISIT_REPORT_SECTION_KEYS: VisitReportSectionKey[] = [
  'beneficiary',
  'context',
  'housing',
  'sanitaires',
  'measurements',
  'summary',
];

export const buildVisitReportBeneficiarySection = (dossier: Dossier): VisitReportBeneficiarySection => ({
  patient: pickDefined<Partial<Patient>>({
    firstName: dossier.patient.firstName,
    lastName: dossier.patient.lastName,
    address: dossier.patient.address,
    city: dossier.patient.city,
    cityId: dossier.patient.cityId,
    zipCode: dossier.patient.zipCode,
    phone: dossier.patient.phone,
    email: dossier.patient.email,
    occupant1BirthDate: dossier.patient.occupant1BirthDate,
    occupant2BirthDate: dossier.patient.occupant2BirthDate,
    birthDateMr: dossier.patient.birthDateMr,
    birthDateMme: dossier.patient.birthDateMme,
    familySituation: dossier.patient.familySituation,
    occupationStatus: dossier.patient.occupationStatus,
    numberPeople: dossier.patient.numberPeople,
    fiscalRevenue: dossier.patient.fiscalRevenue,
    apa: dossier.patient.apa,
    invalidity: dossier.patient.invalidity,
    invalidityTxt: dossier.patient.invalidityTxt,
    homeHelp: dossier.patient.homeHelp,
    homeHelpTxt: dossier.patient.homeHelpTxt,
    dependenceTxt: dossier.patient.dependenceTxt,
    occupant1SocialSecurityNumber: dossier.patient.occupant1SocialSecurityNumber,
    occupant2SocialSecurityNumber: dossier.patient.occupant2SocialSecurityNumber,
    numeroSecuriteSocialeMonsieur: dossier.patient.numeroSecuriteSocialeMonsieur,
    numeroSecuriteSocialeMadame: dossier.patient.numeroSecuriteSocialeMadame,
    caisseRetraitePrincipale: dossier.patient.caisseRetraitePrincipale,
    caissesRetraiteComplementaires: dossier.patient.caissesRetraiteComplementaires,
    trustedPerson: dossier.patient.trustedPerson,
  }),
  dossier: pickDefined({
    compteAnah: dossier.compteAnah,
    natureAccompagnement: dossier.natureAccompagnement,
    envoiRapport: dossier.envoiRapport,
    personnesPresentesVisite: dossier.personnesPresentesVisite,
    ergoId: dossier.ergoId,
    status: dossier.status,
    visitDate: dossier.visitDate,
  }),
});

export const buildVisitReportContextSection = (dossier: Dossier): VisitReportContextSection => ({
  medicalContext: dossier.medicalContext ? { ...dossier.medicalContext } : undefined,
  autonomy: dossier.autonomy
    ? {
      done: Boolean(dossier.autonomy.done),
      checklist: (dossier.autonomy.checklist || []).map((item) => ({
        name: item.name,
        checked: Boolean(item.checked),
      })),
    }
    : undefined,
});

export const buildVisitReportHousingSection = (housing: Housing): Partial<Housing> => ({ ...housing });

export const buildVisitReportSanitairesSection = (
  sanitaires?: DiagnosticSanitaires,
): Partial<DiagnosticSanitaires> => ({ ...(sanitaires || {}) });

export const buildVisitReportMeasurementsSection = (
  measurements?: MesuresAnthropometriques,
): Partial<MesuresAnthropometriques> => ({ ...(measurements || {}) });

export const buildVisitReportSummarySection = (
  summary?: ObservationsSynthese,
): Partial<ObservationsSynthese> => ({ ...(summary || {}) });

export const buildVisitReportSectionsFromDossier = (dossier: Dossier): VisitReportOfflineSections => ({
  beneficiary: buildVisitReportBeneficiarySection(dossier),
  context: buildVisitReportContextSection(dossier),
  housing: buildVisitReportHousingSection(dossier.housing),
  sanitaires: buildVisitReportSanitairesSection(dossier.diagnosticSanitaires),
  measurements: buildVisitReportMeasurementsSection(dossier.mesuresAnthropometriques),
  summary: buildVisitReportSummarySection(dossier.observationsSynthese),
});
