import React, { useEffect, useMemo, useState } from 'react';
import { Loader2, Plus, Search, X } from 'lucide-react';
import wikiLibraryStatic from '../data/wikiLibraryStatic.json';
import { createWikiLibraryItem, fetchWikiLibrary, preloadImageAssets } from '../services/dataService';
import { WikiLibraryItem } from '../types';
import { ViewportOverlay } from './ViewportOverlay';
import { uiChipActiveClass, uiChipBaseClass, uiChipInactiveClass, uiFieldClass, uiIconButtonClass, uiModalClass, uiPanelInteractiveClass, uiPrimaryButtonClass, uiSecondaryButtonClass } from './uiTheme';

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

const EMPTY_CREATE_ITEM = {
  title: '',
  description: '',
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
      const haystack = `${item.title} ${item.description} ${item.tags.join(' ')}`.toLowerCase();
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
        description: createDraft.description.trim(),
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
              className={`${uiPanelInteractiveClass} group relative p-4 text-left`}
            >
              <div className="aspect-square rounded-xl overflow-hidden mb-4 bg-slate-100 relative">
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
                  <p className="font-bold text-slate-800">{item.title}</p>
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
          onClick={() => setSelectedItem(null)}
        >
          <div
            className={`${uiModalClass} relative flex h-[90vh] w-full max-w-5xl flex-col overflow-hidden md:h-auto md:flex-row`}
            onClick={(event) => event.stopPropagation()}
          >
            <button
              type="button"
              onClick={() => setSelectedItem(null)}
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

            <div className="w-full md:w-1/3 p-6 flex flex-col gap-6 overflow-y-auto bg-white">
              <div>
                <p className="text-xs font-bold text-slate-500 uppercase tracking-wider mb-2">Titre</p>
                <h3 className="text-2xl font-bold text-slate-900">{selectedItem.title}</h3>
              </div>

              {selectedItem.tags[0] && (
                <div>
                  <p className="text-xs font-bold text-slate-500 uppercase tracking-wider mb-2">Tag</p>
                  <div className="inline-flex px-3 py-1.5 rounded-full bg-slate-100 text-sm font-semibold text-slate-700">
                    {selectedItem.tags[0]}
                  </div>
                </div>
              )}

              <div className="flex-1">
                <p className="text-xs font-bold text-slate-500 uppercase tracking-wider mb-2">Description</p>
                <p className="text-slate-700 leading-relaxed">{selectedItem.description}</p>
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
                <FormBlock label="Description">
                  <textarea
                    value={createDraft.description}
                    onChange={(event) => setCreateDraft((prev) => ({ ...prev, description: event.target.value }))}
                    className="w-full min-h-[120px] rounded-2xl border border-slate-200 px-4 py-3 outline-none resize-y focus:ring-2 focus:ring-[#907CA1]"
                  />
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
