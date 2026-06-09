import React, { useState, useEffect, useRef, useCallback, useMemo } from 'react';
import { AlertTriangle, ArrowLeft, Ban, Bath, Blinds, Check, CheckCircle, ChevronDown, ChevronLeft, ChevronRight, Coins, DoorOpen, FolderOpen, Hand, Heart, House, ImagePlus, LayoutGrid, MapPin, Plus, Search, ShowerHead, Toilet, Trash2, User, Zap } from 'lucide-react';
import { BathroomLevelInstance, Dossier, HeatingMode, DiagnosticSanitaires, MesuresAnthropometriques, NotePage, ObservationsSynthese, VisitRecommendationItem, VisitReportLocation, WikiLibraryItem, WcLevelInstance } from '../../../../types';
import { NotesCanvas, buildNotePreviewDataUrlFromContent, type DrawingTool } from '../../../shared/NotesCanvas';
import { CommuneFieldGroup, type CommuneOption } from '../../../shared/CommuneFieldGroup';
import { ViewportOverlay } from '../../../layout/ViewportOverlay';
import { cx, uiFieldClass, uiFieldWarningClass, uiLabelClass } from '../../../shared/uiTheme';
import wikiLibraryStatic from '../../../../data/wikiLibraryStatic.json';
import {
    fetchVisitRecommendations,
    updateDossier,
    updateBeneficiary as updateBeneficiaryService,
    updateHousing,
    createNotePage,
    deleteNotePage,
    fetchNotePages,
    fetchReferenceData,
    fetchRetirementFunds,
    fetchPrincipalRetirementFunds,
    fetchDiagnosticSanitaires,
    upsertDiagnosticSanitaires,
    fetchMesuresAnthropometriques,
    upsertMesuresAnthropometriques,
    fetchObservationsSynthese,
    fetchWikiLibrary,
    normalizeCityInput,
    saveNotePage,
    saveVisitRecommendations,
    upsertObservationsSynthese,
} from '../../../../services/dataService';

interface RefOption { id: string; label: string; establishmentId?: string; establishmentLabel?: string; }

interface VisitReportViewProps {
    dossier: Dossier;
    onBack: () => void;
    onUpdateDossier?: (d: Dossier) => void;
    onSavingChange?: (isSaving: boolean) => void;
    location?: VisitReportLocation;
    onLocationChange?: (location: VisitReportLocation) => void;
}

const TABS = [
    'Bénéficiaire', 'Contexte de vie', 'Mesures', 'Accessibilité', 'Salle de bain', 'WC', 'Préconisations', 'Synthèse', 'Plans'
];

const WIKI_FILTER_TAGS = [
    'Salle de bain',
    'WC',
    'Cuisine',
    'Chambre',
    'Escaliers & ascenseur',
    'Accès extérieurs',
    "Barres d'appui",
    'Ouvertures',
    'Equipements',
];

const STATIC_WIKI_ITEMS: WikiLibraryItem[] = (wikiLibraryStatic.items as WikiLibraryItem[])
    .slice()
    .sort((left, right) => left.title.localeCompare(right.title));
const MAX_WIKI_DESCRIPTIONS = 3;

const parseWikiDescriptions = (value: string): string[] => {
    const raw = String(value || '').trim();
    if (!raw) return [];
    if (raw.startsWith('[')) {
        try {
            const parsed = JSON.parse(raw);
            if (Array.isArray(parsed)) {
                return parsed
                    .map((entry) => String(entry || '').trim())
                    .filter(Boolean)
                    .slice(0, MAX_WIKI_DESCRIPTIONS);
            }
        } catch {
            // Legacy plain text fallback below.
        }
    }
    return [raw].slice(0, MAX_WIKI_DESCRIPTIONS);
};

const searchableWikiDescriptionText = (value: string): string => {
    const descriptions = parseWikiDescriptions(value);
    return descriptions.length > 0 ? descriptions.join(' ') : value;
};

const createDefaultVisitReportLocation = (): VisitReportLocation => ({
    activeTab: 'Bénéficiaire',
    beneficiarySection: 'profile',
    contextSection: 'medical',
    accessSection: 'general',
    bathroomSection: 'equipment',
    wcSection: 'main',
});

const normalizeVisitReportLocation = (location?: VisitReportLocation | null): VisitReportLocation => {
    const defaults = createDefaultVisitReportLocation();
    if (!location) return defaults;

    const activeTab = location.activeTab === 'Équipements lourds' || location.activeTab === 'Logement'
        ? 'Accessibilité'
        : location.activeTab === 'Observations'
            ? 'Synthèse'
            : (location.activeTab || defaults.activeTab);

    const accessSection = location.activeTab === 'Équipements lourds' || location.activeTab === 'Logement'
        ? defaults.accessSection
        : (location.accessSection || defaults.accessSection);

    return {
        ...defaults,
        ...location,
        activeTab,
        accessSection,
    };
};

const createEmptyRecommendationItem = (): VisitRecommendationItem => {
    const now = new Date().toISOString();
    return {
        id: `local-rec-${now}-${Math.random().toString(36).slice(2, 8)}`,
        wikiItemId: '',
        wikiTitle: '',
        wikiImageUrl: '',
        wikiTag: '',
        customTitle: '',
        note: '',
        createdAt: now,
        updatedAt: now,
    };
};

const findErgoOption = (ergos: RefOption[], ergoValue?: string) => {
    const normalized = String(ergoValue || '').trim().toLowerCase();
    if (!normalized) return undefined;
    return ergos.find((option) => option.label.trim().toLowerCase() === normalized);
};

const formatHouseholdSize = (value?: number) => {
    if (value == null) return '1';
    return value >= 5 ? '5+' : String(value);
};

const parseNamedOccupantCount = (value?: string | number) => {
    const raw = String(value ?? '').trim();
    if (raw === '5+') return 5;
    const parsed = Number.parseInt(raw, 10);
    if (Number.isFinite(parsed) && parsed > 0) return parsed;
    return 1;
};

const BENEFICIARY_NOTE_SUBTAB_LABELS: Record<VisitReportLocation['beneficiarySection'], string> = {
    profile: 'profile',
    finance: 'finance',
    health: 'health',
    admin: 'admin',
};

const CONTEXT_NOTE_SUBTAB_LABELS: Record<VisitReportLocation['contextSection'], string> = {
    medical: 'medical',
    autonomy: 'autonomy',
};

const ACCESS_NOTE_SUBTAB_LABELS: Record<VisitReportLocation['accessSection'], string> = {
    general: 'general',
    interior: 'interior',
    exterior: 'exterior',
    shutters: 'shutters',
};

const BATHROOM_NOTE_SUBTAB_LABELS: Record<VisitReportLocation['bathroomSection'], string> = {
    equipment: 'equipment',
    door: 'door',
};

const WC_NOTE_SUBTAB_LABELS: Record<VisitReportLocation['wcSection'], string> = {
    main: 'main',
    door: 'door',
};

const VISIT_NOTE_TAB_KEYS = {
    'Bénéficiaire': 'beneficiaire',
    'Contexte de vie': 'contexte_de_vie',
    'Accessibilité': 'accessibilite',
    'Salle de bain': 'salle_de_bain',
    'WC': 'wc',
    'Mesures': 'mesures',
    'Plans': 'plans',
    'Synthèse': 'synthese',
    'Préconisations': 'preconisations',
} as const;

const createEmptyOccupant = () => ({
    firstName: '',
    lastName: '',
    birthDate: '',
    apa: false,
    invalidity: false,
    invalidityTxt: '',
    homeHelp: false,
    homeHelpTxt: '',
    dependenceTxt: '',
    numeroSecuriteSociale: '',
    caisseRetraitePrincipale: '',
    caissesRetraiteComplementaires: '',
});

const normalizeOccupant = (value: any) => ({
    firstName: String(value?.firstName || ''),
    lastName: String(value?.lastName || ''),
    birthDate: String(value?.birthDate || '').trim(),
    apa: Boolean(value?.apa),
    invalidity: Boolean(value?.invalidity),
    invalidityTxt: String(value?.invalidityTxt || '').trim(),
    homeHelp: Boolean(value?.homeHelp),
    homeHelpTxt: String(value?.homeHelpTxt || '').trim(),
    dependenceTxt: String(value?.dependenceTxt || '').trim(),
    numeroSecuriteSociale: String(value?.numeroSecuriteSociale || '').trim(),
    caisseRetraitePrincipale: String(value?.caisseRetraitePrincipale || '').trim(),
    caissesRetraiteComplementaires: String(value?.caissesRetraiteComplementaires || '').trim(),
});

const buildOccupantsFromPatient = (patient: any, countOverride?: string | number) => {
    const fallbackOccupants = [
        normalizeOccupant({
            firstName: patient?.firstName,
            lastName: patient?.lastName,
            birthDate: patient?.occupant1BirthDate || patient?.birthDateMr,
            apa: patient?.apa,
            invalidity: patient?.invalidity,
            invalidityTxt: patient?.invalidityTxt,
            homeHelp: patient?.homeHelp,
            homeHelpTxt: patient?.homeHelpTxt,
            dependenceTxt: patient?.dependenceTxt,
            numeroSecuriteSociale: patient?.occupant1SocialSecurityNumber || patient?.numeroSecuriteSocialeMonsieur,
            caisseRetraitePrincipale: patient?.caisseRetraitePrincipale,
            caissesRetraiteComplementaires: patient?.caissesRetraiteComplementaires,
        }),
        ...((patient?.secondFirstName || patient?.secondLastName || patient?.occupant2BirthDate || patient?.birthDateMme || patient?.occupant2SocialSecurityNumber || patient?.numeroSecuriteSocialeMadame) ? [normalizeOccupant({
            firstName: patient?.secondFirstName,
            lastName: patient?.secondLastName,
            birthDate: patient?.occupant2BirthDate || patient?.birthDateMme,
            numeroSecuriteSociale: patient?.occupant2SocialSecurityNumber || patient?.numeroSecuriteSocialeMadame,
        })] : []),
    ];
    const existing = Array.isArray(patient?.occupants) && patient.occupants.length > 0
        ? patient.occupants.map((occupant: any, index: number) => normalizeOccupant({
            ...(fallbackOccupants[index] || createEmptyOccupant()),
            ...occupant,
        }))
        : fallbackOccupants;

    const targetCount = parseNamedOccupantCount(countOverride ?? patient?.numberPeople);
    const next = [...existing];
    while (next.length < targetCount) {
        next.push(createEmptyOccupant());
    }
    return next;
};

const buildBeneficiaryIdentityPayload = (beneficiary: any) => {
    const occupants = buildOccupantsFromPatient(beneficiary, beneficiary.numberPeople);
    const primaryOccupant = occupants[0] || createEmptyOccupant();
    const secondaryOccupant = occupants[1] || createEmptyOccupant();

    return {
        ...beneficiary,
        occupants,
        firstName: primaryOccupant.firstName,
        lastName: primaryOccupant.lastName,
        occupant1BirthDate: primaryOccupant.birthDate,
        birthDateMr: primaryOccupant.birthDate,
        secondFirstName: secondaryOccupant.firstName,
        secondLastName: secondaryOccupant.lastName,
        occupant2BirthDate: secondaryOccupant.birthDate,
        birthDateMme: secondaryOccupant.birthDate,
        apa: primaryOccupant.apa,
        invalidity: primaryOccupant.invalidity,
        invalidityTxt: primaryOccupant.invalidityTxt,
        homeHelp: primaryOccupant.homeHelp,
        homeHelpTxt: primaryOccupant.homeHelpTxt,
        dependenceTxt: primaryOccupant.dependenceTxt,
        occupant1SocialSecurityNumber: primaryOccupant.numeroSecuriteSociale,
        numeroSecuriteSocialeMonsieur: primaryOccupant.numeroSecuriteSociale,
        occupant2SocialSecurityNumber: secondaryOccupant.numeroSecuriteSociale,
        numeroSecuriteSocialeMadame: secondaryOccupant.numeroSecuriteSociale,
        caisseRetraitePrincipale: primaryOccupant.caisseRetraitePrincipale,
        caissesRetraiteComplementaires: primaryOccupant.caissesRetraiteComplementaires,
    };
};

const mergeOccupantDraftDetails = (incomingOccupants: any[], currentOccupants: any[]) => {
    const targetLength = Math.max(incomingOccupants.length, currentOccupants.length);
    return Array.from({ length: targetLength }, (_value, index) => {
        const incoming = normalizeOccupant(incomingOccupants[index] || createEmptyOccupant());
        const current = normalizeOccupant(currentOccupants[index] || createEmptyOccupant());
        return {
            ...incoming,
            invalidityTxt: incoming.invalidityTxt || current.invalidityTxt,
            homeHelpTxt: incoming.homeHelpTxt || current.homeHelpTxt,
            numeroSecuriteSociale: incoming.numeroSecuriteSociale || current.numeroSecuriteSociale,
            caisseRetraitePrincipale: incoming.caisseRetraitePrincipale || current.caisseRetraitePrincipale,
            caissesRetraiteComplementaires: incoming.caissesRetraiteComplementaires || current.caissesRetraiteComplementaires,
        };
    });
};

const serializeForAutosave = (value: unknown) => JSON.stringify(value);
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const isValidEmail = (value?: string) => {
    const normalized = String(value || '').trim();
    return normalized.length === 0 || EMAIL_PATTERN.test(normalized);
};

const isValidFrenchPhone = (value?: string) => {
    const digits = String(value || '').replace(/\D/g, '');
    if (digits.length === 0) return true;
    return /^0[1-9]\d{8}$/.test(digits) || /^33[1-9]\d{8}$/.test(digits);
};

const parseLegacySizeWeight = (sizeWeight?: string) => {
    const rawValue = String(sizeWeight || '');
    const normalized = rawValue.replace(',', '.');
    const heightMatch = normalized.match(/(\d+(?:\.\d+)?)\s*cm/i);
    const weightMatch = normalized.match(/(\d+(?:\.\d+)?)\s*kg/i);

    return {
        heightCm: heightMatch?.[1] || '',
        weightKg: weightMatch?.[1] || '',
    };
};

const HOUSEHOLD_OPTIONS: RefOption[] = [
    { id: '1', label: '1' },
    { id: '2', label: '2' },
    { id: '3', label: '3' },
    { id: '4', label: '4' },
    { id: '5+', label: '5+' },
];

const ANAH_ACCOUNT_OPTIONS: RefOption[] = [
    { id: 'done', label: 'Déjà fait' },
    { id: 'review', label: 'A vérifier' },
    { id: 'todo', label: 'A faire' },
    { id: 'mandate', label: 'Mandat' },
];

const LEVEL_COUNT_OPTIONS: RefOption[] = [
    { id: '1', label: '1' },
    { id: '2', label: '2' },
    { id: '3', label: '3' },
    { id: '4', label: '4' },
    { id: '5', label: '5' },
];

type MultiFieldOption = {
    field: string;
    label: string;
    roomsField?: string;
    roomOptions?: string[];
};

