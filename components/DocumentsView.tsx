import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowLeft, Camera, Check, File, FileText, Image as ImageIcon, Loader2, Plus, ScanLine, Upload, X } from 'lucide-react';

import { deleteDocument, fetchDocumentBlob, fetchDocuments, getCachedDocumentBlob, updateDocument, uploadDocument } from '../services/dataService';
import { AppDocument, Dossier } from '../types';
import { LoadingProgress, SimpleLoader, useSmoothLoadingState } from './LoadingProgress';
import { ViewportOverlay } from './ViewportOverlay';

interface DocumentsViewProps {
  dossier: Dossier;
  onBack: () => void;
  initialDocuments?: AppDocument[];
  initialPreparedAt?: string | null;
  initialIsReady?: boolean;
}

const AVAILABLE_TAGS = ['Mandat', 'Rapport', 'Facture', 'Devis', 'Cerfa', 'Photo', 'Plan', 'Autre'];

const buildCachedObjectUrls = (documents: AppDocument[]) => {
  if (typeof window === 'undefined') {
    return {};
  }

  return documents.reduce<Record<string, string>>((accumulator, document) => {
    const cachedBlob = getCachedDocumentBlob(document.id);
    if (!cachedBlob) {
      return accumulator;
    }
    accumulator[document.id] = window.URL.createObjectURL(cachedBlob);
    return accumulator;
  }, {});
};

