import React, { useEffect, useMemo, useState } from 'react';
import { CheckCheck, Clock3, ExternalLink, Loader2, Phone, Plus, Save, Search, StickyNote, Users, X } from 'lucide-react';
import { createRetirementFund, fetchRetirementFunds, getCachedRetirementFunds, preloadImageAssets, updateRetirementFund } from '../services/dataService';
import { RetirementFund } from '../types';
import { SimpleLoader } from './LoadingProgress';
import { ViewportOverlay } from './ViewportOverlay';

const phoneHref = (phone: string) => `tel:${phone.replace(/[^\d+]/g, '')}`;

const formatLastEditedAt = (value?: string) => {
    if (!value) return 'Jamais modifié';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return 'Jamais modifié';
    return `Mis à jour le ${date.toLocaleDateString('fr-FR')} à ${date.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}`;
};

type SaveState = 'idle' | 'saving' | 'saved' | 'error';

type CreateFundDraft = {
    name: string;
    phone: string;
    audience: string;
    requestMethod: string;
    requestDelay: string;
    aidAmount: string;
    therapistNote: string;
};

const getInitialCachedFunds = () => getCachedRetirementFunds();

const toDraftMap = (items: RetirementFund[]) => Object.fromEntries(items.map((fund) => [fund.id, fund]));

const EMPTY_CREATE_FUND: CreateFundDraft = {
    name: '',
    phone: '',
    audience: '',
    requestMethod: '',
    requestDelay: '',
    aidAmount: '',
    therapistNote: '',
};