const ACCESS_LEVEL_OPTIONS: MultiFieldOption[] = [
    { field: 'basement', label: 'Sous-sol', roomsField: 'basementRooms', roomOptions: ['Salle de bain', 'WC'] },
    { field: 'rdc', label: 'RDC', roomsField: 'rdcRooms', roomOptions: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'] },
    { field: 'floor', label: '1er étage', roomsField: 'floorRooms', roomOptions: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'] },
    { field: 'secondFloor', label: '2e étage', roomsField: 'secondFloorRooms', roomOptions: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'] },
    { field: 'thirdFloor', label: '3e étage', roomsField: 'thirdFloorRooms', roomOptions: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'] },
];

const UPPER_FLOOR_STORAGE_PREFIX = '__upper_floors__:';

const parseChecklistString = (value?: string) => (
    String(value || '')
        .split(',')
        .map((entry) => entry.trim())
        .filter(Boolean)
);

const parseUpperFloorSelections = (value?: string) => {
    const normalized = String(value || '').trim();
    if (!normalized) {
        return { floorRooms: [] as string[], secondFloorRooms: [] as string[], thirdFloorRooms: [] as string[] };
    }

    if (normalized.startsWith(UPPER_FLOOR_STORAGE_PREFIX)) {
        try {
            const parsed = JSON.parse(normalized.slice(UPPER_FLOOR_STORAGE_PREFIX.length));
            return {
                floorRooms: Array.isArray(parsed?.floorRooms) ? parsed.floorRooms.filter(Boolean) : [],
                secondFloorRooms: Array.isArray(parsed?.secondFloorRooms) ? parsed.secondFloorRooms.filter(Boolean) : [],
                thirdFloorRooms: Array.isArray(parsed?.thirdFloorRooms) ? parsed.thirdFloorRooms.filter(Boolean) : [],
            };
        } catch {
            return { floorRooms: [], secondFloorRooms: [], thirdFloorRooms: [] };
        }
    }

    return {
        floorRooms: parseChecklistString(normalized),
        secondFloorRooms: [],
        thirdFloorRooms: [],
    };
};

const serializeChecklistString = (values: string[] = []) => values.filter(Boolean).join(', ');

const buildSanitaryLevelSelections = (housing: any, targetRoom: string) => (
    ACCESS_LEVEL_OPTIONS
        .filter((option) => {
            const values = Array.isArray(housing?.[option.roomsField as string]) ? housing[option.roomsField as string] : [];
            return values.includes(targetRoom);
        })
        .map((option) => ({ field: option.field, label: option.label }))
);

const createEmptyBathroomInstance = (levelField: string, levelLabel: string): BathroomLevelInstance => ({
    id: `sdb-${levelField}`,
    levelField,
    levelLabel,
    sdbBaignoire: false,
    sdbBaignoireHauteur: undefined,
    sdbBacDouche: false,
    sdbBacDoucheHauteur: undefined,
    sdbVasqueSuspendue: false,
    sdbVasqueSuspendueHauteur: undefined,
    sdbVasqueColonne: false,
    sdbVasqueColonneHauteur: undefined,
    sdbMeubleVasque: false,
    sdbMeubleVasqueHauteur: undefined,
    sdbBidet: false,
    sdbBidetHauteur: undefined,
    sdbParoiDouche: false,
    sdbParoiDoucheHauteur: undefined,
    sdbSolGlissant: false,
    sdbMachineALaver: false,
    sdbMachineALaverHauteur: undefined,
    porteSdbLargeurSuffisante: false,
    porteSdbDimension: undefined,
    porteSdbSensAdapte: false,
});

const createEmptyWcInstance = (levelField: string, levelLabel: string): WcLevelInstance => ({
    id: `wc-${levelField}`,
    levelField,
    levelLabel,
    wcCuvetteBonneHauteur: false,
    wcCuvetteTropBasse: false,
    wcCuvetteHauteur: undefined,
    wcBarreRelevement: false,
    porteWcLargeurSuffisante: false,
    porteWcDimension: undefined,
    porteWcSensAdapte: false,
    observationEquipementsUtilisation: '',
});

const createLegacyBathroomInstance = (source: DiagnosticSanitaires, levelField: string, levelLabel: string): BathroomLevelInstance => ({
    ...createEmptyBathroomInstance(levelField, levelLabel),
    sdbBaignoire: Boolean(source.sdbBaignoire),
    sdbBaignoireHauteur: source.sdbBaignoireHauteur,
    sdbBacDouche: Boolean(source.sdbBacDouche),
    sdbBacDoucheHauteur: source.sdbBacDoucheHauteur,
    sdbVasqueSuspendue: Boolean(source.sdbVasqueSuspendue),
    sdbVasqueSuspendueHauteur: source.sdbVasqueSuspendueHauteur,
    sdbVasqueColonne: Boolean(source.sdbVasqueColonne),
    sdbVasqueColonneHauteur: source.sdbVasqueColonneHauteur,
    sdbMeubleVasque: Boolean(source.sdbMeubleVasque),
    sdbMeubleVasqueHauteur: source.sdbMeubleVasqueHauteur,
    sdbBidet: Boolean(source.sdbBidet),
    sdbBidetHauteur: source.sdbBidetHauteur,
    sdbParoiDouche: Boolean(source.sdbParoiDouche),
    sdbParoiDoucheHauteur: source.sdbParoiDoucheHauteur,
    sdbSolGlissant: Boolean(source.sdbSolGlissant),
    sdbMachineALaver: Boolean(source.sdbMachineALaver),
    sdbMachineALaverHauteur: source.sdbMachineALaverHauteur,
    porteSdbLargeurSuffisante: Boolean(source.porteSdbLargeurSuffisante),
    porteSdbDimension: source.porteSdbDimension,
    porteSdbSensAdapte: Boolean(source.porteSdbSensAdapte),
});

const createLegacyWcInstance = (source: DiagnosticSanitaires, levelField: string, levelLabel: string): WcLevelInstance => ({
    ...createEmptyWcInstance(levelField, levelLabel),
    wcCuvetteBonneHauteur: Boolean(source.wcCuvetteBonneHauteur),
    wcCuvetteTropBasse: Boolean(source.wcCuvetteTropBasse),
    wcCuvetteHauteur: source.wcCuvetteHauteur,
    wcBarreRelevement: Boolean(source.wcBarreRelevement),
    porteWcLargeurSuffisante: Boolean(source.porteWcLargeurSuffisante),
    porteWcDimension: source.porteWcDimension,
    porteWcSensAdapte: Boolean(source.porteWcSensAdapte),
    observationEquipementsUtilisation: source.observationEquipementsUtilisation || '',
});

const normalizeSanitairesForHousing = (sanitaires: DiagnosticSanitaires, housing: any): DiagnosticSanitaires => {
    const bathroomLevels = buildSanitaryLevelSelections(housing, 'Salle de bain');
    const wcLevels = buildSanitaryLevelSelections(housing, 'WC');
    const currentBathroomInstances = Array.isArray(sanitaires.sdbInstances) ? sanitaires.sdbInstances : [];
    const currentWcInstances = Array.isArray(sanitaires.wcInstances) ? sanitaires.wcInstances : [];

    const nextBathroomInstances = bathroomLevels.map((level, index) => {
        const existing = currentBathroomInstances.find((instance) => instance.levelField === level.field);
        if (existing) {
            return { ...existing, levelField: level.field, levelLabel: level.label };
        }
        if (currentBathroomInstances.length === 0 && index === 0) {
            return createLegacyBathroomInstance(sanitaires, level.field, level.label);
        }
        return createEmptyBathroomInstance(level.field, level.label);
    });

    const nextWcInstances = wcLevels.map((level, index) => {
        const existing = currentWcInstances.find((instance) => instance.levelField === level.field);
        if (existing) {
            return { ...existing, levelField: level.field, levelLabel: level.label };
        }
        if (currentWcInstances.length === 0 && index === 0) {
            return createLegacyWcInstance(sanitaires, level.field, level.label);
        }
        return createEmptyWcInstance(level.field, level.label);
    });

    const firstBathroom = nextBathroomInstances[0];
    const firstWc = nextWcInstances[0];

    return {
        ...sanitaires,
        sdbInstances: nextBathroomInstances,
        wcInstances: nextWcInstances,
        sdbNiveauPiecesVie: firstBathroom ? firstBathroom.levelField === 'rdc' : sanitaires.sdbNiveauPiecesVie,
        wcNiveau: firstWc ? firstWc.levelField === 'rdc' : sanitaires.wcNiveau,
        wcEtage: firstWc ? firstWc.levelField !== 'rdc' : sanitaires.wcEtage,
    };
};

const serializeUpperFloorSelections = ({
    floorRooms,
    secondFloorRooms,
    thirdFloorRooms,
}: {
    floorRooms: string[];
    secondFloorRooms: string[];
    thirdFloorRooms: string[];
}) => {
    const normalized = {
        floorRooms: floorRooms.filter(Boolean),
        secondFloorRooms: secondFloorRooms.filter(Boolean),
        thirdFloorRooms: thirdFloorRooms.filter(Boolean),
    };

    if (normalized.secondFloorRooms.length === 0 && normalized.thirdFloorRooms.length === 0) {
        return serializeChecklistString(normalized.floorRooms);
    }

    if (normalized.floorRooms.length === 0 && normalized.secondFloorRooms.length === 0 && normalized.thirdFloorRooms.length === 0) {
        return '';
    }

    return `${UPPER_FLOOR_STORAGE_PREFIX}${JSON.stringify(normalized)}`;
};

const toggleChecklistValue = (values: string[] = [], target: string, checked: boolean) => {
    if (checked) {
        return values.includes(target) ? values : [...values, target];
    }
    return values.filter((value) => value !== target);
};

const buildHousingPayload = (housing: any) => {
    const {
        basementRooms = [],
        rdcRooms = [],
        floorRooms = [],
        secondFloorRooms = [],
        thirdFloorRooms = [],
        secondFloor,
        thirdFloor,
        ...rest
    } = housing;

    return {
        ...rest,
        basementDesc: serializeChecklistString(basementRooms),
        rdcDesc: serializeChecklistString(rdcRooms),
        floorDesc: serializeUpperFloorSelections({ floorRooms, secondFloorRooms, thirdFloorRooms }),
    };
};

const ACCESS_PATH_OPTIONS: MultiFieldOption[] = [
    { field: 'cheminementPlat', label: 'Cheminement plat' },
    { field: 'cheminementPenteDouce', label: 'Pente douce' },
    { field: 'cheminementQuelquesMarches', label: 'Quelques marches' },
    { field: 'cheminementEscalierExterieur', label: 'Escalier extérieur' },
    { field: 'cheminementEscalierInterieur', label: 'Escalier intérieur' },
    { field: 'cheminementSeuilPorte', label: 'Seuil de porte' },
    { field: 'cheminementParArriere', label: "Accès par l'arrière" },
];

const ANNEX_OPTIONS: MultiFieldOption[] = [
    { field: 'garage', label: 'Garage' },
    { field: 'veranda', label: 'Véranda' },
    { field: 'balcon', label: 'Balcon' },
    { field: 'terrasse', label: 'Terrasse' },
    { field: 'jardin', label: 'Jardin' },
];

const HEATING_OPTIONS: MultiFieldOption[] = [
    { field: 'electric', label: 'Électrique' },
    { field: 'gas', label: 'Gaz' },
    { field: 'oil', label: 'Fioul' },
    { field: 'heatPump', label: 'PAC' },
    { field: 'wood', label: 'Bois' },
    { field: 'pellet', label: 'Granulés' },
    { field: 'collective', label: 'Collectif' },
    { field: 'other', label: 'Autre' },
];

const AUTONOMY_DEFAULT_ITEMS = [
    "Déplacements/transferts",
    "Escaliers",
    "Conduite automobile",
    "Transports en commun",
    "Toilette/habillage",
    "Continence",
    "Repas (y compris courses)",
    "Tâches ménagères.domestiques",
    "Démarches admin",
    "Cognition",
    "Communication",
];

const buildAutonomyItems = (items?: Array<{ name: string; checked: boolean }>) => AUTONOMY_DEFAULT_ITEMS.map((name) => {
    const existing = items?.find((item) => item.name === name);
    return {
        name,
        label: name === 'Tâches ménagères.domestiques' ? 'Tâches ménagères' : name,
        checked: Boolean(existing?.checked),
    };
});

const formatOccupantLabel = (occupant: any, index: number) => {
    const firstName = String(occupant?.firstName || '').trim();
    const lastName = String(occupant?.lastName || '').trim();
    const fullName = [firstName, lastName].filter(Boolean).join(' ').trim();
    if (fullName) {
        return fullName;
    }
    const fallbackLetter = String.fromCharCode(65 + (index % 26));
    return `Profil ${fallbackLetter}`;
};

const formatOccupantBadgeLabel = (occupant: any, index: number) => {
    const firstName = String(occupant?.firstName || '').trim();
    if (firstName) {
        return `(${firstName})`;
    }
    const fallbackLetter = String.fromCharCode(65 + (index % 26));
    return `(Profil ${fallbackLetter})`;
};

const formatOccupantSwitcherLabel = (occupant: any, index: number) => {
    const firstName = String(occupant?.firstName || '').trim();
    if (firstName) {
        return firstName;
    }
    const fallbackLetter = String.fromCharCode(65 + (index % 26));
    return `Profil ${fallbackLetter}`;
};

const computeAgeFromBirthDate = (birthDate?: string) => {
    const raw = String(birthDate || '').trim();
    if (!raw) return '';
    const date = new Date(raw);
    if (Number.isNaN(date.getTime())) return '';

    const now = new Date();
    let age = now.getFullYear() - date.getFullYear();
    const monthDelta = now.getMonth() - date.getMonth();
    const dayDelta = now.getDate() - date.getDate();
    if (monthDelta < 0 || (monthDelta === 0 && dayDelta < 0)) {
        age -= 1;
    }

    return age >= 0 ? `${age} ans` : '';
};

const buildToggleOptions = (options: RefOption[], currentValue?: string, emptyLabel?: string) => {
    const labels = options.map((option) => option.label).filter(Boolean);
    const current = String(currentValue || '').trim();
    if (current && !labels.includes(current)) {
        labels.push(current);
    }
    if (emptyLabel) {
        return [emptyLabel, ...labels];
    }
    return labels;
};

const parseComplementaryFundNames = (value?: string) => (
    String(value || '')
        .split(',')
        .map((entry) => entry.trim())
        .filter(Boolean)
);

const parseHumanHelpItems = (rawValue?: string) => {
    const normalized = String(rawValue || '').toLowerCase();
    return AUTONOMY_DEFAULT_ITEMS.map((name) => ({
        name,
        checked: normalized.includes(name.toLowerCase()),
    }));
};

const serializeHumanHelpItems = (items: Array<{ name: string; checked: boolean }>) => (
    items.filter((item) => item.checked).map((item) => item.name).join(', ')
);

const createEmptyMedicalValues = () => ({
    pathology: '',
    followUp: '',
    sensory: '',
    heightCm: '',
    weightKg: '',
});

const normalizeMedicalValues = (value: any) => ({
    pathology: String(value?.pathology || '').trim(),
    followUp: String(value?.followUp || '').trim(),
    sensory: String(value?.sensory || '').trim(),
    heightCm: String(value?.heightCm || '').trim(),
    weightKg: String(value?.weightKg || '').trim(),
});

const createEmptyContextOccupant = (homeHelpTxt = '') => ({
    medical: createEmptyMedicalValues(),
    autonomyDone: false,
    autonomy: buildAutonomyItems(),
    humanHelp: parseHumanHelpItems(homeHelpTxt),
});

const buildContextOccupants = (context: any, beneficiary: any) => {
    const beneficiaryOccupants = buildOccupantsFromPatient(beneficiary, beneficiary?.numberPeople);
    const targetCount = parseNamedOccupantCount(beneficiary?.numberPeople);
    const fallbackPrimary = {
        medical: normalizeMedicalValues(context?.medical),
        autonomyDone: Boolean(context?.autonomyDone),
        autonomy: buildAutonomyItems(context?.autonomy),
        humanHelp: Array.isArray(context?.humanHelp) ? context.humanHelp : parseHumanHelpItems(beneficiaryOccupants[0]?.homeHelpTxt || ''),
    };
    const existing = Array.isArray(context?.occupants) && context.occupants.length > 0
        ? context.occupants
        : [fallbackPrimary];

    const next = existing.map((entry: any, index: number) => ({
        medical: normalizeMedicalValues(entry?.medical || (index === 0 ? context?.medical : undefined)),
        autonomyDone: Boolean(entry?.autonomyDone ?? (index === 0 ? context?.autonomyDone : false)),
        autonomy: buildAutonomyItems(entry?.autonomy || (index === 0 ? context?.autonomy : undefined)),
        humanHelp: Array.isArray(entry?.humanHelp)
            ? entry.humanHelp.map((item: any, itemIndex: number) => ({
                name: AUTONOMY_DEFAULT_ITEMS[itemIndex] || String(item?.name || ''),
                checked: Boolean(item?.checked),
            }))
            : parseHumanHelpItems(beneficiaryOccupants[index]?.homeHelpTxt || ''),
    }));

    while (next.length < targetCount) {
        next.push(createEmptyContextOccupant(beneficiaryOccupants[next.length]?.homeHelpTxt || ''));
    }

    return next.slice(0, targetCount);
};

const buildContextPayload = (context: any, beneficiary: any) => {
    const occupants = buildContextOccupants(context, beneficiary);
    const primary = occupants[0] || createEmptyContextOccupant();
    return {
        ...context,
        medical: primary.medical,
        autonomyDone: primary.autonomyDone,
        autonomy: primary.autonomy,
        humanHelp: primary.humanHelp,
        occupants,
    };
};

const BATHROOM_MEASURED_EQUIPMENT = [
    { enabledField: 'sdbBaignoire', heightField: 'sdbBaignoireHauteur', label: 'Hauteur baignoire', requires: 'bath' },
    { enabledField: 'sdbBacDouche', heightField: 'sdbBacDoucheHauteur', label: 'Hauteur bac à douche', requires: 'shower' },
    { enabledField: 'sdbParoiDouche', heightField: 'sdbParoiDoucheHauteur', label: 'Hauteur paroi de douche', requires: 'shower' },
    { enabledField: 'sdbVasqueSuspendue', heightField: 'sdbVasqueSuspendueHauteur', label: 'Hauteur vasque suspendue', requires: 'always' },
    { enabledField: 'sdbVasqueColonne', heightField: 'sdbVasqueColonneHauteur', label: 'Hauteur vasque sur colonne', requires: 'always' },
    { enabledField: 'sdbMeubleVasque', heightField: 'sdbMeubleVasqueHauteur', label: 'Hauteur meuble vasque', requires: 'always' },
    { enabledField: 'sdbBidet', heightField: 'sdbBidetHauteur', label: 'Hauteur bidet', requires: 'always' },
    { enabledField: 'sdbMachineALaver', heightField: 'sdbMachineALaverHauteur', label: 'Hauteur machine à laver', requires: 'always' },
] as const;

const WC_LOCATION_OPTIONS: RefOption[] = [
    { id: 'wc-level', label: 'WC à niveau' },
    { id: 'wc-upstairs', label: "WC à l'étage" },
];

const BATHROOM_LOCATION_OPTIONS: RefOption[] = [
    { id: 'bathroom-level', label: 'Salle de bain à niveau' },
    { id: 'bathroom-upstairs', label: "Salle de bain à l'étage" },
];

const EMPTY_DRAWING_JSON = JSON.stringify({ version: 1, strokes: [] });

// =============================================================
// Save Status Indicator Hook
// =============================================================
type SaveStatus = 'idle' | 'saving' | 'saved' | 'error';

function useSaveStatus() {
    const [status, setStatus] = useState<SaveStatus>('idle');
    const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

    const markSaving = useCallback(() => {
        if (timeoutRef.current) clearTimeout(timeoutRef.current);
        setStatus('saving');
    }, []);

    const markSaved = useCallback(() => {
        setStatus('saved');
        if (timeoutRef.current) clearTimeout(timeoutRef.current);
        timeoutRef.current = setTimeout(() => setStatus('idle'), 2500);
    }, []);

    const markError = useCallback(() => {
        setStatus('error');
        if (timeoutRef.current) clearTimeout(timeoutRef.current);
        timeoutRef.current = setTimeout(() => setStatus('idle'), 4000);
    }, []);

    return { status, markSaving, markSaved, markError };
}

// Hook for debouncing
function useDebounce<T>(value: T, delay: number): T {
    const [debouncedValue, setDebouncedValue] = useState(value);
    useEffect(() => {
        const handler = setTimeout(() => setDebouncedValue(value), delay);
        return () => clearTimeout(handler);
    }, [value, delay]);
    return debouncedValue;
}

const BENEFICIARY_SYNC_DEBOUNCE_MS = 5000;
const CONTEXT_SYNC_DEBOUNCE_MS = 5000;
const HOUSING_SYNC_DEBOUNCE_MS = 5000;
const RELEVE_BLOCK_SYNC_DEBOUNCE_MS = 5000;
const NOTE_DRAFT_SYNC_DEBOUNCE_MS = 5000;

// =============================================================
// Main Component
// =============================================================
export const VisitReportView: React.FC<VisitReportViewProps> = ({ dossier, onBack, onUpdateDossier, onSavingChange, location, onLocationChange }) => {
    const resolvedLocation = normalizeVisitReportLocation(location);
    const initialUpperFloorSelections = parseUpperFloorSelections(dossier.housing.floorDesc);
    const [activeTab, setActiveTab] = useState(resolvedLocation.activeTab);
    const [activeBeneficiarySection, setActiveBeneficiarySection] = useState<VisitReportLocation['beneficiarySection']>(resolvedLocation.beneficiarySection);
    const [activeContextSection, setActiveContextSection] = useState<VisitReportLocation['contextSection']>(resolvedLocation.contextSection);
    const [activeAccessSection, setActiveAccessSection] = useState<VisitReportLocation['accessSection']>(resolvedLocation.accessSection);
    const [activeBathroomSection, setActiveBathroomSection] = useState<VisitReportLocation['bathroomSection']>(resolvedLocation.bathroomSection);
    const [activeWcSection, setActiveWcSection] = useState<VisitReportLocation['wcSection']>(resolvedLocation.wcSection);
    const dossierRef = useRef(dossier);
    const onUpdateDossierRef = useRef(onUpdateDossier);
    const [fiscalRevenueDraft, setFiscalRevenueDraft] = useState(dossier.patient.fiscalRevenue?.toString() || '');
    const [isEditingFiscalRevenue, setIsEditingFiscalRevenue] = useState(false);

    useEffect(() => {
        dossierRef.current = dossier;
    }, [dossier]);

    useEffect(() => {
        onUpdateDossierRef.current = onUpdateDossier;
    }, [onUpdateDossier]);

    useEffect(() => {
        const nextLocation = normalizeVisitReportLocation(location);
        setActiveTab(nextLocation.activeTab);
        setActiveBeneficiarySection(nextLocation.beneficiarySection);
        setActiveContextSection(nextLocation.contextSection);
        setActiveAccessSection(nextLocation.accessSection);
        setActiveBathroomSection(nextLocation.bathroomSection);
        setActiveWcSection(nextLocation.wcSection);
    }, [dossier.id]);

    useEffect(() => {
        onLocationChange?.({
            activeTab,
            beneficiarySection: activeBeneficiarySection,
            contextSection: activeContextSection,
            accessSection: activeAccessSection,
            bathroomSection: activeBathroomSection,
            wcSection: activeWcSection,
        });
    }, [
        activeAccessSection,
        activeBathroomSection,
        activeBeneficiarySection,
        activeContextSection,
        activeTab,
        activeWcSection,
        onLocationChange,
    ]);

    // --- Reference tables from API ---
    const [refSituations, setRefSituations] = useState<RefOption[]>([]);
    const [refDependances, setRefDependances] = useState<RefOption[]>([]);
    const [refPorteGarage, setRefPorteGarage] = useState<RefOption[]>([]);
    const [refPortail, setRefPortail] = useState<RefOption[]>([]);
    const [refErgos, setRefErgos] = useState<RefOption[]>([]);
    const [refEtablissements, setRefEtablissements] = useState<RefOption[]>([]);
    const [refCommunes, setRefCommunes] = useState<CommuneOption[]>([]);
    const [retirementFundOptions, setRetirementFundOptions] = useState<string[]>([]);
    const [principalRetirementFundOptions, setPrincipalRetirementFundOptions] = useState<string[]>([]);
    const [wikiLibraryItems, setWikiLibraryItems] = useState<WikiLibraryItem[]>(STATIC_WIKI_ITEMS);
    const isAutosaveReadyRef = useRef(false);
    const beneficiarySnapshotRef = useRef<string | null>(null);
    const contextSnapshotRef = useRef<string | null>(null);
    const housingSnapshotRef = useRef<string | null>(null);
    const sanitairesSnapshotRef = useRef<string | null>(null);
    const mesuresSnapshotRef = useRef<string | null>(null);
    const syntheseSnapshotRef = useRef<string | null>(null);
    const recommendationsSnapshotRef = useRef<string | null>(null);
    const tabsScrollRef = useRef<HTMLDivElement | null>(null);
    const tabButtonRefs = useRef<Record<string, HTMLButtonElement | null>>({});
    const [canScrollTabsLeft, setCanScrollTabsLeft] = useState(false);
    const [canScrollTabsRight, setCanScrollTabsRight] = useState(false);
    const [plansActiveTool, setPlansActiveTool] = useState<DrawingTool>('pen');
    const initialBeneficiaryState = {
        ...buildBeneficiaryIdentityPayload({
            firstName: dossier.patient.firstName || '',
            lastName: dossier.patient.lastName || '',
            secondFirstName: dossier.patient.secondFirstName || '',
            secondLastName: dossier.patient.secondLastName || '',
            occupant1BirthDate: dossier.patient.occupant1BirthDate || dossier.patient.birthDateMr || '',
            occupant2BirthDate: dossier.patient.occupant2BirthDate || dossier.patient.birthDateMme || '',
            occupants: dossier.patient.occupants || [],
            numberPeople: formatHouseholdSize(dossier.patient.numberPeople),
        }),
        address: dossier.patient.address || '',
        city: normalizeCityInput(dossier.patient.city),
        cityId: dossier.patient.cityId || '',
        zipCode: dossier.patient.zipCode || '',
        phone: dossier.patient.phone || '',
        email: dossier.patient.email || '',
        familySituation: dossier.patient.familySituation || '',
        occupationStatus: dossier.patient.occupationStatus || 'Propriétaire',
        numberPeople: formatHouseholdSize(dossier.patient.numberPeople),
        incomeCategory: dossier.patient.incomeCategory || 'Modeste',
        fiscalRevenue: dossier.patient.fiscalRevenue?.toString() || '',
        apa: dossier.patient.apa,
        invalidity: dossier.patient.invalidity,
        invalidityTxt: dossier.patient.invalidityTxt || '',
        homeHelp: dossier.patient.homeHelp,
        homeHelpTxt: dossier.patient.homeHelpTxt || '',
        dependenceTxt: dossier.patient.dependenceTxt || '',
        trustedName: dossier.patient.trustedPerson?.name || '',
        trustedPhone: dossier.patient.trustedPerson?.phone || '',
        trustedEmail: dossier.patient.trustedPerson?.email || '',
        occupant1SocialSecurityNumber: dossier.patient.occupant1SocialSecurityNumber || dossier.patient.numeroSecuriteSocialeMonsieur || '',
        occupant2SocialSecurityNumber: dossier.patient.occupant2SocialSecurityNumber || dossier.patient.numeroSecuriteSocialeMadame || '',
        numeroSecuriteSocialeMonsieur: dossier.patient.occupant1SocialSecurityNumber || dossier.patient.numeroSecuriteSocialeMonsieur || '',
        numeroSecuriteSocialeMadame: dossier.patient.occupant2SocialSecurityNumber || dossier.patient.numeroSecuriteSocialeMadame || '',
        caisseRetraitePrincipale: dossier.patient.caisseRetraitePrincipale || '',
        caissesRetraiteComplementaires: dossier.patient.caissesRetraiteComplementaires || '',
        compteAnah: dossier.compteAnah || 'A faire',
        natureAccompagnement: dossier.natureAccompagnement || 'Complet',
        envoiRapport: dossier.envoiRapport || 'Mail',
        personnesPresentesVisite: dossier.personnesPresentesVisite || '',
        ergoId: dossier.ergoId || '',
        etablissementId: '',
    };
    const initialContextState = buildContextPayload({
        medical: (() => {
            const medicalContext = dossier.medicalContext || {};
            const legacyMetrics = parseLegacySizeWeight(medicalContext.sizeWeight);
            return {
                pathology: medicalContext.pathology || '',
                followUp: medicalContext.followUp || '',
                sensory: medicalContext.sensory || '',
                heightCm: medicalContext.heightCm || legacyMetrics.heightCm,
                weightKg: medicalContext.weightKg || legacyMetrics.weightKg,
            };
        })(),
        autonomyDone: dossier.autonomy?.done || false,
        autonomy: buildAutonomyItems(dossier.autonomy?.checklist),
        humanHelp: parseHumanHelpItems(dossier.patient.homeHelpTxt),
        occupants: dossier.medicalContext?.occupants || dossier.autonomy?.occupants || [],
    }, initialBeneficiaryState);

    useEffect(() => {
        const load = async () => {
            const refs = await fetchReferenceData();
            setRefSituations(refs.situations);
            setRefDependances(refs.dependances);
            setRefPorteGarage(refs.porteGarage);
            setRefPortail(refs.portail);
            setRefErgos(refs.ergos);
            setRefEtablissements(refs.etablissements);
            setRefCommunes(refs.communes || []);
            try {
                const funds = await fetchRetirementFunds();
                setRetirementFundOptions(
                    funds
                        .map((fund) => String(fund.name || '').trim())
                        .filter(Boolean)
                        .sort((left, right) => left.localeCompare(right)),
                );
            } catch (error) {
                console.error('Failed to load retirement funds', error);
                setRetirementFundOptions([]);
            }
            try {
                const principalFunds = await fetchPrincipalRetirementFunds();
                setPrincipalRetirementFundOptions(
                    principalFunds
                        .map((fund) => String(fund.name || '').trim())
                        .filter(Boolean)
                        .sort((left, right) => left.localeCompare(right)),
                );
            } catch (error) {
                console.error('Failed to load principal retirement funds', error);
                setPrincipalRetirementFundOptions([]);
            }
            const wikiItems = await fetchWikiLibrary();
            if (wikiItems.length > 0) {
                setWikiLibraryItems(wikiItems);
            } else {
                setWikiLibraryItems(STATIC_WIKI_ITEMS);
            }
        };
        load().catch((error) => {
            console.error('Failed to load reference data from API', error);
            setWikiLibraryItems(STATIC_WIKI_ITEMS);
        });
    }, []);

    useEffect(() => {
        setFormData((prev) => {
            const ergo = findErgoOption(refErgos, prev.beneficiary.ergoId);
            const nextEtablissement = ergo?.establishmentLabel || '';
            if (prev.beneficiary.etablissementId === nextEtablissement) {
                return prev;
            }
            return {
                ...prev,
                beneficiary: {
                    ...prev.beneficiary,
                    etablissementId: nextEtablissement,
                }
            };
        });
    }, [refErgos]);

    // --- Notes State ---
    const [activeTabNotePages, setActiveTabNotePages] = useState<NotePage[]>([]);
    const [notePagesCache, setNotePagesCache] = useState<Record<string, NotePage[]>>({});
    const [currentLocalPage, setCurrentLocalPage] = useState<number>(0);
    const [notePageMemory, setNotePageMemory] = useState<Record<string, number>>({});
    const [isMutatingPages, setIsMutatingPages] = useState(false);
    const isMutatingPagesRef = useRef(false);
    const [noteDraft, setNoteDraft] = useState<{ text: string; drawingJson: string; isDirty: boolean; noteKey: string }>({
        text: '',
        drawingJson: '',
        isDirty: false,
        noteKey: '',
    });
    const noteRequestKeyRef = useRef('');
    const notePagesCacheRef = useRef<Record<string, NotePage[]>>({});
    const notePageMemoryRef = useRef<Record<string, number>>({});
    const pendingPageSelectionRef = useRef<{ cacheKey: string; pageNumber: number } | null>(null);
    const currentTextNotePagesRef = useRef<NotePage[]>([]);
    const noteSaveChainRef = useRef<Promise<void>>(Promise.resolve());
    const setPageMutationState = useCallback((next: boolean) => {
        isMutatingPagesRef.current = next;
        setIsMutatingPages(next);
    }, []);

    // --- Data Forms State ---
    const [formData, setFormData] = useState({
        beneficiary: initialBeneficiaryState,
        context: initialContextState,
        housing: {
            yearConstruction: dossier.housing.yearConstruction || '',
            yearHabitation: dossier.housing.yearHabitation || '',
            surface: dossier.housing.surface || '',
            levels: dossier.housing.levels?.toString() || '1',
            typology: dossier.housing.typology || 'Maison',
            easyAccess: dossier.housing.easyAccess,
            accessObservation: dossier.housing.accessObservation || '',
            basement: dossier.housing.basement,
            basementDesc: dossier.housing.basementDesc || '',
            basementRooms: parseChecklistString(dossier.housing.basementDesc),
            rdc: dossier.housing.rdc,
            rdcDesc: dossier.housing.rdcDesc || '',
            rdcRooms: parseChecklistString(dossier.housing.rdcDesc),
            floor: dossier.housing.floor,
            floorDesc: dossier.housing.floorDesc || '',
            floorRooms: initialUpperFloorSelections.floorRooms,
            secondFloor: initialUpperFloorSelections.secondFloorRooms.length > 0,
            secondFloorRooms: initialUpperFloorSelections.secondFloorRooms,
            thirdFloor: initialUpperFloorSelections.thirdFloorRooms.length > 0,
            thirdFloorRooms: initialUpperFloorSelections.thirdFloorRooms,
            garage: dossier.housing.garage,
            veranda: dossier.housing.veranda,
            balcon: dossier.housing.balcon,
            terrasse: dossier.housing.terrasse,
            jardin: dossier.housing.jardin,
            heatingMain: dossier.housing.heatingMain,
            heatingDetails: dossier.housing.heatingDetails || {
                electric: false, gas: false, oil: false, heatPump: false,
                collective: false, wood: false, pellet: false, other: false
            },
            voletsRoulantsManuelsLocalisation: dossier.housing.voletsRoulantsManuelsLocalisation || '',
            voletsRoulantsManuelsEntier: dossier.housing.voletsRoulantsManuelsEntier || false,
            voletsRoulantsElectriquesLocalisation: dossier.housing.voletsRoulantsElectriquesLocalisation || '',
            voletsRoulantsElectriquesEntier: dossier.housing.voletsRoulantsElectriquesEntier || false,
            voletsPersiennesLocalisation: dossier.housing.voletsPersiennesLocalisation || '',
            voletsPersiennesEntier: dossier.housing.voletsPersiennesEntier || false,
            cheminementEscalierExterieur: dossier.housing.cheminementEscalierExterieur || false,
            cheminementEscalierInterieur: dossier.housing.cheminementEscalierInterieur || false,
            cheminementPenteDouce: dossier.housing.cheminementPenteDouce || false,
            cheminementPlat: dossier.housing.cheminementPlat || false,
            cheminementQuelquesMarches: dossier.housing.cheminementQuelquesMarches || false,
            cheminementParArriere: dossier.housing.cheminementParArriere || false,
            cheminementSeuilPorte: dossier.housing.cheminementSeuilPorte || false,
            difficultesCirculationInterieure: dossier.housing.difficultesCirculationInterieure || false,
            motorisationPorteGarage: dossier.housing.motorisationPorteGarage || '',
            motorisationPortail: dossier.housing.motorisationPortail || '',
        }
    });
    const liveBeneficiarySnapshotRef = useRef(
        serializeForAutosave(buildBeneficiaryIdentityPayload(initialBeneficiaryState)),
    );

    useEffect(() => {
        liveBeneficiarySnapshotRef.current = serializeForAutosave(
            buildBeneficiaryIdentityPayload(formData.beneficiary),
        );
    }, [formData.beneficiary]);

    useEffect(() => {
        setFormData((prev) => {
            const ergo = findErgoOption(refErgos, dossier.ergoId || prev.beneficiary.ergoId);
            const fallbackEtablissement = ergo?.establishmentLabel
                || (dossier.ergoId === 'Coralie' || dossier.ergoId === 'Christelle' ? "Aid'habitat" : '');
            const mergedOccupants = mergeOccupantDraftDetails(
                buildOccupantsFromPatient({
                    firstName: dossier.patient.firstName || '',
                    lastName: dossier.patient.lastName || '',
                    secondFirstName: dossier.patient.secondFirstName || '',
                    secondLastName: dossier.patient.secondLastName || '',
                    birthDateMr: dossier.patient.birthDateMr || '',
                    birthDateMme: dossier.patient.birthDateMme || '',
                    occupants: dossier.patient.occupants || [],
                    numberPeople: formatHouseholdSize(dossier.patient.numberPeople),
                    apa: dossier.patient.apa,
                    invalidity: dossier.patient.invalidity,
                    invalidityTxt: dossier.patient.invalidityTxt || '',
                    homeHelp: dossier.patient.homeHelp,
                    homeHelpTxt: dossier.patient.homeHelpTxt || '',
                    dependenceTxt: dossier.patient.dependenceTxt || '',
                    numeroSecuriteSocialeMonsieur: dossier.patient.numeroSecuriteSocialeMonsieur || '',
                    numeroSecuriteSocialeMadame: dossier.patient.numeroSecuriteSocialeMadame || '',
                    caisseRetraitePrincipale: dossier.patient.caisseRetraitePrincipale || '',
                    caissesRetraiteComplementaires: dossier.patient.caissesRetraiteComplementaires || '',
                }, formatHouseholdSize(dossier.patient.numberPeople)),
                buildOccupantsFromPatient(prev.beneficiary, prev.beneficiary.numberPeople),
            );
            const nextBeneficiary = {
                ...prev.beneficiary,
                ...buildBeneficiaryIdentityPayload({
                    firstName: dossier.patient.firstName || '',
                    lastName: dossier.patient.lastName || '',
                    secondFirstName: dossier.patient.secondFirstName || '',
                    secondLastName: dossier.patient.secondLastName || '',
                    occupant1BirthDate: dossier.patient.occupant1BirthDate || dossier.patient.birthDateMr || '',
                    occupant2BirthDate: dossier.patient.occupant2BirthDate || dossier.patient.birthDateMme || '',
                    occupants: mergedOccupants,
                    numberPeople: formatHouseholdSize(dossier.patient.numberPeople),
                }),
                address: dossier.patient.address || '',
                city: normalizeCityInput(dossier.patient.city),
                cityId: dossier.patient.cityId || '',
                zipCode: dossier.patient.zipCode || '',
                phone: dossier.patient.phone || '',
                email: dossier.patient.email || '',
                familySituation: dossier.patient.familySituation || '',
                occupationStatus: dossier.patient.occupationStatus || 'Propriétaire',
                numberPeople: formatHouseholdSize(dossier.patient.numberPeople),
                incomeCategory: dossier.patient.incomeCategory || 'Modeste',
                fiscalRevenue: dossier.patient.fiscalRevenue?.toString() || '',
                apa: dossier.patient.apa,
                invalidity: dossier.patient.invalidity,
                invalidityTxt: dossier.patient.invalidityTxt || '',
                homeHelp: dossier.patient.homeHelp,
                homeHelpTxt: dossier.patient.homeHelpTxt || '',
                dependenceTxt: dossier.patient.dependenceTxt || '',
                trustedName: dossier.patient.trustedPerson?.name || '',
                trustedPhone: dossier.patient.trustedPerson?.phone || '',
                trustedEmail: dossier.patient.trustedPerson?.email || '',
                occupant1SocialSecurityNumber: dossier.patient.occupant1SocialSecurityNumber || dossier.patient.numeroSecuriteSocialeMonsieur || '',
                occupant2SocialSecurityNumber: dossier.patient.occupant2SocialSecurityNumber || dossier.patient.numeroSecuriteSocialeMadame || '',
                numeroSecuriteSocialeMonsieur: dossier.patient.occupant1SocialSecurityNumber || dossier.patient.numeroSecuriteSocialeMonsieur || '',
                numeroSecuriteSocialeMadame: dossier.patient.occupant2SocialSecurityNumber || dossier.patient.numeroSecuriteSocialeMadame || '',
                caisseRetraitePrincipale: dossier.patient.caisseRetraitePrincipale || '',
                caissesRetraiteComplementaires: dossier.patient.caissesRetraiteComplementaires || '',
                compteAnah: dossier.compteAnah || 'A faire',
                natureAccompagnement: dossier.natureAccompagnement || 'Complet',
                envoiRapport: dossier.envoiRapport || 'Mail',
                personnesPresentesVisite: dossier.personnesPresentesVisite || '',
                ergoId: dossier.ergoId || '',
                etablissementId: fallbackEtablissement,
            };

            const occupantsUnchanged = JSON.stringify(prev.beneficiary.occupants || []) === JSON.stringify(nextBeneficiary.occupants || []);
            const unchanged = Object.entries(nextBeneficiary).every(([key, value]) => {
                if (key === 'occupants') {
                    return occupantsUnchanged;
                }
                return prev.beneficiary[key as keyof typeof nextBeneficiary] === value;
            });
            if (unchanged) {
                return prev;
            }

            return {
                ...prev,
                beneficiary: nextBeneficiary,
            };
        });
    }, [
        dossier.compteAnah,
        dossier.envoiRapport,
        dossier.ergoId,
        dossier.natureAccompagnement,
        dossier.patient.address,
        dossier.patient.apa,
        dossier.patient.birthDateMme,
        dossier.patient.birthDateMr,
        dossier.patient.caissesRetraiteComplementaires,
        dossier.patient.caisseRetraitePrincipale,
        dossier.patient.city,
        dossier.patient.cityId,
        dossier.patient.dependenceTxt,
        dossier.patient.email,
        dossier.patient.familySituation,
        dossier.patient.firstName,
        dossier.patient.occupants,
        dossier.patient.fiscalRevenue,
        dossier.patient.homeHelp,
        dossier.patient.homeHelpTxt,
        dossier.patient.incomeCategory,
        dossier.patient.invalidity,
        dossier.patient.invalidityTxt,
        dossier.patient.lastName,
        dossier.patient.numberPeople,
        dossier.patient.numeroSecuriteSocialeMadame,
        dossier.patient.numeroSecuriteSocialeMonsieur,
        dossier.patient.occupationStatus,
        dossier.patient.phone,
        dossier.patient.trustedPerson?.email,
        dossier.patient.trustedPerson?.name,
        dossier.patient.trustedPerson?.phone,
        dossier.patient.zipCode,
        dossier.personnesPresentesVisite,
        refErgos,
    ]);

    useEffect(() => {
        if (isEditingFiscalRevenue) return;
        setFiscalRevenueDraft(formData.beneficiary.fiscalRevenue);
    }, [formData.beneficiary.fiscalRevenue, isEditingFiscalRevenue]);

    useEffect(() => {
        setFormData((prev) => {
            const normalizedBeneficiary = buildBeneficiaryIdentityPayload(prev.beneficiary);
            if (
                JSON.stringify(prev.beneficiary.occupants || []) === JSON.stringify(normalizedBeneficiary.occupants || [])
                && prev.beneficiary.firstName === normalizedBeneficiary.firstName
                && prev.beneficiary.lastName === normalizedBeneficiary.lastName
                && prev.beneficiary.secondFirstName === normalizedBeneficiary.secondFirstName
                && prev.beneficiary.secondLastName === normalizedBeneficiary.secondLastName
                && prev.beneficiary.birthDateMr === normalizedBeneficiary.birthDateMr
                && prev.beneficiary.birthDateMme === normalizedBeneficiary.birthDateMme
            ) {
                return prev;
            }

            return {
                ...prev,
                beneficiary: {
                    ...prev.beneficiary,
                    ...normalizedBeneficiary,
                },
            };
        });
    }, [formData.beneficiary.numberPeople]);

    useEffect(() => {
        setFormData((prev) => {
            const normalizedContext = buildContextPayload(prev.context, prev.beneficiary);
            if (serializeForAutosave(normalizedContext) === serializeForAutosave(prev.context)) {
                return prev;
            }
            return {
                ...prev,
                context: normalizedContext,
            };
        });
    }, [formData.beneficiary.numberPeople, formData.beneficiary.occupants]);

    // --- Sanitaires / Mesures / Synthese State ---
    const [sanitairesData, setSanitairesData] = useState<DiagnosticSanitaires>({
        sdbInstances: [],
        wcInstances: [],
        sdbNiveauPiecesVie: false, wcNiveau: false, wcEtage: false,
        sdbBaignoire: false, sdbBaignoireHauteur: undefined, sdbBacDouche: false, sdbBacDoucheHauteur: undefined,
        sdbVasqueSuspendue: false, sdbVasqueSuspendueHauteur: undefined,
        sdbVasqueColonne: false, sdbVasqueColonneHauteur: undefined,
        sdbMeubleVasque: false, sdbMeubleVasqueHauteur: undefined,
        sdbBidet: false, sdbBidetHauteur: undefined,
        sdbParoiDouche: false, sdbParoiDoucheHauteur: undefined,
        sdbSolGlissant: false,
        sdbMachineALaver: false, sdbMachineALaverHauteur: undefined,
        wcCuvetteBonneHauteur: false, wcCuvetteTropBasse: false, wcCuvetteHauteur: undefined, wcBarreRelevement: false,
        porteSdbLargeurSuffisante: false, porteSdbDimension: undefined, porteSdbSensAdapte: false,
        porteWcLargeurSuffisante: false, porteWcDimension: undefined, porteWcSensAdapte: false,
        observationEquipementsUtilisation: ''
    });

    const [mesuresData, setMesuresData] = useState<MesuresAnthropometriques>({
        deboutHauteurCoude: undefined, assisHauteurAssise: undefined,
        assisProfondeurGenoux: undefined, assisHauteurCoudes: undefined, observations: ''
    });

    const [syntheseData, setSyntheseData] = useState<ObservationsSynthese>({
        observationEquipements: '', projetSouhaitUsage: '', resumePreconisations: ''
    });

    const [recommendationsData, setRecommendationsData] = useState<VisitRecommendationItem[]>([]);

    // --- Load sub-entities (Sanitaires, Mesures, Synthese) on mount ---
    useEffect(() => {
        const loadSubEntities = async () => {
            if (dossier.id.startsWith('temp-')) return;
            const [san, mes, obs, recommendations] = await Promise.all([
                fetchDiagnosticSanitaires(dossier.id),
                fetchMesuresAnthropometriques(dossier.id),
                fetchObservationsSynthese(dossier.id, dossier.patient.id),
                fetchVisitRecommendations(dossier.id),
            ]);
            if (san) setSanitairesData(normalizeSanitairesForHousing(san, formData.housing));
            if (mes) setMesuresData(mes);
            if (obs) setSyntheseData(obs);
            setRecommendationsData(recommendations);
        };
        loadSubEntities()
            .catch((error) => {
                console.error('Failed to load visit sub-entities', error);
            });
    }, [dossier.id, dossier.patient.id]);

    useEffect(() => {
        setSanitairesData((previous) => {
            const next = normalizeSanitairesForHousing(previous, formData.housing);
            return serializeForAutosave(previous) === serializeForAutosave(next) ? previous : next;
        });
    }, [formData.housing]);

    // =============================================================
    // AUTO-SAVE with Status Indicator
    // =============================================================
    const debouncedBeneficiary = useDebounce(formData.beneficiary, BENEFICIARY_SYNC_DEBOUNCE_MS);
    const debouncedContext = useDebounce(formData.context, CONTEXT_SYNC_DEBOUNCE_MS);
    const debouncedHousing = useDebounce(formData.housing, HOUSING_SYNC_DEBOUNCE_MS);
    const debouncedSanitaires = useDebounce(sanitairesData, RELEVE_BLOCK_SYNC_DEBOUNCE_MS);
    const debouncedMesures = useDebounce(mesuresData, RELEVE_BLOCK_SYNC_DEBOUNCE_MS);
    const debouncedSynthese = useDebounce(syntheseData, RELEVE_BLOCK_SYNC_DEBOUNCE_MS);
    const debouncedRecommendations = useDebounce(recommendationsData, RELEVE_BLOCK_SYNC_DEBOUNCE_MS);

    const pendingSavesRef = useRef(new Map<string, {
        label: string;
        task: () => Promise<{ success: boolean; error: string | null }>;
        version: number;
        inFlight: boolean;
        resolves: Array<(value: { success: boolean; error: string | null }) => void>;
        rejects: Array<(reason?: unknown) => void>;
    }>());
    const activeTabNotePagesRef = useRef<NotePage[]>([]);

    const drainSaveQueue = useCallback(async (key: string) => {
        const entry = pendingSavesRef.current.get(key);
        if (!entry || entry.inFlight) return;

        entry.inFlight = true;
        try {
            while (true) {
                const current = pendingSavesRef.current.get(key);
                if (!current) break;
                const targetVersion = current.version;
                const saveTask = current.task;
                const saveLabel = current.label;
                const resolves = current.resolves;
                const rejects = current.rejects;
                current.resolves = [];
                current.rejects = [];

                try {
                    const result = await saveTask();
                    if (!result.success) {
                        console.error(`✗ ${saveLabel} error:`, result.error);
                    }
                    resolves.forEach((resolve) => resolve(result));
                } catch (error) {
                    console.error(`✗ ${saveLabel} failed:`, error);
                    rejects.forEach((reject) => reject(error));
                }

                const latest = pendingSavesRef.current.get(key);
                if (!latest || latest.version === targetVersion) {
                    break;
                }
            }
        } finally {
            const latest = pendingSavesRef.current.get(key);
            if (latest) {
                latest.inFlight = false;
                if (latest.resolves.length === 0 && latest.rejects.length === 0) {
                    pendingSavesRef.current.delete(key);
                } else {
                    void drainSaveQueue(key);
                }
            }
        }
    }, []);

    // --- Helper: queue saves and keep only the latest payload per block ---
    const runSave = useCallback(<T extends { success: boolean; error: string | null }>(
        key: string,
        saveFn: () => Promise<T>,
        label: string,
    ): Promise<T> => {
        return new Promise<T>((resolve, reject) => {
            const existing = pendingSavesRef.current.get(key);
            if (existing) {
                existing.label = label;
                existing.task = saveFn as () => Promise<{ success: boolean; error: string | null }>;
                existing.version += 1;
                existing.resolves.push(resolve as (value: { success: boolean; error: string | null }) => void);
                existing.rejects.push(reject);
            } else {
                pendingSavesRef.current.set(key, {
                    label,
                    task: saveFn as () => Promise<{ success: boolean; error: string | null }>,
                    version: 1,
                    inFlight: false,
                    resolves: [resolve as (value: { success: boolean; error: string | null }) => void],
                    rejects: [reject],
                });
            }
            void drainSaveQueue(key);
        });
    }, [drainSaveQueue]);

    const flushActiveTabSaves = useCallback(() => {
        if (activeTab === 'Bénéficiaire' || activeTab === 'Contexte de vie') {
            const phoneIsValid = isValidFrenchPhone(formData.beneficiary.phone);
            const emailIsValid = isValidEmail(formData.beneficiary.email);
            const trustedPhoneIsValid = isValidFrenchPhone(formData.beneficiary.trustedPhone);
            const trustedEmailIsValid = isValidEmail(formData.beneficiary.trustedEmail);
            const normalizedBeneficiary = buildBeneficiaryIdentityPayload(formData.beneficiary);
            void runSave('beneficiary', async () => {
                const [beneficiaryResult] = await Promise.all([
                    updateBeneficiaryService(dossier.patient.id, {
                        firstName: normalizedBeneficiary.firstName, lastName: normalizedBeneficiary.lastName,
                        secondFirstName: normalizedBeneficiary.secondFirstName, secondLastName: normalizedBeneficiary.secondLastName,
                        occupant1BirthDate: normalizedBeneficiary.occupant1BirthDate,
                        occupant2BirthDate: normalizedBeneficiary.occupant2BirthDate,
                        birthDateMr: normalizedBeneficiary.birthDateMr, birthDateMme: normalizedBeneficiary.birthDateMme,
                        occupants: normalizedBeneficiary.occupants,
                        address: normalizedBeneficiary.address, city: normalizedBeneficiary.city,
                        cityId: normalizedBeneficiary.cityId,
                        zipCode: normalizedBeneficiary.zipCode,
                        phone: phoneIsValid ? normalizedBeneficiary.phone : undefined,
                        email: emailIsValid ? normalizedBeneficiary.email : undefined,
                        familySituation: normalizedBeneficiary.familySituation,
                        occupationStatus: normalizedBeneficiary.occupationStatus,
                        numberPeople: parseInt(normalizedBeneficiary.numberPeople) || 1,
                        fiscalRevenue: parseFloat(normalizedBeneficiary.fiscalRevenue) || 0,
                        apa: normalizedBeneficiary.apa, invalidity: normalizedBeneficiary.invalidity,
                        invalidityTxt: normalizedBeneficiary.invalidityTxt, homeHelp: normalizedBeneficiary.homeHelp,
                        homeHelpTxt: normalizedBeneficiary.homeHelpTxt, dependenceTxt: normalizedBeneficiary.dependenceTxt,
                        occupant1SocialSecurityNumber: normalizedBeneficiary.occupant1SocialSecurityNumber,
                        occupant2SocialSecurityNumber: normalizedBeneficiary.occupant2SocialSecurityNumber,
                        numeroSecuriteSocialeMonsieur: normalizedBeneficiary.numeroSecuriteSocialeMonsieur,
                        numeroSecuriteSocialeMadame: normalizedBeneficiary.numeroSecuriteSocialeMadame,
                        caisseRetraitePrincipale: normalizedBeneficiary.caisseRetraitePrincipale,
                        caissesRetraiteComplementaires: normalizedBeneficiary.caissesRetraiteComplementaires,
                        trustedPerson: {
                            name: normalizedBeneficiary.trustedName,
                            phone: trustedPhoneIsValid ? normalizedBeneficiary.trustedPhone : undefined,
                            email: trustedEmailIsValid ? normalizedBeneficiary.trustedEmail : undefined,
                        },
                    }, { immediate: true }),
                    updateDossier(dossier.id, {
                        compteAnah: normalizedBeneficiary.compteAnah,
                        natureAccompagnement: normalizedBeneficiary.natureAccompagnement,
                        envoiRapport: normalizedBeneficiary.envoiRapport,
                        personnesPresentesVisite: normalizedBeneficiary.personnesPresentesVisite,
                        ergoId: normalizedBeneficiary.ergoId,
                    }, { immediate: true }),
                ]);
                if (beneficiaryResult.success && beneficiaryResult.data?.patient) {
                    const refreshedPatient = beneficiaryResult.data.patient;
                    beneficiarySnapshotRef.current = serializeForAutosave(formData.beneficiary);
                    setFormData((prev) => {
                        const mergedOccupants = buildOccupantsFromPatient({ ...prev.beneficiary, occupants: refreshedPatient.occupants || [] }, prev.beneficiary.numberPeople);
                        return {
                            ...prev,
                            beneficiary: {
                                ...prev.beneficiary,
                                incomeCategory: refreshedPatient.incomeCategory || prev.beneficiary.incomeCategory,
                                numberPeople: formatHouseholdSize(refreshedPatient.numberPeople),
                                fiscalRevenue: refreshedPatient.fiscalRevenue != null ? String(refreshedPatient.fiscalRevenue) : prev.beneficiary.fiscalRevenue,
                                occupants: mergedOccupants,
                            },
                        };
                    });
                }
                return beneficiaryResult;
            }, 'Bénéficiaire').catch(() => undefined);
        }
        if (activeTab === 'Contexte de vie') {
            void runSave('context', async () => updateDossier(dossier.id, {
                medicalContext: formData.context.medical,
                autonomy: {
                    done: formData.context.autonomyDone,
                    checklist: formData.context.autonomy,
                    humanHelp: formData.context.humanHelp,
                    occupants: formData.context.occupants,
                }
            }, { immediate: true }), 'Contexte → dossiers (jsonb)').then(() => {
                contextSnapshotRef.current = serializeForAutosave(formData.context);
            }).catch(() => undefined);
        }
        if (activeTab === 'Accessibilité') {
            void runSave('housing', async () => updateHousing(dossier.patient.id, dossier.housing.id, buildHousingPayload(formData.housing), { immediate: true }), 'Logement → logements')
                .then(() => { housingSnapshotRef.current = serializeForAutosave(formData.housing); })
                .catch(() => undefined);
        }
        if (activeTab === 'Salle de bain' || activeTab === 'WC') {
            void runSave('sanitaires', async () => upsertDiagnosticSanitaires(dossier.id, sanitairesData), 'Sanitaires → diagnostic_sanitaires')
                .then(() => { sanitairesSnapshotRef.current = serializeForAutosave(sanitairesData); })
                .catch(() => undefined);
        }
        if (activeTab === 'Mesures') {
            void runSave('mesures', async () => upsertMesuresAnthropometriques(dossier.id, mesuresData), 'Mesures → mesures_anthropometriques')
                .then(() => { mesuresSnapshotRef.current = serializeForAutosave(mesuresData); })
                .catch(() => undefined);
        }
        if (activeTab === 'Synthèse') {
            void runSave('synthese', async () => upsertObservationsSynthese(dossier.id, dossier.patient.id, syntheseData), 'Synthèse → observations')
                .then(() => { syntheseSnapshotRef.current = serializeForAutosave(syntheseData); })
                .catch(() => undefined);
        }
        if (activeTab === 'Préconisations') {
            void runSave('recommendations', async () => saveVisitRecommendations(dossier.id, recommendationsData), 'Préconisations')
                .then(() => { recommendationsSnapshotRef.current = serializeForAutosave(recommendationsData); })
                .catch(() => undefined);
        }
    }, [activeTab, formData, sanitairesData, mesuresData, syntheseData, recommendationsData, dossier, runSave]);

    // Save Beneficiary (includes occupation status, APA, etc.)
    useEffect(() => {
        if (!isAutosaveReadyRef.current) return;
        const phoneIsValid = isValidFrenchPhone(debouncedBeneficiary.phone);
        const emailIsValid = isValidEmail(debouncedBeneficiary.email);
        const trustedPhoneIsValid = isValidFrenchPhone(debouncedBeneficiary.trustedPhone);
        const trustedEmailIsValid = isValidEmail(debouncedBeneficiary.trustedEmail);
        const beneficiarySnapshot = serializeForAutosave(debouncedBeneficiary);
        if (beneficiarySnapshotRef.current === null) {
            beneficiarySnapshotRef.current = beneficiarySnapshot;
            return;
        }
        if (beneficiarySnapshotRef.current === beneficiarySnapshot) return;
        const syncBeneficiary = async () => {
            const normalizedBeneficiary = buildBeneficiaryIdentityPayload(debouncedBeneficiary);
            const requestedBeneficiarySnapshot = serializeForAutosave(normalizedBeneficiary);
            const result = await runSave('beneficiary', async () => {
                const [beneficiaryResult, dossierInfoResult] = await Promise.all([
                    updateBeneficiaryService(dossier.patient.id, {
                        firstName: normalizedBeneficiary.firstName, lastName: normalizedBeneficiary.lastName,
                        secondFirstName: normalizedBeneficiary.secondFirstName, secondLastName: normalizedBeneficiary.secondLastName,
                        occupant1BirthDate: normalizedBeneficiary.occupant1BirthDate,
                        occupant2BirthDate: normalizedBeneficiary.occupant2BirthDate,
                        birthDateMr: normalizedBeneficiary.birthDateMr, birthDateMme: normalizedBeneficiary.birthDateMme,
                        occupants: normalizedBeneficiary.occupants,
                        address: normalizedBeneficiary.address, city: normalizedBeneficiary.city,
                        cityId: normalizedBeneficiary.cityId,
                        zipCode: normalizedBeneficiary.zipCode,
                        phone: phoneIsValid ? normalizedBeneficiary.phone : undefined,
                        email: emailIsValid ? normalizedBeneficiary.email : undefined,
                        familySituation: normalizedBeneficiary.familySituation,
                        occupationStatus: normalizedBeneficiary.occupationStatus,
                        numberPeople: parseInt(normalizedBeneficiary.numberPeople) || 1,
                        fiscalRevenue: parseFloat(normalizedBeneficiary.fiscalRevenue) || 0,
                        apa: normalizedBeneficiary.apa, invalidity: normalizedBeneficiary.invalidity,
                        invalidityTxt: normalizedBeneficiary.invalidityTxt, homeHelp: normalizedBeneficiary.homeHelp,
                        homeHelpTxt: normalizedBeneficiary.homeHelpTxt, dependenceTxt: normalizedBeneficiary.dependenceTxt,
                        occupant1SocialSecurityNumber: normalizedBeneficiary.occupant1SocialSecurityNumber,
                        occupant2SocialSecurityNumber: normalizedBeneficiary.occupant2SocialSecurityNumber,
                        numeroSecuriteSocialeMonsieur: normalizedBeneficiary.numeroSecuriteSocialeMonsieur,
                        numeroSecuriteSocialeMadame: normalizedBeneficiary.numeroSecuriteSocialeMadame,
                        caisseRetraitePrincipale: normalizedBeneficiary.caisseRetraitePrincipale,
                        caissesRetraiteComplementaires: normalizedBeneficiary.caissesRetraiteComplementaires,
                        trustedPerson: {
                            name: normalizedBeneficiary.trustedName,
                            phone: trustedPhoneIsValid ? normalizedBeneficiary.trustedPhone : undefined,
                            email: trustedEmailIsValid ? normalizedBeneficiary.trustedEmail : undefined,
                        }
                    }),
                    updateDossier(dossier.id, {
                        compteAnah: normalizedBeneficiary.compteAnah,
                        natureAccompagnement: normalizedBeneficiary.natureAccompagnement,
                        envoiRapport: normalizedBeneficiary.envoiRapport,
                        personnesPresentesVisite: normalizedBeneficiary.personnesPresentesVisite,
                        ergoId: normalizedBeneficiary.ergoId,
                    }),
                ]);

                if (!beneficiaryResult.success) {
                    return { success: false, error: beneficiaryResult.error };
                }
                if (!dossierInfoResult.success) {
                    return { success: false, error: dossierInfoResult.error };
                }

                const refreshedPatient = beneficiaryResult.data?.patient;
                const resolvedCity = normalizeCityInput(refreshedPatient?.city ?? normalizedBeneficiary.city);
                const resolvedCityId = String(refreshedPatient?.cityId ?? normalizedBeneficiary.cityId ?? '');
                const resolvedZipCode = String(refreshedPatient?.zipCode ?? normalizedBeneficiary.zipCode ?? '');
                const nextBeneficiarySnapshot = serializeForAutosave({
                    ...normalizedBeneficiary,
                    ...buildBeneficiaryIdentityPayload({
                        ...normalizedBeneficiary,
                        occupants: refreshedPatient?.occupants || normalizedBeneficiary.occupants,
                        firstName: refreshedPatient?.firstName || normalizedBeneficiary.firstName,
                        lastName: refreshedPatient?.lastName || normalizedBeneficiary.lastName,
                        secondFirstName: refreshedPatient?.secondFirstName || normalizedBeneficiary.secondFirstName,
                        secondLastName: refreshedPatient?.secondLastName || normalizedBeneficiary.secondLastName,
                        birthDateMr: refreshedPatient?.birthDateMr || normalizedBeneficiary.birthDateMr,
                        birthDateMme: refreshedPatient?.birthDateMme || normalizedBeneficiary.birthDateMme,
                        numberPeople: formatHouseholdSize(refreshedPatient?.numberPeople ?? (parseInt(normalizedBeneficiary.numberPeople) || 1)),
                    }),
                    address: refreshedPatient?.address || normalizedBeneficiary.address,
                    city: resolvedCity,
                    cityId: resolvedCityId,
                    zipCode: resolvedZipCode,
                    phone: refreshedPatient?.phone || normalizedBeneficiary.phone,
                    email: refreshedPatient?.email || normalizedBeneficiary.email,
                    familySituation: refreshedPatient?.familySituation || normalizedBeneficiary.familySituation,
                    occupationStatus: refreshedPatient?.occupationStatus || normalizedBeneficiary.occupationStatus,
                    incomeCategory: refreshedPatient?.incomeCategory || normalizedBeneficiary.incomeCategory,
                    numberPeople: formatHouseholdSize(refreshedPatient?.numberPeople ?? (parseInt(normalizedBeneficiary.numberPeople) || 1)),
                    fiscalRevenue: refreshedPatient?.fiscalRevenue != null ? String(refreshedPatient.fiscalRevenue) : normalizedBeneficiary.fiscalRevenue,
                });

                const isStalePayload = liveBeneficiarySnapshotRef.current !== requestedBeneficiarySnapshot;
                if (isStalePayload) {
                    beneficiarySnapshotRef.current = requestedBeneficiarySnapshot;
                    return { success: true, error: null };
                }

                if (refreshedPatient) {
                    setFormData((prev) => {
                        if (
                            prev.beneficiary.incomeCategory === (refreshedPatient.incomeCategory || '')
                            && prev.beneficiary.numberPeople === String(refreshedPatient.numberPeople ?? '')
                            && prev.beneficiary.fiscalRevenue === String(refreshedPatient.fiscalRevenue ?? '')
                        ) {
                            return prev;
                        }
                        return {
                            ...prev,
                            beneficiary: {
                                ...prev.beneficiary,
                                incomeCategory: refreshedPatient.incomeCategory || prev.beneficiary.incomeCategory,
                                numberPeople: formatHouseholdSize(refreshedPatient.numberPeople),
                                fiscalRevenue: refreshedPatient.fiscalRevenue != null ? String(refreshedPatient.fiscalRevenue) : prev.beneficiary.fiscalRevenue,
                            },
                        };
                    });
                }

                beneficiarySnapshotRef.current = nextBeneficiarySnapshot;

                if (onUpdateDossierRef.current) {
                    const currentDossier = dossierRef.current;
                    onUpdateDossierRef.current({
                        ...currentDossier,
                        patient: {
                            ...currentDossier.patient,
                            firstName: refreshedPatient?.firstName || normalizedBeneficiary.firstName,
                            lastName: refreshedPatient?.lastName || normalizedBeneficiary.lastName,
                            secondFirstName: refreshedPatient?.secondFirstName || normalizedBeneficiary.secondFirstName,
                            secondLastName: refreshedPatient?.secondLastName || normalizedBeneficiary.secondLastName,
                            occupant1BirthDate: refreshedPatient?.occupant1BirthDate || normalizedBeneficiary.occupant1BirthDate,
                            occupant2BirthDate: refreshedPatient?.occupant2BirthDate || normalizedBeneficiary.occupant2BirthDate,
                            address: refreshedPatient?.address || normalizedBeneficiary.address,
                            city: resolvedCity,
                            cityId: resolvedCityId,
                            zipCode: resolvedZipCode,
                            phone: refreshedPatient?.phone || normalizedBeneficiary.phone,
                            email: refreshedPatient?.email || normalizedBeneficiary.email,
                            familySituation: refreshedPatient?.familySituation || normalizedBeneficiary.familySituation,
                            occupationStatus: refreshedPatient?.occupationStatus || normalizedBeneficiary.occupationStatus,
                            incomeCategory: refreshedPatient?.incomeCategory || currentDossier.patient.incomeCategory,
                            numberPeople: refreshedPatient?.numberPeople ?? (parseInt(normalizedBeneficiary.numberPeople) || currentDossier.patient.numberPeople),
                            fiscalRevenue: refreshedPatient?.fiscalRevenue ?? (parseFloat(normalizedBeneficiary.fiscalRevenue) || currentDossier.patient.fiscalRevenue),
                            apa: normalizedBeneficiary.apa,
                            invalidity: normalizedBeneficiary.invalidity,
                            invalidityTxt: normalizedBeneficiary.invalidityTxt,
                            homeHelp: normalizedBeneficiary.homeHelp,
                            homeHelpTxt: normalizedBeneficiary.homeHelpTxt,
                            dependenceTxt: normalizedBeneficiary.dependenceTxt,
                            trustedPerson: {
                                name: normalizedBeneficiary.trustedName,
                                phone: normalizedBeneficiary.trustedPhone,
                                email: normalizedBeneficiary.trustedEmail,
                            },
                            occupant1SocialSecurityNumber: normalizedBeneficiary.occupant1SocialSecurityNumber,
                            occupant2SocialSecurityNumber: normalizedBeneficiary.occupant2SocialSecurityNumber,
                            numeroSecuriteSocialeMonsieur: normalizedBeneficiary.numeroSecuriteSocialeMonsieur,
                            numeroSecuriteSocialeMadame: normalizedBeneficiary.numeroSecuriteSocialeMadame,
                            caisseRetraitePrincipale: normalizedBeneficiary.caisseRetraitePrincipale,
                            caissesRetraiteComplementaires: normalizedBeneficiary.caissesRetraiteComplementaires,
                        },
                        compteAnah: normalizedBeneficiary.compteAnah,
                        natureAccompagnement: normalizedBeneficiary.natureAccompagnement,
                        envoiRapport: normalizedBeneficiary.envoiRapport,
                        personnesPresentesVisite: normalizedBeneficiary.personnesPresentesVisite,
                        ergoId: normalizedBeneficiary.ergoId,
                    });
                }

                return { success: true, error: null };
            }, 'Bénéficiaire');

            if (!result.success) {
                console.error('✗ Bénéficiaire sync failed:', result.error);
            }
        };

        syncBeneficiary().catch((error) => {
            console.error('✗ Bénéficiaire sync failed:', error);
        });
    }, [debouncedBeneficiary, dossier.patient.id, dossier.id, runSave]);

    // Save Context (Medical & Autonomy)
    useEffect(() => {
        if (!isAutosaveReadyRef.current) return;
        const contextSnapshot = serializeForAutosave(debouncedContext);
        if (contextSnapshotRef.current === null) {
            contextSnapshotRef.current = contextSnapshot;
            return;
        }
        if (contextSnapshotRef.current === contextSnapshot) return;
        runSave('context', async () => updateDossier(dossier.id, {
            medicalContext: debouncedContext.medical,
            autonomy: {
                done: debouncedContext.autonomyDone,
                checklist: debouncedContext.autonomy,
                humanHelp: debouncedContext.humanHelp,
                occupants: debouncedContext.occupants,
            }
        }), 'Contexte → dossiers (jsonb)')
            .then((result) => {
                if (result.success) {
                    contextSnapshotRef.current = contextSnapshot;
                }
            })
            .catch(() => undefined);
    }, [debouncedContext, dossier.id, runSave]);

    // Save Housing
    useEffect(() => {
        if (!isAutosaveReadyRef.current) return;
        const housingSnapshot = serializeForAutosave(debouncedHousing);
        if (housingSnapshotRef.current === null) {
            housingSnapshotRef.current = housingSnapshot;
            return;
        }
        if (housingSnapshotRef.current === housingSnapshot) return;
        runSave('housing', async () => updateHousing(dossier.patient.id, dossier.housing.id, buildHousingPayload(debouncedHousing)), 'Logement → logements')
            .then((result) => {
                if (result.success) {
                    housingSnapshotRef.current = housingSnapshot;
                }
            })
            .catch(() => undefined);
    }, [debouncedHousing, dossier.patient.id, dossier.housing.id, runSave]);

    // Save Sanitaires
    useEffect(() => {
        if (!isAutosaveReadyRef.current) return;
        if (dossier.id.startsWith('temp-')) return;
        const sanitairesSnapshot = serializeForAutosave(debouncedSanitaires);
        if (sanitairesSnapshotRef.current === null) {
            sanitairesSnapshotRef.current = sanitairesSnapshot;
            return;
        }
        if (sanitairesSnapshotRef.current === sanitairesSnapshot) return;
        runSave('sanitaires', async () => upsertDiagnosticSanitaires(dossier.id, debouncedSanitaires), 'Sanitaires → diagnostic_sanitaires')
            .then((result) => {
                if (result.success) {
                    sanitairesSnapshotRef.current = sanitairesSnapshot;
                }
            })
            .catch(() => undefined);
    }, [debouncedSanitaires, dossier.id, runSave]);

    // Save Mesures
    useEffect(() => {
        if (!isAutosaveReadyRef.current) return;
        if (dossier.id.startsWith('temp-')) return;
        const mesuresSnapshot = serializeForAutosave(debouncedMesures);
        if (mesuresSnapshotRef.current === null) {
            mesuresSnapshotRef.current = mesuresSnapshot;
            return;
        }
        if (mesuresSnapshotRef.current === mesuresSnapshot) return;
        runSave('mesures', async () => upsertMesuresAnthropometriques(dossier.id, debouncedMesures), 'Mesures → mesures_anthropometriques')
            .then((result) => {
                if (result.success) {
                    mesuresSnapshotRef.current = mesuresSnapshot;
                }
            })
            .catch(() => undefined);
    }, [debouncedMesures, dossier.id, runSave]);

    // Save Synthese
    useEffect(() => {
        if (!isAutosaveReadyRef.current) return;
        if (dossier.id.startsWith('temp-')) return;
        const syntheseSnapshot = serializeForAutosave(debouncedSynthese);
        if (syntheseSnapshotRef.current === null) {
            syntheseSnapshotRef.current = syntheseSnapshot;
            return;
        }
        if (syntheseSnapshotRef.current === syntheseSnapshot) return;
        runSave('synthese', async () => upsertObservationsSynthese(dossier.id, dossier.patient.id, debouncedSynthese), 'Synthèse → observations')
            .then((result) => {
                if (result.success) {
                    syntheseSnapshotRef.current = syntheseSnapshot;
                }
            })
            .catch(() => undefined);
    }, [debouncedSynthese, dossier.id, dossier.patient.id, runSave]);

    // Save Recommendations
    useEffect(() => {
        if (!isAutosaveReadyRef.current) return;
        if (dossier.id.startsWith('temp-')) return;
        const recommendationsSnapshot = serializeForAutosave(debouncedRecommendations);
        if (recommendationsSnapshotRef.current === null) {
            recommendationsSnapshotRef.current = recommendationsSnapshot;
            return;
        }
        if (recommendationsSnapshotRef.current === recommendationsSnapshot) return;
        runSave('recommendations', async () => saveVisitRecommendations(dossier.id, debouncedRecommendations), 'Préconisations')
            .then((result) => {
                if (result.success) {
                    recommendationsSnapshotRef.current = recommendationsSnapshot;
                }
            })
            .catch(() => undefined);
    }, [debouncedRecommendations, dossier.id, runSave]);

    // =============================================================
    // FORM HANDLERS — Instant state update, debounced save
    // =============================================================
    const updateBeneficiary = (field: string, value: any) => {
        setFormData(prev => {
            const nextBeneficiary = { ...prev.beneficiary, [field]: value };
            let nextContext = prev.context;
            if (field === 'ergoId') {
                const ergo = findErgoOption(refErgos, value);
                nextBeneficiary.etablissementId = ergo?.establishmentLabel || '';
            }
            if (field === 'occupants') {
                const normalizedBeneficiary = buildBeneficiaryIdentityPayload({
                    ...nextBeneficiary,
                    occupants: value,
                });
                const syncedContext = buildContextPayload(prev.context, normalizedBeneficiary);
                const beneficiaryOccupants = buildOccupantsFromPatient(normalizedBeneficiary, normalizedBeneficiary.numberPeople);
                const cleanedContext = {
                    ...syncedContext,
                    occupants: syncedContext.occupants.map((occupant: any, index: number) => ({
                        ...occupant,
                        humanHelp: beneficiaryOccupants[index]?.homeHelp
                            ? occupant.humanHelp
                            : parseHumanHelpItems(''),
                    })),
                };
                return {
                    ...prev,
                    beneficiary: normalizedBeneficiary,
                    context: buildContextPayload(cleanedContext, normalizedBeneficiary),
                };
            }
            if (field === 'homeHelp' && !value) {
                nextBeneficiary.homeHelpTxt = '';
                nextContext = {
                    ...prev.context,
                    humanHelp: parseHumanHelpItems(''),
                };
            }
            return { ...prev, beneficiary: nextBeneficiary, context: nextContext };
        });
    };

    useEffect(() => {
        if (!onUpdateDossierRef.current) return;

        const currentDossier = dossierRef.current;
        const normalizedBeneficiary = buildBeneficiaryIdentityPayload(formData.beneficiary);
        const nextPatient = {
            ...currentDossier.patient,
            firstName: normalizedBeneficiary.firstName,
            lastName: normalizedBeneficiary.lastName,
            secondFirstName: normalizedBeneficiary.secondFirstName,
            secondLastName: normalizedBeneficiary.secondLastName,
            occupants: normalizedBeneficiary.occupants,
            occupant1BirthDate: normalizedBeneficiary.occupant1BirthDate,
            occupant2BirthDate: normalizedBeneficiary.occupant2BirthDate,
            birthDateMr: normalizedBeneficiary.birthDateMr,
            birthDateMme: normalizedBeneficiary.birthDateMme,
            address: normalizedBeneficiary.address,
            city: normalizedBeneficiary.city,
            cityId: normalizedBeneficiary.cityId || '',
            zipCode: normalizedBeneficiary.zipCode,
            phone: normalizedBeneficiary.phone,
            email: normalizedBeneficiary.email,
            familySituation: normalizedBeneficiary.familySituation,
            occupationStatus: normalizedBeneficiary.occupationStatus,
            numberPeople: parseInt(normalizedBeneficiary.numberPeople) || currentDossier.patient.numberPeople,
            incomeCategory: normalizedBeneficiary.incomeCategory,
            fiscalRevenue: normalizedBeneficiary.fiscalRevenue ? parseFloat(normalizedBeneficiary.fiscalRevenue) : currentDossier.patient.fiscalRevenue,
            apa: Boolean(normalizedBeneficiary.apa),
            invalidity: Boolean(normalizedBeneficiary.invalidity),
            invalidityTxt: normalizedBeneficiary.invalidityTxt,
            homeHelp: Boolean(normalizedBeneficiary.homeHelp),
            homeHelpTxt: normalizedBeneficiary.homeHelpTxt,
            dependenceTxt: normalizedBeneficiary.dependenceTxt,
            occupant1SocialSecurityNumber: normalizedBeneficiary.occupant1SocialSecurityNumber,
            occupant2SocialSecurityNumber: normalizedBeneficiary.occupant2SocialSecurityNumber,
            numeroSecuriteSocialeMonsieur: normalizedBeneficiary.numeroSecuriteSocialeMonsieur,
            numeroSecuriteSocialeMadame: normalizedBeneficiary.numeroSecuriteSocialeMadame,
            caisseRetraitePrincipale: normalizedBeneficiary.caisseRetraitePrincipale,
            caissesRetraiteComplementaires: normalizedBeneficiary.caissesRetraiteComplementaires,
            trustedPerson: {
                name: normalizedBeneficiary.trustedName,
                phone: normalizedBeneficiary.trustedPhone,
                email: normalizedBeneficiary.trustedEmail,
            },
        };

        const nextDossier = {
            ...currentDossier,
            patient: nextPatient,
            compteAnah: formData.beneficiary.compteAnah,
            natureAccompagnement: formData.beneficiary.natureAccompagnement,
            envoiRapport: formData.beneficiary.envoiRapport,
            personnesPresentesVisite: formData.beneficiary.personnesPresentesVisite,
            ergoId: formData.beneficiary.ergoId,
        };

        if (JSON.stringify({
            patient: currentDossier.patient,
            compteAnah: currentDossier.compteAnah,
            natureAccompagnement: currentDossier.natureAccompagnement,
            envoiRapport: currentDossier.envoiRapport,
            personnesPresentesVisite: currentDossier.personnesPresentesVisite,
            ergoId: currentDossier.ergoId,
        }) === JSON.stringify({
            patient: nextDossier.patient,
            compteAnah: nextDossier.compteAnah,
            natureAccompagnement: nextDossier.natureAccompagnement,
            envoiRapport: nextDossier.envoiRapport,
            personnesPresentesVisite: nextDossier.personnesPresentesVisite,
            ergoId: nextDossier.ergoId,
        })) {
            return;
        }

        dossierRef.current = nextDossier;
        onUpdateDossierRef.current(nextDossier);
    }, [formData.beneficiary]);

    useEffect(() => {
        if (!onUpdateDossierRef.current) return;

        const currentDossier = dossierRef.current;
        const normalizedContext = buildContextPayload(formData.context, formData.beneficiary);
        const nextDossier = {
            ...currentDossier,
            medicalContext: normalizedContext.medical,
            autonomy: {
                done: normalizedContext.autonomyDone,
                checklist: normalizedContext.autonomy,
                occupants: normalizedContext.occupants,
            },
        };

        if (serializeForAutosave({
            medicalContext: currentDossier.medicalContext,
            autonomy: currentDossier.autonomy,
        }) === serializeForAutosave({
            medicalContext: nextDossier.medicalContext,
            autonomy: nextDossier.autonomy,
        })) {
            return;
        }

        dossierRef.current = nextDossier;
        onUpdateDossierRef.current(nextDossier);
    }, [formData.context, formData.beneficiary]);

    const commitFiscalRevenueDraft = useCallback(() => {
        const normalizedDraft = fiscalRevenueDraft.trim().replace(',', '.');
        setFormData((prev) => {
            if (prev.beneficiary.fiscalRevenue === normalizedDraft) {
                return prev;
            }
            return {
                ...prev,
                beneficiary: {
                    ...prev.beneficiary,
                    fiscalRevenue: normalizedDraft,
                }
            };
        });
    }, [fiscalRevenueDraft]);

    const updateContextMedical = (occupantIndex: number, field: string, value: string) => {
        setFormData((prev) => {
            const occupants = buildContextOccupants(prev.context, prev.beneficiary);
            occupants[occupantIndex] = {
                ...occupants[occupantIndex],
                medical: {
                    ...occupants[occupantIndex].medical,
                    [field]: value,
                },
            };
            return { ...prev, context: buildContextPayload({ ...prev.context, occupants }, prev.beneficiary) };
        });
    };

    const toggleAutonomyDone = (occupantIndex: number) => {
        setFormData((prev) => {
            const occupants = buildContextOccupants(prev.context, prev.beneficiary);
            const currentOccupant = occupants[occupantIndex] || createEmptyContextOccupant();
            const nextDone = !currentOccupant.autonomyDone;
            const clearedHumanHelp = (currentOccupant.humanHelp || parseHumanHelpItems(buildOccupantsFromPatient(prev.beneficiary, prev.beneficiary.numberPeople)[occupantIndex]?.homeHelpTxt || ''))
                .map((item: any) => ({ ...item, checked: nextDone ? false : item.checked }));
            occupants[occupantIndex] = {
                ...currentOccupant,
                autonomyDone: nextDone,
                autonomy: currentOccupant.autonomy.map((item: any) => ({ ...item, checked: nextDone })),
                humanHelp: clearedHumanHelp,
            };
            return {
                ...prev,
                context: buildContextPayload({ ...prev.context, occupants }, prev.beneficiary),
            };
        });
    };

    const toggleAutonomyItem = (occupantIndex: number, idx: number) => {
        setFormData(prev => {
            const occupants = buildContextOccupants(prev.context, prev.beneficiary);
            const currentOccupant = occupants[occupantIndex] || createEmptyContextOccupant();
            const newItems = [...currentOccupant.autonomy];
            const nextChecked = !newItems[idx].checked;
            newItems[idx] = { ...newItems[idx], checked: nextChecked };
            const newHumanHelp = [...(currentOccupant.humanHelp || parseHumanHelpItems(buildOccupantsFromPatient(prev.beneficiary, prev.beneficiary.numberPeople)[occupantIndex]?.homeHelpTxt || ''))];
            if (nextChecked && newHumanHelp[idx]) {
                newHumanHelp[idx] = { ...newHumanHelp[idx], checked: false };
            }
            occupants[occupantIndex] = {
                ...currentOccupant,
                autonomy: newItems,
                humanHelp: newHumanHelp,
                autonomyDone: newItems.every((item: any) => item.checked),
            };
            return {
                ...prev,
                context: buildContextPayload({ ...prev.context, occupants }, prev.beneficiary),
            };
        });
    };

    const toggleHumanHelpItem = (occupantIndex: number, idx: number) => {
        setFormData((prev) => {
            const occupants = buildContextOccupants(prev.context, prev.beneficiary);
            const currentOccupant = occupants[occupantIndex] || createEmptyContextOccupant();
            if (currentOccupant.autonomy?.[idx]?.checked) {
                return prev;
            }
            const newItems = [...(currentOccupant.humanHelp || parseHumanHelpItems(buildOccupantsFromPatient(prev.beneficiary, prev.beneficiary.numberPeople)[occupantIndex]?.homeHelpTxt || ''))];
            newItems[idx] = { ...newItems[idx], checked: !newItems[idx].checked };
            const occupantsWithUpdate = [...occupants];
            occupantsWithUpdate[occupantIndex] = {
                ...currentOccupant,
                humanHelp: newItems,
            };
            const nextBeneficiaryOccupants = buildOccupantsFromPatient(prev.beneficiary, prev.beneficiary.numberPeople);
            nextBeneficiaryOccupants[occupantIndex] = {
                ...nextBeneficiaryOccupants[occupantIndex],
                homeHelpTxt: serializeHumanHelpItems(newItems),
            };
            const nextBeneficiary = buildBeneficiaryIdentityPayload({
                ...prev.beneficiary,
                occupants: nextBeneficiaryOccupants,
            });
            return {
                ...prev,
                beneficiary: nextBeneficiary,
                context: buildContextPayload({ ...prev.context, occupants: occupantsWithUpdate }, nextBeneficiary),
            };
        });
    };

    useEffect(() => {
        const beneficiaryOccupants = buildOccupantsFromPatient(formData.beneficiary, formData.beneficiary.numberPeople);
        const contextOccupants = buildContextOccupants(formData.context, formData.beneficiary);
        const shouldClear = beneficiaryOccupants.some((occupant, index) => !occupant.homeHelp && (contextOccupants[index]?.humanHelp || []).some((item: any) => item.checked));
        if (!shouldClear) {
            return;
        }
        setFormData((prev) => ({
            ...prev,
            context: buildContextPayload({
                ...prev.context,
                occupants: buildContextOccupants(prev.context, prev.beneficiary).map((occupant, index) => ({
                    ...occupant,
                    humanHelp: buildOccupantsFromPatient(prev.beneficiary, prev.beneficiary.numberPeople)[index]?.homeHelp
                        ? occupant.humanHelp
                        : parseHumanHelpItems(''),
                })),
            }, prev.beneficiary),
        }));
    }, [formData.beneficiary.occupants, formData.beneficiary.numberPeople, formData.context.occupants]);

    const updateHousingForm = (field: string, value: any) => {
        setFormData(prev => ({ ...prev, housing: { ...prev.housing, [field]: value } }));
    };

    const updateHeatingDetail = (key: string, val: boolean) => {
        setFormData(prev => ({
            ...prev,
            housing: { ...prev.housing, heatingDetails: { ...prev.housing.heatingDetails, [key]: val } }
        }));
    };

    const updateSanitaires = (field: string, value: any) => {
        setSanitairesData(prev => ({ ...prev, [field]: value }));
    };

    const updateBathroomInstance = useCallback((levelField: string, field: keyof BathroomLevelInstance, value: any) => {
        setSanitairesData((previous) => ({
            ...previous,
            sdbInstances: (previous.sdbInstances || []).map((instance) =>
                instance.levelField === levelField ? { ...instance, [field]: value } : instance),
        }));
    }, []);

    const updateWcInstance = useCallback((levelField: string, field: keyof WcLevelInstance, value: any) => {
        setSanitairesData((previous) => ({
            ...previous,
            wcInstances: (previous.wcInstances || []).map((instance) =>
                instance.levelField === levelField ? { ...instance, [field]: value } : instance),
        }));
    }, []);

    const updateMesures = (field: string, value: any) => {
        setMesuresData(prev => ({ ...prev, [field]: value }));
    };

    const updateSynthese = (field: string, value: any) => {
        setSyntheseData(prev => ({ ...prev, [field]: value }));
    };

    const addRecommendation = () => {
        const nextItem = createEmptyRecommendationItem();
        setRecommendationsData((prev) => [...prev, nextItem]);
        return nextItem.id;
    };

    const removeRecommendation = (itemId: string) => {
        setRecommendationsData((prev) => prev.filter((item) => item.id !== itemId));
    };

    const updateRecommendation = (itemId: string, updates: Partial<VisitRecommendationItem>) => {
        setRecommendationsData((prev) => prev.map((item) => (
            item.id === itemId
                ? { ...item, ...updates, updatedAt: new Date().toISOString() }
                : item
        )));
    };

    // =============================================================
    // NOTES — Unique pages by visit scope + tab / sous-partie
    // =============================================================
    const isMeasurementsTab = activeTab === 'Mesures';
    const isPlansTab = activeTab === 'Plans';
    const isStructuredGridTab = isPlansTab;

    const buildNoteScopeConfig = useCallback((tab: string) => {
        const structured = tab === 'Mesures' || tab === 'Plans';
        const scopeType = structured ? 'visit_grid' : 'visit_report';
        const layoutKind = structured ? 'grid' : 'freeform';

        if (tab === 'Bénéficiaire') {
            const drawingTabKey = VISIT_NOTE_TAB_KEYS[tab];
            const drawingSubTabKey = BENEFICIARY_NOTE_SUBTAB_LABELS[activeBeneficiarySection];
            const textTabKey = drawingTabKey;
            const textSubTabKey = 'shared_text';
            return {
                scopeType,
                layoutKind,
                drawingTabKey,
                drawingSubTabKey,
                textTabKey,
                textSubTabKey,
                drawingCacheKey: `${scopeType}:${drawingTabKey}:${drawingSubTabKey}`,
                textCacheKey: `${scopeType}:${textTabKey}:${textSubTabKey}`,
                sharedText: true,
            };
        }

        if (tab === 'Contexte de vie') {
            const drawingTabKey = VISIT_NOTE_TAB_KEYS[tab];
            const drawingSubTabKey = CONTEXT_NOTE_SUBTAB_LABELS[activeContextSection];
            const textTabKey = drawingTabKey;
            const textSubTabKey = 'shared_text';
            return {
                scopeType,
                layoutKind,
                drawingTabKey,
                drawingSubTabKey,
                textTabKey,
                textSubTabKey,
                drawingCacheKey: `${scopeType}:${drawingTabKey}:${drawingSubTabKey}`,
                textCacheKey: `${scopeType}:${textTabKey}:${textSubTabKey}`,
                sharedText: true,
            };
        }

        if (tab === 'Accessibilité') {
            const drawingTabKey = VISIT_NOTE_TAB_KEYS[tab];
            const drawingSubTabKey = ACCESS_NOTE_SUBTAB_LABELS[activeAccessSection];
            const textTabKey = drawingTabKey;
            const textSubTabKey = 'shared_text';
            return {
                scopeType,
                layoutKind,
                drawingTabKey,
                drawingSubTabKey,
                textTabKey,
                textSubTabKey,
                drawingCacheKey: `${scopeType}:${drawingTabKey}:${drawingSubTabKey}`,
                textCacheKey: `${scopeType}:${textTabKey}:${textSubTabKey}`,
                sharedText: true,
            };
        }

        if (tab === 'Salle de bain') {
            const drawingTabKey = VISIT_NOTE_TAB_KEYS[tab];
            const drawingSubTabKey = BATHROOM_NOTE_SUBTAB_LABELS[activeBathroomSection];
            return {
                scopeType,
                layoutKind,
                drawingTabKey,
                drawingSubTabKey,
                textTabKey: tab,
                textSubTabKey: drawingSubTabKey,
                drawingCacheKey: `${scopeType}:${drawingTabKey}:${drawingSubTabKey}`,
                textCacheKey: `${scopeType}:${drawingTabKey}:${drawingSubTabKey}`,
                sharedText: false,
            };
        }

        if (tab === 'WC') {
            const drawingTabKey = VISIT_NOTE_TAB_KEYS[tab];
            const drawingSubTabKey = WC_NOTE_SUBTAB_LABELS[activeWcSection];
            return {
                scopeType,
                layoutKind,
                drawingTabKey,
                drawingSubTabKey,
                textTabKey: tab,
                textSubTabKey: drawingSubTabKey,
                drawingCacheKey: `${scopeType}:${drawingTabKey}:${drawingSubTabKey}`,
                textCacheKey: `${scopeType}:${drawingTabKey}:${drawingSubTabKey}`,
                sharedText: false,
            };
        }

        return {
            scopeType,
            layoutKind,
            drawingTabKey: VISIT_NOTE_TAB_KEYS[tab as keyof typeof VISIT_NOTE_TAB_KEYS] || tab.toLowerCase(),
            drawingSubTabKey: 'general',
            textTabKey: VISIT_NOTE_TAB_KEYS[tab as keyof typeof VISIT_NOTE_TAB_KEYS] || tab.toLowerCase(),
            textSubTabKey: 'general',
            drawingCacheKey: `${scopeType}:${VISIT_NOTE_TAB_KEYS[tab as keyof typeof VISIT_NOTE_TAB_KEYS] || tab.toLowerCase()}:general`,
            textCacheKey: `${scopeType}:${VISIT_NOTE_TAB_KEYS[tab as keyof typeof VISIT_NOTE_TAB_KEYS] || tab.toLowerCase()}:general`,
            sharedText: false,
        };
    }, [activeAccessSection, activeBathroomSection, activeBeneficiarySection, activeContextSection, activeWcSection]);

    const currentNoteScope = buildNoteScopeConfig(activeTab);
    const noteScopeType = currentNoteScope.scopeType;
    const noteLayoutKind = currentNoteScope.layoutKind;
    const noteTabKey = currentNoteScope.drawingTabKey;
    const noteSubTabKey = currentNoteScope.drawingSubTabKey;
    const noteTextTabKey = currentNoteScope.textTabKey;
    const noteTextSubTabKey = currentNoteScope.textSubTabKey;
    const noteCacheKey = currentNoteScope.drawingCacheKey;
    const noteTextCacheKey = currentNoteScope.textCacheKey;
    const isSharedTextSubsectionNotes = currentNoteScope.sharedText;

    const buildNoteCacheKey = useCallback((tab: string) => (
        buildNoteScopeConfig(tab).drawingCacheKey
    ), [buildNoteScopeConfig]);

    const rememberNotePage = useCallback((cacheKey: string, pageNumber: number) => {
        notePageMemoryRef.current = { ...notePageMemoryRef.current, [cacheKey]: pageNumber };
        setNotePageMemory((prev) => {
            if (prev[cacheKey] === pageNumber) return prev;
            return { ...prev, [cacheKey]: pageNumber };
        });
    }, []);

    const sortNotePages = useCallback((pages: NotePage[]) => (
        [...pages].sort((left, right) => left.pageNumber - right.pageNumber)
    ), []);

    const commitNotePages = useCallback((cacheKey: string, pages: NotePage[]) => {
        const dedupedByPage = new Map<number, NotePage>();
        pages.forEach((page) => {
            const pageNumber = Number(page.pageNumber) || 0;
            const existing = dedupedByPage.get(pageNumber);
            if (!existing) {
                dedupedByPage.set(pageNumber, page);
                return;
            }
            const existingUpdatedAt = new Date(existing.updatedAt || 0).getTime();
            const currentUpdatedAt = new Date(page.updatedAt || 0).getTime();
            if (currentUpdatedAt > existingUpdatedAt) {
                dedupedByPage.set(pageNumber, page);
                return;
            }
            if (currentUpdatedAt === existingUpdatedAt && String(existing.id || '').startsWith('pending-') && !String(page.id || '').startsWith('pending-')) {
                dedupedByPage.set(pageNumber, page);
            }
        });
        const sortedPages = sortNotePages(Array.from(dedupedByPage.values()));
        notePagesCacheRef.current = { ...notePagesCacheRef.current, [cacheKey]: sortedPages };
        setNotePagesCache((prev) => ({ ...prev, [cacheKey]: sortedPages }));
        if (cacheKey === noteRequestKeyRef.current) {
            setActiveTabNotePages(sortedPages);
        }
        return sortedPages;
    }, [sortNotePages]);

    const loadActiveTabNotes = useCallback(async (preferredPageNumber = 0) => {
        const requestKey = noteCacheKey;
        noteRequestKeyRef.current = requestKey;
        const cachedPages = notePagesCacheRef.current[requestKey];
        const cachedTextPages = isSharedTextSubsectionNotes
            ? notePagesCacheRef.current[noteTextCacheKey]
            : undefined;
        if (cachedPages) {
            setActiveTabNotePages(cachedPages);
            setCurrentLocalPage((previous) => {
                if (isMeasurementsTab) return 0;
                const pageNumbers = Array.from(new Set([
                    ...cachedPages.map((page) => page.pageNumber),
                    ...(cachedTextPages || []).map((page) => page.pageNumber),
                ])).sort((left, right) => left - right);
                const cachedIndex = pageNumbers.findIndex((pageNumber) => pageNumber === preferredPageNumber);
                return cachedIndex >= 0 ? cachedIndex : previous;
            });
        } else {
            setActiveTabNotePages([]);
            setCurrentLocalPage(0);
        }

        try {
            const [pages, sharedTextPages] = await Promise.all([
                fetchNotePages(dossier.patient.id, {
                    scopeType: noteScopeType,
                    scopeId: dossier.id,
                    tabKey: noteTabKey,
                    subTabKey: noteSubTabKey,
                }),
                isSharedTextSubsectionNotes
                    ? fetchNotePages(dossier.patient.id, {
                        scopeType: noteScopeType,
                        scopeId: dossier.id,
                        tabKey: noteTextTabKey,
                        subTabKey: noteTextSubTabKey,
                    })
                    : Promise.resolve([]),
            ]);

            if (noteRequestKeyRef.current !== requestKey) {
                return;
            }

            const sortedPages = commitNotePages(requestKey, pages);
            const sortedSharedTextPages = isSharedTextSubsectionNotes
                ? commitNotePages(noteTextCacheKey, sharedTextPages)
                : [];
            const allPageNumbers = Array.from(new Set([
                ...sortedPages.map((page) => page.pageNumber),
                ...sortedSharedTextPages.map((page) => page.pageNumber),
            ])).sort((left, right) => left - right);

            if (allPageNumbers.length === 0) {
                setCurrentLocalPage(0);
                return;
            }

            if (isMeasurementsTab) {
                setCurrentLocalPage(0);
                return;
            }

            const pageIndex = allPageNumbers.findIndex((pageNumber) => pageNumber === preferredPageNumber);
            setCurrentLocalPage((previous) => (
                pageIndex >= 0 ? pageIndex : Math.min(previous, allPageNumbers.length - 1)
            ));
        } catch (error) {
            console.error('Failed to load visit note pages', error);
            if (noteRequestKeyRef.current === requestKey && !cachedPages) {
                setActiveTabNotePages([]);
                setCurrentLocalPage(0);
            }
        }
    }, [commitNotePages, dossier.id, dossier.patient.id, isMeasurementsTab, isSharedTextSubsectionNotes, noteCacheKey, noteScopeType, noteSubTabKey, noteTabKey, noteTextCacheKey, noteTextSubTabKey, noteTextTabKey]);

    useEffect(() => {
        const preferredPageNumber = notePageMemoryRef.current[noteCacheKey] ?? 0;
        loadActiveTabNotes(preferredPageNumber).catch((error) => console.error('Failed to refresh visit note pages', error));
    }, [loadActiveTabNotes, noteCacheKey]);

    useEffect(() => {
        if (typeof window === 'undefined') return;

        const preloadRemainingTabs = () => {
            TABS.filter((tab) => tab !== activeTab).forEach((tab) => {
                const cacheKey = buildNoteCacheKey(tab);
                if (notePagesCacheRef.current[cacheKey]) {
                    return;
                }

                const structured = tab === 'Mesures' || tab === 'Plans';
                const scope = buildNoteScopeConfig(tab);
                Promise.all([
                    fetchNotePages(dossier.patient.id, {
                        scopeType: structured ? 'visit_grid' : 'visit_report',
                        scopeId: dossier.id,
                        tabKey: scope.drawingTabKey,
                        subTabKey: scope.drawingSubTabKey,
                    }),
                    scope.sharedText
                        ? fetchNotePages(dossier.patient.id, {
                            scopeType: structured ? 'visit_grid' : 'visit_report',
                            scopeId: dossier.id,
                            tabKey: scope.textTabKey,
                            subTabKey: scope.textSubTabKey,
                        })
                        : Promise.resolve([]),
                ])
                    .then(([pages, sharedTextPages]) => {
                        if (notePagesCacheRef.current[cacheKey]) return;
                        commitNotePages(cacheKey, pages);
                        if (scope.sharedText) {
                            commitNotePages(scope.textCacheKey, sharedTextPages);
                        }
                    })
                    .catch((error) => {
                        console.error(`Failed to preload visit note pages for ${tab}`, error);
                    });
            });
        };

        const idleCallback = (window as Window & {
            requestIdleCallback?: (callback: () => void, options?: { timeout: number }) => number;
            cancelIdleCallback?: (handle: number) => void;
        }).requestIdleCallback;

        if (idleCallback) {
            const handle = idleCallback(preloadRemainingTabs, { timeout: 1200 });
            return () => {
                (window as Window & { cancelIdleCallback?: (handle: number) => void }).cancelIdleCallback?.(handle);
            };
        }

        const timeoutId = window.setTimeout(preloadRemainingTabs, 250);
        return () => window.clearTimeout(timeoutId);
    }, [activeTab, buildNoteCacheKey, buildNoteScopeConfig, commitNotePages, dossier.id, dossier.patient.id]);

    useEffect(() => {
        const nextLocation = normalizeVisitReportLocation(location);
        isAutosaveReadyRef.current = false;
        isMutatingPagesRef.current = false;
        setIsMutatingPages(false);
        beneficiarySnapshotRef.current = null;
        contextSnapshotRef.current = null;
        housingSnapshotRef.current = null;
        sanitairesSnapshotRef.current = null;
        mesuresSnapshotRef.current = null;
        syntheseSnapshotRef.current = null;
        recommendationsSnapshotRef.current = null;
        notePagesCacheRef.current = {};
        notePageMemoryRef.current = {};
        pendingPageSelectionRef.current = null;
        setNotePagesCache({});
        setNotePageMemory({});
        setActiveTabNotePages([]);
        setCurrentLocalPage(0);
        setActiveTab(nextLocation.activeTab);
        setActiveBeneficiarySection(nextLocation.beneficiarySection);
        setActiveContextSection(nextLocation.contextSection);
        setActiveAccessSection(nextLocation.accessSection);
        setActiveBathroomSection(nextLocation.bathroomSection);
        setActiveWcSection(nextLocation.wcSection);
        setPlansActiveTool('pen');
    }, [dossier.id]);

    useEffect(() => {
        const currentPages = notePagesCache[noteCacheKey] || [];
        noteRequestKeyRef.current = noteCacheKey;
        setActiveTabNotePages(currentPages);
    }, [isMeasurementsTab, noteCacheKey, notePagesCache]);

    const currentTextNotePages = isSharedTextSubsectionNotes
        ? (notePagesCache[noteTextCacheKey] || [])
        : activeTabNotePages;

    useEffect(() => {
        currentTextNotePagesRef.current = currentTextNotePages;
    }, [currentTextNotePages]);

    const notePageNumbers = useMemo(() => {
        const pageNumbers = Array.from(new Set([
            ...activeTabNotePages.map((page) => page.pageNumber),
            ...currentTextNotePages.map((page) => page.pageNumber),
        ])).sort((left, right) => left - right);
        return pageNumbers.length > 0 ? pageNumbers : [0];
    }, [activeTabNotePages, currentTextNotePages]);

    useEffect(() => {
        if (isMeasurementsTab) {
            pendingPageSelectionRef.current = null;
            setCurrentLocalPage(0);
            return;
        }

        const pendingSelection = pendingPageSelectionRef.current;
        const preferredPageNumber = pendingSelection?.cacheKey === noteCacheKey
            ? pendingSelection.pageNumber
            : (notePageMemory[noteCacheKey] ?? 0);
        const preferredIndex = notePageNumbers.findIndex((pageNumber) => pageNumber === preferredPageNumber);

        setCurrentLocalPage((previous) => {
            if (preferredIndex >= 0) {
                return preferredIndex;
            }
            return Math.min(previous, notePageNumbers.length - 1);
        });

        if (pendingSelection?.cacheKey === noteCacheKey && preferredIndex >= 0) {
            pendingPageSelectionRef.current = null;
        }
    }, [isMeasurementsTab, noteCacheKey, notePageMemory, notePageNumbers]);

    const currentPageNumber = notePageNumbers[currentLocalPage] ?? 0;
    const currentDrawingNotePage = activeTabNotePages.find((page) => page.pageNumber === currentPageNumber) || {
        id: '',
        patientId: dossier.patient.id,
        dossierId: dossier.id,
        scopeType: noteScopeType,
        scopeId: dossier.id,
        tabKey: noteTabKey,
        subTabKey: noteSubTabKey,
        pageNumber: currentPageNumber,
        textContent: '',
        drawingJson: '',
        layoutKind: noteLayoutKind,
    };
    const currentTextNotePage = currentTextNotePages.find((page) => page.pageNumber === currentPageNumber) || {
        id: '',
        patientId: dossier.patient.id,
        dossierId: dossier.id,
        scopeType: noteScopeType,
        scopeId: dossier.id,
        tabKey: noteTextTabKey,
        subTabKey: noteTextSubTabKey,
        pageNumber: currentPageNumber,
        textContent: '',
        drawingJson: EMPTY_DRAWING_JSON,
        layoutKind: 'freeform' as const,
    };
    const currentNotePage = {
        ...currentDrawingNotePage,
        textContent: currentTextNotePage.textContent || '',
    };
    const currentNoteIdentity = `${noteCacheKey}:${noteTextCacheKey}:${currentPageNumber}`;

    useEffect(() => {
        if (isMeasurementsTab) return;
        const hasResolvedNotePage = Boolean(
            currentDrawingNotePage.id
            || currentTextNotePage.id
            || activeTabNotePages.length > 0
            || currentTextNotePages.length > 0
        );
        if (!hasResolvedNotePage) return;
        const pendingSelection = pendingPageSelectionRef.current;
        if (pendingSelection?.cacheKey === noteCacheKey && pendingSelection.pageNumber !== currentPageNumber) {
            return;
        }
        rememberNotePage(noteCacheKey, currentPageNumber);
    }, [
        activeTabNotePages.length,
        currentDrawingNotePage.id,
        currentPageNumber,
        currentTextNotePage.id,
        currentTextNotePages.length,
        isMeasurementsTab,
        noteCacheKey,
        rememberNotePage,
    ]);

    useEffect(() => {
        activeTabNotePagesRef.current = activeTabNotePages;
    }, [activeTabNotePages]);

    const lastHydratedIdentityRef = useRef('');
    useEffect(() => {
        const identity = `${currentNoteIdentity}:${currentNotePage.id}:${currentNotePage.pageNumber}`;
        if (identity === lastHydratedIdentityRef.current) return;
        lastHydratedIdentityRef.current = identity;
        setNoteDraft((previous) => {
            if (previous.isDirty && previous.noteKey === currentNoteIdentity) {
                return previous;
            }
            return {
                text: currentNotePage.textContent || '',
                drawingJson: currentNotePage.drawingJson || '',
                isDirty: false,
                noteKey: currentNoteIdentity,
            };
        });
    }, [currentNoteIdentity, currentNotePage.id, currentNotePage.pageNumber, currentNotePage.textContent, currentNotePage.drawingJson]);

    const handleNoteDraftChange = useCallback((payload: { text: string; drawingJson: string; isDirty: boolean }) => {
        setNoteDraft((previous) => {
            const nextDraft = {
                ...payload,
                noteKey: currentNoteIdentity,
            };
            if (
                previous.noteKey === nextDraft.noteKey
                && previous.text === nextDraft.text
                && previous.drawingJson === nextDraft.drawingJson
                && previous.isDirty === nextDraft.isDirty
            ) {
                return previous;
            }
            return nextDraft;
        });
    }, [currentNoteIdentity]);

    const handlePageChange = async (newLocalPage: number) => {
        if (newLocalPage === currentLocalPage) return;
        if (isMutatingPagesRef.current) return;
        await flushCurrentNoteDraft();
        const nextPageNumber = notePageNumbers[newLocalPage] ?? 0;
        if (!isMeasurementsTab) {
            rememberNotePage(noteCacheKey, nextPageNumber);
        }
        setCurrentLocalPage(newLocalPage);
    };

    const handleTabSelect = async (tab: string) => {
        if (tab === activeTab) return;
        if (isMutatingPagesRef.current) return;
        await flushCurrentNoteDraft();
        if (!isMeasurementsTab) {
            rememberNotePage(noteCacheKey, currentPageNumber);
        }
        const nextKey = buildNoteCacheKey(tab);
        const cachedPages = notePagesCacheRef.current[nextKey] || [];
        noteRequestKeyRef.current = nextKey;
        setActiveTabNotePages(cachedPages);
        const nextPreferredPageNumber = notePageMemoryRef.current[nextKey] ?? 0;
        if (cachedPages.length > 0) {
            const cachedPageNumbers = Array.from(new Set<number>(cachedPages.map((page) => page.pageNumber))).sort((left, right) => left - right);
            const nextIndex = cachedPageNumbers.findIndex((pageNumber) => pageNumber === nextPreferredPageNumber);
            setCurrentLocalPage(nextIndex >= 0 ? nextIndex : 0);
        } else {
            setCurrentLocalPage(0);
        }
        if (tab === 'Accessibilité') {
            setActiveAccessSection('general');
        }
        setActiveTab(tab);
    };

    const updateTabsScrollState = useCallback(() => {
        const element = tabsScrollRef.current;
        if (!element) return;
        const maxScrollLeft = Math.max(0, element.scrollWidth - element.clientWidth);
        setCanScrollTabsLeft(element.scrollLeft > 8);
        setCanScrollTabsRight(maxScrollLeft - element.scrollLeft > 8);
    }, []);

    const scrollTabs = useCallback((direction: 'left' | 'right') => {
        const element = tabsScrollRef.current;
        if (!element) return;
        const offset = Math.max(220, Math.round(element.clientWidth * 0.6));
        element.scrollBy({
            left: direction === 'right' ? offset : -offset,
            behavior: 'smooth',
        });
    }, []);

    useEffect(() => {
        const element = tabsScrollRef.current;
        if (!element) return;

        const syncState = () => updateTabsScrollState();
        syncState();
        element.addEventListener('scroll', syncState, { passive: true });
        window.addEventListener('resize', syncState);

        return () => {
            element.removeEventListener('scroll', syncState);
            window.removeEventListener('resize', syncState);
        };
    }, [updateTabsScrollState]);

    useEffect(() => {
        const activeButton = tabButtonRefs.current[activeTab];
        activeButton?.scrollIntoView({ behavior: 'smooth', inline: 'center', block: 'nearest' });
        const timeoutId = window.setTimeout(() => updateTabsScrollState(), 220);
        return () => window.clearTimeout(timeoutId);
    }, [activeTab, updateTabsScrollState]);

    const handleAddPage = async () => {
        if (isMeasurementsTab) return;
        if (isMutatingPagesRef.current) return;
        setPageMutationState(true);
        await flushCurrentNoteDraft();
        try {
            const createdPage = await createNotePage(dossier.patient.id, {
                scopeType: noteScopeType,
                scopeId: dossier.id,
                tabKey: noteTabKey,
                subTabKey: noteSubTabKey,
                layoutKind: noteLayoutKind,
            });
            const nextPages = commitNotePages(noteCacheKey, [...activeTabNotePagesRef.current, createdPage]);
            const pendingSelection = {
                cacheKey: noteCacheKey,
                pageNumber: createdPage.pageNumber,
            };
            pendingPageSelectionRef.current = pendingSelection;
            rememberNotePage(noteCacheKey, createdPage.pageNumber);

            let nextTextPages = currentTextNotePagesRef.current;
            if (isSharedTextSubsectionNotes) {
                const optimisticSharedTextPage: NotePage = {
                    id: `pending-text-page-${createdPage.id || Date.now()}`,
                    patientId: dossier.patient.id,
                    dossierId: dossier.id,
                    scopeType: noteScopeType,
                    scopeId: dossier.id,
                    tabKey: noteTextTabKey,
                    subTabKey: noteTextSubTabKey,
                    pageNumber: createdPage.pageNumber,
                    textContent: '',
                    drawingJson: EMPTY_DRAWING_JSON,
                    layoutKind: 'freeform',
                    updatedAt: new Date().toISOString(),
                };
                const otherSharedPages = currentTextNotePagesRef.current.filter((page) => page.pageNumber !== optimisticSharedTextPage.pageNumber && page.id !== optimisticSharedTextPage.id);
                nextTextPages = commitNotePages(noteTextCacheKey, [...otherSharedPages, optimisticSharedTextPage]);

                void saveNotePage({
                    notePageId: optimisticSharedTextPage.id,
                    patientId: dossier.patient.id,
                    dossierId: dossier.id,
                    scopeType: noteScopeType,
                    scopeId: dossier.id,
                    tabKey: noteTextTabKey,
                    subTabKey: noteTextSubTabKey,
                    pageNumber: createdPage.pageNumber,
                    textContent: '',
                    drawingJson: EMPTY_DRAWING_JSON,
                    layoutKind: 'freeform',
                })
                    .then((savedSharedTextPage) => {
                        const latestSharedPages = notePagesCacheRef.current[noteTextCacheKey] || [];
                        const mergedSharedPages = latestSharedPages.map((page) => (
                            page.id === optimisticSharedTextPage.id ? savedSharedTextPage : page
                        ));
                        if (!mergedSharedPages.some((page) => page.id === savedSharedTextPage.id)) {
                            mergedSharedPages.push(savedSharedTextPage);
                        }
                        commitNotePages(noteTextCacheKey, mergedSharedPages);
                    })
                    .catch((error) => {
                        console.error('Failed to create shared visit note page', error);
                    });
            }

            const nextPageNumbers = Array.from(new Set([
                ...nextPages.map((page) => page.pageNumber),
                ...nextTextPages.map((page) => page.pageNumber),
                createdPage.pageNumber,
            ])).sort((left, right) => left - right);
            const nextPageIndex = nextPageNumbers.findIndex((pageNumber) => pageNumber === createdPage.pageNumber);
            setNoteDraft({
                text: '',
                drawingJson: '',
                isDirty: false,
                noteKey: `${noteCacheKey}:${noteTextCacheKey}:${createdPage.pageNumber}`,
            });
            setCurrentLocalPage(Math.max(0, nextPageIndex));
        } catch (error) {
            console.error('Failed to create visit note page', error);
            alert('Création de page impossible.');
        } finally {
            setPageMutationState(false);
        }
    };

    const handleDeletePage = async () => {
        if (isMeasurementsTab) return;
        if (activeTabNotePages.length <= 1) return;
        if (isMutatingPagesRef.current) return;
        const deletedPageId = currentDrawingNotePage.id;
        const deletedSharedTextPageId = isSharedTextSubsectionNotes ? currentTextNotePage.id : '';
        const remainingPages = commitNotePages(
            noteCacheKey,
            activeTabNotePagesRef.current.filter((page) => page.id !== deletedPageId),
        );
        let remainingTextPages = currentTextNotePagesRef.current;
        if (isSharedTextSubsectionNotes) {
            remainingTextPages = commitNotePages(
                noteTextCacheKey,
                currentTextNotePagesRef.current.filter((page) => page.id !== deletedSharedTextPageId && page.pageNumber !== currentPageNumber),
            );
        }
        const remainingPageNumbers = Array.from(new Set([
            ...remainingPages.map((page) => page.pageNumber),
            ...remainingTextPages.map((page) => page.pageNumber),
        ])).sort((left, right) => left - right);
        const nextPageIndex = Math.max(0, Math.min(currentLocalPage - 1, remainingPageNumbers.length - 1));
        const nextPageNumber = remainingPageNumbers[nextPageIndex] ?? 0;
        pendingPageSelectionRef.current = {
            cacheKey: noteCacheKey,
            pageNumber: nextPageNumber,
        };
        rememberNotePage(noteCacheKey, nextPageNumber);
        setCurrentLocalPage(nextPageIndex);

        if (!deletedPageId && !deletedSharedTextPageId) {
            return;
        }

        setPageMutationState(true);
        Promise.allSettled([
            deletedPageId ? deleteNotePage(deletedPageId, dossier.patient.id) : Promise.resolve({ success: true, error: null }),
            deletedSharedTextPageId ? deleteNotePage(deletedSharedTextPageId, dossier.patient.id) : Promise.resolve({ success: true, error: null }),
        ])
            .then((results) => {
                if (results.some((result) => result.status === 'rejected')) {
                    console.error('Failed to delete visit note page', results);
                    alert('Suppression de page impossible.');
                    loadActiveTabNotes().catch((loadError) => console.error('Failed to reload visit notes after delete rollback', loadError));
                }
            })
            .finally(() => {
                setPageMutationState(false);
            });
    };

    const handleSaveNote = useCallback(async ({ text, drawingJson, previewDataUrl }: { text: string; drawingJson: string; previewDataUrl: string }) => {
        const normalizedDrawingJson = drawingJson || EMPTY_DRAWING_JSON;
        const resolvedPreviewDataUrl = previewDataUrl || buildNotePreviewDataUrlFromContent({
            text,
            drawingJson: normalizedDrawingJson,
            mode: noteLayoutKind === 'grid' ? 'grid' : 'freeform',
        });
        const isBlankText = text.trim().length === 0;
        const isBlankDrawing = normalizedDrawingJson === EMPTY_DRAWING_JSON;
        if (!currentDrawingNotePage.id && !currentTextNotePage.id && isBlankText && isBlankDrawing) {
            return;
        }

        const optimisticDrawingPage = {
            ...currentDrawingNotePage,
            id: currentDrawingNotePage.id || `pending-${Date.now()}`,
            textContent: isSharedTextSubsectionNotes ? '' : text,
            drawingJson: normalizedDrawingJson,
            previewDataUrl: resolvedPreviewDataUrl,
            updatedAt: new Date().toISOString(),
        };
        const otherDrawingPages = activeTabNotePagesRef.current.filter((page) => page.id !== optimisticDrawingPage.id && page.pageNumber !== currentPageNumber);
        commitNotePages(noteCacheKey, [...otherDrawingPages, optimisticDrawingPage]);

        const optimisticTextPage = isSharedTextSubsectionNotes
            ? {
                ...currentTextNotePage,
                id: currentTextNotePage.id || `pending-text-${Date.now()}`,
                textContent: text,
                drawingJson: EMPTY_DRAWING_JSON,
                previewDataUrl: resolvedPreviewDataUrl,
                updatedAt: new Date().toISOString(),
            }
            : null;

        if (optimisticTextPage) {
            const otherTextPages = currentTextNotePagesRef.current.filter((page) => page.id !== optimisticTextPage.id && page.pageNumber !== currentPageNumber);
            commitNotePages(noteTextCacheKey, [...otherTextPages, optimisticTextPage]);
        }

        setNoteDraft((prev) => {
            if (!prev.isDirty) return prev;
            return { ...prev, isDirty: false };
        });

        const doSave = async () => {
            try {
                const [savedPage, savedSharedTextPage] = await Promise.all([
                    saveNotePage({
                        notePageId: optimisticDrawingPage.id || undefined,
                        patientId: dossier.patient.id,
                        dossierId: dossier.id,
                        scopeType: noteScopeType,
                        scopeId: dossier.id,
                        tabKey: noteTabKey,
                        subTabKey: noteSubTabKey,
                        pageNumber: currentPageNumber,
                        textContent: isSharedTextSubsectionNotes ? '' : text,
                        drawingJson: normalizedDrawingJson,
                        previewDataUrl: resolvedPreviewDataUrl,
                        layoutKind: noteLayoutKind,
                    }),
                    isSharedTextSubsectionNotes
                        ? saveNotePage({
                            notePageId: optimisticTextPage?.id || undefined,
                            patientId: dossier.patient.id,
                            dossierId: dossier.id,
                            scopeType: noteScopeType,
                            scopeId: dossier.id,
                            tabKey: noteTextTabKey,
                            subTabKey: noteTextSubTabKey,
                            pageNumber: currentPageNumber,
                            textContent: text,
                            drawingJson: EMPTY_DRAWING_JSON,
                            previewDataUrl: resolvedPreviewDataUrl,
                            layoutKind: 'freeform',
                        })
                        : Promise.resolve(null),
                ]);
                const latestPages = notePagesCacheRef.current[noteCacheKey] || [];
                const mergedPages = latestPages.map((page) =>
                    page.id === optimisticDrawingPage.id ? savedPage : page
                );
                if (!mergedPages.some((page) => page.id === savedPage.id)) {
                    mergedPages.push(savedPage);
                }
                commitNotePages(noteCacheKey, mergedPages);
                if (savedSharedTextPage) {
                    const latestTextPages = notePagesCacheRef.current[noteTextCacheKey] || [];
                    const mergedTextPages = latestTextPages.map((page) =>
                        page.id === optimisticTextPage?.id ? savedSharedTextPage : page
                    );
                    if (!mergedTextPages.some((page) => page.id === savedSharedTextPage.id)) {
                        mergedTextPages.push(savedSharedTextPage);
                    }
                    commitNotePages(noteTextCacheKey, mergedTextPages);
                }
            } catch (error) {
                console.error('Background note save failed', error);
            }
        };

        const prev = noteSaveChainRef.current;
        noteSaveChainRef.current = prev.then(doSave, doSave).then(() => undefined, () => undefined);
    }, [commitNotePages, currentDrawingNotePage, currentPageNumber, currentTextNotePage, dossier.id, dossier.patient.id, isSharedTextSubsectionNotes, noteCacheKey, noteLayoutKind, noteScopeType, noteSubTabKey, noteTabKey, noteTextCacheKey, noteTextSubTabKey, noteTextTabKey]);

    const debouncedNoteDraft = useDebounce(noteDraft, NOTE_DRAFT_SYNC_DEBOUNCE_MS);

    useEffect(() => {
        if (!debouncedNoteDraft.isDirty) return;
        if (debouncedNoteDraft.noteKey !== currentNoteIdentity) return;
        handleSaveNote({
            text: debouncedNoteDraft.text,
            drawingJson: debouncedNoteDraft.drawingJson,
            previewDataUrl: buildNotePreviewDataUrlFromContent({
                text: debouncedNoteDraft.text,
                drawingJson: debouncedNoteDraft.drawingJson,
                mode: noteLayoutKind === 'grid' ? 'grid' : 'freeform',
            }),
        }).catch(() => {
            // saveStatus already handles UI feedback
        });
    }, [currentNoteIdentity, debouncedNoteDraft, handleSaveNote]);

    const flushCurrentNoteDraft = useCallback(async () => {
        if (!noteDraft.isDirty) return;
        try {
            await handleSaveNote({
                text: noteDraft.text,
                drawingJson: noteDraft.drawingJson,
            });
        } catch (error) {
            console.error('Failed to flush note draft', error);
        }
    }, [handleSaveNote, noteDraft.drawingJson, noteDraft.isDirty, noteDraft.text]);

    const handleBeneficiarySectionChange = useCallback(async (section: VisitReportLocation['beneficiarySection']) => {
        if (section === activeBeneficiarySection) return;
        if (isMutatingPagesRef.current) return;
        await flushCurrentNoteDraft();
        setActiveBeneficiarySection(section);
    }, [activeBeneficiarySection, flushCurrentNoteDraft]);

    const handleContextSectionChange = useCallback(async (section: VisitReportLocation['contextSection']) => {
        if (section === activeContextSection) return;
        if (isMutatingPagesRef.current) return;
        await flushCurrentNoteDraft();
        setActiveContextSection(section);
    }, [activeContextSection, flushCurrentNoteDraft]);

    const handleAccessSectionChange = useCallback(async (section: VisitReportLocation['accessSection']) => {
        if (section === activeAccessSection) return;
        if (isMutatingPagesRef.current) return;
        await flushCurrentNoteDraft();
        setActiveAccessSection(section);
    }, [activeAccessSection, flushCurrentNoteDraft]);

    const isNavigationLocked = isMutatingPages;

    // =============================================================
    // RENDER
    // =============================================================
    useEffect(() => {
        const frame = window.requestAnimationFrame(() => {
            beneficiarySnapshotRef.current = serializeForAutosave(debouncedBeneficiary);
            contextSnapshotRef.current = serializeForAutosave(debouncedContext);
            housingSnapshotRef.current = serializeForAutosave(debouncedHousing);
            sanitairesSnapshotRef.current = serializeForAutosave(debouncedSanitaires);
            mesuresSnapshotRef.current = serializeForAutosave(debouncedMesures);
            syntheseSnapshotRef.current = serializeForAutosave(debouncedSynthese);
            recommendationsSnapshotRef.current = serializeForAutosave(debouncedRecommendations);
            isAutosaveReadyRef.current = true;
        });
        return () => window.cancelAnimationFrame(frame);
    }, [debouncedBeneficiary, debouncedContext, debouncedHousing, debouncedMesures, debouncedRecommendations, debouncedSanitaires, debouncedSynthese]);

    useEffect(() => {
        onSavingChange?.(isNavigationLocked);
    }, [isNavigationLocked, onSavingChange]);

    const hasInnerQuickNav = [
        'Bénéficiaire',
        'Contexte de vie',
        'Accessibilité',
        'Salle de bain',
        'WC',
    ].includes(activeTab);
    const isPreconisationsTab = activeTab === 'Préconisations';

    const renderTabContent = () => {
        switch (activeTab) {
            case 'Bénéficiaire':
                return (
                    <BeneficiaryForm
                        data={formData.beneficiary}
                        activeQuickLink={activeBeneficiarySection}
                        onQuickLinkChange={handleBeneficiarySectionChange}
                        fiscalRevenueDraft={fiscalRevenueDraft}
                        onFiscalRevenueChange={setFiscalRevenueDraft}
                        onFiscalRevenueFocus={() => setIsEditingFiscalRevenue(true)}
                        onFiscalRevenueBlur={() => {
                            setIsEditingFiscalRevenue(false);
                            commitFiscalRevenueDraft();
                        }}
                        onChange={updateBeneficiary}
                        refSituations={refSituations}
                        refDependances={refDependances}
                        retirementFundOptions={retirementFundOptions}
                        principalRetirementFundOptions={principalRetirementFundOptions}
                        refCommunes={refCommunes}
                    />
                );
            case 'Contexte de vie':
                return (
                    <ContextForm
                        data={formData.context}
                        beneficiary={formData.beneficiary}
                        activeContextSection={activeContextSection}
                        onSectionChange={handleContextSectionChange}
                        onMedicalChange={updateContextMedical}
                        onToggleAutonomyDone={toggleAutonomyDone}
                        onToggleAutonomyItem={toggleAutonomyItem}
                        onToggleHumanHelpItem={toggleHumanHelpItem}
                    />
                );
            case 'Accessibilité':
                return <AccessForm data={formData.housing} activeAccessSection={activeAccessSection} onSectionChange={handleAccessSectionChange} onChange={updateHousingForm} onHeatingChange={updateHeatingDetail} refPorteGarage={refPorteGarage} refPortail={refPortail} />;
            case 'Salle de bain':
                return (
                    <SalleDeBainForm
                        instances={sanitairesData.sdbInstances || []}
                        activeBathroomSection={activeBathroomSection}
                        onSectionChange={setActiveBathroomSection}
                        onInstanceChange={updateBathroomInstance}
                    />
                );
            case 'WC':
                return (
                    <WCForm
                        instances={sanitairesData.wcInstances || []}
                        activeWcSection={activeWcSection}
                        onSectionChange={setActiveWcSection}
                        onInstanceChange={updateWcInstance}
                    />
                );
            case 'Préconisations':
                return (
                    <PreconisationsForm
                        items={recommendationsData}
                        wikiItems={wikiLibraryItems}
                        onAdd={addRecommendation}
                        onRemove={removeRecommendation}
                        onUpdate={updateRecommendation}
                    />
                );
            case 'Synthèse':
                return <SyntheseForm data={syntheseData} onChange={updateSynthese} />;
            case 'Plans':
                return null;
            case 'Mesures':
                return <MesuresForm data={mesuresData} onChange={updateMesures} />;
            default:
                return <div className="flex flex-col items-center justify-center h-full text-slate-400"><p>Formulaire {activeTab} à venir...</p></div>;
        }
    };

    return (
        <div className="h-full flex flex-col relative">
            {/* Top Nav */}
            <div className="flex items-center justify-between mb-6">
                <div onClick={onBack} className="w-12 h-12 bg-white rounded-full border border-slate-200 cursor-pointer flex items-center justify-center hover:bg-slate-50 transition-colors">
                    <ArrowLeft size={24} className="text-black" />
                </div>
                <div className="relative ml-4 flex-1">
                    <div
                        ref={tabsScrollRef}
                        className="overflow-x-auto no-scrollbar rounded-full border border-[#597E8D] bg-white p-1"
                    >
                        <div className="flex min-w-max gap-1.5">
                            {TABS.map(tab => (
                                <button
                                    key={tab}
                                    ref={(node) => {
                                        tabButtonRefs.current[tab] = node;
                                    }}
                                    onClick={() => handleTabSelect(tab)}
                                    disabled={isNavigationLocked}
                                    className={`flex shrink-0 items-center justify-center rounded-full px-3.5 py-2.5 text-center text-[13px] font-bold whitespace-nowrap transition-all disabled:cursor-not-allowed ${
                                        activeTab === tab
                                            ? 'bg-[#D8D0DC] text-[#554a63]'
                                            : isNavigationLocked
                                                ? 'text-slate-300'
                                                : 'text-slate-500 hover:text-slate-800'
                                    }`}
                                >
                                    {tab}
                                </button>
                            ))}
                        </div>
                    </div>
                    {canScrollTabsLeft && (
                        <button
                            type="button"
                            onClick={() => scrollTabs('left')}
                            className="absolute left-2 top-1/2 -translate-y-1/2 rounded-full border border-slate-200 bg-white/95 p-1.5 text-slate-500 shadow-sm transition hover:text-slate-800"
                            aria-label="Voir les onglets précédents"
                        >
                            <ChevronLeft size={14} />
                        </button>
                    )}
                    {canScrollTabsRight && (
                        <button
                            type="button"
                            onClick={() => scrollTabs('right')}
                            className="absolute right-2 top-1/2 -translate-y-1/2 rounded-full border border-slate-200 bg-white/95 p-1.5 text-slate-500 shadow-sm transition hover:text-slate-800"
                            aria-label="Voir plus d'onglets"
                        >
                            <ChevronRight size={14} />
                        </button>
                    )}
                </div>
            </div>

            {/* Content Grid */}
            <div className={`flex-1 ${
                (isMeasurementsTab || isPlansTab)
                    ? 'overflow-hidden h-[calc(100%-80px)]'
                    : isPreconisationsTab
                        ? 'overflow-hidden h-[calc(100%-80px)]'
                        : 'grid grid-cols-1 lg:grid-cols-[minmax(0,1.12fr)_minmax(0,1.88fr)] gap-4 overflow-hidden h-[calc(100%-80px)]'
            }`}>
                {(isMeasurementsTab || isPlansTab) ? (
                    <div className="h-full flex flex-col overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
                        <NotesCanvas
                            key={`${activeTab}-${currentNotePage.pageNumber}`}
                            documentKey={currentNoteIdentity}
                            placeholder=""
                            currentPage={currentLocalPage}
                            totalPages={isPlansTab ? Math.max(notePageNumbers.length, 1) : 1}
                            initialText={currentNotePage.textContent}
                            initialDrawingJson={currentNotePage.drawingJson}
                            onPageChange={handlePageChange}
                            onSave={handleSaveNote}
                            onDraftChange={handleNoteDraftChange}
                            onAddPage={isPlansTab ? handleAddPage : undefined}
                            onDeletePage={isPlansTab ? handleDeletePage : undefined}
                            canDeletePage={isPlansTab && notePageNumbers.length > 1 && Boolean(currentNotePage.id) && !isMutatingPages}
                            mode={isPlansTab ? 'grid' : 'freeform'}
                            showText={false}
                            toolset={isPlansTab ? 'structured' : 'advanced'}
                            allowPagination={isPlansTab}
                            showSaveButton={false}
                            embedded
                            fillParentHeight={isPlansTab}
                            canvasMinHeightClassName={isPlansTab ? 'h-full min-h-0' : 'min-h-[620px] md:min-h-[660px]'}
                            toolbarPlacement={isPlansTab ? 'bottom-center' : 'top-right'}
                            toolbarInFooter={false}
                            toolbarDockedToBorder={isPlansTab}
                            toolbarOffsetClassName={isPlansTab ? '!bottom-10' : undefined}
                            activeTool={isPlansTab ? plansActiveTool : undefined}
                            onToolChange={isPlansTab ? setPlansActiveTool : undefined}
                            backgroundContent={isMeasurementsTab ? <MeasurementsCanvasBackground /> : undefined}
                        />
                    </div>
                ) : isPreconisationsTab ? (
                    <div onBlur={() => { void flushActiveTabSaves(); }} className={`h-full overflow-y-auto rounded-3xl bg-white pl-1 pr-4 custom-scrollbar relative ${hasInnerQuickNav ? 'pt-0 pb-5' : 'py-5'}`}>
                        {renderTabContent()}
                    </div>
                ) : (
                    <>
                {/* Form Panel */}
                <div onBlur={() => { void flushActiveTabSaves(); }} className={`bg-white rounded-3xl pl-1 pr-4 overflow-y-auto custom-scrollbar relative ${hasInnerQuickNav ? 'pt-0 pb-5' : 'py-5'}`}>
                    {renderTabContent()}
                </div>

                {/* Notes Panel */}
                <div className="h-full flex flex-col">
                    <div className="flex h-full flex-col overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
                        <NotesCanvas
                            key={`${activeTab}-${currentNotePage.pageNumber}`}
                            documentKey={currentNoteIdentity}
                            placeholder={isStructuredGridTab ? '' : `Notes pour ${activeTab} (Texte + Dessin)...`}
                            currentPage={currentLocalPage}
                            totalPages={isStructuredGridTab ? 1 : Math.max(notePageNumbers.length, 1)}
                            initialText={currentNotePage.textContent}
                            initialDrawingJson={currentDrawingNotePage.drawingJson}
                            onPageChange={handlePageChange}
                            onSave={handleSaveNote}
                            onDraftChange={handleNoteDraftChange}
                            onAddPage={isStructuredGridTab ? undefined : handleAddPage}
                            onDeletePage={isStructuredGridTab ? undefined : handleDeletePage}
                            canDeletePage={!isStructuredGridTab && notePageNumbers.length > 1 && (Boolean(currentDrawingNotePage.id) || Boolean(currentTextNotePage.id)) && !isMutatingPages}
                            mode={noteLayoutKind}
                            showText={!isStructuredGridTab}
                            toolset={isStructuredGridTab ? 'structured' : 'advanced'}
                            allowPagination={!isStructuredGridTab}
                            showSaveButton={false}
                            embedded
                        />
                    </div>
                </div>
                    </>
                )}
            </div>
        </div>
    );
};

// =============================================================
// --- Sub-Components (unchanged design system) ---
// =============================================================

const BeneficiaryForm: React.FC<{
    data: any,
    activeQuickLink: 'profile' | 'finance' | 'health' | 'admin',
    onQuickLinkChange: (section: 'profile' | 'finance' | 'health' | 'admin') => void,
    fiscalRevenueDraft: string,
    onFiscalRevenueChange: (value: string) => void,
    onFiscalRevenueFocus: () => void,
    onFiscalRevenueBlur: () => void,
    onChange: (f: string, v: any) => void,
    refSituations: RefOption[],
    refDependances: RefOption[],
    retirementFundOptions: string[],
    principalRetirementFundOptions: string[],
    refCommunes: CommuneOption[]
}> = ({
    data,
    activeQuickLink,
    onQuickLinkChange,
    fiscalRevenueDraft,
    onFiscalRevenueChange,
    onFiscalRevenueFocus,
    onFiscalRevenueBlur,
    onChange,
    refSituations,
    refDependances,
    retirementFundOptions,
    principalRetirementFundOptions,
    refCommunes
}) => {
    const phoneInvalid = !isValidFrenchPhone(data.phone);
    const emailInvalid = !isValidEmail(data.email);
    const trustedPhoneInvalid = !isValidFrenchPhone(data.trustedPhone);
    const trustedEmailInvalid = !isValidEmail(data.trustedEmail);
    const occupantCount = Math.max(1, Number.parseInt(String(data.numberPeople || '1'), 10) || 1);
    const displayedOccupants = buildOccupantsFromPatient(data, data.numberPeople).slice(0, occupantCount);
    const hasMultipleOccupants = displayedOccupants.length > 1;
    const [activeOccupantIndex, setActiveOccupantIndex] = useState(0);

    useEffect(() => {
        if (activeOccupantIndex >= displayedOccupants.length) {
            setActiveOccupantIndex(0);
        }
    }, [activeOccupantIndex, displayedOccupants.length]);

    const activeOccupant = displayedOccupants[activeOccupantIndex] || createEmptyOccupant();
    const activeOccupantAge = computeAgeFromBirthDate(activeOccupant.birthDate);
    const familySituationOptions = buildToggleOptions(refSituations, data.familySituation);
    const dependenceOptions = buildToggleOptions(refDependances, activeOccupant.dependenceTxt, 'Aucune');
    const selectedComplementaryFunds = parseComplementaryFundNames(activeOccupant.caissesRetraiteComplementaires);
    const updateActiveOccupant = (field: keyof ReturnType<typeof createEmptyOccupant>, value: string | boolean) => {
        const nextOccupants = buildOccupantsFromPatient(data, data.numberPeople);
        nextOccupants[activeOccupantIndex] = {
            ...nextOccupants[activeOccupantIndex],
            [field]: value,
        };
        if (field === 'homeHelp' && !value) {
            nextOccupants[activeOccupantIndex].homeHelpTxt = '';
        }
        if (field === 'invalidity' && !value) {
            nextOccupants[activeOccupantIndex].invalidityTxt = '';
        }
        onChange('occupants', nextOccupants);
    };
    const updateComplementaryFunds = (fundName: string, checked: boolean) => {
        const nextFunds = checked
            ? Array.from(new Set([...selectedComplementaryFunds, fundName]))
            : selectedComplementaryFunds.filter((entry) => entry !== fundName);
        updateActiveOccupant('caissesRetraiteComplementaires', nextFunds.join(', '));
    };
    const renderOccupantSwitcher = (title: string, tone: 'default' | 'soft' = 'default') => (
        <div className="flex items-center justify-between gap-3">
            <span>{title}</span>
            {hasMultipleOccupants && (
                <div className="flex items-center gap-2">
                    {displayedOccupants.map((occupant, index) => (
                        <button
                            key={`occupant-${title}-${index}`}
                            type="button"
                            onClick={() => setActiveOccupantIndex(index)}
                            className={`flex min-w-[72px] items-center justify-center rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors ${
                                activeOccupantIndex === index
                                    ? 'border-[#907CA1] bg-[#F4EFF7] text-[#554A63]'
                                    : tone === 'soft'
                                        ? 'border-slate-200 bg-slate-50 text-slate-400'
                                        : 'border-slate-200 bg-white text-slate-400'
                            }`}
                            title={formatOccupantLabel(occupant, index)}
                            aria-label={`Afficher ${formatOccupantLabel(occupant, index)}`}
                        >
                            {formatOccupantSwitcherLabel(occupant, index)}
                        </button>
                    ))}
                </div>
            )}
        </div>
    );

    return (
    <div className="space-y-6">
        <div className="sticky top-0 z-10 -mx-1 rounded-[22px] border border-slate-200 bg-white/95 px-2 py-2 backdrop-blur">
            <div className="grid grid-cols-4 gap-2">
                <QuickNavButton icon={User} label="Profil" active={activeQuickLink === 'profile'} onClick={() => onQuickLinkChange('profile')} />
                <QuickNavButton icon={Coins} label="Revenus" active={activeQuickLink === 'finance'} onClick={() => onQuickLinkChange('finance')} />
                <QuickNavButton icon={Heart} label="Santé" active={activeQuickLink === 'health'} onClick={() => onQuickLinkChange('health')} />
                <QuickNavButton icon={FolderOpen} label="Dossier" active={activeQuickLink === 'admin'} onClick={() => onQuickLinkChange('admin')} />
            </div>
        </div>

        {activeQuickLink === 'profile' && (
        <div className="space-y-6">
            <Section title={renderOccupantSwitcher('Identité')}>
                <div className="grid grid-cols-2 gap-2">
                    <Input
                        label="Nom"
                        value={activeOccupant.lastName || ''}
                        onChange={v => updateActiveOccupant('lastName', v)}
                    />
                    <Input
                        label="Prénom"
                        value={activeOccupant.firstName || ''}
                        onChange={v => updateActiveOccupant('firstName', v)}
                    />
                </div>
                <div className="grid grid-cols-2 gap-2">
                    <Input
                        label="Date de naissance"
                        type="date"
                        value={activeOccupant.birthDate || ''}
                        onChange={v => updateActiveOccupant('birthDate', v)}
                    />
                    <div className="flex items-end justify-center h-full pb-5 -ml-[50px]">
                        <span className="text-sm font-extrabold text-[#554A63]">{activeOccupantAge ? `${activeOccupantAge} !` : ''}</span>
                    </div>
                </div>
            </Section>
            <Section title="Coordonnées">
                <Input
                    label="Adresse du logement"
                    value={data.address || ''}
                    onChange={v => onChange('address', v)}
                />
                <CommuneFieldGroup
                    city={data.city}
                    zipCode={data.zipCode}
                    cityId={data.cityId}
                    options={refCommunes}
                    zipLabel="Code postal"
                    onChange={(updates) => {
                        if (Object.prototype.hasOwnProperty.call(updates, 'zipCode')) onChange('zipCode', updates.zipCode ?? '');
                        if (Object.prototype.hasOwnProperty.call(updates, 'city')) onChange('city', updates.city ?? '');
                        if (Object.prototype.hasOwnProperty.call(updates, 'cityId')) onChange('cityId', updates.cityId ?? '');
                    }}
                />
                <Input
                    label="Téléphone"
                    type="tel"
                    value={data.phone}
                    onChange={v => onChange('phone', v)}
                    showWarningIcon={phoneInvalid}
                    warningLabel="Numéro français invalide"
                />
                <Input
                    label="Email"
                    type="email"
                    value={data.email}
                    onChange={v => onChange('email', v)}
                    showWarningIcon={emailInvalid}
                    warningLabel="Adresse mail invalide"
                />
            </Section>
        </div>
        )}

        {activeQuickLink === 'finance' && (
        <div className="space-y-6">
            <Section title="Situation">
                <ToggleGroup
                    label="Situation familiale"
                    options={familySituationOptions}
                    selected={data.familySituation}
                    onSelect={v => onChange('familySituation', v)}
                    small
                />
                <ToggleGroup label="Occupation" options={['Propriétaire', 'Locataire', 'Usufruitier']} selected={data.occupationStatus} onSelect={v => onChange('occupationStatus', v)} small />
            </Section>
            <Section title="Revenus">
                <ReadOnlyField
                    label="Catégorie"
                    value={data.incomeCategory || 'Calcul automatique'}
                    hint="Calculée automatiquement à partir des revenus et du foyer."
                />
                <Input
                    label="Revenu Fiscal Ref."
                    type="number"
                    value={fiscalRevenueDraft}
                    onChange={onFiscalRevenueChange}
                    onFocus={onFiscalRevenueFocus}
                    onBlur={onFiscalRevenueBlur}
                />
            </Section>
        </div>
        )}

        {activeQuickLink === 'health' && (
        <div className="space-y-6">
            <Section title={renderOccupantSwitcher('Santé', 'soft')}>
                <div className="space-y-3">
                    <Checkbox label="Bénéficiaire APA" checked={Boolean(activeOccupant.apa)} onChange={v => updateActiveOccupant('apa', v)} />
                    <Checkbox label="Reconnaissance Invalidité" checked={Boolean(activeOccupant.invalidity)} onChange={v => updateActiveOccupant('invalidity', v)} />
                    <Checkbox label="Aide à domicile" checked={Boolean(activeOccupant.homeHelp)} onChange={v => updateActiveOccupant('homeHelp', v)} />
                    <ToggleGroup
                        label="Dépendance"
                        options={dependenceOptions}
                        selected={activeOccupant.dependenceTxt || 'Aucune'}
                        onSelect={v => updateActiveOccupant('dependenceTxt', v === 'Aucune' ? '' : v)}
                        small
                    />
                </div>
            </Section>
            <Section title="Personne de Confiance">
                <Input label="Nom" value={data.trustedName} onChange={v => onChange('trustedName', v)} />
                <div className="grid grid-cols-2 gap-2 mt-2">
                    <Input
                        label="Téléphone"
                        type="tel"
                        value={data.trustedPhone}
                        onChange={v => onChange('trustedPhone', v)}
                        showWarningIcon={trustedPhoneInvalid}
                        warningLabel="Numéro français invalide"
                    />
                    <Input
                        label="Email"
                        type="email"
                        value={data.trustedEmail}
                        onChange={v => onChange('trustedEmail', v)}
                        showWarningIcon={trustedEmailInvalid}
                        warningLabel="Adresse mail invalide"
                    />
                </div>
            </Section>
        </div>
        )}

        {activeQuickLink === 'admin' && (
        <div className="space-y-6">
            <Section title="Informations Administratives">
                <div className="space-y-3">
                    <Select
                        label="Création compte Anah"
                        value={data.compteAnah}
                        onChange={v => onChange('compteAnah', v)}
                        options={ANAH_ACCOUNT_OPTIONS}
                        placeholder="Sélectionner..."
                    />
                </div>
            </Section>
            <Section title={renderOccupantSwitcher('Personnel', 'soft')}>
                <div className="space-y-3">
                    <div className="grid grid-cols-2 gap-2">
                        <Input label="N° Sécu" value={activeOccupant.numeroSecuriteSociale || ''} onChange={v => updateActiveOccupant('numeroSecuriteSociale', v)} placeholder="1 23 45 67..." />
                        <Select
                            label="Caisse princ."
                            value={activeOccupant.caisseRetraitePrincipale || ''}
                            onChange={v => updateActiveOccupant('caisseRetraitePrincipale', v)}
                            options={principalRetirementFundOptions.map((name) => ({ id: name, label: name }))}
                            placeholder="Sélectionner..."
                        />
                    </div>
                    <MultiSelectDropdown
                        label="Caisses complém."
                        options={retirementFundOptions.map((fundName) => ({
                            label: fundName,
                            checked: selectedComplementaryFunds.includes(fundName),
                            onToggle: (checked) => updateComplementaryFunds(fundName, checked),
                        }))}
                        placeholder="Sélectionner une ou plusieurs caisses"
                    />
                </div>
            </Section>
            <Section title="Renseignements sur la visite">
                <ToggleGroup label="Envoi du rapport" options={['Mail', 'Courrier']} selected={data.envoiRapport} onSelect={v => onChange('envoiRapport', v)} small />
                <div className="pt-2">
                    <Input label="Personnes présentes à la visite" value={data.personnesPresentesVisite} onChange={v => onChange('personnesPresentesVisite', v)} placeholder="Bénéficiaire, proche, ergothérapeute..." />
                </div>
            </Section>
        </div>
        )}
    </div>
);
};

const QuickNavButton: React.FC<{
    icon: any;
    label: string;
    active?: boolean;
    onClick: () => void;
}> = ({ icon: Icon, label, active = false, onClick }) => (
    <button
        type="button"
        onClick={onClick}
        className={`flex items-center justify-center rounded-2xl px-2 py-3 text-xs font-bold transition-colors ${
            active ? 'bg-[#D8D0DC] text-[#554A63]' : 'text-slate-500 hover:bg-slate-100 hover:text-slate-800'
        }`}
        title={label}
        aria-label={label}
    >
        <Icon size={20} />
    </button>
);

const summarizeSelections = (labels: string[]) => {
    if (labels.length === 0) return '';
    if (labels.length <= 2) return labels.join(', ');
    return `${labels.slice(0, 2).join(', ')} +${labels.length - 2}`;
};

const MultiSelectDropdown: React.FC<{
    label: string;
    options: Array<{ label: string; checked: boolean; onToggle: (checked: boolean) => void }>;
    placeholder?: string;
}> = ({ label, options, placeholder = 'Sélectionner...' }) => {
    const [isOpen, setIsOpen] = useState(false);
    const containerRef = useRef<HTMLDivElement>(null);
    const selectedLabels = options.filter((option) => option.checked).map((option) => option.label);

    useEffect(() => {
        if (!isOpen) return undefined;

        const handlePointerDown = (event: MouseEvent) => {
            if (!containerRef.current?.contains(event.target as Node)) {
                setIsOpen(false);
            }
        };

        document.addEventListener('mousedown', handlePointerDown);
        return () => document.removeEventListener('mousedown', handlePointerDown);
    }, [isOpen]);

    return (
        <div className="mb-3" ref={containerRef}>
            <label className="mb-1 block text-xs font-bold text-slate-500">{label}</label>
            <div className="relative">
                <button
                    type="button"
                    onClick={() => setIsOpen((current) => !current)}
                    className="flex w-full items-center justify-between rounded-2xl border border-slate-200 bg-white px-3 py-2 text-left text-sm transition-colors hover:border-slate-300"
                >
                    <span className={selectedLabels.length > 0 ? 'text-slate-700' : 'text-slate-400'}>
                        {selectedLabels.length > 0 ? summarizeSelections(selectedLabels) : placeholder}
                    </span>
                    <ChevronDown size={16} className={`text-slate-400 transition-transform ${isOpen ? 'rotate-180' : ''}`} />
                </button>
                {isOpen && (
                    <div className="absolute left-0 right-0 top-full z-20 mt-2 rounded-2xl border border-slate-200 bg-white p-2 shadow-lg">
                        <div className="max-h-[138px] space-y-1 overflow-y-auto pr-1">
                            {options.map((option) => (
                                <label key={option.label} className="flex cursor-pointer items-center gap-3 rounded-xl px-3 py-2 hover:bg-slate-50">
                                    <input
                                        type="checkbox"
                                        checked={option.checked}
                                        onChange={(event) => option.onToggle(event.target.checked)}
                                        className="h-4 w-4 rounded border-slate-300 text-[#907CA1] focus:ring-[#907CA1]"
                                    />
                                    <span className="text-sm text-slate-700">{option.label}</span>
                                </label>
                            ))}
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

const MeasuredOptionCard: React.FC<{
    label: string;
    checked: boolean;
    value: string;
    onToggle: (checked: boolean) => void;
    onValueChange: (value: string) => void;
    helper?: string;
}> = ({ label, checked, value, onToggle, onValueChange, helper }) => (
    <div className={`rounded-[24px] border px-4 py-3 transition-colors ${checked ? 'border-[#907CA1] bg-[#F4EFF7]' : 'border-slate-200 bg-white'}`}>
        <button
            type="button"
            onClick={() => onToggle(!checked)}
            className="flex w-full items-start justify-between gap-3 text-left"
        >
            <div className="min-w-0 flex-1">
                <p className={`text-sm font-semibold ${checked ? 'text-[#554A63]' : 'text-slate-700'}`}>{label}</p>
            </div>
        </button>
        {checked && (
            <div className="mt-3 border-t border-[#907CA1]/15 pt-3">
                <Input
                    label="Hauteur"
                    type="number"
                    value={value}
                    onChange={onValueChange}
                    unit="cm"
                    placeholder="Saisir la hauteur"
                />
            </div>
        )}
    </div>
);

const BathroomPresenceOptionCard: React.FC<{
    label: string;
    description: string;
    selected: boolean;
    icon: React.ComponentType<{ size?: number; className?: string }>;
    onClick: () => void;
}> = ({ label, description, selected, icon: Icon, onClick }) => (
    <button
        type="button"
        onClick={onClick}
        className={`rounded-[24px] border px-4 py-3 text-left transition-colors ${
            selected
                ? 'border-[#907CA1] bg-[#F4EFF7]'
                : 'border-slate-200 bg-white hover:border-slate-300 hover:bg-slate-50'
        }`}
    >
        <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
                <p className={`text-sm font-semibold ${selected ? 'text-[#554A63]' : 'text-slate-700'}`}>{label}</p>
                <p className="mt-1 text-xs text-slate-500">{description}</p>
            </div>
            <span className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl ${
                selected ? 'bg-white text-[#907CA1]' : 'bg-slate-50 text-slate-400'
            }`}>
                <Icon size={18} />
            </span>
        </div>
    </button>
);

const ContextForm: React.FC<{
    data: any,
    beneficiary: any,
    activeContextSection: 'medical' | 'autonomy',
    onSectionChange: (section: 'medical' | 'autonomy') => void,
    onMedicalChange: (occupantIndex: number, field: string, value: string) => void,
    onToggleAutonomyDone: (occupantIndex: number) => void,
    onToggleAutonomyItem: (occupantIndex: number, itemIndex: number) => void,
    onToggleHumanHelpItem: (occupantIndex: number, itemIndex: number) => void,
}> = ({ data, beneficiary, activeContextSection, onSectionChange, onMedicalChange, onToggleAutonomyDone, onToggleAutonomyItem, onToggleHumanHelpItem }) => {
    const displayedOccupants = buildOccupantsFromPatient(beneficiary, beneficiary.numberPeople);
    const hasMultipleOccupants = displayedOccupants.length > 1;
    const [activeOccupantIndex, setActiveOccupantIndex] = useState(0);

    useEffect(() => {
        if (activeOccupantIndex >= displayedOccupants.length) {
            setActiveOccupantIndex(0);
        }
    }, [activeOccupantIndex, displayedOccupants.length]);

    const contextOccupants = buildContextOccupants(data, beneficiary);
    const activeContext = contextOccupants[activeOccupantIndex] || createEmptyContextOccupant(displayedOccupants[activeOccupantIndex]?.homeHelpTxt || '');
    const autonomyLocked = Boolean(activeContext.autonomyDone);
    const autonomyItems = Array.isArray(activeContext.autonomy) ? activeContext.autonomy : buildAutonomyItems();
    const humanHelpItems = Array.isArray(activeContext.humanHelp) ? activeContext.humanHelp : parseHumanHelpItems('');
    const humanHelpEnabled = Boolean(displayedOccupants[activeOccupantIndex]?.homeHelp) && !autonomyLocked;
    const toggleMedicalFlag = (field: 'pathology' | 'followUp' | 'sensory') => {
        const currentValue = String(activeContext.medical?.[field] || '').trim();
        onMedicalChange(activeOccupantIndex, field, currentValue ? '' : 'Oui');
    };
    const medicalFlagItems = [
        {
            key: 'pathology',
            label: 'Pathologie',
            completed: Boolean(String(activeContext.medical.pathology || '').trim()),
            onToggle: () => toggleMedicalFlag('pathology'),
        },
        {
            key: 'followUp',
            label: 'Suivi médical',
            completed: Boolean(String(activeContext.medical.followUp || '').trim()),
            onToggle: () => toggleMedicalFlag('followUp'),
        },
        {
            key: 'sensory',
            label: 'Sensoriel',
            completed: Boolean(String(activeContext.medical.sensory || '').trim()),
            onToggle: () => toggleMedicalFlag('sensory'),
        }
    ];
    return (
        <div className="space-y-6">
            <div className="sticky top-0 z-10 -mx-1 rounded-[22px] border border-slate-200 bg-white/95 px-2 py-2 backdrop-blur">
                <div className="grid grid-cols-2 gap-2">
                    <QuickNavButton icon={Heart} label="Informations médicales" active={activeContextSection === 'medical'} onClick={() => onSectionChange('medical')} />
                    <QuickNavButton icon={User} label="Autonomie" active={activeContextSection === 'autonomy'} onClick={() => onSectionChange('autonomy')} />
                </div>
            </div>

            {activeContextSection === 'medical' && (
                <Section title={
                    <div className="flex items-center justify-between gap-3">
                        <span>Médicales</span>
                        {hasMultipleOccupants && (
                            <div className="flex items-center gap-2">
                                {displayedOccupants.map((occupant, index) => (
                                    <button
                                        key={`context-medical-${index}`}
                                        type="button"
                                        onClick={() => setActiveOccupantIndex(index)}
                                        className={`flex min-w-[72px] items-center justify-center rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors ${
                                            activeOccupantIndex === index
                                                ? 'border-[#907CA1] bg-[#F4EFF7] text-[#554A63]'
                                                : 'border-slate-200 bg-white text-slate-400'
                                        }`}
                                        title={formatOccupantLabel(occupant, index)}
                                        aria-label={`Afficher ${formatOccupantLabel(occupant, index)}`}
                                    >
                                        {formatOccupantSwitcherLabel(occupant, index)}
                                    </button>
                                ))}
                            </div>
                        )}
                    </div>
                }>
                    <div className="space-y-2 rounded-2xl border border-slate-200 bg-slate-50/70 p-1.5">
                        {medicalFlagItems.map((item, index) => (
                            <MedicalFlagRow
                                key={item.key}
                                index={index + 1}
                                label={item.label}
                                completed={item.completed}
                                onToggle={item.onToggle}
                            />
                        ))}
                    </div>
                    <div className="mt-3">
                        <div className="mb-2 flex items-center gap-2">
                            <span className="text-[13px] font-semibold text-slate-700">Mesures</span>
                        </div>
                        <div className="grid grid-cols-2 gap-2">
                            <Input type="number" value={activeContext.medical.heightCm || ''} onChange={v => onMedicalChange(activeOccupantIndex, 'heightCm', v)} unit="cm" />
                            <Input type="number" value={activeContext.medical.weightKg || ''} onChange={v => onMedicalChange(activeOccupantIndex, 'weightKg', v)} unit="kg" />
                        </div>
                    </div>
                </Section>
            )}

            {activeContextSection === 'autonomy' && (
                <Section
                    title={
                        <div className="flex items-center justify-between gap-3">
                            <div className="flex items-center gap-2.5">
                                <button
                                    type="button"
                                    onClick={() => onToggleAutonomyDone(activeOccupantIndex)}
                                    className={`flex h-6 w-6 items-center justify-center rounded-full border transition-colors ${
                                        activeContext.autonomyDone ? 'border-[#907CA1] bg-[#907CA1] text-white' : 'border-[#907CA1]/45 text-[#907CA1]/55 hover:border-[#907CA1]'
                                    }`}
                                    title="Valider toute l'autonomie"
                                    aria-label="Valider toute l'autonomie"
                                >
                                    <Check size={12} strokeWidth={2.2} />
                                </button>
                                <span className="text-sm font-bold uppercase text-[#597E8D]">Autonomie</span>
                            </div>
                            <div className="flex items-center gap-2">
                                {hasMultipleOccupants && displayedOccupants.map((occupant, index) => (
                                    <button
                                        key={`context-autonomy-${index}`}
                                        type="button"
                                        onClick={() => setActiveOccupantIndex(index)}
                                        className={`flex min-w-[72px] items-center justify-center rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors ${
                                            activeOccupantIndex === index
                                                ? 'border-[#907CA1] bg-[#F4EFF7] text-[#554A63]'
                                                : 'border-slate-200 bg-white text-slate-400'
                                        }`}
                                        title={formatOccupantLabel(occupant, index)}
                                        aria-label={`Afficher ${formatOccupantLabel(occupant, index)}`}
                                    >
                                        {formatOccupantSwitcherLabel(occupant, index)}
                                    </button>
                                ))}
                                {humanHelpEnabled && (
                                    <span className="inline-flex min-w-[92px] items-center justify-center rounded-full bg-amber-100 px-2 py-1 text-center text-[10px] font-bold uppercase tracking-wider text-amber-700">
                                        Aide humaine
                                    </span>
                                )}
                            </div>
                        </div>
                    }
                >
                    <div className={`space-y-4 transition-opacity ${autonomyLocked ? 'opacity-55' : 'opacity-100'}`}>
                        <div className="rounded-2xl border border-slate-200 bg-slate-50/70 p-1.5">
                            <div className="space-y-2">
                            {autonomyItems.map((item: any, idx: number) => (
                                <NumberedCheckRow
                                    key={item.name}
                                    index={idx + 1}
                                    label={item.label || item.name}
                                    concernChecked={Boolean(item.checked)}
                                    onConcernToggle={() => onToggleAutonomyItem(activeOccupantIndex, idx)}
                                    helpChecked={Boolean(!item.checked && humanHelpItems[idx]?.checked)}
                                    onHelpToggle={() => onToggleHumanHelpItem(activeOccupantIndex, idx)}
                                    helpEnabled={humanHelpEnabled && !item.checked}
                                />
                            ))}
                            </div>
                        </div>
                    </div>
                    {autonomyLocked && (
                        <div className="mt-3 rounded-2xl bg-[#907CA1]/8 px-4 py-3 text-center text-sm font-bold text-[#554A63]">
                            La personne est considérée autonome sur l’ensemble de cette section.
                        </div>
                    )}
                </Section>
            )}
        </div>
    );
};

const MedicalFlagRow: React.FC<{
    index: number;
    label: string;
    completed: boolean;
    onToggle: () => void;
}> = ({ index, label, completed, onToggle }) => (
    <div className="px-1 py-1">
        <div className="flex items-center gap-2">
            <button
                type="button"
                onClick={onToggle}
                className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-[5px] border ${
                    completed ? 'border-[#907CA1] bg-[#907CA1] text-white' : 'border-[#907CA1]/55 bg-white text-transparent'
                }`}
                aria-label={`Cocher ${label}`}
                title={`Cocher ${label}`}
            >
                <Check size={10} />
            </button>
            <button
                type="button"
                onClick={onToggle}
                className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[10px] font-bold ${
                    completed ? 'bg-[#E9DFF0] text-[#554A63]' : 'bg-[#F4EFF7] text-[#554A63]'
                }`}
                aria-label={`Basculer ${label}`}
                title={`Basculer ${label}`}
            >
                {String(index).padStart(2, '0')}
            </button>
            <span className={`flex-1 text-[13px] ${completed ? 'text-slate-500 line-through' : 'font-medium text-slate-700'}`}>{label}</span>
        </div>
    </div>
);

const NumberedCheckRow: React.FC<{
    index: number;
    label: string;
    concernChecked: boolean;
    onConcernToggle: () => void;
    helpChecked: boolean;
    onHelpToggle: () => void;
    helpEnabled?: boolean;
}> = ({ index, label, concernChecked, onConcernToggle, helpChecked, onHelpToggle, helpEnabled = false }) => (
    <div className="flex items-center gap-2 rounded-xl px-2.5 py-1.5 transition-colors hover:bg-white">
        <button
            type="button"
            onClick={onConcernToggle}
            className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-[5px] border ${
                concernChecked ? 'border-[#907CA1] bg-[#907CA1] text-white' : 'border-[#907CA1]/55 bg-white text-transparent'
            }`}
            title="Non concerné"
            aria-label={`Non concerné pour ${label}`}
        >
            <Check size={10} />
        </button>
        <span className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[10px] font-bold ${
            concernChecked ? 'bg-[#E9DFF0] text-[#554A63]' : 'bg-white text-slate-500'
        }`}>
            {String(index).padStart(2, '0')}
        </span>
        <span className={`flex-1 text-[13px] ${concernChecked ? 'text-slate-500 line-through' : 'text-slate-700'}`}>{label}</span>
        {helpEnabled ? (
            <button
                type="button"
                onClick={onHelpToggle}
                className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-[5px] border ${
                    helpChecked ? 'border-amber-400 bg-amber-100 text-amber-700' : 'border-amber-300 bg-amber-50 text-transparent'
                } hover:border-amber-400`}
                title="Aide humaine"
                aria-label={`Aide humaine pour ${label}`}
            >
                <Check size={10} />
            </button>
        ) : null}
    </div>
);

const AccessForm: React.FC<{
    data: any,
    activeAccessSection: VisitReportLocation['accessSection'],
    onSectionChange: (section: VisitReportLocation['accessSection']) => void,
    onChange: (f: string, v: any) => void,
    onHeatingChange: (field: string, value: any) => void,
    refPorteGarage: RefOption[],
    refPortail: RefOption[]
}> = ({ data, activeAccessSection, onSectionChange, onChange, onHeatingChange, refPorteGarage, refPortail }) => {
    const selectedLevelOptions = useMemo(
        () => ACCESS_LEVEL_OPTIONS.filter((option) => Boolean(data[option.field]) && option.roomsField && option.roomOptions),
        [data],
    );
    const [activeInteriorLevelField, setActiveInteriorLevelField] = useState<string>(selectedLevelOptions[0]?.field || '');
    const [customRoomDrafts, setCustomRoomDrafts] = useState<Record<string, string>>({});

    useEffect(() => {
        if (selectedLevelOptions.length === 0) {
            if (activeInteriorLevelField !== '') {
                setActiveInteriorLevelField('');
            }
            return;
        }

        if (!selectedLevelOptions.some((option) => option.field === activeInteriorLevelField)) {
            setActiveInteriorLevelField(selectedLevelOptions[0].field);
        }
    }, [activeInteriorLevelField, selectedLevelOptions]);

    const handleAddCustomRoom = useCallback((roomsField: string) => {
        const rawDraft = customRoomDrafts[roomsField] || '';
        const trimmedDraft = rawDraft.trim();
        if (!trimmedDraft) return;

        const currentValues = Array.isArray(data[roomsField]) ? data[roomsField] : [];
        const alreadyExists = currentValues.some((value: string) => value.trim().toLowerCase() === trimmedDraft.toLowerCase());
        if (!alreadyExists) {
            onChange(roomsField, [...currentValues, trimmedDraft]);
        }
        setCustomRoomDrafts((previous) => ({ ...previous, [roomsField]: '' }));
    }, [customRoomDrafts, data, onChange]);

    const levelOptions = ACCESS_LEVEL_OPTIONS.map((option) => ({
        label: option.label,
        checked: Boolean(data[option.field]),
        onToggle: (checked: boolean) => {
            onChange(option.field, checked);
            if (!checked && option.roomsField) {
                onChange(option.roomsField, []);
            }
        },
    }));

    const pathOptions = ACCESS_PATH_OPTIONS.map((option) => ({
        label: option.label,
        checked: Boolean(data[option.field]),
        onToggle: (checked: boolean) => onChange(option.field, checked),
    }));

    const annexOptions = ANNEX_OPTIONS.map((option) => ({
        label: option.label,
        checked: Boolean(data[option.field]),
        onToggle: (checked: boolean) => onChange(option.field, checked),
    }));

    return (
        <div className="space-y-6">
            <div className="sticky top-0 z-10 -mx-1 rounded-[22px] border border-slate-200 bg-white/95 px-2 py-2 backdrop-blur">
                <div className="grid grid-cols-4 gap-2">
                    <QuickNavButton icon={House} label="Général" active={activeAccessSection === 'general'} onClick={() => onSectionChange('general')} />
                    <QuickNavButton icon={LayoutGrid} label="Intérieur" active={activeAccessSection === 'interior'} onClick={() => onSectionChange('interior')} />
                    <QuickNavButton icon={MapPin} label="Extérieur" active={activeAccessSection === 'exterior'} onClick={() => onSectionChange('exterior')} />
                    <QuickNavButton icon={Blinds} label="Volets" active={activeAccessSection === 'shutters'} onClick={() => onSectionChange('shutters')} />
                </div>
            </div>

            {activeAccessSection === 'general' && (
                <div className="space-y-6">
                    <Section title="Informations Générales">
                        <div className="grid grid-cols-2 gap-3">
                            <Input label="Année construction" value={data.yearConstruction} onChange={(v: any) => onChange('yearConstruction', v)} type="text" placeholder="Ex: 1987" />
                            <Input label="Année d'habitation" value={data.yearHabitation} onChange={(v: any) => onChange('yearHabitation', v)} type="text" placeholder="Ex: 2014" />
                        </div>
                        <div className="grid grid-cols-2 gap-3">
                            <Input label="Surface habitable" type="number" value={data.surface} onChange={(v: any) => onChange('surface', v)} unit="m²" />
                            <Select label="Nombre de niveaux" value={String(data.levels || '1')} onChange={(v: any) => onChange('levels', v)} options={LEVEL_COUNT_OPTIONS} placeholder="Sélectionner..." />
                        </div>
                        <ToggleGroup label="Type de logement" options={['Maison', 'Appartement']} selected={data.typology} onSelect={(v: any) => onChange('typology', v)} small />
                    </Section>
                </div>
            )}

            {activeAccessSection === 'interior' && (
                <div className="space-y-6">
                    <Section title="Niveaux & Pièces">
                        <MultiSelectDropdown label="Niveaux présents" options={levelOptions} placeholder="Sélectionner un ou plusieurs niveaux" />
                        {selectedLevelOptions.length > 0 && (
                            <div className="mt-4 space-y-3">
                                <div className="flex flex-wrap gap-2">
                                    {selectedLevelOptions.map((option) => (
                                        <button
                                            key={option.field}
                                            type="button"
                                            onClick={() => setActiveInteriorLevelField(option.field)}
                                            className={`rounded-full border px-3 py-1.5 text-xs font-bold uppercase tracking-wide transition-colors ${
                                                activeInteriorLevelField === option.field
                                                    ? 'border-[#907CA1] bg-[#F4EFF7] text-[#554A63]'
                                                    : 'border-slate-200 bg-white text-slate-500 hover:border-slate-300 hover:text-slate-700'
                                            }`}
                                        >
                                            {option.label}
                                        </button>
                                    ))}
                                </div>
                                {selectedLevelOptions
                                    .filter((option) => option.field === activeInteriorLevelField)
                                    .map((option) => (
                                        <div key={option.field} className="rounded-2xl border border-slate-200 bg-slate-50/70 px-4 py-3">
                                            <p className="mb-3 text-xs font-bold uppercase tracking-wide text-slate-500">{option.label}</p>
                                            <div className="grid grid-cols-2 gap-x-3 gap-y-2">
                                                {[
                                                    ...(option.roomOptions || []),
                                                    ...((Array.isArray(data[option.roomsField as string]) ? data[option.roomsField as string] : [])
                                                        .filter((room: string) => !(option.roomOptions || []).some((defaultRoom) => defaultRoom.toLowerCase() === String(room).trim().toLowerCase()))),
                                                ].map((room) => (
                                                    <Checkbox
                                                        key={`${option.field}-${room}`}
                                                        label={room}
                                                        checked={Array.isArray(data[option.roomsField as string]) && data[option.roomsField as string].includes(room)}
                                                        onChange={(checked) => onChange(
                                                            option.roomsField as string,
                                                            toggleChecklistValue(data[option.roomsField as string] || [], room, checked),
                                                        )}
                                                    />
                                                ))}
                                            </div>
                                            <div className="mt-3">
                                                <div className="relative">
                                                    <input
                                                        type="text"
                                                        value={customRoomDrafts[option.roomsField as string] || ''}
                                                        onChange={(event) => setCustomRoomDrafts((previous) => ({
                                                            ...previous,
                                                            [option.roomsField as string]: event.target.value,
                                                        }))}
                                                        onKeyDown={(event) => {
                                                            if (event.key === 'Enter') {
                                                                event.preventDefault();
                                                                handleAddCustomRoom(option.roomsField as string);
                                                            }
                                                        }}
                                                        placeholder="Ajouter un champ"
                                                        className="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 pr-11 text-sm text-slate-700 outline-none transition-colors focus:border-[#907CA1] focus:ring-2 focus:ring-[#907CA1]/20"
                                                    />
                                                    {Boolean((customRoomDrafts[option.roomsField as string] || '').trim()) && (
                                                        <button
                                                            type="button"
                                                            onClick={() => handleAddCustomRoom(option.roomsField as string)}
                                                            className="absolute right-2 top-1/2 flex h-7 w-7 -translate-y-1/2 items-center justify-center rounded-full bg-[#F4EFF7] text-[#554A63] transition-colors hover:bg-[#E9DFF0]"
                                                            aria-label="Ajouter ce champ"
                                                            title="Ajouter ce champ"
                                                        >
                                                            <Plus size={14} />
                                                        </button>
                                                    )}
                                                </div>
                                            </div>
                                        </div>
                                    ))}
                            </div>
                        )}
                    </Section>

                    <Section title="Chauffage">
                        <div className="mb-2.5">
                            <div className="grid grid-cols-2 gap-2">
                                {HEATING_OPTIONS.map((option) => {
                                    const checked = Boolean(data.heatingDetails?.[option.field]);
                                    return (
                                        <button
                                            key={option.field}
                                            type="button"
                                            onClick={() => {
                                                const nextChecked = !checked;
                                                onHeatingChange(option.field, nextChecked);
                                                const hasAnyHeating = nextChecked || HEATING_OPTIONS.some((entry) => (
                                                    entry.field !== option.field && Boolean(data.heatingDetails?.[entry.field])
                                                ));
                                                onChange('heatingMain', hasAnyHeating);
                                            }}
                                            className={`w-full rounded-lg border px-3 py-2.5 text-center text-sm font-medium transition-colors ${
                                                checked
                                                    ? 'border-[#907CA1] bg-[#907CA1] text-white'
                                                    : 'border-slate-200 bg-slate-50 text-slate-700 hover:border-slate-300'
                                            }`}
                                        >
                                            {option.label}
                                        </button>
                                    );
                                })}
                            </div>
                        </div>

                    </Section>
                </div>
            )}

            {activeAccessSection === 'exterior' && (
                <div className="space-y-3">
                    <Section title="Accès Depuis la Rue">
                        <ToggleGroup
                            options={['Facile', 'À revoir']}
                            selected={data.easyAccess ? 'Facile' : 'À revoir'}
                            onSelect={(value) => onChange('easyAccess', value === 'Facile')}
                            small
                        />
                        <TextArea
                            value={data.accessObservation}
                            onChange={(v: any) => onChange('accessObservation', v)}
                            rows={2}
                            placeholder={data.easyAccess ? "Observation d'accès si besoin..." : "Points à revoir: pente, marches, seuil, revêtement, éclairage..."}
                        />
                    </Section>

                    <div className="grid gap-1.5 xl:grid-cols-2">
                        <Section title="Chemin d'Accès">
                            <div className="flex flex-wrap gap-1.5">
                                {pathOptions.map((opt) => (
                                    <button
                                        key={opt.label}
                                        type="button"
                                        onClick={() => opt.onToggle(!opt.checked)}
                                        className={`rounded-xl border px-3 py-2 text-xs font-semibold transition-colors ${
                                            opt.checked
                                                ? 'border-[#907CA1] bg-[#907CA1] text-white'
                                                : 'border-slate-200 bg-slate-50 text-slate-600 hover:border-slate-300'
                                        }`}
                                    >
                                        {opt.label}
                                    </button>
                                ))}
                            </div>
                        </Section>

                        <Section title="Annexes & Motorisations">
                            <div className="flex flex-wrap gap-1.5">
                                {annexOptions.map((opt) => (
                                    <button
                                        key={opt.label}
                                        type="button"
                                        onClick={() => opt.onToggle(!opt.checked)}
                                        className={`rounded-xl border px-3 py-2 text-xs font-semibold transition-colors ${
                                            opt.checked
                                                ? 'border-[#907CA1] bg-[#907CA1] text-white'
                                                : 'border-slate-200 bg-slate-50 text-slate-600 hover:border-slate-300'
                                        }`}
                                    >
                                        {opt.label}
                                    </button>
                                ))}
                            </div>
                            <div className="mt-0.5 grid grid-cols-2 gap-2">
                                <IconToggleRow
                                    label="Porte garage"
                                    options={refPorteGarage}
                                    selected={data.motorisationPorteGarage || ''}
                                    onSelect={(v) => onChange('motorisationPorteGarage', v)}
                                />
                                <IconToggleRow
                                    label="Portail"
                                    options={refPortail}
                                    selected={data.motorisationPortail || ''}
                                    onSelect={(v) => onChange('motorisationPortail', v)}
                                />
                            </div>
                        </Section>
                    </div>
                </div>
            )}

            {activeAccessSection === 'shutters' && (
                <VoletsFormSection data={data} onChange={onChange} />
            )}
        </div>
    );
};

const SalleDeBainForm: React.FC<{
    instances: BathroomLevelInstance[],
    activeBathroomSection: 'equipment' | 'door',
    onSectionChange: (section: 'equipment' | 'door') => void,
    onInstanceChange: (levelField: string, field: keyof BathroomLevelInstance, value: any) => void
}> = ({ instances, activeBathroomSection, onSectionChange, onInstanceChange }) => {
    const [activeLevelField, setActiveLevelField] = useState(instances[0]?.levelField || '');

    useEffect(() => {
        if (instances.length === 0) {
            if (activeLevelField !== '') setActiveLevelField('');
            return;
        }
        if (!instances.some((instance) => instance.levelField === activeLevelField)) {
            setActiveLevelField(instances[0].levelField);
        }
    }, [activeLevelField, instances]);

    const activeInstance = instances.find((instance) => instance.levelField === activeLevelField) || instances[0];
    if (!activeInstance) {
        return (
            <div className="rounded-2xl border border-dashed border-slate-300 bg-slate-50/70 px-4 py-5 text-sm text-slate-500">
                Coche une salle de bain dans Accessibilité pour afficher cette section.
            </div>
        );
    }

    const hasBath = Boolean(activeInstance.sdbBaignoire);
    const hasShower = Boolean(activeInstance.sdbBacDouche);
    const wetZoneSelection = hasBath && hasShower ? 'Douche + baignoire' : hasBath ? 'Baignoire' : hasShower ? 'Douche' : 'Aucune';
    const wetZoneEquipment = BATHROOM_MEASURED_EQUIPMENT.filter((item) =>
        item.requires === 'always'
            ? false
            : (item.requires === 'bath' && hasBath) || (item.requires === 'shower' && hasShower)
    );
    const commonBathroomEquipment = BATHROOM_MEASURED_EQUIPMENT.filter((item) => item.requires === 'always');

    const toggleWetZone = (zone: 'shower' | 'bath') => {
        if (zone === 'bath') {
            const next = !hasBath;
            onInstanceChange(activeInstance.levelField, 'sdbBaignoire', next);
            if (!next) {
                onInstanceChange(activeInstance.levelField, 'sdbBaignoireHauteur', null);
            }
        } else {
            const next = !hasShower;
            onInstanceChange(activeInstance.levelField, 'sdbBacDouche', next);
            if (!next) {
                onInstanceChange(activeInstance.levelField, 'sdbBacDoucheHauteur', null);
                onInstanceChange(activeInstance.levelField, 'sdbParoiDouche', false);
                onInstanceChange(activeInstance.levelField, 'sdbParoiDoucheHauteur', null);
            }
        }
    };

    return (
        <div className="space-y-6">
            <div className="flex flex-wrap gap-2">
                {instances.map((instance) => (
                    <button
                        key={instance.id}
                        type="button"
                        onClick={() => setActiveLevelField(instance.levelField)}
                        className={`rounded-full border px-3 py-1.5 text-xs font-bold uppercase tracking-wide transition-colors ${
                            activeLevelField === instance.levelField
                                ? 'border-[#907CA1] bg-[#F4EFF7] text-[#554A63]'
                                : 'border-slate-200 bg-white text-slate-500 hover:border-slate-300 hover:text-slate-700'
                        }`}
                    >
                        {instance.levelLabel}
                    </button>
                ))}
            </div>
            <div className="sticky top-0 z-10 -mx-1 rounded-[22px] border border-slate-200 bg-white/95 px-2 py-2 backdrop-blur">
                <div className="grid grid-cols-2 gap-2">
                    <QuickNavButton icon={Bath} label="Équipements" active={activeBathroomSection === 'equipment'} onClick={() => onSectionChange('equipment')} />
                    <QuickNavButton icon={DoorOpen} label="Porte" active={activeBathroomSection === 'door'} onClick={() => onSectionChange('door')} />
                </div>
            </div>

            {activeBathroomSection === 'equipment' && (
                <Section title={`Équipements Salle de Bain — ${activeInstance.levelLabel}`}>
                    <div className="space-y-4">
                        <div className="flex gap-2">
                            <button
                                type="button"
                                onClick={() => toggleWetZone('shower')}
                                className={`flex-1 rounded-xl border px-3 py-2 text-sm font-medium transition-colors ${
                                    hasShower
                                        ? 'border-[#907CA1] bg-[#907CA1] text-white'
                                        : 'border-slate-200 bg-slate-50 text-slate-700 hover:border-slate-300'
                                }`}
                            >
                                Douche
                            </button>
                            <button
                                type="button"
                                onClick={() => toggleWetZone('bath')}
                                className={`flex-1 rounded-xl border px-3 py-2 text-sm font-medium transition-colors ${
                                    hasBath
                                        ? 'border-[#907CA1] bg-[#907CA1] text-white'
                                        : 'border-slate-200 bg-slate-50 text-slate-700 hover:border-slate-300'
                                }`}
                            >
                                Baignoire
                            </button>
                        </div>

                        <div className="grid gap-4 xl:grid-cols-[minmax(0,1.05fr)_minmax(0,0.95fr)]">
                            {wetZoneEquipment.length > 0 && (
                                <div className="rounded-[28px] border border-slate-200 bg-slate-50/70 p-4">
                                    <div className="mb-3 flex items-center gap-2">
                                        <span className="flex h-9 w-9 items-center justify-center rounded-2xl bg-white text-[#907CA1] shadow-sm">
                                            <Bath size={18} />
                                        </span>
                                        <div>
                                            <p className="text-sm font-semibold text-slate-800">Zone douche / baignoire</p>
                                        </div>
                                    </div>
                                    <div className="grid gap-3">
                                        {wetZoneEquipment.map(({ enabledField, heightField, label }) => (
                                            <MeasuredOptionCard
                                                key={enabledField}
                                                label={label.replace(/^Hauteur\s+/i, '')}
                                                checked={Boolean(activeInstance[enabledField as keyof BathroomLevelInstance])}
                                                value={activeInstance[heightField as keyof BathroomLevelInstance]?.toString() || ''}
                                                onToggle={(checked) => {
                                                    onInstanceChange(activeInstance.levelField, enabledField as keyof BathroomLevelInstance, checked);
                                                    if (!checked) {
                                                        onInstanceChange(activeInstance.levelField, heightField as keyof BathroomLevelInstance, null);
                                                    }
                                                }}
                                                onValueChange={(value) => onInstanceChange(activeInstance.levelField, heightField as keyof BathroomLevelInstance, parseFloat(value) || null)}
                                            />
                                        ))}
                                    </div>
                                </div>
                            )}

                            <div className="space-y-4">
                                <div className="rounded-[28px] border border-slate-200 bg-slate-50/70 p-4">
                                    <div className="mb-3 flex items-center gap-2">
                                        <span className="flex h-9 w-9 items-center justify-center rounded-2xl bg-white text-[#907CA1] shadow-sm">
                                            <ShowerHead size={18} />
                                        </span>
                                        <div>
                                            <p className="text-sm font-semibold text-slate-800">Équipements complémentaires</p>
                                        </div>
                                    </div>
                                    <div className="grid gap-3">
                                        {commonBathroomEquipment.map(({ enabledField, heightField, label }) => (
                                            <MeasuredOptionCard
                                                key={enabledField}
                                                label={label.replace(/^Hauteur\s+/i, '')}
                                                checked={Boolean(activeInstance[enabledField as keyof BathroomLevelInstance])}
                                                value={activeInstance[heightField as keyof BathroomLevelInstance]?.toString() || ''}
                                                onToggle={(checked) => {
                                                    onInstanceChange(activeInstance.levelField, enabledField as keyof BathroomLevelInstance, checked);
                                                    if (!checked) {
                                                        onInstanceChange(activeInstance.levelField, heightField as keyof BathroomLevelInstance, null);
                                                    }
                                                }}
                                                onValueChange={(value) => onInstanceChange(activeInstance.levelField, heightField as keyof BathroomLevelInstance, parseFloat(value) || null)}
                                            />
                                        ))}
                                    </div>
                                </div>

                                <button
                                    type="button"
                                    onClick={() => onInstanceChange(activeInstance.levelField, 'sdbSolGlissant', !activeInstance.sdbSolGlissant)}
                                    className={`flex w-full items-center gap-3 rounded-[28px] border px-4 py-4 text-left transition-colors ${
                                        activeInstance.sdbSolGlissant ? 'border-amber-300 bg-amber-50' : 'border-slate-200 bg-white hover:border-slate-300'
                                    }`}
                                >
                                    <span className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl ${
                                        activeInstance.sdbSolGlissant ? 'bg-white text-amber-600' : 'bg-slate-50 text-slate-400'
                                    }`}>
                                        <AlertTriangle size={18} />
                                    </span>
                                    <p className="text-sm font-semibold text-slate-800">Sol glissant</p>
                                </button>
                            </div>
                        </div>
                    </div>
                </Section>
            )}

            {activeBathroomSection === 'door' && (
                <Section title={`Porte Salle de Bain — ${activeInstance.levelLabel}`}>
                    <ToggleGroup
                        label="Largeur de porte"
                        options={['Suffisante', 'À revoir']}
                        selected={activeInstance.porteSdbLargeurSuffisante ? 'Suffisante' : 'À revoir'}
                        onSelect={(value) => onInstanceChange(activeInstance.levelField, 'porteSdbLargeurSuffisante', value === 'Suffisante')}
                        small
                    />
                    <Input
                        label="Largeur de porte"
                        type="number"
                        value={activeInstance.porteSdbDimension?.toString() || ''}
                        onChange={v => onInstanceChange(activeInstance.levelField, 'porteSdbDimension', parseFloat(v) || null)}
                        unit="cm"
                    />
                    <ToggleGroup
                        label="Sens d'ouverture"
                        options={['Intérieur', 'Extérieur']}
                        selected={activeInstance.porteSdbSensAdapte ? 'Intérieur' : 'Extérieur'}
                        onSelect={(value) => onInstanceChange(activeInstance.levelField, 'porteSdbSensAdapte', value === 'Intérieur')}
                        small
                    />
                </Section>
            )}
        </div>
    );
};

const WCForm: React.FC<{
    instances: WcLevelInstance[],
    activeWcSection: 'main' | 'door',
    onSectionChange: (section: 'main' | 'door') => void,
    onInstanceChange: (levelField: string, field: keyof WcLevelInstance, value: any) => void
}> = ({ instances, activeWcSection, onSectionChange, onInstanceChange }) => {
    const [activeLevelField, setActiveLevelField] = useState(instances[0]?.levelField || '');

    useEffect(() => {
        if (instances.length === 0) {
            if (activeLevelField !== '') setActiveLevelField('');
            return;
        }
        if (!instances.some((instance) => instance.levelField === activeLevelField)) {
            setActiveLevelField(instances[0].levelField);
        }
    }, [activeLevelField, instances]);

    const activeInstance = instances.find((instance) => instance.levelField === activeLevelField) || instances[0];
    if (!activeInstance) {
        return (
            <div className="rounded-2xl border border-dashed border-slate-300 bg-slate-50/70 px-4 py-5 text-sm text-slate-500">
                Coche un WC dans Accessibilité pour afficher cette section.
            </div>
        );
    }

    return (
        <div className="space-y-6">
            <div className="flex flex-wrap gap-2">
                {instances.map((instance) => (
                    <button
                        key={instance.id}
                        type="button"
                        onClick={() => setActiveLevelField(instance.levelField)}
                        className={`rounded-full border px-3 py-1.5 text-xs font-bold uppercase tracking-wide transition-colors ${
                            activeLevelField === instance.levelField
                                ? 'border-[#907CA1] bg-[#F4EFF7] text-[#554A63]'
                                : 'border-slate-200 bg-white text-slate-500 hover:border-slate-300 hover:text-slate-700'
                        }`}
                    >
                        {instance.levelLabel}
                    </button>
                ))}
            </div>
            <div className="sticky top-0 z-10 -mx-1 rounded-[22px] border border-slate-200 bg-white/95 px-2 py-2 backdrop-blur">
                <div className="grid grid-cols-2 gap-2">
                    <QuickNavButton icon={Toilet} label="Configuration et équipements" active={activeWcSection === 'main'} onClick={() => onSectionChange('main')} />
                    <QuickNavButton icon={DoorOpen} label="Porte" active={activeWcSection === 'door'} onClick={() => onSectionChange('door')} />
                </div>
            </div>

            {activeWcSection === 'main' && (
                <Section title={`Équipements WC — ${activeInstance.levelLabel}`}>
                    <ToggleGroup
                        label="Hauteur de cuvette"
                        options={['Bonne hauteur', 'Trop basse']}
                        selected={activeInstance.wcCuvetteTropBasse ? 'Trop basse' : 'Bonne hauteur'}
                        onSelect={(value) => {
                            const isLow = value === 'Trop basse';
                            onInstanceChange(activeInstance.levelField, 'wcCuvetteBonneHauteur', !isLow);
                            onInstanceChange(activeInstance.levelField, 'wcCuvetteTropBasse', isLow);
                        }}
                        small
                    />
                    <Input
                        label="Hauteur cuvette"
                        type="number"
                        value={activeInstance.wcCuvetteHauteur?.toString() || ''}
                        onChange={v => onInstanceChange(activeInstance.levelField, 'wcCuvetteHauteur', parseFloat(v) || null)}
                        unit="cm"
                    />
                    <ToggleGroup
                        label="Barre de relèvement"
                        options={['Présente', 'Absente']}
                        selected={activeInstance.wcBarreRelevement ? 'Présente' : 'Absente'}
                        onSelect={(value) => onInstanceChange(activeInstance.levelField, 'wcBarreRelevement', value === 'Présente')}
                        small
                    />
                    <TextArea
                        placeholder="Observations utiles sur l'utilisation du WC..."
                        value={activeInstance.observationEquipementsUtilisation || ''}
                        onChange={v => onInstanceChange(activeInstance.levelField, 'observationEquipementsUtilisation', v)}
                        rows={3}
                    />
                </Section>
            )}

            {activeWcSection === 'door' && (
                <Section title={`Porte WC — ${activeInstance.levelLabel}`}>
                    <ToggleGroup
                        label="Largeur de porte"
                        options={['Suffisante', 'À revoir']}
                        selected={activeInstance.porteWcLargeurSuffisante ? 'Suffisante' : 'À revoir'}
                        onSelect={(value) => onInstanceChange(activeInstance.levelField, 'porteWcLargeurSuffisante', value === 'Suffisante')}
                        small
                    />
                    <Input
                        label="Largeur de porte"
                        type="number"
                        value={activeInstance.porteWcDimension?.toString() || ''}
                        onChange={v => onInstanceChange(activeInstance.levelField, 'porteWcDimension', parseFloat(v) || null)}
                        unit="cm"
                    />
                    <ToggleGroup
                        label="Sens d'ouverture"
                        options={['Intérieur', 'Extérieur']}
                        selected={activeInstance.porteWcSensAdapte ? 'Intérieur' : 'Extérieur'}
                        onSelect={(value) => onInstanceChange(activeInstance.levelField, 'porteWcSensAdapte', value === 'Intérieur')}
                        small
                    />
                </Section>
            )}

        </div>
    );
};

const VoletsFormSection: React.FC<{ data: any, onChange: (f: string, v: any) => void }> = ({ data, onChange }) => {
    const handleWholeHousingToggle = (entierField: string, localisationField: string, checked: boolean) => {
        onChange(entierField, checked);
        if (checked) {
            onChange(localisationField, '');
        }
    };

    return (
        <div className="space-y-6">
            <Section title="Volets roulants manuels">
                <Checkbox
                    label="Logement entier"
                    checked={data.voletsRoulantsManuelsEntier || false}
                    onChange={(v: any) => handleWholeHousingToggle('voletsRoulantsManuelsEntier', 'voletsRoulantsManuelsLocalisation', v)}
                />
                {!data.voletsRoulantsManuelsEntier && (
                    <div className="pt-2">
                        <Input
                            label="Localisation"
                            value={data.voletsRoulantsManuelsLocalisation || ''}
                            onChange={(v: any) => onChange('voletsRoulantsManuelsLocalisation', v)}
                        />
                    </div>
                )}
            </Section>
            <Section title="Volets roulants électriques">
                <Checkbox
                    label="Logement entier"
                    checked={data.voletsRoulantsElectriquesEntier || false}
                    onChange={(v: any) => handleWholeHousingToggle('voletsRoulantsElectriquesEntier', 'voletsRoulantsElectriquesLocalisation', v)}
                />
                {!data.voletsRoulantsElectriquesEntier && (
                    <div className="pt-2">
                        <Input
                            label="Localisation"
                            value={data.voletsRoulantsElectriquesLocalisation || ''}
                            onChange={(v: any) => onChange('voletsRoulantsElectriquesLocalisation', v)}
                        />
                    </div>
                )}
            </Section>
            <Section title="Volets persiennes">
                <Checkbox
                    label="Logement entier"
                    checked={data.voletsPersiennesEntier || false}
                    onChange={(v: any) => handleWholeHousingToggle('voletsPersiennesEntier', 'voletsPersiennesLocalisation', v)}
                />
                {!data.voletsPersiennesEntier && (
                    <div className="pt-2">
                        <Input
                            label="Localisation"
                            value={data.voletsPersiennesLocalisation || ''}
                            onChange={(v: any) => onChange('voletsPersiennesLocalisation', v)}
                        />
                    </div>
                )}
            </Section>
        </div>
    );
};

const normalizePreconLookupKey = (value?: string) => String(value || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();

const extractImageFileKey = (value?: string) => {
    const raw = String(value || '').trim();
    if (!raw) return '';
    try {
        const parsed = raw.startsWith('http://') || raw.startsWith('https://')
            ? new URL(raw)
            : new URL(raw, window.location.origin);
        const fileName = parsed.pathname.split('/').filter(Boolean).at(-1) || '';
        return normalizePreconLookupKey(decodeURIComponent(fileName));
    } catch {
        const fileName = raw.split(/[/?#]/).filter(Boolean).at(-1) || '';
        return normalizePreconLookupKey(fileName);
    }
};

const PreconisationsForm: React.FC<{
    items: VisitRecommendationItem[];
    wikiItems: WikiLibraryItem[];
    onAdd: () => string;
    onRemove: (itemId: string) => void;
    onUpdate: (itemId: string, updates: Partial<VisitRecommendationItem>) => void;
}> = ({ items, wikiItems, onAdd, onRemove, onUpdate }) => {
    const [activePickerId, setActivePickerId] = useState<string | null>(null);
    const [pendingDescriptionChoice, setPendingDescriptionChoice] = useState<{
        itemId: string;
        wikiItem: WikiLibraryItem;
        descriptions: string[];
        selectedIndex: number;
    } | null>(null);
    const [selectedTag, setSelectedTag] = useState<string | null>(null);
    const [search, setSearch] = useState('');
    const availableImages = wikiItems.filter((item) => Boolean(item.imageUrl));
    const activePickerItem = items.find((item) => item.id === activePickerId) || null;
    const availableTags = useMemo(() => {
        const tags = new Set(WIKI_FILTER_TAGS);
        availableImages.forEach((item) => item.tags.forEach((tag) => tags.add(tag)));
        return Array.from(tags)
            .filter((tag) => availableImages.some((item) => item.tags.includes(tag)))
            .sort((left, right) => left.localeCompare(right));
    }, [availableImages]);
    const filteredImages = useMemo(() => {
        const normalized = search.trim().toLowerCase();
        return availableImages.filter((item) => {
            const matchesTag = selectedTag ? item.tags.includes(selectedTag) : true;
            const haystack = `${item.title} ${searchableWikiDescriptionText(item.description)} ${item.tags.join(' ')}`.toLowerCase();
            const matchesSearch = normalized ? haystack.includes(normalized) : true;
            return matchesTag && matchesSearch;
        });
    }, [availableImages, search, selectedTag]);

    const applyWikiSelection = (targetItem: VisitRecommendationItem, wikiItem: WikiLibraryItem, selectedDescription: string) => {
        onUpdate(targetItem.id, {
            wikiItemId: wikiItem.id,
            wikiTitle: wikiItem.title,
            wikiImageUrl: wikiItem.imageUrl,
            wikiTag: wikiItem.tags?.[0] || '',
            note: targetItem.note || selectedDescription || '',
        });
        setActivePickerId(null);
        setPendingDescriptionChoice(null);
    };
    const pendingTargetItem = pendingDescriptionChoice
        ? items.find((item) => item.id === pendingDescriptionChoice.itemId) || null
        : null;

    return (
        <div className="space-y-6">
            <Section title="Préconisations visuelles">
                {items.length === 0 && (
                    <div className="rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-4 py-5 text-sm text-slate-500">
                        Aucune préconisation pour l'instant.
                    </div>
                )}

                <div className="space-y-4">
                    {items.map((item, index) => {
                        const selectedWikiItem = availableImages.find((wikiItem) => wikiItem.id === item.wikiItemId)
                            || availableImages.find((wikiItem) => normalizePreconLookupKey(wikiItem.title) === normalizePreconLookupKey(item.wikiTitle))
                            || availableImages.find((wikiItem) => extractImageFileKey(wikiItem.imageUrl) === extractImageFileKey(item.wikiImageUrl));
                        const displayTitle = item.customTitle || selectedWikiItem?.title || item.wikiTitle || `Préconisation ${index + 1}`;
                        const displayImage = selectedWikiItem?.imageUrl || item.wikiImageUrl;

                        return (
                            <div key={item.id} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                                <div className="flex items-center justify-between gap-3">
                                    <input
                                        type="text"
                                        value={displayTitle}
                                        onChange={(e) => onUpdate(item.id, { customTitle: e.target.value })}
                                        className="flex-1 bg-transparent text-sm font-semibold text-slate-800 outline-none"
                                    />
                                    <div className="flex items-center gap-1 shrink-0">
                                        {displayImage && (
                                            <button
                                                type="button"
                                                onClick={() => setActivePickerId(item.id)}
                                                className="rounded-full px-2 py-1 text-xs font-medium text-[#7B688D] transition hover:bg-[#F4EFF7] hover:text-[#5f506e]"
                                            >
                                                Changer d'image
                                            </button>
                                        )}
                                        <button
                                            type="button"
                                            onClick={() => onRemove(item.id)}
                                            className="rounded-full p-2 text-slate-400 transition hover:bg-slate-100 hover:text-slate-700"
                                            aria-label="Supprimer cette préconisation"
                                        >
                                            <Trash2 size={16} />
                                        </button>
                                    </div>
                                </div>

                                <div className="mt-4 grid gap-4 lg:grid-cols-[minmax(0,1fr)_180px]">
                                    <div className="space-y-3">
                                        {!displayImage && (
                                            <button
                                                type="button"
                                                onClick={() => setActivePickerId((prev) => prev === item.id ? null : item.id)}
                                                className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm font-medium text-slate-700 transition hover:border-slate-300"
                                            >
                                                <ImagePlus size={16} />
                                                Choisir une image dans la bibliothèque
                                            </button>
                                        )}

                                        <TextArea
                                            placeholder="Texte libre pour cette préconisation..."
                                                value={item.note || ''}
                                                onChange={(value) => onUpdate(item.id, { note: value })}
                                                rows={6}
                                            />
                                        </div>

                                    <div className="overflow-hidden rounded-2xl border border-slate-200 bg-slate-50">
                                        {displayImage ? (
                                            <img src={displayImage} alt={displayTitle} className="h-48 w-full object-cover" />
                                        ) : (
                                            <div className="flex h-48 flex-col items-center justify-center gap-2 text-center text-slate-400">
                                                <ImagePlus size={20} />
                                                <span className="text-sm font-medium">Aucune image sélectionnée</span>
                                            </div>
                                        )}
                                    </div>
                                </div>
                            </div>
                        );
                    })}
                </div>

                <button
                    type="button"
                    onClick={() => {
                        const newItemId = onAdd();
                        setActivePickerId(newItemId);
                    }}
                    className="mt-4 inline-flex items-center gap-2 rounded-xl bg-[#907CA1] px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-[#7f6c90]"
                >
                    <ImagePlus size={16} />
                    Ajouter une préconisation
                </button>
            </Section>

            {activePickerItem && (
                <ViewportOverlay
                    className="fixed inset-0 z-[90] flex min-h-screen w-screen items-center justify-center bg-slate-900/45 px-4 py-6 backdrop-blur-[2px]"
                    onClick={() => setActivePickerId(null)}
                >
                    <div
                        className="flex max-h-[88vh] w-full max-w-4xl flex-col overflow-hidden rounded-[28px] border border-slate-200 bg-white shadow-2xl"
                        onClick={(event) => event.stopPropagation()}
                    >
                        <div className="flex items-center justify-between border-b border-slate-100 px-5 py-4">
                            <div>
                                <h5 className="text-base font-semibold text-slate-800">Choisir une image du wiki</h5>
                                <p className="mt-1 text-sm text-slate-500">
                                    Sélectionne une image pour illustrer cette préconisation.
                                </p>
                            </div>
                            <button
                                type="button"
                                onClick={() => setActivePickerId(null)}
                                className="rounded-full px-3 py-2 text-sm font-medium text-slate-500 transition hover:bg-slate-100 hover:text-slate-800"
                            >
                                Fermer
                            </button>
                        </div>

                        <div className="overflow-y-auto p-5 custom-scrollbar">
                            <div className="mb-4 flex flex-col gap-3">
                                <div className="relative overflow-hidden rounded-full border border-slate-200 bg-white">
                                    <input
                                        type="text"
                                        placeholder="Rechercher une image..."
                                        value={search}
                                        onChange={(event) => {
                                            setSearch(event.target.value);
                                            setSelectedTag(null);
                                        }}
                                        className="w-full bg-transparent py-3 pl-5 pr-10 text-slate-900 outline-none placeholder-slate-400"
                                    />
                                    <Search className="absolute right-4 top-1/2 -translate-y-1/2 text-slate-500" size={18} />
                                </div>

                                <div className="flex flex-wrap gap-2">
                                    {availableTags.map((tag) => (
                                        <button
                                            key={tag}
                                            type="button"
                                            onClick={() => setSelectedTag(tag === selectedTag ? null : tag)}
                                            className={`rounded-full px-4 py-2 text-sm font-medium transition-colors whitespace-nowrap ${
                                                tag === selectedTag
                                                    ? 'bg-[#907CA1] text-white'
                                                    : 'border border-slate-200 bg-white text-slate-600'
                                            }`}
                                        >
                                            {tag}
                                        </button>
                                    ))}
                                </div>
                            </div>

                            {availableImages.length === 0 ? (
                                <div className="rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-4 py-6 text-sm text-slate-500">
                                    Aucune image disponible dans la bibliothèque.
                                </div>
                            ) : filteredImages.length === 0 ? (
                                <div className="rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-4 py-6 text-sm text-slate-500">
                                    Aucun résultat pour ce filtre.
                                </div>
                            ) : (
                                <div className="grid grid-cols-3 gap-3">
                                    {filteredImages.map((wikiItem) => {
                                        const isSelected = wikiItem.id === activePickerItem.wikiItemId;
                                        return (
                                            <button
                                                key={wikiItem.id}
                                                type="button"
                                                onClick={() => {
                                                    const descriptions = parseWikiDescriptions(wikiItem.description);
                                                    if (descriptions.length > 1) {
                                                        setPendingDescriptionChoice({
                                                            itemId: activePickerItem.id,
                                                            wikiItem,
                                                            descriptions,
                                                            selectedIndex: 0,
                                                        });
                                                        return;
                                                    }
                                                    applyWikiSelection(activePickerItem, wikiItem, descriptions[0] || wikiItem.description || '');
                                                }}
                                                className={`overflow-hidden rounded-2xl border bg-white text-left transition ${
                                                    isSelected
                                                        ? 'border-[#907CA1] ring-2 ring-[#907CA1]/20'
                                                        : 'border-slate-200 hover:border-slate-300'
                                                }`}
                                            >
                                                <img src={wikiItem.imageUrl} alt={wikiItem.title} className="h-24 w-full object-cover" />
                                                <div className="space-y-1 px-2.5 py-2.5">
                                                    <div className="line-clamp-2 text-sm font-semibold text-slate-800">{wikiItem.title}</div>
                                                    {wikiItem.tags?.[0] && (
                                                        <div className="text-xs font-medium text-[#7B688D]">{wikiItem.tags[0]}</div>
                                                    )}
                                                </div>
                                            </button>
                                        );
                                    })}
                                </div>
                            )}
                        </div>
                    </div>
                </ViewportOverlay>
            )}

            {pendingDescriptionChoice && pendingTargetItem && (
                <ViewportOverlay
                    className="fixed inset-0 z-[100] flex min-h-screen w-screen items-center justify-center bg-slate-900/50 px-4 py-6 backdrop-blur-[2px]"
                    onClick={() => setPendingDescriptionChoice(null)}
                >
                    <div
                        className="w-full max-w-xl rounded-[24px] border border-slate-200 bg-white p-5 shadow-2xl"
                        onClick={(event) => event.stopPropagation()}
                    >
                        <div className="flex items-start justify-between gap-4">
                            <div>
                                <h5 className="text-base font-semibold text-slate-800">Choisir la description</h5>
                                <p className="mt-1 text-sm text-slate-500">{pendingDescriptionChoice.wikiItem.title}</p>
                            </div>
                            <button
                                type="button"
                                onClick={() => setPendingDescriptionChoice(null)}
                                className="rounded-full p-2 text-slate-500 transition hover:bg-slate-100 hover:text-slate-800"
                                aria-label="Fermer"
                            >
                                <X size={18} />
                            </button>
                        </div>

                        <div className="mt-4 space-y-2">
                            {pendingDescriptionChoice.descriptions.map((description, index) => {
                                const selected = index === pendingDescriptionChoice.selectedIndex;
                                return (
                                    <button
                                        key={index}
                                        type="button"
                                        onClick={() => setPendingDescriptionChoice((prev) => prev ? { ...prev, selectedIndex: index } : prev)}
                                        className={`flex w-full items-start gap-3 rounded-2xl border p-3 text-left transition ${
                                            selected
                                                ? 'border-[#907CA1] bg-[#F4EFF7]'
                                                : 'border-slate-200 bg-white hover:border-slate-300'
                                        }`}
                                    >
                                        <span className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border ${
                                            selected ? 'border-[#907CA1] bg-[#907CA1]' : 'border-slate-300 bg-white'
                                        }`}>
                                            {selected ? <span className="h-2 w-2 rounded-full bg-white" /> : null}
                                        </span>
                                        <span className="text-sm leading-relaxed text-slate-700">{description}</span>
                                    </button>
                                );
                            })}
                        </div>

                        <div className="mt-5 flex justify-end gap-2">
                            <button
                                type="button"
                                onClick={() => setPendingDescriptionChoice(null)}
                                className="rounded-xl px-4 py-2 text-sm font-semibold text-slate-600 transition hover:bg-slate-100"
                            >
                                Annuler
                            </button>
                            <button
                                type="button"
                                onClick={() => {
                                    const selected = pendingDescriptionChoice.descriptions[pendingDescriptionChoice.selectedIndex] || '';
                                    applyWikiSelection(pendingTargetItem, pendingDescriptionChoice.wikiItem, selected);
                                }}
                                className="rounded-xl bg-[#907CA1] px-4 py-2 text-sm font-semibold text-white transition hover:bg-[#7f6c90]"
                            >
                                Valider
                            </button>
                        </div>
                    </div>
                </ViewportOverlay>
            )}
        </div>
    );
};

