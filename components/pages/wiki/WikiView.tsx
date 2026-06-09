import React, { useEffect, useMemo, useState } from 'react';
import { Loader2, Plus, Search, X } from 'lucide-react';
import wikiLibraryStatic from '../../../data/wikiLibraryStatic.json';
import { createWikiLibraryItem, fetchWikiLibrary, preloadImageAssets, updateWikiLibraryItem } from '../../../services/dataService';
import { WikiLibraryItem } from '../../../types';
import { ViewportOverlay } from '../../layout/ViewportOverlay';
import { uiChipActiveClass, uiChipBaseClass, uiChipInactiveClass, uiFieldClass, uiIconButtonClass, uiModalClass, uiPanelInteractiveClass, uiPrimaryButtonClass, uiSecondaryButtonClass } from '../../shared/uiTheme';

const FILTER_TAGS = [
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

const STATIC_ITEMS = (wikiLibraryStatic.items as WikiLibraryItem[]).slice().sort((a, b) => a.title.localeCompare(b.title));
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

const ensureDescriptionFields = (values: string[]): string[] => {
  const next = values.slice(0, MAX_WIKI_DESCRIPTIONS);
  return next.length > 0 ? next : [''];
};

const serializeWikiDescriptions = (values: string[]): string => {
  const clean = values
    .map((entry) => entry.trim())
    .filter(Boolean)
    .slice(0, MAX_WIKI_DESCRIPTIONS);
  if (clean.length === 0) return '';
  if (clean.length === 1) return clean[0];
  return JSON.stringify(clean);
};

const searchableDescriptionText = (value: string): string => {
  const descriptions = parseWikiDescriptions(value);
  return descriptions.length > 0 ? descriptions.join(' ') : value;
};

const EMPTY_CREATE_ITEM = {
  title: '',
  descriptions: [''],
  tag: '',
  imageFile: null as File | null,
};

export const WikiView: React.FC = () => {
  const [items, setItems] = useState<WikiLibraryItem[]>(STATIC_ITEMS);
  const [selectedItem, setSelectedItem] = useState<WikiLibraryItem | null>(null);
  const [selectedTag, setSelectedTag] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [createDraft, setCreateDraft] = useState(EMPTY_CREATE_ITEM);
  const [createError, setCreateError] = useState<string | null>(null);
  const [isCreating, setIsCreating] = useState(false);
  const [editDraft, setEditDraft] = useState<{ title: string; descriptions: string[]; tag: string } | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const [draggedEditDescriptionIndex, setDraggedEditDescriptionIndex] = useState<number | null>(null);
  const [draggedCreateDescriptionIndex, setDraggedCreateDescriptionIndex] = useState<number | null>(null);

  const availableTags = useMemo(() => {
    const tags = new Set(FILTER_TAGS);
    items.forEach((item) => item.tags.forEach((tag) => tags.add(tag)));
    return Array.from(tags)
      .filter((tag) => items.some((item) => item.tags.includes(tag)))
      .sort((left, right) => left.localeCompare(right));
  }, [items]);

  const filteredItems = useMemo(() => {
    const normalized = search.trim().toLowerCase();
    return items.filter((item) => {
      const matchesTag = selectedTag ? item.tags.includes(selectedTag) : true;
      const haystack = `${item.title} ${searchableDescriptionText(item.description)} ${item.tags.join(' ')}`.toLowerCase();
      const matchesSearch = normalized ? haystack.includes(normalized) : true;
      return matchesTag && matchesSearch;
    });
  }, [items, search, selectedTag]);

  useEffect(() => {
    const loadItems = async () => {
      try {
        const remoteItems = await fetchWikiLibrary();
        if (remoteItems.length > 0) {
          setItems(remoteItems);
        }
      } catch {
        // Keep local static fallback.
      }
    };

    void loadItems();
  }, []);

  useEffect(() => {
    void preloadImageAssets(items.map((item) => item.imageUrl));
  }, [items]);

  const resetCreateForm = () => {
    setCreateDraft(EMPTY_CREATE_ITEM);
    setCreateError(null);
    setIsCreating(false);
  };

  const updateCreateDescriptions = (updater: (values: string[]) => string[]) => {
    setCreateDraft((prev) => ({
      ...prev,
      descriptions: ensureDescriptionFields(updater(prev.descriptions)).slice(0, MAX_WIKI_DESCRIPTIONS),
    }));
  };

  const updateEditDescriptions = (updater: (values: string[]) => string[]) => {
    if (!selectedItem) return;
    const fallbackDescriptions = ensureDescriptionFields(parseWikiDescriptions(selectedItem.description));
    setEditDraft((prev) => ({
      title: prev?.title ?? selectedItem.title,
      descriptions: ensureDescriptionFields(updater(prev?.descriptions ?? fallbackDescriptions)).slice(0, MAX_WIKI_DESCRIPTIONS),
      tag: prev?.tag ?? (selectedItem.tags[0] || ''),
    }));
  };

  const moveDescription = (values: string[], fromIndex: number, toIndex: number) => {
    if (fromIndex < 0 || fromIndex >= values.length || toIndex < 0 || toIndex >= values.length) return values;
    const next = [...values];
    const [moved] = next.splice(fromIndex, 1);
    next.splice(toIndex, 0, moved);
    return next;
  };

  const handleCreateItem = async () => {
    const title = createDraft.title.trim();
    if (!title) {
      setCreateError('Le titre est obligatoire.');
      return;
    }

    setIsCreating(true);
    setCreateError(null);
    try {
      const imageDataUrl = createDraft.imageFile ? await readFileAsDataUrl(createDraft.imageFile) : undefined;
      const tags = createDraft.tag ? [createDraft.tag] : [];
      const createdItem = await createWikiLibraryItem({
        title,
        description: serializeWikiDescriptions(createDraft.descriptions),
        category: createDraft.tag || 'Autre',
        tags,
        imageDataUrl,
      });
      setItems((prev) => [createdItem, ...prev.filter((item) => item.id !== createdItem.id)]);
      setIsCreateOpen(false);
      resetCreateForm();
    } catch (error: any) {
      setCreateError(error?.message || 'Création impossible');
      setIsCreating(false);
    }
  };

  const selectedDescriptionFields = selectedItem
    ? ensureDescriptionFields(parseWikiDescriptions(selectedItem.description))
    : [''];
  const activeEditDraft = selectedItem
    ? editDraft ?? {
        title: selectedItem.title,
        descriptions: selectedDescriptionFields,
        tag: selectedItem.tags[0] || '',
      }
    : null;

  return (
    <div className="space-y-6 h-full flex flex-col pb-24">
      <div className="flex flex-col xl:flex-row xl:items-end xl:justify-between gap-5">
        <div>
          <h2 className="text-3xl font-bold text-black">Bibliothèque</h2>
          <p className="mt-2 text-slate-600">Bibliothèque locale figée, disponible hors ligne et optimisée pour une consultation rapide.</p>
        </div>

        <div className="flex w-full flex-col gap-3 xl:w-auto xl:flex-row xl:items-center">
          <div className="relative w-full xl:w-[340px] overflow-hidden rounded-full border border-slate-200 bg-white">
          <input
            type="text"
            placeholder="Rechercher un equipement..."
            value={search}
            onChange={(event) => {
              setSearch(event.target.value);
              setSelectedTag(null);
            }}
            className={`${uiFieldClass} rounded-full border-0 bg-transparent py-3 pl-6 pr-10 text-slate-900`}
          />
            <Search className="absolute right-4 top-1/2 -translate-y-1/2 text-slate-500" size={18} />
          </div>
        </div>
      </div>

      <div className="flex flex-wrap gap-2">
        {availableTags.map((tag) => (
          <button
            key={tag}
            onClick={() => setSelectedTag(tag === selectedTag ? null : tag)}
            className={`${uiChipBaseClass} whitespace-nowrap text-sm ${tag === selectedTag ? uiChipActiveClass : uiChipInactiveClass}`}
          >
            {tag}
          </button>
        ))}
      </div>

      <div className="flex-1 overflow-y-auto pb-10 pr-2">
        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-6">
          {filteredItems.map((item) => (
            <button
              key={item.id}
              type="button"
              onClick={() => setSelectedItem(item)}
              className="group relative p-4 text-left rounded-[28px] transition-all duration-200 hover:bg-slate-50"
            >
              <div className="aspect-square rounded-xl overflow-hidden mb-4 bg-slate-100 relative ring-1 ring-black/10">
                <img
                  src={item.imageUrl}
                  alt={item.title}
                  loading="lazy"
                  decoding="async"
                  className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
                />
                {item.tags[0] && (
                  <div className="absolute bottom-2 left-2">
                    <span className="px-2 py-1 bg-black/55 rounded-md text-[10px] text-white font-bold">
                      {item.tags[0]}
                    </span>
                  </div>
                )}
              </div>
              <div>
                <div className="w-full">
                  <p className="font-bold text-slate-800 truncate">{item.title}</p>
                  {item.tags[0] && (
                    <p className="mt-1 text-xs font-semibold uppercase tracking-wider text-slate-400">{item.tags[0]}</p>
                  )}
                </div>
              </div>
            </button>
          ))}
        </div>
      </div>

      {selectedItem && (
        <ViewportOverlay
          className="fixed inset-0 bg-black/60 z-[80] flex items-center justify-center p-4 backdrop-blur-sm"
          onClick={() => { setSelectedItem(null); setEditDraft(null); }}
        >
          <div
            className={`${uiModalClass} relative flex h-[90vh] w-full max-w-5xl flex-col overflow-hidden md:h-auto md:flex-row`}
            onClick={(event) => event.stopPropagation()}
          >
            <button
              type="button"
              onClick={() => { setSelectedItem(null); setEditDraft(null); }}
              className="absolute top-4 right-4 z-10 rounded-full bg-black/20 p-2 text-white backdrop-blur-md transition-colors hover:bg-black/40"
            >
              <X size={20} />
            </button>

            <div className="w-full md:w-2/3 h-1/2 md:h-[640px] bg-slate-100 flex items-center justify-center">
              <img
                src={selectedItem.imageUrl}
                alt={selectedItem.title}
                loading="eager"
                decoding="async"
                className="max-w-full max-h-full object-contain"
              />
            </div>

            <div className="w-full md:w-1/3 p-6 flex flex-col gap-5 overflow-y-auto bg-white">
              <FormBlock label="Titre">
                <input
                  value={activeEditDraft?.title ?? selectedItem.title}
                  onChange={(e) => setEditDraft((prev) => ({
                    title: e.target.value,
                    descriptions: prev?.descriptions ?? selectedDescriptionFields,
                    tag: prev?.tag ?? (selectedItem.tags[0] || ''),
                  }))}
                  className="w-full rounded-2xl border border-slate-200 px-4 py-3 text-lg font-bold text-slate-900 outline-none focus:ring-2 focus:ring-[#907CA1]"
                />
              </FormBlock>

              <FormBlock label="Tag">
                <select
                  value={activeEditDraft?.tag ?? (selectedItem.tags[0] || '')}
                  onChange={(e) => setEditDraft((prev) => ({
                    title: prev?.title ?? selectedItem.title,
                    descriptions: prev?.descriptions ?? selectedDescriptionFields,
                    tag: e.target.value,
                  }))}
                  className="w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 outline-none focus:ring-2 focus:ring-[#907CA1]"
                >
                  <option value="">Aucun tag</option>
                  {availableTags.map((tag) => (
                    <option key={tag} value={tag}>{tag}</option>
                  ))}
                </select>
              </FormBlock>

              <div className="flex-1">
                <FormBlock label={`Descriptions (${activeEditDraft?.descriptions.length ?? selectedDescriptionFields.length}/${MAX_WIKI_DESCRIPTIONS})`}>
                  <div className="space-y-3">
                    {(activeEditDraft?.descriptions ?? selectedDescriptionFields).map((description, index, descriptions) => (
                      <div
                        key={index}
                        draggable={descriptions.length > 1}
                        onDragStart={(event) => {
                          setDraggedEditDescriptionIndex(index);
                          event.dataTransfer.effectAllowed = 'move';
                        }}
                        onDragOver={(event) => {
                          if (draggedEditDescriptionIndex !== null) event.preventDefault();
                        }}
                        onDrop={(event) => {
                          event.preventDefault();
                          if (draggedEditDescriptionIndex === null || draggedEditDescriptionIndex === index) return;
                          updateEditDescriptions((values) => moveDescription(values, draggedEditDescriptionIndex, index));
                          setDraggedEditDescriptionIndex(null);
                        }}
                        onDragEnd={() => setDraggedEditDescriptionIndex(null)}
                        className=""
                      >
                        <textarea
                          value={description}
                          onChange={(event) => {
                            const next = [...descriptions];
                            next[index] = event.target.value;
                            updateEditDescriptions(() => next);
                          }}
                          className="min-h-[92px] w-full resize-y rounded-2xl border border-slate-200 px-4 py-3 text-slate-700 leading-relaxed outline-none focus:ring-2 focus:ring-[#907CA1]"
                        />
                      </div>
                    ))}
                    {(activeEditDraft?.descriptions.length ?? selectedDescriptionFields.length) < MAX_WIKI_DESCRIPTIONS && (
                      <button
                        type="button"
                        onClick={() => updateEditDescriptions((values) => [...values, ''])}
                        className="inline-flex items-center gap-2 rounded-full border border-slate-200 px-3 py-2 text-xs font-bold text-slate-600 transition hover:border-[#907CA1] hover:text-slate-900"
                      >
                        <Plus size={14} />
                        Ajouter une description
                      </button>
                    )}
                  </div>
                </FormBlock>
              </div>

              {editDraft && (
                <button
                  type="button"
                  disabled={isSaving}
                  onClick={async () => {
                    setIsSaving(true);
                    try {
                      const saved = await updateWikiLibraryItem(selectedItem.id, {
                        title: editDraft.title.trim(),
                        description: serializeWikiDescriptions(editDraft.descriptions),
                        tags: editDraft.tag ? [editDraft.tag] : [],
                        category: editDraft.tag || 'Autre',
                      });
                      setItems((prev) => prev.map((item) => item.id === saved.id ? saved : item));
                      setSelectedItem(saved);
                      setEditDraft(null);
                    } catch {
                      // keep draft on error
                    } finally {
                      setIsSaving(false);
                    }
                  }}
                  className="rounded-2xl bg-[#907CA1] px-5 py-3 text-sm font-bold text-white transition-colors hover:bg-[#7a668a] disabled:opacity-50"
                >
                  {isSaving ? 'Enregistrement...' : 'Enregistrer'}
                </button>
              )}
            </div>
          </div>
        </ViewportOverlay>
      )}

      <div className="fixed bottom-6 right-6 z-40 md:bottom-8 md:right-8">
        <button
          type="button"
          onClick={() => {
            setIsCreateOpen(true);
            setCreateError(null);
          }}
          className="flex h-14 w-14 items-center justify-center rounded-full bg-[#907CA1] text-white shadow-lg transition-all hover:scale-105 hover:bg-[#7a668a] md:h-16 md:w-16"
          aria-label="Ajouter un élément"
          title="Ajouter un élément"
        >
          <Plus className="w-7 h-7 md:w-8 md:h-8" strokeWidth={2} />
        </button>
      </div>

      {isCreateOpen && (
        <ViewportOverlay
          className="fixed inset-0 bg-black/60 z-[80] flex items-center justify-center p-4 backdrop-blur-sm"
          onClick={() => {
            setIsCreateOpen(false);
            resetCreateForm();
          }}
        >
          <div
            className={`${uiModalClass} relative w-full max-w-3xl overflow-hidden`}
            onClick={(event) => event.stopPropagation()}
          >
            <button
              type="button"
              onClick={() => {
                setIsCreateOpen(false);
                resetCreateForm();
              }}
              className="absolute top-4 right-4 z-10 p-2 bg-slate-100 hover:bg-slate-200 text-slate-600 rounded-full transition-colors"
            >
              <X size={20} />
            </button>

            <div className="px-6 py-6 border-b border-slate-200">
              <h3 className="text-2xl font-bold text-slate-900">Nouvel élément</h3>
              <p className="mt-2 text-sm text-slate-500">Ajoute un visuel ou une inspiration avec ses informations principales.</p>
            </div>

            <div className="p-6 grid grid-cols-1 md:grid-cols-2 gap-5">
              <FormBlock label="Titre">
                <input
                  value={createDraft.title}
                  onChange={(event) => setCreateDraft((prev) => ({ ...prev, title: event.target.value }))}
                  className="w-full rounded-2xl border border-slate-200 px-4 py-3 outline-none focus:ring-2 focus:ring-[#907CA1]"
                />
              </FormBlock>

              <FormBlock label="Tag">
                <select
                  value={createDraft.tag}
                  onChange={(event) => setCreateDraft((prev) => ({ ...prev, tag: event.target.value }))}
                  className="w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 outline-none focus:ring-2 focus:ring-[#907CA1]"
                >
                  <option value="">Choisir un tag</option>
                  {availableTags.map((tag) => (
                    <option key={tag} value={tag}>
                      {tag}
                    </option>
                  ))}
                </select>
              </FormBlock>

              <div className="md:col-span-2">
                <FormBlock label={`Descriptions (${createDraft.descriptions.length}/${MAX_WIKI_DESCRIPTIONS})`}>
                  <div className="space-y-3">
                    {createDraft.descriptions.map((description, index, descriptions) => (
                      <div
                        key={index}
                        draggable={descriptions.length > 1}
                        onDragStart={(event) => {
                          setDraggedCreateDescriptionIndex(index);
                          event.dataTransfer.effectAllowed = 'move';
                        }}
                        onDragOver={(event) => {
                          if (draggedCreateDescriptionIndex !== null) event.preventDefault();
                        }}
                        onDrop={(event) => {
                          event.preventDefault();
                          if (draggedCreateDescriptionIndex === null || draggedCreateDescriptionIndex === index) return;
                          updateCreateDescriptions((values) => moveDescription(values, draggedCreateDescriptionIndex, index));
                          setDraggedCreateDescriptionIndex(null);
                        }}
                        onDragEnd={() => setDraggedCreateDescriptionIndex(null)}
                        className=""
                      >
                        <textarea
                          value={description}
                          onChange={(event) => {
                            const next = [...descriptions];
                            next[index] = event.target.value;
                            updateCreateDescriptions(() => next);
                          }}
                          className="min-h-[92px] w-full resize-y rounded-2xl border border-slate-200 px-4 py-3 outline-none focus:ring-2 focus:ring-[#907CA1]"
                        />
                      </div>
                    ))}
                    {createDraft.descriptions.length < MAX_WIKI_DESCRIPTIONS && (
                      <button
                        type="button"
                        onClick={() => updateCreateDescriptions((values) => [...values, ''])}
                        className="inline-flex items-center gap-2 rounded-full border border-slate-200 px-3 py-2 text-xs font-bold text-slate-600 transition hover:border-[#907CA1] hover:text-slate-900"
                      >
                        <Plus size={14} />
                        Ajouter une description
                      </button>
                    )}
                  </div>
                </FormBlock>
              </div>

              <div className="md:col-span-2">
                <FormBlock label="Image">
                  <label className="flex items-center justify-between gap-4 rounded-2xl border border-dashed border-slate-300 px-4 py-3 text-sm font-medium text-slate-600 cursor-pointer hover:border-[#907CA1] hover:text-slate-900 transition-colors">
                    <span>{createDraft.imageFile ? createDraft.imageFile.name : 'Choisir une image'}</span>
                    <span className="inline-flex items-center gap-2 rounded-full bg-slate-100 px-3 py-1.5 text-xs font-bold uppercase tracking-wider text-slate-500">Parcourir</span>
                    <input
                      type="file"
                      accept="image/*"
                      className="hidden"
                      onChange={(event) => {
                        const file = event.target.files?.[0] || null;
                        setCreateDraft((prev) => ({ ...prev, imageFile: file }));
                      }}
                    />
                  </label>
                </FormBlock>
              </div>
            </div>

            <div className="px-6 pb-6 flex items-center justify-between gap-4">
              <div className="text-sm font-medium text-red-600">
                {createError || null}
              </div>
              <button
                type="button"
                onClick={() => void handleCreateItem()}
                className="inline-flex items-center justify-center gap-2 rounded-2xl bg-[#907CA1] px-5 py-3 text-sm font-bold text-white transition-colors hover:bg-[#7a668a] disabled:opacity-50"
                disabled={isCreating || !createDraft.title.trim()}
              >
                {isCreating ? <Loader2 size={16} className="animate-spin" /> : null}
                <span>Créer</span>
              </button>
            </div>
          </div>
        </ViewportOverlay>
      )}
    </div>
  );
};

const FormBlock: React.FC<{ label: string; children: React.ReactNode }> = ({ label, children }) => (
  <div>
    <p className="mb-2 text-xs font-bold uppercase tracking-wider text-slate-500">{label}</p>
    {children}
  </div>
);

const readFileAsDataUrl = (file: File): Promise<string> => (
  new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ''));
    reader.onerror = () => reject(new Error('Lecture du fichier impossible'));
    reader.readAsDataURL(file);
  })
);