export const RetirementFundsView: React.FC = () => {
    const [funds, setFunds] = useState<RetirementFund[]>(() => getInitialCachedFunds());
    const [drafts, setDrafts] = useState<Record<string, RetirementFund>>(() => toDraftMap(getInitialCachedFunds()));
    const [saveStates, setSaveStates] = useState<Record<string, SaveState>>({});
    const [selectedFundId, setSelectedFundId] = useState<string | null>(null);
    const [query, setQuery] = useState('');
    const [isLoading, setIsLoading] = useState(() => getInitialCachedFunds().length === 0);
    const [error, setError] = useState<string | null>(null);
    const [isCreateOpen, setIsCreateOpen] = useState(false);
    const [createDraft, setCreateDraft] = useState<CreateFundDraft>(EMPTY_CREATE_FUND);
    const [createState, setCreateState] = useState<SaveState>('idle');
    const [createError, setCreateError] = useState<string | null>(null);
    useEffect(() => {
        const load = async () => {
            const cachedItems = getCachedRetirementFunds();
            if (cachedItems.length > 0) {
                setFunds(cachedItems);
                setDrafts(toDraftMap(cachedItems));
            } else {
                setIsLoading(true);
            }

            try {
                setError(null);
                const items = await fetchRetirementFunds();
                setFunds(items);
                setDrafts(toDraftMap(items));
            } catch (loadError: any) {
                if (cachedItems.length === 0) {
                    setError(loadError.message || 'Chargement impossible');
                }
            } finally {
                setIsLoading(false);
            }
        };

        load().catch(() => {
            if (getCachedRetirementFunds().length === 0) {
                setError('Chargement impossible');
            }
            setIsLoading(false);
        });
    }, []);

    useEffect(() => {
        void preloadImageAssets(funds.map((fund) => fund.logoUrl));
    }, [funds]);

    const filteredFunds = useMemo(() => {
        const normalizedQuery = query.trim().toLowerCase();
        const source = funds.map((fund) => drafts[fund.id] || fund);
        if (!normalizedQuery) return source;
        return source.filter((fund) =>
            `${fund.name} ${fund.audience} ${fund.requestMethod} ${fund.therapistNote}`.toLowerCase().includes(normalizedQuery)
        );
    }, [drafts, funds, query]);

    const selectedFund = selectedFundId ? drafts[selectedFundId] || funds.find((fund) => fund.id === selectedFundId) || null : null;

    const updateDraft = (fundId: string, field: keyof RetirementFund, value: string) => {
        setDrafts((prev) => ({
            ...prev,
            [fundId]: {
                ...(prev[fundId] || funds.find((fund) => fund.id === fundId)!),
                [field]: value,
            },
        }));
        setSaveStates((prev) => ({ ...prev, [fundId]: 'idle' }));
    };

    const openFund = (fundId: string) => {
        const source = drafts[fundId] || funds.find((fund) => fund.id === fundId);
        if (!source) return;
        setDrafts((prev) => ({ ...prev, [fundId]: source }));
        setSelectedFundId(fundId);
    };

    const updateCreateDraft = (field: keyof CreateFundDraft, value: string) => {
        setCreateDraft((prev) => ({ ...prev, [field]: value }));
        setCreateError(null);
        setCreateState('idle');
    };

    const handleSave = async (fundId: string) => {
        const draft = drafts[fundId];
        if (!draft) return;

        setSaveStates((prev) => ({ ...prev, [fundId]: 'saving' }));
        try {
            const saved = await updateRetirementFund(fundId, {
                name: draft.name,
                phone: draft.phone,
                audience: draft.audience,
                requestMethod: draft.requestMethod,
                requestDelay: draft.requestDelay,
                aidAmount: draft.aidAmount,
                therapistNote: draft.therapistNote,
                website: draft.website,
            });

            setFunds((prev) => prev.map((fund) => fund.id === fundId ? { ...fund, ...saved } : fund));
            setDrafts((prev) => ({
                ...prev,
                [fundId]: {
                    ...draft,
                    ...saved,
                },
            }));
            setSaveStates((prev) => ({ ...prev, [fundId]: 'saved' }));
        } catch {
            setSaveStates((prev) => ({ ...prev, [fundId]: 'error' }));
        }
    };

    const handleCreateFund = async () => {
        if (!createDraft.name.trim()) {
            setCreateError('Le nom de la caisse est obligatoire.');
            setCreateState('error');
            return;
        }

        setCreateState('saving');
        setCreateError(null);
        try {
            const createdFund = await createRetirementFund({
                name: createDraft.name,
                phone: createDraft.phone,
                audience: createDraft.audience,
                requestMethod: createDraft.requestMethod,
                requestDelay: createDraft.requestDelay,
                aidAmount: createDraft.aidAmount,
                therapistNote: createDraft.therapistNote,
            });
            setFunds((prev) => [createdFund, ...prev.filter((fund) => fund.id !== createdFund.id)]);
            setDrafts((prev) => ({
                ...prev,
                [createdFund.id]: createdFund,
            }));
            setSelectedFundId(createdFund.id);
            setIsCreateOpen(false);
            setCreateDraft(EMPTY_CREATE_FUND);
            setCreateState('saved');
        } catch (creationError: any) {
            setCreateError(creationError?.message || 'Création impossible');
            setCreateState('error');
        }
    };

    return (
        <div className="space-y-8 pb-24">
            <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
                <h2 className="text-2xl font-bold text-slate-900 lg:text-3xl">Caisses de retraites complémentaires</h2>

                <div className="flex w-full flex-col gap-3 lg:w-auto lg:flex-row lg:items-center">
                    <div className="w-full lg:w-[360px]">
                        <div className="flex items-center gap-3 bg-white border border-slate-200 rounded-2xl px-4 py-3 shadow-sm">
                            <Search size={18} className="text-slate-400" />
                            <input
                                value={query}
                                onChange={(event) => setQuery(event.target.value)}
                                placeholder="Klésia, AG2R, Pro BTP..."
                                className="w-full bg-transparent outline-none text-slate-700 placeholder:text-slate-400"
                            />
                        </div>
                    </div>
                </div>
            </div>

            {isLoading ? (
                <SimpleLoader label="Chargement des caisses" />
            ) : error ? (
                <div className="bg-red-50 border border-red-100 rounded-[28px] p-6 text-red-700 font-medium">
                    {error}
                </div>
            ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                    {filteredFunds.map((fund) => (
                        <button
                            key={fund.id}
                            type="button"
                            onClick={() => openFund(fund.id)}
                            className="h-full flex flex-col items-start justify-start text-left bg-white rounded-[28px] border border-slate-200 p-6 shadow-sm hover:shadow-md hover:border-[#907CA1] transition-all duration-200"
                        >
                            <div className="w-full flex items-start justify-between gap-4">
                                <div className="w-24 h-16 rounded-2xl bg-white border border-slate-200 px-2 py-1.5 flex items-center justify-center overflow-hidden">
                                    <img
                                        src={fund.logoUrl}
                                        alt={fund.name}
                                        loading="lazy"
                                        decoding="async"
                                        className="w-full h-full object-contain object-center scale-[1.08]"
                                    />
                                </div>
                                <span className="px-3 py-1 rounded-full bg-[#907CA1]/10 text-[#907CA1] text-xs font-bold uppercase tracking-wider">
                                    Ouvrir
                                </span>
                            </div>

                            <h3 className="mt-5 text-2xl font-bold text-slate-900">{fund.name}</h3>
                            <p className="mt-3 text-sm text-slate-600 leading-relaxed line-clamp-3">{fund.audience}</p>
                            {fund.therapistNote && (
                                <p className="mt-4 text-sm font-medium text-slate-900 line-clamp-2">{fund.therapistNote}</p>
                            )}

                            <div className="mt-5 flex flex-wrap gap-2 text-xs font-semibold text-slate-500">
                                {fund.phone && (
                                    <span className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-slate-100">
                                        <Phone size={12} />
                                        {fund.phone}
                                    </span>
                                )}
                                <span className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-slate-100">
                                    <Clock3 size={12} />
                                    {formatLastEditedAt(fund.lastEditedAt).replace('Mis à jour le ', '')}
                                </span>
                            </div>
                        </button>
                    ))}
                </div>
            )}

            {!isLoading && !error && filteredFunds.length === 0 && (
                <div className="bg-white rounded-[28px] border border-slate-200 p-8 text-center text-slate-500">
                    Aucun organisme ne correspond à cette recherche.
                </div>
            )}

            {selectedFund && (
                <ViewportOverlay
                    className="fixed inset-0 z-[80] bg-slate-950/50 backdrop-blur-sm flex items-center justify-center p-4"
                    onClick={() => setSelectedFundId(null)}
                >
                    <div
                        className="w-full max-w-4xl bg-white rounded-[36px] shadow-2xl overflow-hidden"
                        onClick={(event) => event.stopPropagation()}
                    >
                        <div className="px-8 py-7 border-b border-slate-200 flex items-start justify-between gap-6">
                            <div className="flex items-center gap-5">
                                <div className="w-28 h-20 rounded-[24px] bg-white border border-slate-200 px-3 py-2 flex items-center justify-center overflow-hidden">
                                    <img
                                        src={selectedFund.logoUrl}
                                        alt={selectedFund.name}
                                        loading="lazy"
                                        decoding="async"
                                        className="w-full h-full object-contain object-center scale-[1.08]"
                                    />
                                </div>
                                <div>
                                    <input
                                        value={selectedFund.name}
                                        onChange={(event) => updateDraft(selectedFund.id, 'name', event.target.value)}
                                        className="text-3xl font-bold text-slate-900 bg-transparent outline-none border-b border-transparent focus:border-[#907CA1]"
                                    />
                                    <p className="mt-2 text-sm font-semibold text-slate-500">{formatLastEditedAt(selectedFund.lastEditedAt)}</p>
                                </div>
                            </div>

                            <div className="ml-auto flex items-start gap-2">
                                <SaveStateIndicator
                                    status={saveStates[selectedFund.id] || 'idle'}
                                    onSave={() => handleSave(selectedFund.id)}
                                />
                                <button
                                    type="button"
                                    onClick={() => setSelectedFundId(null)}
                                    className="w-11 h-11 rounded-full bg-slate-100 hover:bg-slate-200 text-slate-600 flex items-center justify-center transition-colors"
                                >
                                    <X size={20} />
                                </button>
                            </div>
                        </div>

                        <div className="p-8 grid grid-cols-1 lg:grid-cols-2 gap-5 max-h-[80vh] overflow-y-auto">
                            <FieldBlock icon={Users} label="Profils éligibles">
                                <Textarea value={selectedFund.audience} onChange={(value) => updateDraft(selectedFund.id, 'audience', value)} />
                            </FieldBlock>
                            <FieldBlock icon={Clock3} label="Délai">
                                <Textarea value={selectedFund.requestDelay} onChange={(value) => updateDraft(selectedFund.id, 'requestDelay', value)} />
                            </FieldBlock>
                            <FieldBlock icon={StickyNote} label="Montant possible">
                                <Textarea value={selectedFund.aidAmount || ''} onChange={(value) => updateDraft(selectedFund.id, 'aidAmount', value)} />
                            </FieldBlock>
                            <FieldBlock icon={StickyNote} label="Format de demande">
                                <Textarea value={selectedFund.requestMethod} onChange={(value) => updateDraft(selectedFund.id, 'requestMethod', value)} />
                            </FieldBlock>

                            <div className="lg:col-span-2 rounded-[24px] border border-[#E6D7A8] bg-[#FFF7D6] px-5 py-4">
                                <div className="flex items-center gap-2 text-xs font-bold uppercase tracking-wider text-[#8A6A00]">
                                    <StickyNote size={14} />
                                    <span>Note ergothérapeute</span>
                                </div>
                                <textarea
                                    value={selectedFund.therapistNote}
                                    onChange={(event) => updateDraft(selectedFund.id, 'therapistNote', event.target.value)}
                                    className="mt-2 w-full min-h-[88px] bg-transparent outline-none resize-y text-[#5C4300] font-semibold leading-relaxed"
                                />
                            </div>

                            <FieldBlock icon={Phone} label="Téléphone">
                                <div className="space-y-3">
                                    <Input value={selectedFund.phone} onChange={(value) => updateDraft(selectedFund.id, 'phone', value)} />
                                    {selectedFund.phone && (
                                        <a href={phoneHref(selectedFund.phone)} className="inline-flex items-center gap-2 text-sm font-semibold text-[#907CA1] hover:text-[#7a668a]">
                                            <Phone size={14} />
                                            Appeler
                                        </a>
                                    )}
                                </div>
                            </FieldBlock>

                            <FieldBlock icon={ExternalLink} label="Site officiel">
                                <div className="space-y-3">
                                    <Input value={selectedFund.website} onChange={(value) => updateDraft(selectedFund.id, 'website', value)} />
                                    {selectedFund.website && (
                                        <a href={selectedFund.website} target="_blank" rel="noreferrer" className="inline-flex items-center gap-2 text-sm font-semibold text-[#907CA1] hover:text-[#7a668a] break-all">
                                            <ExternalLink size={14} />
                                            Ouvrir le site
                                        </a>
                                    )}
                                </div>
                            </FieldBlock>

                            <div className="lg:col-span-2 text-xs font-bold uppercase tracking-wider">
                                {saveStates[selectedFund.id] === 'saved' && <span className="text-emerald-600">Enregistré</span>}
                                {saveStates[selectedFund.id] === 'error' && <span className="text-red-600">Erreur d’enregistrement</span>}
                            </div>
                        </div>
                    </div>
                </ViewportOverlay>
            )}

            {isCreateOpen && (
                <ViewportOverlay
                    className="fixed inset-0 z-[80] bg-slate-950/50 backdrop-blur-sm flex items-center justify-center p-4"
                    onClick={() => {
                        setIsCreateOpen(false);
                        setCreateDraft(EMPTY_CREATE_FUND);
                        setCreateError(null);
                        setCreateState('idle');
                    }}
                >
                    <div
                        className="w-full max-w-4xl bg-white rounded-[36px] shadow-2xl overflow-hidden"
                        onClick={(event) => event.stopPropagation()}
                    >
                        <div className="px-8 py-7 border-b border-slate-200 flex items-start justify-between gap-6">
                            <div>
                                <h3 className="text-3xl font-bold text-slate-900">Nouvelle caisse</h3>
                                <p className="mt-2 text-sm font-medium text-slate-500">Renseigne les champs utiles, puis valide la création.</p>
                            </div>

                            <button
                                type="button"
                                onClick={() => {
                                    setIsCreateOpen(false);
                                    setCreateDraft(EMPTY_CREATE_FUND);
                                    setCreateError(null);
                                    setCreateState('idle');
                                }}
                                className="ml-auto w-11 h-11 rounded-full bg-slate-100 hover:bg-slate-200 text-slate-600 flex items-center justify-center transition-colors"
                            >
                                <X size={20} />
                            </button>
                        </div>

                        <div className="p-8 grid grid-cols-1 lg:grid-cols-2 gap-5 max-h-[80vh] overflow-y-auto">
                            <FieldBlock icon={Users} label="Nom">
                                <Input value={createDraft.name} onChange={(value) => updateCreateDraft('name', value)} />
                            </FieldBlock>
                            <FieldBlock icon={Phone} label="Téléphone">
                                <Input value={createDraft.phone} onChange={(value) => updateCreateDraft('phone', value)} />
                            </FieldBlock>
                            <FieldBlock icon={Users} label="Profils éligibles">
                                <Textarea compact value={createDraft.audience} onChange={(value) => updateCreateDraft('audience', value)} />
                            </FieldBlock>
                            <FieldBlock icon={StickyNote} label="Format de demande">
                                <Textarea compact value={createDraft.requestMethod} onChange={(value) => updateCreateDraft('requestMethod', value)} />
                            </FieldBlock>
                            <FieldBlock icon={Clock3} label="Délai">
                                <Textarea compact value={createDraft.requestDelay} onChange={(value) => updateCreateDraft('requestDelay', value)} />
                            </FieldBlock>
                            <FieldBlock icon={StickyNote} label="Montant possible">
                                <Textarea compact value={createDraft.aidAmount} onChange={(value) => updateCreateDraft('aidAmount', value)} />
                            </FieldBlock>

                            <div className="lg:col-span-2 rounded-[24px] border border-[#E6D7A8] bg-[#FFF7D6] px-5 py-4">
                                <div className="flex items-center gap-2 text-xs font-bold uppercase tracking-wider text-[#8A6A00]">
                                    <StickyNote size={14} />
                                    <span>Note ergothérapeute</span>
                                </div>
                                <textarea
                                    value={createDraft.therapistNote}
                                    onChange={(event) => updateCreateDraft('therapistNote', event.target.value)}
                                    rows={1}
                                    className="mt-2 h-11 w-full bg-transparent outline-none resize-none text-[#5C4300] font-semibold leading-relaxed"
                                />
                            </div>

                            <div className="lg:col-span-2 flex items-center justify-between gap-4">
                                <div className="text-sm font-medium text-red-600">
                                    {createError || null}
                                </div>
                                <button
                                    type="button"
                                    onClick={() => void handleCreateFund()}
                                    className="inline-flex items-center justify-center gap-2 rounded-2xl bg-[#907CA1] px-5 py-3 text-sm font-bold text-white transition-colors hover:bg-[#7a668a] disabled:opacity-50"
                                    disabled={createState === 'saving' || !createDraft.name.trim()}
                                >
                                    {createState === 'saving' && <Loader2 size={16} className="animate-spin" />}
                                    Créer
                                </button>
                            </div>
                        </div>
                    </div>
                </ViewportOverlay>
            )}

            <div className="fixed bottom-6 right-6 z-40 md:bottom-8 md:right-8">
                <button
                    type="button"
                    onClick={() => {
                        setIsCreateOpen(true);
                        setCreateState('idle');
                        setCreateError(null);
                    }}
                    className="w-14 h-14 md:w-16 md:h-16 bg-[#907CA1] rounded-full shadow-lg flex items-center justify-center text-white hover:scale-105 hover:bg-[#7a668a] transition-all"
                    aria-label="Ajouter une caisse"
                    title="Ajouter une caisse"
                >
                    <Plus className="w-7 h-7 md:w-8 md:h-8" strokeWidth={2} />
                </button>
            </div>
        </div>
    );
};