const SyntheseForm: React.FC<{ data: ObservationsSynthese, onChange: (f: string, v: any) => void }> = ({ data, onChange }) => (
    <div className="space-y-6">
        <Section title="Observation sur les équipements">
            <TextArea placeholder="Difficultés rencontrées, changements envisagés, besoins..."
                value={data.observationEquipements || ''} onChange={v => onChange('observationEquipements', v)} rows={5} />
        </Section>
        <Section title="Projet ou souhait de l'usager">
            <TextArea placeholder="Décrivez le projet ou le souhait exprimé par le bénéficiaire..."
                value={data.projetSouhaitUsage || ''} onChange={v => onChange('projetSouhaitUsage', v)} rows={6} />
        </Section>
        <Section title="Résumé des préconisations">
            <TextArea placeholder="Synthèse des préconisations de l'ergothérapeute..."
                value={data.resumePreconisations || ''} onChange={v => onChange('resumePreconisations', v)} rows={8} />
        </Section>
    </div>
);

const MesuresForm: React.FC<{ data: MesuresAnthropometriques, onChange: (f: string, v: any) => void }> = ({ data, onChange }) => (
    <div className="space-y-6">
        <div className="rounded-[28px] border border-slate-200 bg-white p-4 md:p-6 shadow-sm">
            <div className="mb-5">
                <h4 className="text-sm font-bold uppercase tracking-wider text-[#597E8D]">Mesures anthropométriques</h4>
                <p className="mt-1 text-sm text-slate-500">Renseigne directement les mesures sur les silhouettes.</p>
            </div>

            <div className="grid grid-cols-1 xl:grid-cols-2 gap-6">
                <MeasurementFigureCard
                    title="Position assise"
                    imageSrc="/measurements/seated-figure.png"
                    imageAlt="Silhouette assise pour relever les mesures"
                    hotspots={[
                        {
                            label: "Hauteur coudes assis",
                            unit: "cm",
                            value: data.assisHauteurCoudes,
                            onChange: (value) => onChange('assisHauteurCoudes', value),
                            className: "left-[8%] top-[44%] md:left-[7%] md:top-[44%]",
                        },
                        {
                            label: "Profondeur genoux",
                            unit: "cm",
                            value: data.assisProfondeurGenoux,
                            onChange: (value) => onChange('assisProfondeurGenoux', value),
                            className: "left-[58%] top-[44%] md:left-[60%] md:top-[44%]",
                        },
                        {
                            label: "Hauteur d'assise",
                            unit: "cm",
                            value: data.assisHauteurAssise,
                            onChange: (value) => onChange('assisHauteurAssise', value),
                            className: "left-[8%] bottom-[13%] md:left-[7%] md:bottom-[12%]",
                        },
                    ]}
                />

                <MeasurementFigureCard
                    title="Position debout"
                    imageSrc="/measurements/standing-figure.png"
                    imageAlt="Silhouette debout pour relever les mesures"
                    hotspots={[
                        {
                            label: "Hauteur coude fléchi",
                            unit: "cm",
                            value: data.deboutHauteurCoude,
                            onChange: (value) => onChange('deboutHauteurCoude', value),
                            className: "left-[43%] top-[46%] md:left-[44%] md:top-[45%]",
                        },
                    ]}
                />
            </div>
        </div>

        <Section title="Observations">
            <TextArea
                placeholder="Remarques sur les mesures, posture particulière..."
                value={data.observations || ''}
                onChange={v => onChange('observations', v)}
                rows={5}
            />
        </Section>
    </div>
);

