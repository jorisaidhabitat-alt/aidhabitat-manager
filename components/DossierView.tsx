import React, { useState, useEffect, useCallback, useRef } from 'react';
import { AppUser, Dossier, NotePage, OccupantIdentity } from '../types';
import {
  ArrowRight, Search, ChevronRight, Plus, ChevronDown,
  Paperclip, Home, User, Phone, MapPin, Calendar, Activity, ArrowLeft, X
} from 'lucide-react';
import { NotesCanvas, buildNotePreviewDataUrlFromContent } from './NotesCanvas';
import { CommuneFieldGroup, type CommuneOption } from './CommuneFieldGroup';
import { fetchNotePages, saveNotePage, mapVirtualDossierFromBeneficiary, createBeneficiaryWithDossier, fetchReferenceData, getReferenceDataSnapshot, updateBeneficiary, fetchObservationsSynthese, formatCityLabel, normalizeCityInput } from '../services/dataService';
import { SimpleLoader } from './LoadingProgress';
import { ViewportOverlay } from './ViewportOverlay';
import { uiActionCardClass, uiBadgeAccentClass, uiFieldClass, uiFieldReadonlyAccentClass, uiFieldReadonlyClass, uiIconButtonClass, uiLabelClass, uiPanelClass } from './uiTheme';

interface DossierViewProps {
  dossiers: Dossier[];
  onSelectDossier: (dossier: Dossier) => void;
  onCreateDossier: (dossier: Dossier) => void;
  onUpdateDossier?: (dossier: Dossier) => void;
  onBack: () => void;
  selectedDossier: Dossier | null;
  onStartVisit: (dossier: Dossier) => void;
  onOpenDocuments: (dossier: Dossier) => void;
  currentUser: AppUser;
}

export const DossierView: React.FC<DossierViewProps> = ({ dossiers, onSelectDossier, onCreateDossier, onUpdateDossier, selectedDossier, onBack, onStartVisit, onOpenDocuments, currentUser }) => {
  if (!selectedDossier) {
    return <DossierList dossiers={dossiers} onSelect={onSelectDossier} onCreate={onCreateDossier} currentUser={currentUser} />;
  }

  return (
    <DossierDetail
      dossier={selectedDossier}
      onUpdateDossier={onUpdateDossier}
      onBack={onBack}
      onStartVisit={() => onStartVisit(selectedDossier)}
      onOpenDocuments={() => onOpenDocuments(selectedDossier)}
    />
  );
};

const OCCUPANT_OPTIONS = [
  { value: '1', label: '1 occupant' },
  { value: '2', label: '2 occupants' },
  { value: '3', label: '3 occupants' },
  { value: '4', label: '4 occupants' },
  { value: '5', label: '5 occupants' },
  { value: '5+', label: '5+ occupants' },
];
const QUICK_NOTE_AUTOSAVE_DELAY_MS = 250;
const BENEFICIARY_AUTOSAVE_DELAY_MS = 180;

const parseOccupantCount = (value: string | number | undefined) => {
  const normalized = Number.parseInt(String(value ?? '').trim(), 10);
  return Number.isFinite(normalized) && normalized > 0 ? normalized : 1;
};