export const DocumentsView: React.FC<DocumentsViewProps> = ({
  dossier,
  onBack,
  initialDocuments = [],
  initialPreparedAt = null,
  initialIsReady = false,
}) => {
  const fileInputRef = useRef<HTMLInputElement>(null);
  const cameraInputRef = useRef<HTMLInputElement>(null);
  const scannerInputRef = useRef<HTMLInputElement>(null);
  const importInputRef = useRef<HTMLInputElement>(null);
  const objectUrlsRef = useRef<Record<string, string>>({});
  const objectUrlPromisesRef = useRef<Record<string, Promise<string>>>({});

  const [docs, setDocs] = useState<AppDocument[]>(initialDocuments);
  const [showAddMenu, setShowAddMenu] = useState(false);
  const [selectedDoc, setSelectedDoc] = useState<AppDocument | null>(null);
  const [isUploading, setIsUploading] = useState(false);
  const [isSavingMetadata, setIsSavingMetadata] = useState(false);
  const [editingTitle, setEditingTitle] = useState('');
  const [editingTag, setEditingTag] = useState('Autre');
  const [docToDelete, setDocToDelete] = useState<AppDocument | null>(null);
  const [selectedTag, setSelectedTag] = useState<string | null>(null);
  const [uploadModalOpen, setUploadModalOpen] = useState(false);
  const [pendingFile, setPendingFile] = useState<File | null>(null);
  const [uploadName, setUploadName] = useState('');
  const [uploadTag, setUploadTag] = useState('Autre');
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [lastSyncedAt, setLastSyncedAt] = useState<string | null>(initialPreparedAt);
  const [documentObjectUrls, setDocumentObjectUrls] = useState<Record<string, string>>(() => buildCachedObjectUrls(initialDocuments));
  const [previewLoadingId, setPreviewLoadingId] = useState<string | null>(null);
  const [isGalleryReady, setIsGalleryReady] = useState(initialIsReady);
  const uploadLoadingState = useSmoothLoadingState(isUploading, { minVisibleMs: 520 });

  const revokeObjectUrl = useCallback((url?: string) => {
    if (url) {
      window.URL.revokeObjectURL(url);
    }
  }, []);

  useEffect(() => {
    objectUrlsRef.current = documentObjectUrls;
  }, [documentObjectUrls]);

  const setDocumentObjectUrl = useCallback((documentId: string, objectUrl: string) => {
    setDocumentObjectUrls((current) => {
      const previousUrl = current[documentId];
      if (previousUrl === objectUrl) {
        return current;
      }
      if (previousUrl) {
        revokeObjectUrl(previousUrl);
      }
      return { ...current, [documentId]: objectUrl };
    });
  }, [revokeObjectUrl]);

  const ensureDocumentObjectUrl = useCallback(async (document: AppDocument): Promise<string> => {
    if (objectUrlsRef.current[document.id]) {
      return objectUrlsRef.current[document.id];
    }

    if (objectUrlPromisesRef.current[document.id]) {
      return objectUrlPromisesRef.current[document.id];
    }

    const pendingPromise = (async () => {
      const blob = await fetchDocumentBlob(document);
      const objectUrl = window.URL.createObjectURL(blob);
      const existingUrl = objectUrlsRef.current[document.id];
      if (existingUrl) {
        revokeObjectUrl(objectUrl);
        return existingUrl;
      }
      setDocumentObjectUrl(document.id, objectUrl);
      return objectUrl;
    })().finally(() => {
      delete objectUrlPromisesRef.current[document.id];
    });

    objectUrlPromisesRef.current[document.id] = pendingPromise;
    return pendingPromise;
  }, [revokeObjectUrl, setDocumentObjectUrl]);

  const preloadDocumentPreviews = useCallback(async (documents: AppDocument[]) => {
    const previewableDocs = documents.filter((doc) => doc.type === 'image' || doc.type === 'pdf');
    if (previewableDocs.length === 0) {
      return;
    }

    await Promise.allSettled(previewableDocs.map((doc) => ensureDocumentObjectUrl(doc)));
  }, [ensureDocumentObjectUrl]);

  useEffect(() => {
    const activeIds = new Set(docs.map((doc) => doc.id));
    setDocumentObjectUrls((current) => {
      let changed = false;
      const next: Record<string, string> = {};
      (Object.entries(current) as Array<[string, string]>).forEach(([documentId, objectUrl]) => {
        if (activeIds.has(documentId)) {
          next[documentId] = objectUrl;
          return;
        }
        revokeObjectUrl(objectUrl);
        changed = true;
      });
      return changed ? next : current;
    });
  }, [docs, revokeObjectUrl]);

  const refreshDocuments = useCallback(async (options?: { silent?: boolean }) => {
    if (!options?.silent) {
      setIsRefreshing(true);
      setIsGalleryReady(false);
    }

    try {
      const fetchedDocs = await fetchDocuments(dossier.patient.id, dossier.id);
      if (options?.silent) {
        void preloadDocumentPreviews(fetchedDocs);
      } else {
        await preloadDocumentPreviews(fetchedDocs);
      }
      setDocs(fetchedDocs);
      setLastSyncedAt(new Date().toISOString());
      setSelectedDoc((current) => {
        if (!current) return null;
        return fetchedDocs.find((doc) => doc.id === current.id) || null;
      });
      setIsGalleryReady(true);
    } finally {
      if (!options?.silent) {
        setIsRefreshing(false);
      }
    }
  }, [dossier.id, dossier.patient.id, preloadDocumentPreviews]);

  useEffect(() => {
    const initialRefresh = initialIsReady
      ? refreshDocuments({ silent: true })
      : refreshDocuments();
    initialRefresh.catch((error) => console.error('DocumentsView: failed to load documents', error));

    const intervalId = window.setInterval(() => {
      refreshDocuments({ silent: true }).catch((error) => console.error('DocumentsView: background refresh failed', error));
    }, 10000);

    const handleVisibilityRefresh = () => {
      if (document.visibilityState === 'visible') {
        refreshDocuments({ silent: true }).catch((error) => console.error('DocumentsView: visibility refresh failed', error));
      }
    };

    window.addEventListener('focus', handleVisibilityRefresh);
    document.addEventListener('visibilitychange', handleVisibilityRefresh);

    return () => {
      window.clearInterval(intervalId);
      window.removeEventListener('focus', handleVisibilityRefresh);
      document.removeEventListener('visibilitychange', handleVisibilityRefresh);
    };
  }, [initialIsReady, refreshDocuments]);

  useEffect(() => {
    if (initialDocuments.length === 0 && !initialIsReady) {
      return;
    }

    setDocs(initialDocuments);
    setLastSyncedAt(initialPreparedAt);
    setDocumentObjectUrls((current) => {
      Object.values(current).forEach((objectUrl) => revokeObjectUrl(objectUrl));
      return buildCachedObjectUrls(initialDocuments);
    });
    setIsGalleryReady(initialIsReady);
  }, [initialDocuments, initialIsReady, initialPreparedAt, revokeObjectUrl]);

  useEffect(() => {
    if (!selectedDoc) return;
    setEditingTitle(selectedDoc.title);
    setEditingTag(selectedDoc.tags[0] || 'Autre');
  }, [selectedDoc]);

  useEffect(() => {
    if (!selectedDoc) return;
    if (selectedDoc.type !== 'image' && selectedDoc.type !== 'pdf' && selectedDoc.type !== 'doc') return;

    setPreviewLoadingId(selectedDoc.id);
    ensureDocumentObjectUrl(selectedDoc)
      .catch((error) => console.error('DocumentsView: failed to load selected document preview', error))
      .finally(() => setPreviewLoadingId((current) => current === selectedDoc.id ? null : current));
  }, [ensureDocumentObjectUrl, selectedDoc]);

  useEffect(() => () => {
    Object.values(objectUrlsRef.current).forEach((url) => revokeObjectUrl(url));
  }, [revokeObjectUrl]);

  const resetInputs = () => {
    if (fileInputRef.current) fileInputRef.current.value = '';
    if (cameraInputRef.current) cameraInputRef.current.value = '';
    if (scannerInputRef.current) scannerInputRef.current.value = '';
    if (importInputRef.current) importInputRef.current.value = '';
  };

  const handleFileSelect = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) {
      setPendingFile(file);
      setUploadName(file.name.split('.').slice(0, -1).join('.') || file.name);
      setUploadTag('Autre');
      setUploadModalOpen(true);
      setShowAddMenu(false);
    }
    event.target.value = '';
  };

  const handleConfirmUpload = async () => {
    if (!pendingFile || !uploadName.trim()) return;

    const uploadedFile = pendingFile;
    setIsUploading(true);
    const patientName = `${dossier.patient.lastName} ${dossier.patient.firstName}`;
    const { success, error, document } = await uploadDocument(
      dossier.patient.id,
      uploadedFile,
      patientName,
      uploadName.trim(),
      [uploadTag],
      dossier.id,
    );

    if (!success) {
      console.error('Upload failed:', error);
      alert(`Erreur lors de l'upload: ${error || 'Erreur inconnue'}.`);
      setIsUploading(false);
      return;
    }

    setUploadModalOpen(false);
    setPendingFile(null);
    resetInputs();
    setIsUploading(false);

    if (document) {
      setDocumentObjectUrl(document.id, window.URL.createObjectURL(uploadedFile));
      setDocs((current) => {
        const remaining = current.filter((entry) => entry.id !== document.id);
        return [document, ...remaining];
      });
      setLastSyncedAt(new Date().toISOString());
      setIsGalleryReady(true);
    }

    setLastSyncedAt(document.lastSyncedAt || null);
  };

  const handleDelete = (doc: AppDocument, event: React.MouseEvent) => {
    event.stopPropagation();
    setDocToDelete(doc);
  };

  const confirmDelete = async () => {
    if (!docToDelete) return;

    const deletedDocId = docToDelete.id;
    setDocs((current) => current.filter((doc) => doc.id !== deletedDocId));
    setSelectedDoc((current) => current?.id === deletedDocId ? null : current);
    setDocToDelete(null);

    const { success, error } = await deleteDocument(deletedDocId);
    if (!success) {
      alert(`Erreur lors de la suppression: ${error || 'Erreur inconnue'}`);
    }
  };

  const handleSaveMetadata = async () => {
    if (!selectedDoc || !editingTitle.trim()) return;

    setIsSavingMetadata(true);
    const { success, error, document } = await updateDocument(selectedDoc.id, {
      title: editingTitle.trim(),
      tags: [editingTag],
    });
    setIsSavingMetadata(false);

    if (!success) {
      alert(`Erreur lors de la mise a jour: ${error || 'Erreur inconnue'}`);
      return;
    }

    if (document) {
      setDocs((current) => current.map((doc) => doc.id === document.id ? document : doc));
      setSelectedDoc(document);
      setLastSyncedAt(document.lastSyncedAt || null);
    }
  };

  const filteredDocs = docs.filter((doc) => {
    const matchesTag = selectedTag ? doc.tags.includes(selectedTag) : true;
    return matchesTag;
  });

  const documentsStatus = useMemo(() => {
    const hasPending = docs.some((doc) => doc.syncStatus && doc.syncStatus !== 'synced');
    const latest = docs
      .map((doc) => doc.lastSyncedAt || null)
      .filter(Boolean)
      .sort((left, right) => new Date(right as string).getTime() - new Date(left as string).getTime())[0] || lastSyncedAt;

    return {
      hasPending,
      latest,
    };
  }, [docs, lastSyncedAt]);

  const handleOpenDocument = useCallback(async (document: AppDocument) => {
    try {
      const objectUrl = await ensureDocumentObjectUrl(document);
      window.open(objectUrl, '_blank', 'noopener,noreferrer');
    } catch (error) {
      console.error('DocumentsView: failed to open document', error);
      alert('Ouverture du document impossible.');
    }
  }, [ensureDocumentObjectUrl]);

  const selectedDocObjectUrl = selectedDoc ? documentObjectUrls[selectedDoc.id] || '' : '';

  return (
    <div className="h-full flex flex-col relative">
      <div className="flex flex-col gap-4 mb-6 lg:flex-row lg:items-start lg:justify-between">
        <div className="flex flex-col gap-2">
          <div className="flex items-center gap-4">
            <button onClick={onBack} className="w-10 h-10 border border-black rounded-full flex items-center justify-center hover:bg-black hover:text-white transition-colors">
              <ArrowLeft size={20} />
            </button>
            <div>
              <h2 className="text-2xl font-bold uppercase">{dossier.patient.lastName} {dossier.patient.firstName}</h2>
              <p className="text-slate-600 font-medium">Documents du dossier</p>
            </div>
          </div>
          <div className="ml-14 flex flex-wrap items-center gap-2 text-xs font-medium">
            <span className={`px-3 py-1 rounded-full ${documentsStatus.hasPending ? 'bg-amber-100 text-amber-700' : 'bg-emerald-100 text-emerald-700'}`}>
              {documentsStatus.hasPending ? 'Non synchronisé' : 'Synchronisé'}
            </span>
            {documentsStatus.latest && (
              <span className="text-slate-500">
                {documentsStatus.hasPending ? 'Dernière synchro' : 'Synchronisé le'} {new Date(documentsStatus.latest).toLocaleString('fr-FR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}
              </span>
            )}
          </div>
        </div>
      </div>

      <div className="flex gap-2 mb-6 overflow-x-auto pb-2 no-scrollbar">
        <button
          onClick={() => setSelectedTag(null)}
          className={`px-4 py-2 rounded-full text-sm font-medium transition-colors whitespace-nowrap ${!selectedTag ? 'bg-[#907CA1] text-white' : 'bg-white text-slate-600 border border-slate-200'}`}
        >
          Tous
        </button>
        {AVAILABLE_TAGS.map((tag) => (
          <button
            key={tag}
            onClick={() => setSelectedTag(tag === selectedTag ? null : tag)}
            className={`px-4 py-2 rounded-full text-sm font-medium transition-colors whitespace-nowrap ${tag === selectedTag ? 'bg-[#907CA1] text-white' : 'bg-white text-slate-600 border border-slate-200'}`}
          >
            {tag}
          </button>
        ))}
      </div>

      <div className="flex-1 overflow-y-auto pb-48 pr-2">
        {!isGalleryReady ? (
          <div className="h-full min-h-[320px]">
            <SimpleLoader label="Chargement des documents" />
          </div>
        ) : (
        <div className="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-6 content-start">
          <div className="relative">
            <button
              onClick={() => setShowAddMenu((current) => !current)}
              className="w-full aspect-[3/4] border-2 border-dashed border-[#907CA1] rounded-2xl flex flex-col items-center justify-center cursor-pointer hover:bg-white/50 transition-colors group bg-white"
            >
              <Plus size={48} strokeWidth={1.5} className="text-[#907CA1] group-hover:scale-110 transition-transform" />
            </button>

            {showAddMenu && (
              <div className="absolute top-full left-0 mt-2 w-64 bg-white rounded-xl shadow-[0_10px_40px_rgba(0,0,0,0.2)] border border-slate-100 z-50 overflow-hidden py-2 animate-in fade-in zoom-in-95 duration-200">
                <MenuItem icon={ImageIcon} label="Image" onClick={() => fileInputRef.current?.click()} />
                <MenuItem icon={Camera} label="Prendre une photo" onClick={() => cameraInputRef.current?.click()} />
                <MenuItem icon={ScanLine} label="Scanner des documents" onClick={() => scannerInputRef.current?.click()} />
                <MenuItem icon={Upload} label="Importer" onClick={() => importInputRef.current?.click()} />
              </div>
            )}

            <input type="file" ref={fileInputRef} className="hidden" accept="image/*" onChange={handleFileSelect} />
            <input type="file" ref={cameraInputRef} className="hidden" accept="image/*" capture="environment" onChange={handleFileSelect} />
            <input type="file" ref={scannerInputRef} className="hidden" accept="application/pdf,image/*" onChange={handleFileSelect} />
            <input type="file" ref={importInputRef} className="hidden" accept="*" onChange={handleFileSelect} />
          </div>

          {filteredDocs.map((doc) => (
            <div
              key={doc.id}
              onClick={() => setSelectedDoc(doc)}
              onTouchEnd={() => setSelectedDoc(doc)}
              className="flex flex-col items-center gap-2 group cursor-pointer relative text-left"
            >
              <div className="w-full aspect-[3/4] bg-white rounded-2xl border border-slate-200 flex items-center justify-center shadow-sm overflow-hidden relative hover:shadow-md transition-shadow">
                <button
                  onClick={(event) => handleDelete(doc, event)}
                  className="absolute top-2 right-2 p-1 bg-red-500 text-white rounded-full opacity-0 group-hover:opacity-100 transition-opacity z-10"
                >
                  <X size={12} />
                </button>

                {doc.tags.length > 0 && (
                  <div className="absolute top-2 left-2 px-2 py-1 bg-black/50 backdrop-blur-sm rounded-md text-[10px] text-white font-bold z-10">
                    {doc.tags[0]}
                  </div>
                )}

                {doc.type === 'image' && documentObjectUrls[doc.id] ? (
                  <img src={documentObjectUrls[doc.id]} alt={doc.title} className="w-full h-full object-cover pointer-events-none" />
                ) : doc.type === 'pdf' && documentObjectUrls[doc.id] ? (
                  <iframe
                    src={`${documentObjectUrls[doc.id]}#toolbar=0&navpanes=0&scrollbar=0&view=FitH`}
                    title={doc.title}
                    className="w-full h-full pointer-events-none bg-white"
                  />
                ) : (
                  <div className="text-slate-400">
                    {doc.type === 'pdf' ? <FileText size={32} /> : <File size={32} />}
                  </div>
                )}
              </div>
              <span className="font-medium text-black text-sm text-center truncate w-full px-2">{doc.title}</span>
              <span className="text-[10px] text-slate-400">
                {new Date(doc.updatedAt || doc.createdAt).toLocaleDateString('fr-FR')} {new Date(doc.updatedAt || doc.createdAt).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}
              </span>
            </div>
          ))}
        </div>
        )}
      </div>

      {uploadModalOpen && (
        <ViewportOverlay
          className="fixed inset-0 bg-black/50 z-[80] flex items-center justify-center p-4 backdrop-blur-sm animate-in fade-in duration-200"
          onClick={() => {
            setUploadModalOpen(false);
            setPendingFile(null);
            resetInputs();
          }}
        >
          <div
            className="bg-white rounded-2xl p-6 max-w-sm w-full shadow-xl"
            onClick={(event) => event.stopPropagation()}
          >
            <h3 className="text-lg font-bold mb-4">Valider le document</h3>

            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-slate-700 mb-1">Nom du fichier</label>
                <input
                  type="text"
                  value={uploadName}
                  onChange={(event) => setUploadName(event.target.value)}
                  className="w-full px-3 py-2 rounded-lg border border-slate-300 bg-white text-black focus:ring-2 focus:ring-[#907CA1] outline-none"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-slate-700 mb-1">Tag</label>
                <div className="flex flex-wrap gap-2">
                  {AVAILABLE_TAGS.map((tag) => (
                    <button
                      key={tag}
                      onClick={() => setUploadTag(tag)}
                      className={`px-3 py-1 rounded-full text-xs font-bold border transition-colors ${uploadTag === tag ? 'bg-[#907CA1] text-white border-[#907CA1]' : 'bg-transparent text-slate-600 border-slate-300 hover:border-[#907CA1]'}`}
                    >
                      {tag}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            <div className="flex justify-end gap-3 mt-6">
              <button
                onClick={() => {
                  setUploadModalOpen(false);
                  setPendingFile(null);
                  resetInputs();
                }}
                className="px-4 py-2 rounded-lg text-slate-600 hover:bg-slate-100 transition-colors font-medium"
              >
                Annuler
              </button>
              <button
                onClick={handleConfirmUpload}
                disabled={!uploadName.trim() || !uploadTag || isUploading}
                className="px-4 py-2 rounded-lg bg-[#907CA1] text-white hover:bg-[#7a668a] transition-colors font-medium disabled:opacity-50 flex items-center gap-2"
              >
                {uploadLoadingState.visible ? (
                  <LoadingProgress
                    label="Envoi"
                    variant="button"
                    className="text-white"
                    complete={uploadLoadingState.complete}
                    onComplete={uploadLoadingState.handleComplete}
                  />
                ) : 'Valider'}
              </button>
            </div>
          </div>
        </ViewportOverlay>
      )}

      {docToDelete && (
        <ViewportOverlay
          className="fixed inset-0 bg-black/50 z-[80] flex items-center justify-center p-4 backdrop-blur-sm animate-in fade-in duration-200"
          onClick={() => setDocToDelete(null)}
        >
          <div
            className="bg-white rounded-2xl p-6 max-w-sm w-full shadow-xl transform transition-all scale-100"
            onClick={(event) => event.stopPropagation()}
          >
            <h3 className="text-lg font-bold mb-2">Confirmer la suppression</h3>
            <p className="text-slate-600 mb-6">
              Etes-vous sur de vouloir supprimer ce document ? Cette action est irreversible.
            </p>
            <div className="flex justify-end gap-3">
              <button
                onClick={() => setDocToDelete(null)}
                className="px-4 py-2 rounded-lg text-slate-600 hover:bg-slate-100 transition-colors font-medium"
              >
                Annuler
              </button>
              <button
                onClick={confirmDelete}
                className="px-4 py-2 rounded-lg bg-red-500 text-white hover:bg-red-600 transition-colors font-medium"
              >
                Supprimer
              </button>
            </div>
          </div>
        </ViewportOverlay>
      )}

      {selectedDoc && (
        <ViewportOverlay
          className="fixed inset-0 bg-black/50 z-[80] flex items-center justify-center p-8 backdrop-blur-sm"
          onClick={() => setSelectedDoc(null)}
        >
          <div
            className="bg-white rounded-3xl w-full max-w-5xl h-[85vh] flex flex-col shadow-2xl overflow-hidden animate-fade-in"
            onClick={(event) => event.stopPropagation()}
          >
            <div className="p-4 border-b border-slate-100 flex flex-col gap-4 bg-slate-50 lg:flex-row lg:items-center lg:justify-between">
              <div className="flex items-center gap-3 flex-1">
                <input
                  value={editingTitle}
                  onChange={(event) => setEditingTitle(event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') {
                      void handleSaveMetadata();
                    }
                  }}
                  className="text-xl font-bold bg-transparent outline-none border-b border-transparent focus:border-black transition-colors w-full"
                />
              </div>
              <div className="flex items-center gap-2 flex-wrap">
                {AVAILABLE_TAGS.map((tag) => (
                  <button
                    key={tag}
                    onClick={() => setEditingTag(tag)}
                    className={`px-3 py-1 rounded-full text-xs font-bold border transition-colors ${editingTag === tag ? 'bg-[#907CA1] text-white border-[#907CA1]' : 'bg-white text-slate-600 border-slate-300'}`}
                  >
                    {tag}
                  </button>
                ))}
                <button
                  onClick={() => void handleOpenDocument(selectedDoc)}
                  className="px-3 py-2 rounded-lg border border-slate-300 text-sm font-medium text-slate-700 hover:bg-white"
                >
                  Ouvrir
                </button>
                <button
                  onClick={() => void handleSaveMetadata()}
                  disabled={isSavingMetadata || !editingTitle.trim()}
                  className="px-3 py-2 rounded-lg bg-[#907CA1] text-white hover:bg-[#7a668a] transition-colors font-medium disabled:opacity-50 flex items-center gap-2"
                >
                  {isSavingMetadata ? (
                    <SimpleLoader
                      label="Enregistrement"
                      variant="button"
                      className="text-white"
                    />
                  ) : <><Check size={16} /> Enregistrer</>}
                </button>
                <button onClick={() => setSelectedDoc(null)} className="p-2 hover:bg-slate-200 rounded-full transition-colors">
                  <X size={24} />
                </button>
              </div>
            </div>
            <div className="flex-1 bg-slate-100 p-6 flex items-center justify-center overflow-auto">
              {previewLoadingId === selectedDoc.id && !selectedDocObjectUrl && (
                <div className="w-full max-w-md">
                  <SimpleLoader label="Chargement du document" />
                </div>
              )}
              {selectedDoc.type === 'image' && selectedDocObjectUrl && (
                <img src={selectedDocObjectUrl} alt={selectedDoc.title} className="max-w-full max-h-full object-contain shadow-lg rounded-xl" />
              )}
              {selectedDoc.type === 'pdf' && selectedDocObjectUrl && (
                <iframe src={selectedDocObjectUrl} title={selectedDoc.title} className="w-full h-full bg-white rounded-xl shadow-lg" />
              )}
              {selectedDoc.type === 'doc' && (
                <div className="w-full h-full bg-white shadow-lg rounded-xl flex flex-col items-center justify-center gap-4 p-8 text-center">
                  <File size={48} className="text-slate-400" />
                  <p className="text-slate-600">Previsualisation non disponible pour ce format.</p>
                  <button
                    onClick={() => void handleOpenDocument(selectedDoc)}
                    className="px-4 py-2 rounded-lg bg-[#907CA1] text-white hover:bg-[#7a668a] transition-colors font-medium"
                  >
                    Ouvrir le document
                  </button>
                </div>
              )}
            </div>
          </div>
        </ViewportOverlay>
      )}
    </div>
  );
};

const MenuItem: React.FC<{ icon: React.ComponentType<any>; label: string; onClick: () => void }> = ({ icon: Icon, label, onClick }) => (
  <button onClick={onClick} className="w-full flex items-center gap-3 px-4 py-3 hover:bg-slate-50 text-left transition-colors">
    <Icon size={20} className="text-slate-600" />
    <span className="text-sm font-medium text-slate-800">{label}</span>
  </button>
);