const MeasurementFigureCard: React.FC<{
    title: string;
    imageSrc: string;
    imageAlt: string;
    hotspots: Array<{
        label: string;
        unit: string;
        value?: number;
        onChange: (value: number | null) => void;
        className: string;
    }>;
}> = ({ title, imageSrc, imageAlt, hotspots }) => (
    <div className="rounded-[24px] border border-slate-200 bg-white p-4">
        <p className="mb-3 text-sm font-bold uppercase tracking-wider text-slate-500">{title}</p>
        <div className="relative overflow-hidden rounded-[24px] bg-white min-h-[560px] md:min-h-[640px]">
            <img
                src={imageSrc}
                alt={imageAlt}
                className="mx-auto h-full max-h-[640px] w-auto object-contain select-none pointer-events-none"
                draggable={false}
                onDragStart={(event) => event.preventDefault()}
                style={{
                    WebkitUserSelect: 'none',
                    userSelect: 'none',
                    WebkitUserDrag: 'none',
                    WebkitTouchCallout: 'none',
                }}
            />

            {hotspots.map((hotspot) => (
                <div key={hotspot.label} className={`absolute ${hotspot.className} z-10`}>
                    <MeasurementHotspot
                        label={hotspot.label}
                        unit={hotspot.unit}
                        value={hotspot.value}
                        onChange={hotspot.onChange}
                    />
                </div>
            ))}
        </div>
    </div>
);