const SaveStateIndicator: React.FC<{ status: SaveState; onSave: () => void }> = ({ status, onSave }) => {
    if (status === 'idle') {
        return (
            <button
                type="button"
                onClick={onSave}
                className="inline-flex items-center justify-center w-11 h-11 rounded-full bg-[#907CA1] text-white hover:bg-[#7a668a] transition-colors"
                aria-label="Enregistrer"
                title="Enregistrer"
            >
                <Save size={16} />
            </button>
        );
    }

    const config = {
        saving: {
            icon: <Loader2 size={18} className="animate-spin" />,
            className: 'border-amber-200 bg-amber-50 text-amber-700',
            label: 'Enregistrement en cours',
        },
        saved: {
            icon: <CheckCheck size={18} />,
            className: 'border-emerald-200 bg-emerald-50 text-emerald-700',
            label: 'Enregistrement terminé',
        },
        error: {
            icon: <X size={18} />,
            className: 'border-red-200 bg-red-50 text-red-700',
            label: 'Erreur de sauvegarde',
        },
    }[status];

    return (
        <div
            className={`w-11 h-11 rounded-full border flex items-center justify-center transition-all duration-200 ${config.className}`}
            aria-live="polite"
            aria-label={config.label}
            title={config.label}
        >
            {config.icon}
        </div>
    );
};

const FieldBlock: React.FC<{ icon: any; label: string; children: React.ReactNode }> = ({ icon: Icon, label, children }) => (
    <div className="rounded-[24px] border border-slate-200 px-5 py-4 bg-white">
        <div className="flex items-center gap-2 text-xs font-bold uppercase tracking-wider text-slate-500">
            <Icon size={14} />
            <span>{label}</span>
        </div>
        <div className="mt-2">{children}</div>
    </div>
);

const Textarea: React.FC<{ value: string; onChange: (value: string) => void; compact?: boolean }> = ({ value, onChange, compact = false }) => (
    <textarea
        value={value}
        onChange={(event) => onChange(event.target.value)}
        rows={compact ? 1 : 4}
        className={`w-full bg-transparent outline-none text-slate-900 font-semibold leading-relaxed ${
            compact ? 'h-11 resize-none overflow-hidden' : 'min-h-[88px] resize-y'
        }`}
    />
);

const Input: React.FC<{ value: string; onChange: (value: string) => void }> = ({ value, onChange }) => (
    <input
        value={value}
        onChange={(event) => onChange(event.target.value)}
        className="w-full bg-transparent outline-none text-slate-900 font-semibold border-b border-slate-200 focus:border-[#907CA1] pb-2"
    />
);