const createEmptyOccupant = (): OccupantIdentity => ({
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

const normalizeOccupant = (occupant?: Partial<OccupantIdentity>): OccupantIdentity => ({
  ...createEmptyOccupant(),
  ...occupant,
  firstName: String(occupant?.firstName || ''),
  lastName: String(occupant?.lastName || ''),
  birthDate: String(occupant?.birthDate || ''),
  invalidityTxt: String(occupant?.invalidityTxt || ''),
  homeHelpTxt: String(occupant?.homeHelpTxt || ''),
  dependenceTxt: String(occupant?.dependenceTxt || ''),
  numeroSecuriteSociale: String(occupant?.numeroSecuriteSociale || ''),
  caisseRetraitePrincipale: String(occupant?.caisseRetraitePrincipale || ''),
  caissesRetraiteComplementaires: String(occupant?.caissesRetraiteComplementaires || ''),
});

const buildOccupantsForCount = (patient: Dossier['patient'], targetCount: number): OccupantIdentity[] => {
  const fallbackOccupants: OccupantIdentity[] = [
    normalizeOccupant({
      firstName: patient.firstName,
      lastName: patient.lastName,
      birthDate: patient.birthDateMr,
      apa: patient.apa,
      invalidity: patient.invalidity,
      invalidityTxt: patient.invalidityTxt,
      homeHelp: patient.homeHelp,
      homeHelpTxt: patient.homeHelpTxt,
      dependenceTxt: patient.dependenceTxt,
      numeroSecuriteSociale: patient.numeroSecuriteSocialeMonsieur,
      caisseRetraitePrincipale: patient.caisseRetraitePrincipale,
      caissesRetraiteComplementaires: patient.caissesRetraiteComplementaires,
    }),
    ...((patient.secondFirstName || patient.secondLastName || patient.birthDateMme || patient.numeroSecuriteSocialeMadame) ? [
      normalizeOccupant({
        firstName: patient.secondFirstName,
        lastName: patient.secondLastName,
        birthDate: patient.birthDateMme,
        numeroSecuriteSociale: patient.numeroSecuriteSocialeMadame,
      }),
    ] : []),
  ];

  const existing = Array.isArray(patient.occupants) && patient.occupants.length > 0
    ? patient.occupants.map((occupant, index) => normalizeOccupant({
      ...(fallbackOccupants[index] || createEmptyOccupant()),
      ...occupant,
    }))
    : fallbackOccupants;

  const next = [...existing];
  while (next.length < targetCount) {
    next.push(createEmptyOccupant());
  }

  return next.slice(0, targetCount);
};

const buildEditFormFromPatient = (patient: Dossier['patient']) => ({
  firstName: patient.firstName,
  lastName: patient.lastName,
  numberPeople: patient.numberPeople != null ? String(patient.numberPeople) : '1',
  address: patient.address,
  zipCode: patient.zipCode,
  city: normalizeCityInput(patient.city),
  cityId: patient.cityId || '',
  phone: patient.phone,
  email: patient.email,
});

const samePatientIdentity = (left: Dossier['patient'], right: Dossier['patient']) => (
  (left.firstName || '') === (right.firstName || '')
  && (left.lastName || '') === (right.lastName || '')
  && String(left.numberPeople ?? 1) === String(right.numberPeople ?? 1)
  && (left.address || '') === (right.address || '')
  && (left.zipCode || '') === (right.zipCode || '')
  && normalizeCityInput(left.city) === normalizeCityInput(right.city)
  && (left.cityId || '') === (right.cityId || '')
  && (left.phone || '') === (right.phone || '')
  && (left.email || '') === (right.email || '')
  && JSON.stringify(left.occupants || []) === JSON.stringify(right.occupants || [])
);

const sameEditForm = (
  left: ReturnType<typeof buildEditFormFromPatient>,
  right: ReturnType<typeof buildEditFormFromPatient>,
) => (
  left.firstName === right.firstName
  && left.lastName === right.lastName
  && left.numberPeople === right.numberPeople
  && left.address === right.address
  && left.zipCode === right.zipCode
  && left.city === right.city
  && left.cityId === right.cityId
  && left.phone === right.phone
  && left.email === right.email
);

const formatAccompanimentType = (value: string | undefined) => {
  const normalized = String(value || '').trim().toLowerCase();
  if (normalized.includes('diagnostic')) return 'Diagnostic ergo';
  if (normalized === 'ergo') return 'Ergo';
  if (normalized === 'complet') return 'Complet';
  return value || 'Non renseigné';
};

const computeIncomeCategory = (
  baremesAnah: Array<{
    householdSize: number;
    revenueTresModeste?: number;
    revenueModeste?: number;
    revenueIntermediaire?: number;
    plafondYear?: number;
  }>,
  fiscalRevenue: number | undefined,
  householdSize: number,
  fallback: string | undefined,
) => {
  const revenue = Number(fiscalRevenue);
  if (!Number.isFinite(revenue) || revenue < 0) {
    return fallback || 'Non renseigné';
  }

  const exactMatches = baremesAnah.filter((record) => record.householdSize === householdSize);
  const candidates = exactMatches.length > 0
    ? exactMatches
    : baremesAnah.filter((record) => record.householdSize <= householdSize);
  const selected = [...candidates].sort((left, right) => {
    const yearDiff = (right.plafondYear || 0) - (left.plafondYear || 0);
    if (yearDiff !== 0) return yearDiff;
    return right.householdSize - left.householdSize;
  })[0];

  if (!selected) {
    return fallback || 'Non renseigné';
  }

  if (revenue <= Number(selected.revenueTresModeste || 0)) return 'Très modeste';
  if (revenue <= Number(selected.revenueModeste || 0)) return 'Modeste';
  if (revenue <= Number(selected.revenueIntermediaire || 0)) return 'Intermédiaire';
  return 'Supérieure';
};

const prefetchedDossierDetailKeys = new Set<string>();

const warmDossierDetailCache = (dossier: Dossier) => {
  const cacheKey = `${dossier.id}:${dossier.patient.id}`;
  if (prefetchedDossierDetailKeys.has(cacheKey)) {
    return;
  }

  prefetchedDossierDetailKeys.add(cacheKey);
  void Promise.allSettled([
    fetchReferenceData(),
    fetchNotePages(dossier.patient.id, {
      scopeType: 'dossier_detail',
      scopeId: dossier.id,
      tabKey: 'general',
    }),
    fetchObservationsSynthese(dossier.id, dossier.patient.id),
  ]).catch(() => undefined);
};

export const CreateDossierFab: React.FC<{ currentUser: AppUser; onCreate: (dossier: Dossier) => void; className?: string }> = ({ currentUser, onCreate, className }) => {
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [isCreating, setIsCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const [ergoOptions, setErgoOptions] = useState<Array<{ id: string; label: string }>>([]);
  const [communeOptions, setCommuneOptions] = useState<CommuneOption[]>([]);
  const [createForm, setCreateForm] = useState({
    lastName: '',
    firstName: '',
    address: '',
    zipCode: '',
    city: '',
    cityId: '',
    phone: '',
    email: '',
    ergoId: currentUser.role === 'ADMIN' ? '' : (currentUser.ergoLabel || ''),
  });

  useEffect(() => {
    fetchReferenceData()
      .then((refs) => {
        setErgoOptions(refs.ergos);
        setCommuneOptions(refs.communes || []);
      })
      .catch((error) => console.error('Failed to load ergo references', error));
  }, []);

  const handleCreate = async () => {
    setCreateError(null);
    setIsCreating(true);
    const result = await createBeneficiaryWithDossier({
      lastName: createForm.lastName.trim(),
      firstName: createForm.firstName.trim(),
      address: createForm.address.trim(),
      zipCode: createForm.zipCode.trim(),
      city: createForm.city.trim(),
      cityId: createForm.cityId || undefined,
      phone: createForm.phone.trim(),
      email: createForm.email.trim(),
      numberPeople: 1,
      apa: false,
      invalidity: false,
      homeHelp: false,
    }, currentUser.role === 'ADMIN' ? createForm.ergoId : (currentUser.ergoLabel || ''));
    setIsCreating(false);

    if (!result.success || !result.data) {
      setCreateError(result.error || 'Création impossible');
      return;
    }

    setCreateForm({
      lastName: '',
      firstName: '',
      address: '',
      zipCode: '',
      city: '',
      cityId: '',
      phone: '',
      email: '',
      ergoId: currentUser.role === 'ADMIN' ? '' : (currentUser.ergoLabel || ''),
    });
    setIsCreateOpen(false);
    onCreate(result.data);
  };

  return (
    <>
      <div className={className || 'fixed bottom-6 right-6 z-40 md:bottom-8 md:right-8'}>
        <button
          onClick={() => {
            setCreateError(null);
            setIsCreateOpen(true);
          }}
          className="w-14 h-14 md:w-16 md:h-16 bg-[#907CA1] rounded-full shadow-lg flex items-center justify-center text-white hover:scale-105 hover:bg-[#7a668a] transition-all"
          title="Créer un dossier"
        >
          <Plus className="w-7 h-7 md:w-8 md:h-8" strokeWidth={2} />
        </button>
      </div>

      {isCreateOpen && (
        <ViewportOverlay
          className="fixed inset-0 z-[80] bg-black/40 backdrop-blur-sm flex items-center justify-center p-4"
          onClick={() => setIsCreateOpen(false)}
        >
          <div
            className="w-full max-w-xl bg-white rounded-[2rem] shadow-2xl p-6 md:p-8 relative"
            onClick={(event) => event.stopPropagation()}
          >
            <button
              onClick={() => setIsCreateOpen(false)}
              className="absolute top-4 right-4 p-2 text-slate-400 hover:text-slate-700"
            >
              <X size={20} />
            </button>

            <h3 className="text-2xl font-bold text-slate-900 mb-2">Nouveau dossier</h3>
            <p className="text-sm text-slate-500 mb-6">Création d’un bénéficiaire puis de son dossier dans la base métier.</p>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
              <FormInput label="Nom" value={createForm.lastName} onChange={(value) => setCreateForm((prev) => ({ ...prev, lastName: value }))} />
              <FormInput label="Prénom" value={createForm.firstName} onChange={(value) => setCreateForm((prev) => ({ ...prev, firstName: value }))} />
              <FormInput label="Adresse" value={createForm.address} onChange={(value) => setCreateForm((prev) => ({ ...prev, address: value }))} />
              <CommuneFieldGroup
                city={createForm.city}
                zipCode={createForm.zipCode}
                cityId={createForm.cityId}
                options={communeOptions}
                onChange={(updates) => setCreateForm((prev) => ({ ...prev, ...updates }))}
                zipLabel="Code postal"
                cityLabel="Ville"
              />
              <FormInput label="Téléphone" value={createForm.phone} onChange={(value) => setCreateForm((prev) => ({ ...prev, phone: value }))} />
              <div className="md:col-span-2">
                <FormInput label="Email" value={createForm.email} onChange={(value) => setCreateForm((prev) => ({ ...prev, email: value }))} />
              </div>
              {currentUser.role === 'ADMIN' && (
                <div className="md:col-span-2">
                  <FormSelect
                    label="Ergothérapeute"
                    value={createForm.ergoId}
                    options={ergoOptions}
                    onChange={(value) => setCreateForm((prev) => ({ ...prev, ergoId: value }))}
                  />
                </div>
              )}
            </div>

            {createError && (
              <div className="mt-4 rounded-2xl border border-red-100 bg-red-50 px-4 py-3 text-sm text-red-700">
                {createError}
              </div>
            )}

            <div className="mt-6 flex justify-end gap-3">
              <button
                onClick={() => setIsCreateOpen(false)}
                className="px-5 py-3 rounded-full font-bold text-slate-500 hover:bg-slate-100 transition-colors"
              >
                Annuler
              </button>
              <button
                onClick={handleCreate}
                disabled={isCreating || !createForm.lastName.trim() || (currentUser.role === 'ADMIN' && !createForm.ergoId)}
                className="px-6 py-3 rounded-full font-bold bg-[#907CA1] text-white hover:bg-[#7a668a] transition-colors disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
              >
                {isCreating ? <SimpleLoader label="Création" variant="button" /> : 'Créer'}
              </button>
            </div>
          </div>
        </ViewportOverlay>
      )}
    </>
  );
};

const DossierList: React.FC<{ dossiers: Dossier[]; onSelect: (d: Dossier) => void; onCreate: (d: Dossier) => void; currentUser: AppUser }> = ({ dossiers, onSelect, onCreate, currentUser }) => {
  const [searchTerm, setSearchTerm] = useState('');
  const [sortOrder, setSortOrder] = useState<'asc' | 'desc' | 'random'>('asc');
  const [isSortMenuOpen, setIsSortMenuOpen] = useState(false);
  const [localDossiers, setLocalDossiers] = useState<Dossier[]>([]); // Fallback state

  useEffect(() => {
    if (!dossiers || dossiers.length === 0) {
      console.log("DossierList: Props empty, utilizing Snapshot Fallback.");
      fetch('/snapshot.json').then(r => r.json()).then(d => {
        if (d.beneficiaries) {
          const mapped = d.beneficiaries.map(mapVirtualDossierFromBeneficiary);
          setLocalDossiers(mapped);
        }
      }).catch(e => console.error(e));
    }
  }, [dossiers]);

  const effectiveDossiers = (dossiers && dossiers.length > 0) ? dossiers : localDossiers;

  // Filtering
  let filtered = effectiveDossiers.filter(d =>
    d.patient.lastName.toLowerCase().includes(searchTerm.toLowerCase()) ||
    d.patient.firstName.toLowerCase().includes(searchTerm.toLowerCase()) ||
    formatCityLabel(d.patient.city).toLowerCase().includes(searchTerm.toLowerCase())
  );

  // Sorting
  if (sortOrder === 'asc') {
    filtered.sort((a, b) => a.patient.lastName.localeCompare(b.patient.lastName));
  } else if (sortOrder === 'desc') {
    filtered.sort((a, b) => b.patient.lastName.localeCompare(a.patient.lastName));
  } else if (sortOrder === 'random') {
    filtered = filtered.sort(() => Math.random() - 0.5);
  }

  const getSortLabel = () => {
    switch (sortOrder) {
      case 'asc': return 'de A à Z';
      case 'desc': return 'de Z à A';
      default: return 'Aléatoire';
    }
  };

  return (
    <div className="h-full flex flex-col space-y-4 md:space-y-6">
      <h2 className="text-2xl md:text-3xl font-bold text-black">Mes dossiers</h2>

      {/* Controls - Responsive Stack */}
      <div className="flex flex-col lg:flex-row gap-4 z-20">
        <div className="relative flex-1">
          <input
            type="text"
            placeholder="Rechercher..."
            className={`${uiFieldClass} rounded-full border-2 border-slate-300 py-3 pl-6 pr-12 text-base text-black md:py-4 md:text-lg`}
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
          />
          <Search className="absolute right-5 top-1/2 transform -translate-y-1/2 text-slate-400" size={24} />
        </div>

        <div className="relative w-full lg:w-auto">
          <button
            onClick={() => setIsSortMenuOpen(!isSortMenuOpen)}
            className={`${uiPanelClass} flex h-full w-full min-w-[160px] items-center justify-between gap-3 rounded-full border-2 border-slate-300 px-6 py-3 font-medium text-black lg:w-auto md:py-4`}
          >
            <span>{getSortLabel()}</span>
            <ChevronDown size={20} />
          </button>

          {isSortMenuOpen && (
            <div className="absolute right-0 top-full z-30 mt-2 w-full overflow-hidden rounded-[22px] border border-slate-200 bg-white shadow-lg">
              <button onClick={() => { setSortOrder('asc'); setIsSortMenuOpen(false); }} className="w-full text-left px-4 py-3 hover:bg-slate-50">de A à Z</button>
              <button onClick={() => { setSortOrder('desc'); setIsSortMenuOpen(false); }} className="w-full text-left px-4 py-3 hover:bg-slate-50">de Z à A</button>
              <button onClick={() => { setSortOrder('random'); setIsSortMenuOpen(false); }} className="w-full text-left px-4 py-3 hover:bg-slate-50">Aléatoire</button>
            </div>
          )}
        </div>
      </div>

      {/* Main List Area */}
      <div className={`${uiPanelClass} relative flex-1 flex-col overflow-hidden py-4 md:py-6`}>
        {/* Dossier Rows */}
        <div className="flex-1 overflow-y-auto space-y-2">
          {filtered.length > 0 ? (
            filtered.map((dossier) => (
              <div
                key={dossier.id}
                onClick={() => onSelect(dossier)}
                onMouseEnter={() => warmDossierDetailCache(dossier)}
                onFocus={() => warmDossierDetailCache(dossier)}
                className="group px-4 py-3 md:px-6 md:py-4 rounded-2xl cursor-pointer hover:bg-slate-50 border border-transparent hover:border-slate-200 transition-all flex flex-col sm:flex-row sm:items-center justify-between gap-4"
              >
                <div className="flex items-center gap-3 md:gap-4">
                  <div className="w-10 h-10 md:w-12 md:h-12 bg-[#D8D0DC] rounded-full flex items-center justify-center text-[#554a63] font-bold text-lg md:text-xl flex-shrink-0">
                    {getPatientInitials(dossier.patient.firstName, dossier.patient.lastName)}
                  </div>
                  <div className="min-w-0">
                    <h3 className="text-base md:text-lg font-bold text-slate-800 uppercase tracking-wide group-hover:text-[#907CA1] transition-colors truncate">
                      {dossier.patient.lastName} {dossier.patient.firstName}
                    </h3>
                    <div className="mt-1 flex items-center gap-2 text-slate-500 text-xs md:text-sm leading-tight">
                      <MapPin size={14} className="flex-shrink-0" />
                      <span className="line-clamp-1">{formatCityLabel(dossier.patient.city)}</span>
                    </div>
                  </div>
                </div>

                <div className="flex items-center justify-between sm:justify-end gap-4 md:gap-6 pl-14 sm:pl-0">
                  <span className={`px-3 py-1 md:px-4 rounded-full text-[10px] md:text-xs font-bold uppercase tracking-wider ${dossier.status === 'Validé' ? 'bg-emerald-100 text-emerald-700' :
                    dossier.status === 'À visiter' ? 'bg-amber-100 text-amber-700' :
                      'bg-slate-100 text-slate-600'
                    }`}>
                    {dossier.status}
                  </span>
                  <div className="w-8 h-8 md:w-10 md:h-10 rounded-full bg-white border border-slate-200 flex items-center justify-center group-hover:border-[#907CA1] group-hover:text-[#907CA1] transition-all">
                    <ArrowRight size={16} className="text-slate-400 md:w-5 md:h-5" />
                  </div>
                </div>
              </div>
            ))
          ) : (
            <div className="flex flex-col items-center justify-center h-64 text-slate-400">
              <Search size={48} className="mb-4 opacity-50" />
              <p>Aucun dossier ne correspond à votre recherche.</p>
            </div>
          )}
        </div>

      </div>

      <CreateDossierFab currentUser={currentUser} onCreate={onCreate} />
    </div>
  );
};

const FormInput: React.FC<{ label: string; value: string; onChange: (value: string) => void }> = ({ label, value, onChange }) => (
  <div>
    <label className={uiLabelClass}>{label}</label>
    <input
      value={value}
      onChange={(event) => onChange(event.target.value)}
      className={uiFieldClass}
    />
  </div>
);

const FormSelect: React.FC<{ label: string; value: string; options: Array<{ id: string; label: string }>; onChange: (value: string) => void }> = ({ label, value, options, onChange }) => (
  <div>
    <label className={uiLabelClass}>{label}</label>
    <select
      value={value}
      onChange={(event) => onChange(event.target.value)}
      className={`${uiFieldClass} bg-white`}
    >
      <option value="">Sélectionner...</option>
      {options.map((option) => (
        <option key={option.id} value={option.label}>{option.label}</option>
      ))}
    </select>
  </div>
);

const DossierDetail: React.FC<{ dossier: Dossier; onUpdateDossier?: (dossier: Dossier) => void; onBack: () => void; onStartVisit: () => void; onOpenDocuments: () => void }> = ({ dossier, onUpdateDossier, onBack, onStartVisit, onOpenDocuments }) => {
  const noteScopeType = 'dossier_detail';
  const noteTabKey = 'general';
  const emptyDrawingJson = JSON.stringify({ version: 1, strokes: [] });
  const cachedReferences = getReferenceDataSnapshot();
  const [notePage, setNotePage] = useState<NotePage | null>(null);
  const [isNotesReady, setIsNotesReady] = useState(false);
  const initialProjectComment = dossier.observationsSynthese?.projetSouhaitUsage || '';
  const [isProjectCommentReady, setIsProjectCommentReady] = useState(Boolean(initialProjectComment));
  const [projectComment, setProjectComment] = useState(initialProjectComment);
  const [baremesAnah, setBaremesAnah] = useState<Array<{
    id: string;
    label: string;
    householdSize: number;
    revenueTresModeste?: number;
    revenueModeste?: number;
    revenueIntermediaire?: number;
    revenueHaut?: number;
    plafondYear?: number;
  }>>(cachedReferences?.baremesAnah || []);
  const [communeOptions, setCommuneOptions] = useState<CommuneOption[]>(cachedReferences?.communes || []);

  const loadQuickNote = useCallback(async () => {
    try {
      const pages = await fetchNotePages(dossier.patient.id, {
        scopeType: noteScopeType,
        scopeId: dossier.id,
        tabKey: noteTabKey,
      });
      setNotePage(pages[0] || null);
    } catch (error) {
      console.error('Failed to load dossier quick note', error);
      setNotePage(null);
    } finally {
      setIsNotesReady(true);
    }
  }, [dossier.id, dossier.patient.id]);

  useEffect(() => {
    setIsNotesReady(false);
    loadQuickNote().catch((error) => console.error('Failed to refresh dossier quick note', error));
  }, [loadQuickNote]);

  const loadProjectComment = useCallback(async () => {
    try {
      const observations = await fetchObservationsSynthese(dossier.id, dossier.patient.id);
      setProjectComment(observations?.projetSouhaitUsage || dossier.observationsSynthese?.projetSouhaitUsage || '');
    } catch (error) {
      console.error('Failed to load dossier project comment', error);
      setProjectComment(dossier.observationsSynthese?.projetSouhaitUsage || '');
    } finally {
      setIsProjectCommentReady(true);
    }
  }, [dossier.id, dossier.observationsSynthese?.projetSouhaitUsage, dossier.patient.id]);

  useEffect(() => {
    setProjectComment(dossier.observationsSynthese?.projetSouhaitUsage || '');
    setIsProjectCommentReady(Boolean(dossier.observationsSynthese?.projetSouhaitUsage));
    loadProjectComment().catch((error) => console.error('Failed to refresh dossier project comment', error));
  }, [dossier.id, dossier.observationsSynthese?.projetSouhaitUsage, loadProjectComment]);

  // Local state for patient info to allow immediate updates without page reload
  const [patient, setPatient] = useState(dossier.patient);

  useEffect(() => {
    fetchReferenceData()
      .then((references) => {
        setBaremesAnah(references.baremesAnah || []);
        setCommuneOptions(references.communes || []);
      })
      .catch((error) => console.error('Failed to load reference data', error));
  }, []);

  const [editForm, setEditForm] = useState(() => buildEditFormFromPatient(dossier.patient));
  const [isNoteSaving, setIsNoteSaving] = useState(false);
  const [noteDraft, setNoteDraft] = useState({
    text: '',
    drawingJson: emptyDrawingJson,
    isDirty: false,
  });
  const beneficiarySaveRequestRef = useRef(0);
  const noteSaveRequestRef = useRef(0);
  const currentOccupantCount = parseOccupantCount(editForm.numberPeople);
  const displayedAccompanimentType = formatAccompanimentType(dossier.natureAccompagnement);
  const displayedIncomeCategory = computeIncomeCategory(
    baremesAnah,
    patient.fiscalRevenue,
    currentOccupantCount,
    patient.incomeCategory,
  );

  const buildBeneficiaryPayload = useCallback(() => {
    const nextOccupants = buildOccupantsForCount(patient, currentOccupantCount);
    if (nextOccupants[0]) {
      nextOccupants[0] = {
        ...nextOccupants[0],
        firstName: editForm.firstName,
        lastName: editForm.lastName,
      };
    }

    return {
      payload: {
        firstName: editForm.firstName,
        lastName: editForm.lastName,
        occupants: nextOccupants,
        numberPeople: currentOccupantCount,
        address: editForm.address,
        zipCode: editForm.zipCode,
        city: editForm.city,
        cityId: editForm.cityId || undefined,
        phone: editForm.phone,
        email: editForm.email,
      },
      nextOccupants,
    };
  }, [currentOccupantCount, editForm, patient]);

  const persistBeneficiaryDraft = useCallback((immediate = false) => {
    const hasBeneficiaryChanges =
      editForm.firstName !== (patient.firstName || '') ||
      editForm.lastName !== (patient.lastName || '') ||
      editForm.numberPeople !== String(patient.numberPeople ?? 1) ||
      editForm.address !== (patient.address || '') ||
      editForm.zipCode !== (patient.zipCode || '') ||
      editForm.city !== normalizeCityInput(patient.city) ||
      editForm.cityId !== (patient.cityId || '') ||
      editForm.phone !== (patient.phone || '') ||
      editForm.email !== (patient.email || '');

    if (!hasBeneficiaryChanges) return;

    const { payload, nextOccupants } = buildBeneficiaryPayload();
    const nextPatient = {
      ...patient,
      ...payload,
      occupants: nextOccupants,
      cityId: payload.cityId || '',
      incomeCategory: displayedIncomeCategory,
    };

    setPatient((previous) => ({
      ...previous,
      ...nextPatient,
    }));
    onUpdateDossier?.({
      ...dossier,
      patient: nextPatient,
    });
    void updateBeneficiary(dossier.patient.id, payload, { immediate });
  }, [buildBeneficiaryPayload, displayedIncomeCategory, dossier, dossier.patient.id, editForm, onUpdateDossier, patient]);

  useEffect(() => {
    setPatient((previous) => (samePatientIdentity(previous, dossier.patient) ? previous : dossier.patient));
    const nextEditForm = buildEditFormFromPatient(dossier.patient);
    setEditForm((previous) => (sameEditForm(previous, nextEditForm) ? previous : nextEditForm));
  }, [
    dossier.id,
    dossier.patient.id,
    dossier.patient.firstName,
    dossier.patient.lastName,
    dossier.patient.numberPeople,
    dossier.patient.address,
    dossier.patient.zipCode,
    dossier.patient.city,
    dossier.patient.cityId,
    dossier.patient.phone,
    dossier.patient.email,
    dossier.patient.occupants,
  ]);

  useEffect(() => {
    if (!onUpdateDossier) return;

    const nextOccupants = buildOccupantsForCount({
      ...dossier.patient,
      occupants: patient.occupants,
    }, currentOccupantCount);
    if (nextOccupants[0]) {
      nextOccupants[0] = {
        ...nextOccupants[0],
        firstName: editForm.firstName,
        lastName: editForm.lastName,
      };
    }

    const nextPatient = {
      ...dossier.patient,
      firstName: editForm.firstName,
      lastName: editForm.lastName,
      occupants: nextOccupants,
      numberPeople: currentOccupantCount,
      address: editForm.address,
      zipCode: editForm.zipCode,
      city: editForm.city,
      cityId: editForm.cityId || '',
      phone: editForm.phone,
      email: editForm.email,
      incomeCategory: displayedIncomeCategory,
    };

    if (
      dossier.patient.firstName === nextPatient.firstName
      && dossier.patient.lastName === nextPatient.lastName
      && JSON.stringify(dossier.patient.occupants || []) === JSON.stringify(nextPatient.occupants || [])
      && (dossier.patient.numberPeople ?? 1) === (nextPatient.numberPeople ?? 1)
      && dossier.patient.address === nextPatient.address
      && dossier.patient.zipCode === nextPatient.zipCode
      && normalizeCityInput(dossier.patient.city) === normalizeCityInput(nextPatient.city)
      && (dossier.patient.cityId || '') === (nextPatient.cityId || '')
      && dossier.patient.phone === nextPatient.phone
      && dossier.patient.email === nextPatient.email
      && (dossier.patient.incomeCategory || '') === (nextPatient.incomeCategory || '')
    ) {
      return;
    }

    onUpdateDossier({
      ...dossier,
      patient: nextPatient,
    });
  }, [currentOccupantCount, displayedIncomeCategory, dossier, editForm.address, editForm.city, editForm.cityId, editForm.email, editForm.firstName, editForm.lastName, editForm.phone, editForm.zipCode, onUpdateDossier]);

  const currentNotePage = notePage || {
    id: '',
    patientId: dossier.patient.id,
    dossierId: dossier.id,
    scopeType: noteScopeType,
    scopeId: dossier.id,
    tabKey: noteTabKey,
    pageNumber: 0,
    textContent: '',
    drawingJson: '',
    layoutKind: 'freeform',
  };

  useEffect(() => {
      setNoteDraft({
        text: currentNotePage.textContent,
        drawingJson: currentNotePage.drawingJson || emptyDrawingJson,
        isDirty: false,
      });
  }, [currentNotePage.id, currentNotePage.updatedAt, currentNotePage.textContent, currentNotePage.drawingJson, emptyDrawingJson]);

  const handleSaveNote = useCallback(async ({ text, drawingJson, previewDataUrl }: { text: string; drawingJson: string; previewDataUrl: string }) => {
    try {
      const resolvedPreviewDataUrl = previewDataUrl || buildNotePreviewDataUrlFromContent({
        text,
        drawingJson,
        mode: 'freeform',
      });
      const savedPage = await saveNotePage({
        notePageId: currentNotePage.id || undefined,
        patientId: dossier.patient.id,
        dossierId: dossier.id,
        scopeType: noteScopeType,
        scopeId: dossier.id,
        tabKey: noteTabKey,
        pageNumber: 0,
        textContent: text,
        drawingJson,
        previewDataUrl: resolvedPreviewDataUrl,
        layoutKind: 'freeform',
      });
      setNotePage(savedPage);
    } catch (error) {
      console.error('Failed to save dossier quick note', error);
      throw error;
    }
  }, [currentNotePage.id, dossier.id, dossier.patient.id, noteScopeType, noteTabKey]);

  useEffect(() => {
    const hasBeneficiaryChanges =
      editForm.firstName !== (patient.firstName || '') ||
      editForm.lastName !== (patient.lastName || '') ||
      editForm.numberPeople !== String(patient.numberPeople ?? 1) ||
      editForm.address !== (patient.address || '') ||
      editForm.zipCode !== (patient.zipCode || '') ||
      editForm.city !== normalizeCityInput(patient.city) ||
      editForm.cityId !== (patient.cityId || '') ||
      editForm.phone !== (patient.phone || '') ||
      editForm.email !== (patient.email || '');

    if (!hasBeneficiaryChanges) return;
    const { payload, nextOccupants } = buildBeneficiaryPayload();
    const requestId = ++beneficiarySaveRequestRef.current;
    setPatient((previous) => ({
      ...previous,
      ...payload,
      occupants: nextOccupants,
      cityId: payload.cityId || '',
      incomeCategory: displayedIncomeCategory,
    }));

    let isCancelled = false;

    const timer = window.setTimeout(() => {
      void (async () => {
        const { success, error } = await updateBeneficiary(dossier.patient.id, payload);
        if (isCancelled || requestId !== beneficiarySaveRequestRef.current) return;
        if (!success) {
          console.error('Failed to save beneficiary details', error);
        }
      })();
    }, BENEFICIARY_AUTOSAVE_DELAY_MS);

    return () => {
      isCancelled = true;
      window.clearTimeout(timer);
    };
  }, [buildBeneficiaryPayload, displayedIncomeCategory, dossier.patient.id, editForm, patient]);

  useEffect(() => {
    if (!noteDraft.isDirty) return;

    const normalizedDrawingJson = noteDraft.drawingJson || emptyDrawingJson;
    const hasNoteChanges =
      noteDraft.text !== currentNotePage.textContent ||
      normalizedDrawingJson !== (currentNotePage.drawingJson || emptyDrawingJson);

    if (!hasNoteChanges) return;

    const requestId = ++noteSaveRequestRef.current;
    setIsNoteSaving(true);

    const timer = setTimeout(async () => {
      try {
        await handleSaveNote({
          text: noteDraft.text,
          drawingJson: normalizedDrawingJson,
        });
        if (requestId !== noteSaveRequestRef.current) return;
      } catch (error) {
        if (requestId !== noteSaveRequestRef.current) return;
        console.error('Failed to autosave dossier note', error);
      } finally {
        if (requestId === noteSaveRequestRef.current) {
          setIsNoteSaving(false);
        }
      }
    }, QUICK_NOTE_AUTOSAVE_DELAY_MS);

    return () => clearTimeout(timer);
  }, [currentNotePage.drawingJson, currentNotePage.textContent, emptyDrawingJson, handleSaveNote, noteDraft]);

  const flushQuickNoteDraft = useCallback(async () => {
    if (!noteDraft.isDirty) return true;
    try {
      setIsNoteSaving(true);
        await handleSaveNote({
          text: noteDraft.text,
          drawingJson: noteDraft.drawingJson || emptyDrawingJson,
          previewDataUrl: buildNotePreviewDataUrlFromContent({
            text: noteDraft.text,
            drawingJson: noteDraft.drawingJson || emptyDrawingJson,
            mode: 'freeform',
          }),
        });
      setIsNoteSaving(false);
      return true;
    } catch (error) {
      setIsNoteSaving(false);
      return false;
    }
  }, [emptyDrawingJson, handleSaveNote, noteDraft.drawingJson, noteDraft.isDirty, noteDraft.text]);

  const handleBackClick = async () => {
    if (isNoteSaving) return;
    const canLeave = await flushQuickNoteDraft();
    if (!canLeave) return;
    persistBeneficiaryDraft(true);
    onBack();
  };

  const handleOpenDocumentsClick = async () => {
    if (isNoteSaving) return;
    const canLeave = await flushQuickNoteDraft();
    if (!canLeave) return;
    persistBeneficiaryDraft(true);
    onOpenDocuments();
  };

  const handleStartVisitClick = async () => {
    if (isNoteSaving) return;
    const canLeave = await flushQuickNoteDraft();
    if (!canLeave) return;
    persistBeneficiaryDraft(true);
    onStartVisit();
  };

  useEffect(() => () => {
    persistBeneficiaryDraft(true);
  }, [persistBeneficiaryDraft]);

  useEffect(() => {
    const onVisibility = () => {
      if (document.visibilityState === 'visible') {
        loadQuickNote().catch((error) => console.error('Failed to refresh dossier quick note', error));
        loadProjectComment().catch((error) => console.error('Failed to refresh dossier project comment', error));
      }
    };

    const onFocus = () => {
      loadQuickNote().catch((error) => console.error('Failed to refresh dossier quick note', error));
      loadProjectComment().catch((error) => console.error('Failed to refresh dossier project comment', error));
    };

    window.addEventListener('focus', onFocus);
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      window.removeEventListener('focus', onFocus);
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [loadProjectComment, loadQuickNote]);

  const formatDate = (dateStr: string) => {
    if (!dateStr) return 'Non renseigné';
    return new Date(dateStr).toLocaleDateString('fr-FR', {
      day: '2-digit', month: '2-digit', year: 'numeric'
    });
  };

  const isQuickNoteLocked = isNoteSaving;

  return (
    <div className="flex h-full min-h-0 flex-col gap-5 animate-fade-in">
      {/* Header */}
        <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
        <div className="flex items-center gap-4 min-w-0">
          <button onClick={() => void handleBackClick()} disabled={isQuickNoteLocked} className={`${uiIconButtonClass} h-12 w-12 ${isQuickNoteLocked ? 'cursor-not-allowed opacity-45' : ''}`}>
            <ArrowLeft size={24} strokeWidth={2} />
          </button>
          <div className="min-w-0">
            <h2 className="text-xl md:text-3xl font-bold text-black uppercase tracking-tight break-words">
              {editForm.lastName || patient.lastName} {editForm.firstName || patient.firstName}
            </h2>
            <div className="flex items-center gap-2 text-slate-500">
              <span className="w-2 h-2 rounded-full bg-green-500"></span>
              <span className="text-sm font-medium">Dossier actif</span>
            </div>
          </div>
        </div>
        <div className="text-left md:text-right">
          <p className="text-sm text-slate-500 font-bold">Créé le</p>
          <p className="font-mono text-slate-800">{formatDate(dossier.createdAt)}</p>
        </div>
      </div>

      {/* Main Grid */}
      <div className="grid min-h-0 flex-1 grid-cols-1 items-stretch gap-5 overflow-y-auto pb-4 md:grid-cols-2 md:overflow-visible">

        {/* Left Column: Actions + Beneficiary Info */}
        <div className={`relative z-30 flex h-full min-h-[620px] flex-col gap-5 overflow-visible md:min-h-0 transition-opacity ${isQuickNoteLocked ? 'opacity-45 pointer-events-none select-none' : ''}`}>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <button
              onClick={() => void handleOpenDocumentsClick()}
              disabled={isQuickNoteLocked}
              className={`${uiActionCardClass} group p-6`}
            >
              <div className="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
                <Paperclip size={64} className="text-[#907CA1]" />
              </div>
              <div className="w-12 h-12 rounded-full bg-[#f3f0f5] flex items-center justify-center text-[#907CA1] mb-4 group-hover:scale-110 transition-transform">
                <Paperclip size={24} />
              </div>
              <h3 className="font-bold text-lg text-slate-800">Espace Documents</h3>
            </button>

            <button
              onClick={() => void handleStartVisitClick()}
              disabled={isQuickNoteLocked}
              className={`${uiActionCardClass} group p-6`}
            >
              <div className="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
                <Home size={64} className="text-[#907CA1]" />
              </div>
              <div className="w-12 h-12 rounded-full bg-[#f3f0f5] flex items-center justify-center text-[#907CA1] mb-4 group-hover:scale-110 transition-transform">
                <Home size={24} />
              </div>
              <h3 className="font-bold text-lg text-slate-800">Visite Domicile</h3>
            </button>
          </div>

          <div className={`${uiPanelClass} relative z-20 flex flex-1 min-h-0 flex-col overflow-visible p-5 md:p-6`}>
            <div className="mb-4 flex items-center justify-between">
              <div className="flex items-center gap-3">
                <User className="text-slate-400" />
                <h3 className="font-bold text-lg text-slate-800">Informations Bénéficiaire</h3>
              </div>
              <InfoBadge value={displayedIncomeCategory} />
            </div>

            <div className="space-y-3 animate-in fade-in duration-200">
              <div className="grid grid-cols-1 gap-3">
                <ReadOnlyInfoField
                  label="Type d’accompagnement"
                  value={displayedAccompanimentType}
                  emphasized
                />
              </div>
              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <EditableInfoField
                  label="Prénom"
                  value={editForm.firstName}
                  onChange={(value) => setEditForm((previous) => ({ ...previous, firstName: value }))}
                  onBlur={() => persistBeneficiaryDraft(true)}
                />
                <EditableInfoField
                  label="Nom"
                  value={editForm.lastName}
                  onChange={(value) => setEditForm((previous) => ({ ...previous, lastName: value }))}
                  onBlur={() => persistBeneficiaryDraft(true)}
                />
              </div>
              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <SelectInfoField
                  label="Occupants"
                  value={editForm.numberPeople}
                  onChange={(value) => setEditForm((previous) => ({ ...previous, numberPeople: value }))}
                  onBlur={() => persistBeneficiaryDraft(true)}
                  options={OCCUPANT_OPTIONS}
                />
                <CommuneFieldGroup
                  city={editForm.city}
                  zipCode={editForm.zipCode}
                  cityId={editForm.cityId}
                  options={communeOptions}
                  onChange={(updates) => setEditForm((previous) => ({ ...previous, ...updates }))}
                  onBlur={() => persistBeneficiaryDraft(true)}
                  zipLabel="Code postal"
                  cityLabel="Ville"
                  showZipField={false}
                />
              </div>
              <ReadOnlyInfoField
                label="Commentaire projet"
                value={isProjectCommentReady ? (projectComment || 'Non renseigné') : 'Chargement du commentaire...'}
                multiline
                compact
              />

            </div>
          </div>
        </div>

        {/* Right Column: Notes */}
        <div className="flex h-full min-h-[620px] flex-col md:min-h-0">
          <div className={`${uiPanelClass} flex h-full flex-col overflow-hidden`}>
            <div className="flex items-center justify-between border-b border-slate-100 px-5 py-4">
              <h3 className="pl-4 font-bold text-slate-800">Notes Rapides</h3>
            </div>
            {isNotesReady ? (
              <NotesCanvas
                key={`${currentNotePage.id || 'draft'}:${currentNotePage.updatedAt || 'initial'}`}
                initialText={currentNotePage.textContent}
                initialDrawingJson={currentNotePage.drawingJson}
                placeholder="Notes d'appel, observations rapides..."
                currentPage={0}
                totalPages={1}
                onSave={handleSaveNote}
                onDraftChange={setNoteDraft}
                allowPagination={false}
                toolset="quick"
                showSaveButton={false}
                showText={false}
                embedded
              />
            ) : (
              <div className="flex flex-1 items-center justify-center bg-white">
                <SimpleLoader label="Chargement des notes" />
              </div>
            )}
          </div>
        </div>

      </div>
    </div>
  );
};

const EditableInfoField: React.FC<{
  label: string;
  value: string;
  onChange: (value: string) => void;
  onBlur?: () => void;
  type?: 'text' | 'email';
}> = ({ label, value, onChange, onBlur, type = 'text' }) => (
  <div>
    <label className={uiLabelClass}>{label}</label>
    <input
      type={type}
      value={value}
      onChange={(event) => onChange(event.target.value)}
      onBlur={onBlur}
      className={uiFieldClass}
    />
  </div>
);

const SelectInfoField: React.FC<{
  label: string;
  value: string;
  onChange: (value: string) => void;
  onBlur?: () => void;
  options: Array<{ value: string; label: string }>;
}> = ({ label, value, onChange, onBlur, options }) => (
  <div>
    <label className={uiLabelClass}>{label}</label>
    <select
      value={value}
      onChange={(event) => onChange(event.target.value)}
      onBlur={onBlur}
      className={uiFieldClass}
    >
      {options.map((option) => (
        <option key={option.value} value={option.value}>{option.label}</option>
      ))}
    </select>
  </div>
);

const ReadOnlyInfoField: React.FC<{
  label: string;
  value: string;
  multiline?: boolean;
  compact?: boolean;
  emphasized?: boolean;
}> = ({ label, value, multiline = false, compact = false, emphasized = false }) => (
  <div>
    <label className={uiLabelClass}>{label}</label>
    <div className={`w-full px-3.5 py-2.5 ${
      emphasized ? uiFieldReadonlyAccentClass : uiFieldReadonlyClass
    } ${
      multiline
        ? compact
          ? 'max-h-[120px] overflow-y-auto whitespace-pre-wrap text-sm leading-relaxed'
          : 'min-h-[92px] whitespace-pre-wrap text-sm leading-relaxed'
        : 'text-sm'
    }`}>
      {value}
    </div>
  </div>
);

const InfoBadge: React.FC<{
  value: string;
}> = ({ value }) => (
  <div className={uiBadgeAccentClass}>
    <span>{value}</span>
  </div>
);

const InfoRow: React.FC<{ icon: any, label: string, value: string }> = ({ icon: Icon, label, value }) => (
  <div className="flex items-start gap-4">
    <div className="mt-1">
      <Icon size={16} className="text-slate-400" />
    </div>
    <div>
      <p className="text-xs font-bold text-slate-400 uppercase tracking-wider">{label}</p>
      <p className="text-slate-800 font-medium text-lg leading-snug">{value}</p>
    </div>
  </div>
);

const getPatientInitials = (firstName?: string, lastName?: string) => {
  const first = String(firstName || '').trim()[0] || '';
  const last = String(lastName || '').trim()[0] || '';
  return (first + last).toUpperCase() || '?';
};

const formatIdentity = (firstName?: string, lastName?: string) => {
  const value = [firstName, lastName].filter(Boolean).join(' ').trim();
  return value || 'Non renseigné';
};

const formatAddress = (address?: string, zipCode?: string, city?: string) => {
  const parts = [address, [zipCode, city].filter(Boolean).join(' ')].filter(Boolean);
  return parts.join(', ') || 'Non renseignée';
};

const formatAutonomyNotes = (value?: string) => {
  const text = String(value || '').trim();
  if (!text) return 'Aucune note';
  return text.length > 30 ? `${text.slice(0, 30)}...` : text;
};