const MeasurementHotspot: React.FC<{
    label: string;
    unit: string;
    value?: number;
    onChange: (value: number | null) => void;
}> = ({ label, unit, value, onChange }) => (
    <div className="rounded-2xl border border-slate-200 bg-white/95 px-3 py-2 shadow-lg backdrop-blur-sm">
        <p className="text-[10px] font-bold uppercase tracking-wider text-slate-500">{label}</p>
        <div className="mt-1 flex items-center gap-2">
            <input
                type="number"
                value={value?.toString() || ''}
                onChange={(event) => {
                    const nextValue = event.target.value.trim();
                    onChange(nextValue ? Number(nextValue) : null);
                }}
                className="w-24 rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm font-semibold text-slate-900 outline-none focus:border-[#907CA1] focus:ring-2 focus:ring-[#907CA1]/20"
                placeholder="0"
            />
            <span className="text-xs font-bold uppercase tracking-wider text-slate-400">{unit}</span>
        </div>
    </div>
);

const MeasurementsCanvasBackground: React.FC = () => (
    <div className="flex h-full w-full items-center justify-center bg-white px-8 py-8 md:px-12 md:py-8">
        <div className="flex h-full w-full max-w-6xl items-center justify-center gap-8 md:gap-14">
            <div className="flex h-full flex-1 items-center justify-center">
                <img
                    src="/measurements/seated-figure.png"
                    alt=""
                    className="max-h-[470px] md:max-h-[520px] w-auto object-contain pointer-events-none select-none"
                    draggable={false}
                    onDragStart={(event) => event.preventDefault()}
                    style={{
                        WebkitUserSelect: 'none',
                        userSelect: 'none',
                        WebkitUserDrag: 'none',
                        WebkitTouchCallout: 'none',
                    }}
                />
            </div>
            <div className="flex h-full flex-1 items-center justify-center">
                <img
                    src="/measurements/standing-figure.png"
                    alt=""
                    className="max-h-[470px] md:max-h-[520px] w-auto object-contain pointer-events-none select-none"
                    draggable={false}
                    onDragStart={(event) => event.preventDefault()}
                    style={{
                        WebkitUserSelect: 'none',
                        userSelect: 'none',
                        WebkitUserDrag: 'none',
                        WebkitTouchCallout: 'none',
                    }}
                />
            </div>
        </div>
    </div>
);

