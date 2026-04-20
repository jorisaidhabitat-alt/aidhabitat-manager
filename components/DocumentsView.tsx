import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowLeft, Camera, Check, CheckSquare, Download, File, FileText, Image as ImageIcon, Loader2, Plus, Save, ScanLine, Square, Upload, X } from 'lucide-react';

import { deleteDocument, fetchDocumentBlob, fetchDocuments, getCachedDocumentBlob, updateDocument, uploadDocument } from '../services/dataService';
import { AppDocument, Dossier } from '../types';
import { LoadingProgress, SimpleLoader, useSmoothLoadingState } from './LoadingProgress';
import { ViewportOverlay } from './ViewportOverlay';
import { uiActionCardClass, uiDangerButtonClass, uiFieldClass, uiIconButtonClass, uiModalClass, uiPrimaryButtonClass, uiSecondaryButtonClass } from './uiTheme';

interface DocumentsViewProps {
  dossier: Dossier;
  onBack: () => void;
  initialDocuments?: AppDocument[];
  initialPreparedAt?: string | null;
  initialIsReady?: boolean;
}


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
  const [docToDelete, setDocToDelete] = useState<AppDocument | null>(null);
  const [uploadModalOpen, setUploadModalOpen] = useState(false);
  const [pendingFile, setPendingFile] = useState<File | null>(null);
  const [uploadName, setUploadName] = useState('');
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [lastSyncedAt, setLastSyncedAt] = useState<string | null>(initialPreparedAt);
  const [documentObjectUrls, setDocumentObjectUrls] = useState<Record<string, string>>(() => buildCachedObjectUrls(initialDocuments));
  const [previewLoadingId, setPreviewLoadingId] = useState<string | null>(null);
  const [isGalleryReady, setIsGalleryReady] = useState(initialIsReady);
  const uploadLoadingState = useSmoothLoadingState(isUploading, { minVisibleMs: 520 });
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [isSelectionMode, setIsSelectionMode] = useState(false);
  const [inlineEditingId, setInlineEditingId] = useState<string | null>(null);
  const [inlineTitle, setInlineTitle] = useState('');
  const [unsavedPromptOpen, setUnsavedPromptOpen] = useState(false);
  const [isBulkDownloading, setIsBulkDownloading] = useState(false);
  const longPressTimerRef = useRef<number | null>(null);
  const longPressTriggeredRef = useRef(false);

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

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      const isTyping = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable);

      // Ctrl/Cmd + A : tout sélectionner
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a' && !isTyping) {
        event.preventDefault();
        setIsSelectionMode(true);
        setSelectedIds(new Set(docs.map((d) => d.id)));
        return;
      }
      // Escape : quitter la sélection
      if (event.key === 'Escape' && isSelectionMode && !isTyping) {
        setIsSelectionMode(false);
        setSelectedIds(new Set());
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [docs, isSelectionMode]);

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
      ['Autre'],
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

  const filteredDocs = docs;

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

  const handleDownloadDocument = useCallback(async (doc: AppDocument, event?: React.MouseEvent) => {
    if (event) event.stopPropagation();
    try {
      const blob = await fetchDocumentBlob(doc);
      const objectUrl = window.URL.createObjectURL(blob);
      const link = window.document.createElement('a');
      link.href = objectUrl;
      link.download = doc.fileName || doc.title || 'document';
      window.document.body.appendChild(link);
      link.click();
      window.document.body.removeChild(link);
      window.setTimeout(() => window.URL.revokeObjectURL(objectUrl), 500);
    } catch (error) {
      console.error('DocumentsView: failed to download document', error);
      alert('Téléchargement impossible.');
    }
  }, []);

  const handleDragStart = useCallback(async (doc: AppDocument, event: React.DragEvent) => {
    try {
      const extensionFromName = (doc.fileName || '').split('.').pop();
      const fileExt = extensionFromName
        || (doc.type === 'image' ? 'jpg' : doc.type === 'pdf' ? 'pdf' : 'bin');
      const baseName = (doc.fileName && doc.fileName.includes('.'))
        ? doc.fileName
        : `${(doc.title || 'document').replace(/[\\/:*?"<>|]/g, '_')}.${fileExt}`;
      const mime = doc.mimeType || (doc.type === 'image' ? 'image/jpeg' : doc.type === 'pdf' ? 'application/pdf' : 'application/octet-stream');

      // Préfère l'URL publique du serveur (persistante, réutilisable dans un navigateur)
      // et bascule vers une object URL en dernier recours.
      let shareableUrl = '';
      const rawUrl = (doc.url || '').trim();
      if (rawUrl) {
        shareableUrl = rawUrl.startsWith('http')
          ? rawUrl
          : `${window.location.origin}${rawUrl.startsWith('/') ? '' : '/'}${rawUrl}`;
      } else {
        shareableUrl = documentObjectUrls[doc.id] || await ensureDocumentObjectUrl(doc);
      }

      event.dataTransfer.effectAllowed = 'copy';
      // Chrome/Edge : DownloadURL permet le glisser vers le bureau / Finder
      event.dataTransfer.setData('DownloadURL', `${mime}:${baseName}:${shareableUrl}`);
      event.dataTransfer.setData('text/uri-list', shareableUrl);
      event.dataTransfer.setData('text/plain', shareableUrl);
    } catch (error) {
      console.error('DocumentsView: drag start failed', error);
    }
  }, [documentObjectUrls, ensureDocumentObjectUrl]);

  const handleBulkDownload = useCallback(async () => {
    if (selectedIds.size === 0) return;
    setIsBulkDownloading(true);
    try {
      for (const doc of docs) {
        if (!selectedIds.has(doc.id)) continue;
        await handleDownloadDocument(doc);
        // tiny delay so the browser doesn't drop successive downloads
        await new Promise((resolve) => setTimeout(resolve, 200));
      }
    } finally {
      setIsBulkDownloading(false);
    }
  }, [docs, handleDownloadDocument, selectedIds]);

  const toggleSelection = useCallback((docId: string, event?: React.MouseEvent) => {
    if (event) event.stopPropagation();
    setSelectedIds((current) => {
      const next = new Set(current);
      if (next.has(docId)) next.delete(docId);
      else next.add(docId);
      return next;
    });
  }, []);

  const toggleSelectAll = useCallback(() => {
    setSelectedIds((current) => {
      if (current.size === docs.length) return new Set();
      return new Set(docs.map((d) => d.id));
    });
  }, [docs]);

  const exitSelectionMode = useCallback(() => {
    setIsSelectionMode(false);
    setSelectedIds(new Set());
  }, []);

  const cancelLongPress = useCallback(() => {
    if (longPressTimerRef.current !== null) {
      window.clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = null;
    }
  }, []);

  const startLongPress = useCallback((docId: string) => {
    cancelLongPress();
    longPressTriggeredRef.current = false;
    longPressTimerRef.current = window.setTimeout(() => {
      longPressTriggeredRef.current = true;
      setIsSelectionMode(true);
      setSelectedIds((current) => {
        const next = new Set(current);
        next.add(docId);
        return next;
      });
      // Retour haptique sur mobile quand dispo
      if (typeof window !== 'undefined' && 'navigator' in window && 'vibrate' in window.navigator) {
        try { window.navigator.vibrate(20); } catch { /* no-op */ }
      }
    }, 500);
  }, [cancelLongPress]);

  useEffect(() => () => cancelLongPress(), [cancelLongPress]);

  const handleInlineRename = useCallback(async (docId: string) => {
    const title = inlineTitle.trim();
    setInlineEditingId(null);
    if (!title) return;
    const current = docs.find((d) => d.id === docId);
    if (!current || current.title === title) return;
    const { success, document: updated } = await updateDocument(docId, { title });
    if (success && updated) {
      setDocs((prev) => prev.map((d) => d.id === updated.id ? updated : d));
    }
  }, [docs, inlineTitle]);

  const hasUnsavedChanges = Boolean(selectedDoc && editingTitle.trim() !== selectedDoc.title);

  const handleCloseModal = useCallback(() => {
    if (hasUnsavedChanges) {
      setUnsavedPromptOpen(true);
      return;
    }
    setSelectedDoc(null);
  }, [hasUnsavedChanges]);

  const selectedDocObjectUrl = selectedDoc ? documentObjectUrls[selectedDoc.id] || '' : '';

  return (
    <div className="h-full flex flex-col relative">
      <div className="flex flex-col gap-4 mb-6 lg:flex-row lg:items-start lg:justify-between">
        <div className="flex flex-col gap-2">
          <div className="flex items-center gap-4">
            <button onClick={onBack} className={`${uiIconButtonClass} h-10 w-10 border-slate-300`}>
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

        <div className="flex items-center gap-2 flex-wrap">
          {isSelectionMode ? (
            <>
              <span className="text-sm font-semibold text-slate-700 mr-2">{selectedIds.size} sélectionné{selectedIds.size > 1 ? 's' : ''}</span>
              <button
                onClick={toggleSelectAll}
                className={uiSecondaryButtonClass}
                title={selectedIds.size === docs.length ? 'Tout désélectionner' : 'Tout sélectionner'}
              >
                {selectedIds.size === docs.length ? 'Tout désélectionner' : 'Tout sélectionner'}
              </button>
              <button
                onClick={() => void handleBulkDownload()}
                disabled={selectedIds.size === 0 || isBulkDownloading}
                className={`${uiPrimaryButtonClass} disabled:opacity-50`}
                title="Télécharger la sélection"
              >
                {isBulkDownloading ? <Loader2 size={16} className="animate-spin" /> : <Download size={16} />}
                <span>Télécharger</span>
              </button>
              <button onClick={exitSelectionMode} className={uiSecondaryButtonClass} title="Quitter le mode sélection">
                <X size={16} />
              </button>
            </>
          ) : (
            <button
              onClick={() => setIsSelectionMode(true)}
              className={uiSecondaryButtonClass}
              title="Sélection multiple"
            >
              <CheckSquare size={16} />
              <span>Sélectionner</span>
            </button>
          )}
        </div>
      </div>


      <div className="flex-1 overflow-y-auto pb-48 pr-2">
        {!isGalleryReady ? (
          <div className="h-full min-h-[320px]">
            <SimpleLoader label="Chargement des documents" />
          </div>
        ) : (
        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-6 content-start">
          <div className="relative">
            <button
              onClick={() => setShowAddMenu((current) => !current)}
              className={`${uiActionCardClass} flex aspect-[3/4] w-full items-center justify-center border-2 border-dashed border-[#907CA1] bg-white group`}
            >
              <Plus size={48} strokeWidth={1.5} className="text-[#907CA1] group-hover:scale-110 transition-transform" />
            </button>

            {showAddMenu && (
              <div className="absolute top-full left-0 z-50 mt-2 w-64 overflow-hidden rounded-[24px] border border-slate-200 bg-white py-2 shadow-[0_10px_40px_rgba(0,0,0,0.2)] animate-in fade-in zoom-in-95 duration-200">
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

          {filteredDocs.map((doc) => {
            const isSelected = selectedIds.has(doc.id);
            const isEditingThis = inlineEditingId === doc.id;
            return (
            <div
              key={doc.id}
              onClick={() => {
                if (longPressTriggeredRef.current) {
                  longPressTriggeredRef.current = false;
                  return;
                }
                if (isSelectionMode) {
                  toggleSelection(doc.id);
                } else {
                  setSelectedDoc(doc);
                }
              }}
              onPointerDown={(e) => {
                // Ne démarre pas le long press si on clique sur un bouton ou l'input
                const target = e.target as HTMLElement;
                if (target.closest('button, input')) return;
                startLongPress(doc.id);
              }}
              onPointerUp={cancelLongPress}
              onPointerLeave={cancelLongPress}
              onPointerMove={(e) => {
                // Annule si mouvement significatif (drag d'image par ex.)
                if (Math.abs(e.movementX) > 4 || Math.abs(e.movementY) > 4) cancelLongPress();
              }}
              onContextMenu={(e) => {
                // Empêche le menu contextuel natif lors d'un long press sur mobile
                if (longPressTriggeredRef.current) e.preventDefault();
              }}
              className="flex flex-col items-center gap-2 group cursor-pointer relative text-left select-none"
            >
              <div className={`${uiActionCardClass} flex aspect-[3/4] w-full items-center justify-center overflow-hidden relative`}>
                {isSelected && (
                  <div className="absolute inset-0 bg-[#907CA1]/40 z-[5] pointer-events-none" />
                )}
                {isSelectionMode && (
                  <button
                    onClick={(event) => toggleSelection(doc.id, event)}
                    className="absolute top-2 left-2 p-1 bg-white border border-slate-300 rounded-md z-10 shadow-sm"
                    title={isSelected ? 'Désélectionner' : 'Sélectionner'}
                  >
                    {isSelected ? <CheckSquare size={14} className="text-[#907CA1]" /> : <Square size={14} className="text-slate-400" />}
                  </button>
                )}
                <button
                  onClick={(event) => { void handleDownloadDocument(doc, event); }}
                  className="absolute top-2 right-12 p-2 bg-[#907CA1] hover:bg-[#7a668a] text-white rounded-full opacity-0 group-hover:opacity-100 transition-opacity z-10 shadow-md"
                  title="Télécharger"
                >
                  <Download size={18} />
                </button>
                <button
                  onClick={(event) => handleDelete(doc, event)}
                  className="absolute top-2 right-2 p-2 bg-red-500 hover:bg-red-600 text-white rounded-full opacity-0 group-hover:opacity-100 transition-opacity z-10 shadow-md"
                  title="Supprimer"
                >
                  <X size={18} />
                </button>

                {doc.type === 'image' && documentObjectUrls[doc.id] ? (
                  <img
                    src={documentObjectUrls[doc.id]}
                    alt={doc.title}
                    draggable={!isSelectionMode}
                    onDragStart={(e) => { void handleDragStart(doc, e); }}
                    className="w-full h-full object-cover cursor-grab active:cursor-grabbing"
                  />
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
              <input
                value={isEditingThis ? inlineTitle : doc.title}
                readOnly={!isEditingThis}
                onFocus={(e) => {
                  e.stopPropagation();
                  setInlineEditingId(doc.id);
                  setInlineTitle(doc.title);
                }}
                onChange={(e) => setInlineTitle(e.target.value)}
                onClick={(e) => e.stopPropagation()}
                onBlur={() => { if (isEditingThis) void handleInlineRename(doc.id); }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') { e.currentTarget.blur(); }
                  if (e.key === 'Escape') { setInlineEditingId(null); e.currentTarget.blur(); }
                }}
                className={`font-medium text-black text-sm text-center w-full px-2 py-0.5 rounded-md outline-none cursor-text transition-colors ${isEditingThis ? 'border border-[#907CA1] bg-white' : 'border border-transparent hover:border-slate-200 bg-transparent truncate'}`}
              />
              <span className="text-[10px] text-slate-400">
                {new Date(doc.updatedAt || doc.createdAt).toLocaleDateString('fr-FR')} {new Date(doc.updatedAt || doc.createdAt).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}
              </span>
            </div>
            );
          })}
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
            className={`${uiModalClass} w-full max-w-sm p-6`}
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
                  className={uiFieldClass}
                />
              </div>

            </div>

            <div className="flex justify-end gap-3 mt-6">
              <button
                onClick={() => {
                  setUploadModalOpen(false);
                  setPendingFile(null);
                  resetInputs();
                }}
                className={uiSecondaryButtonClass}
              >
                Annuler
              </button>
              <button
                onClick={handleConfirmUpload}
                disabled={!uploadName.trim() || isUploading}
                className={`${uiPrimaryButtonClass} disabled:opacity-50`}
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
            className={`${uiModalClass} w-full max-w-sm p-6`}
            onClick={(event) => event.stopPropagation()}
          >
            <h3 className="text-lg font-bold mb-2">Confirmer la suppression</h3>
            <p className="text-slate-600 mb-6">
              Etes-vous sur de vouloir supprimer ce document ? Cette action est irreversible.
            </p>
            <div className="flex justify-end gap-3">
              <button
                onClick={() => setDocToDelete(null)}
                className={uiSecondaryButtonClass}
              >
                Annuler
              </button>
              <button
                onClick={confirmDelete}
                className={uiDangerButtonClass}
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
          onClick={handleCloseModal}
        >
          <div
            className={`${uiModalClass} animate-fade-in flex h-[85vh] w-full max-w-5xl flex-col overflow-hidden`}
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
                {hasUnsavedChanges && (
                  <span className="text-xs font-semibold text-amber-600 whitespace-nowrap">• Modifié</span>
                )}
              </div>
              <div className="flex items-center gap-2 flex-wrap">
                <button
                  onClick={() => void handleDownloadDocument(selectedDoc)}
                  className="p-2 bg-slate-100 hover:bg-slate-200 text-slate-700 rounded-full transition-colors"
                  title="Télécharger"
                >
                  <Download size={20} />
                </button>
                <button
                  onClick={() => void handleSaveMetadata()}
                  disabled={isSavingMetadata || !editingTitle.trim() || !hasUnsavedChanges}
                  className="p-2 bg-[#907CA1] hover:bg-[#7a668a] text-white rounded-full transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
                  title="Enregistrer"
                >
                  {isSavingMetadata ? <Loader2 size={20} className="animate-spin" /> : <Save size={20} />}
                </button>
                <button onClick={handleCloseModal} className="p-2 hover:bg-slate-200 rounded-full transition-colors" title="Fermer">
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
                    className={uiPrimaryButtonClass}
                  >
                    Ouvrir le document
                  </button>
                </div>
              )}
            </div>
          </div>
        </ViewportOverlay>
      )}

      {unsavedPromptOpen && selectedDoc && (
        <ViewportOverlay
          className="fixed inset-0 bg-black/60 z-[90] flex items-center justify-center p-4 backdrop-blur-sm"
          onClick={() => setUnsavedPromptOpen(false)}
        >
          <div
            className={`${uiModalClass} w-full max-w-sm p-6`}
            onClick={(event) => event.stopPropagation()}
          >
            <h3 className="text-lg font-bold mb-2">Modifications non enregistrées</h3>
            <p className="text-slate-600 mb-6">
              Souhaitez-vous enregistrer les modifications avant de fermer ?
            </p>
            <div className="flex flex-col gap-2">
              <button
                onClick={async () => {
                  await handleSaveMetadata();
                  setUnsavedPromptOpen(false);
                  setSelectedDoc(null);
                }}
                className={uiPrimaryButtonClass}
              >
                <Save size={16} />
                <span>Enregistrer et fermer</span>
              </button>
              <button
                onClick={() => {
                  setUnsavedPromptOpen(false);
                  setSelectedDoc(null);
                }}
                className={uiSecondaryButtonClass}
              >
                Fermer sans enregistrer
              </button>
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