// =============================================================
// --- Primitive Design System Components ---
// =============================================================

const Section: React.FC<{ title: React.ReactNode, children: React.ReactNode }> = ({ title, children }) => (
    <div className="mb-5">
        <h4 className="mb-2 border-b border-slate-100 pb-1 text-sm font-bold uppercase tracking-[0.14em] text-[#597E8D]">{title}</h4>
        {children}
    </div>
);

const Select: React.FC<{ label?: string, value: string, onChange: (v: string) => void, options: RefOption[], placeholder?: string }> = ({ label, value, onChange, options, placeholder }) => {
    const [isOpen, setIsOpen] = useState(false);
    const containerRef = useRef<HTMLDivElement>(null);
    const selectedOption = options.find((option) => option.label === value);

    useEffect(() => {
        if (!isOpen) return undefined;

        const handlePointerDown = (event: MouseEvent) => {
            if (!containerRef.current?.contains(event.target as Node)) {
                setIsOpen(false);
            }
        };

        document.addEventListener('mousedown', handlePointerDown);
        return () => document.removeEventListener('mousedown', handlePointerDown);
    }, [isOpen]);

    return (
        <div className="mb-2.5" ref={containerRef}>
            {label && <label className={uiLabelClass}>{label}</label>}
            <div className="relative">
                <button
                    type="button"
                    onClick={() => setIsOpen((current) => !current)}
                    className={`${uiFieldClass} flex items-center justify-between text-left hover:border-slate-300`}
                >
                    <span className={selectedOption || value ? 'text-slate-700' : 'text-slate-400'}>
                        {selectedOption?.label || value || placeholder || 'Sélectionner...'}
                    </span>
                    <ChevronDown size={16} className={`text-slate-400 transition-transform ${isOpen ? 'rotate-180' : ''}`} />
                </button>
                {isOpen && (
                    <div className="absolute left-0 right-0 top-full z-20 mt-2 rounded-[22px] border border-slate-200 bg-white p-2 shadow-lg">
                        <div className="max-h-[138px] overflow-y-auto pr-1">
                            {placeholder && (
                                <button
                                    type="button"
                                    onClick={() => {
                                        onChange('');
                                        setIsOpen(false);
                                    }}
                                    className={`flex w-full items-center rounded-xl px-3 py-2 text-left text-sm transition-colors hover:bg-slate-50 ${
                                        !value ? 'bg-slate-50 text-slate-700' : 'text-slate-500'
                                    }`}
                                >
                                    {placeholder}
                                </button>
                            )}
                            {options.map((option) => {
                                const selected = option.label === value;
                                return (
                                    <button
                                        key={option.id}
                                        type="button"
                                        onClick={() => {
                                            onChange(option.label);
                                            setIsOpen(false);
                                        }}
                                        className={`flex w-full items-center justify-between rounded-xl px-3 py-2 text-left text-sm transition-colors hover:bg-slate-50 ${
                                            selected ? 'bg-[#F4EFF7] text-[#554A63]' : 'text-slate-700'
                                        }`}
                                    >
                                        <span>{option.label}</span>
                                        <span className={`flex h-4 w-4 items-center justify-center rounded-[5px] border ${
                                            selected ? 'border-[#907CA1] bg-[#907CA1] text-white' : 'border-slate-300 text-transparent'
                                        }`}>
                                            <Check size={10} />
                                        </span>
                                    </button>
                                );
                            })}
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

const Input: React.FC<{
    label?: string,
    type?: string,
    placeholder?: string,
    value: string,
    onChange: (v: string) => void,
    onBlur?: () => void,
    onFocus?: () => void,
    showWarningIcon?: boolean,
    warningLabel?: string,
    unit?: string
}> = ({ label, type = "text", placeholder, value, onChange, onBlur, onFocus, showWarningIcon = false, warningLabel = 'Valeur invalide', unit }) => (
        <div className="mb-2.5">
        {label && <label className={uiLabelClass}>{label}</label>}
        <div className="relative">
            <input type={type} placeholder={placeholder} value={value}
                onChange={e => onChange(e.target.value)}
                onFocus={onFocus}
                onBlur={onBlur}
                className={cx(
                    uiFieldClass,
                    showWarningIcon && uiFieldWarningClass,
                    unit && 'pr-10',
                    unit && showWarningIcon ? 'pr-16' : ''
                )} />
            {unit && (
                <span className={`absolute top-1/2 -translate-y-1/2 text-xs font-bold ${showWarningIcon ? 'right-8 text-amber-500' : 'right-3 text-slate-400'}`}>
                    {unit}
                </span>
            )}
            {showWarningIcon && (
                <span
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-amber-500"
                    title={warningLabel}
                    aria-label={warningLabel}
                >
                    <AlertTriangle size={14} />
                </span>
            )}
        </div>
    </div>
);

const TextArea: React.FC<{ placeholder?: string, value: string, onChange: (v: string) => void, rows?: number }> = ({ placeholder, value, onChange, rows = 4 }) => (
    <textarea placeholder={placeholder} value={value} onChange={e => onChange(e.target.value)} rows={rows}
        className={`${uiFieldClass} resize-none`} />
);

const Checkbox: React.FC<{ label: string, checked: boolean, onChange: (v: boolean) => void }> = ({ label, checked, onChange }) => (
    <button
        type="button"
        onClick={() => onChange(!checked)}
        className={`flex w-full items-center gap-3 rounded-lg border px-3 py-2.5 text-left text-sm transition-colors ${
            checked
                ? 'border-[#907CA1] bg-[#F4EFF7]'
                : 'border-slate-200 bg-slate-50 hover:border-slate-300'
        }`}
    >
        <div className={`flex h-4 w-4 items-center justify-center rounded-[5px] border transition-colors ${checked ? 'border-[#907CA1] bg-[#907CA1] text-white' : 'border-slate-400 bg-white'}`}>
            {checked && <Check size={10} />}
        </div>
        <span className="select-none font-medium text-slate-700">{label}</span>
    </button>
);

const ToggleGroup: React.FC<{ label: string, options: string[], selected: string | undefined, onSelect: (v: string) => void, small?: boolean }> = ({ label, options, selected, onSelect, small }) => {
    const gridClass = options.length <= 2
        ? 'grid-cols-2'
        : options.length === 3
            ? 'grid-cols-3'
            : 'grid-cols-2';

    return (
        <div className="mb-2.5">
            <label className="mb-1 block text-xs font-bold uppercase tracking-wider text-slate-400">{label}</label>
            <div className={`grid ${gridClass} gap-2`}>
                {options.map((opt) => (
                    <button
                        key={opt}
                        type="button"
                        onClick={() => onSelect(opt)}
                        className={`w-full rounded-lg border px-3 py-2.5 text-center transition-colors ${
                            small ? 'text-sm font-medium' : 'text-sm font-medium'
                        } ${
                            selected === opt
                                ? 'border-[#907CA1] bg-[#907CA1] text-white'
                                : 'border-slate-200 bg-slate-50 text-slate-700 hover:border-slate-300'
                        }`}
                    >
                        {opt}
                    </button>
                ))}
            </div>
        </div>
    );
};

const MOTORISATION_ICONS: Record<string, React.ComponentType<{ size?: number }>> = {
    'Manuel': Hand,
    'Électrique': Zap,
    'Pas de porte': Ban,
    'Pas de portail': Ban,
};

const IconToggleRow: React.FC<{
    label: string;
    options: Array<{ id: string; label: string }>;
    selected: string;
    onSelect: (value: string) => void;
}> = ({ label, options, selected, onSelect }) => (
    <div>
        <label className="block text-xs font-bold text-slate-500 mb-1">{label}</label>
        <div className="flex gap-1.5">
            {options.map((opt) => {
                const Icon = MOTORISATION_ICONS[opt.label] || Hand;
                const isActive = selected === opt.label;
                return (
                    <button
                        key={opt.id}
                        type="button"
                        onClick={() => onSelect(isActive ? '' : opt.label)}
                        title={opt.label}
                        className={`flex h-10 w-10 items-center justify-center rounded-xl border transition-colors ${
                            isActive
                                ? 'border-[#907CA1] bg-[#907CA1] text-white'
                                : 'border-slate-200 bg-slate-50 text-slate-500 hover:border-slate-300'
                        }`}
                    >
                        <Icon size={18} />
                    </button>
                );
            })}
        </div>
    </div>
);

const ReadOnlyField: React.FC<{ label: string; value: string; hint?: string }> = ({ label, value, hint }) => (
    <div className="mb-3">
        <label className="block text-xs font-bold text-slate-500 mb-1">{label}</label>
        <div className="w-full rounded-xl px-3 py-2 text-sm text-slate-700">
            {value}
        </div>
        {hint && <p className="mt-1 text-xs text-slate-400">{hint}</p>}
    </div>
);
