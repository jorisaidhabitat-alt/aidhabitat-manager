import React, { Suspense, lazy, useCallback, useEffect, useState } from 'react';
import { Sidebar } from './components/Sidebar';
import { AnahStatus, AppDocument, AppUser, Dossier, Visit, VisitReportLocation } from './types';
import { Building, ExternalLink, Globe, WifiOff } from 'lucide-react';
import { fetchAnahStatus, fetchCurrentAppUser, fetchDossiers, fetchLocalSnapshot, generateVisitsFromDossiers, logoutApp, preloadDocumentsView } from './services/dataService';
import { LoginView } from './components/LoginView';
import { SimpleLoader } from './components/LoadingProgress';
import { VisitReportView } from './components/VisitReportView';
import { flushPendingReleves, registerPendingRelevesSync } from './services/releveSync';

const loadDashboardView = () => import('./components/Dashboard');
const loadDossierView = () => import('./components/DossierView');
const loadAdminPanel = () => import('./components/AdminPanel');
const loadDocumentsView = () => import('./components/DocumentsView');
const loadSettingsView = () => import('./components/SettingsView');
const loadWikiView = () => import('./components/WikiView');
const loadRetirementFundsView = () => import('./components/RetirementFundsView');

const Dashboard = lazy(() => loadDashboardView().then((module) => ({ default: module.Dashboard })));
const DossierView = lazy(() => loadDossierView().then((module) => ({ default: module.DossierView })));
const AdminPanel = lazy(() => loadAdminPanel().then((module) => ({ default: module.AdminPanel })));
const DocumentsView = lazy(() => loadDocumentsView().then((module) => ({ default: module.DocumentsView })));
const SettingsView = lazy(() => loadSettingsView().then((module) => ({ default: module.SettingsView })));
const WikiView = lazy(() => loadWikiView().then((module) => ({ default: module.WikiView })));
const RetirementFundsView = lazy(() => loadRetirementFundsView().then((module) => ({ default: module.RetirementFundsView })));

const DOSSIER_VIEWS = new Set(['dossiers', 'documents', 'visit-report']);
const LIVE_REFRESH_INTERVAL_MS = 15_000;

const createDefaultVisitReportLocation = (): VisitReportLocation => ({
  activeTab: 'Bénéficiaire',
  beneficiarySection: 'profile',
  contextSection: 'medical',
  accessSection: 'general',
  bathroomSection: 'equipment',
  wcSection: 'main',
});

export default function App() {
  const [currentView, setCurrentView] = useState('dashboard');
  const [selectedDossier, setSelectedDossier] = useState<Dossier | null>(null);
  const [lastDossierView, setLastDossierView] = useState<'dossiers' | 'documents' | 'visit-report'>('dossiers');
  const [keepVisitReportMounted, setKeepVisitReportMounted] = useState(false);
  const [visitReportSaving, setVisitReportSaving] = useState(false);
  const [user, setUser] = useState<AppUser | null>(null);

  const [dossiers, setDossiers] = useState<Dossier[]>([]);
  const [visits, setVisits] = useState<Visit[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [isAuthResolved, setIsAuthResolved] = useState(false);
  const [anahStatus, setAnahStatus] = useState<AnahStatus | null>(null);
  const [isCheckingAnah, setIsCheckingAnah] = useState(false);
  const [preloadedDocumentsState, setPreloadedDocumentsState] = useState<{
    dossierId: string;
    documents: AppDocument[];
    preparedAt: string;
  } | null>(null);
  const [visitReportLocations, setVisitReportLocations] = useState<Record<string, VisitReportLocation>>({});

  const applyDossiers = useCallback((items: Dossier[]) => {
    setDossiers(items);
    setVisits(generateVisitsFromDossiers(items));
  }, []);

  const refreshLiveData = useCallback(async (shouldApply = true) => {
    try {
      const liveData = await fetchDossiers();
      if (shouldApply) {
        applyDossiers(liveData);
      }
      return liveData;
    } catch (error) {
      console.error('App: Live fetch failed', error);
      return null;
    }
  }, [applyDossiers]);

  const hydrateInitialData = useCallback(async () => {
    const liveData = await refreshLiveData(false);
    if (Array.isArray(liveData)) {
      applyDossiers(liveData);
      return;
    }

    try {
      const snapshot = await fetchLocalSnapshot();
      applyDossiers(snapshot);
      return;
    } catch (snapshotError) {
      console.error('App: Snapshot preload failed', snapshotError);
    }

    applyDossiers([]);
  }, [applyDossiers, refreshLiveData]);

  useEffect(() => {
    let isMounted = true;
    const initAuth = async () => {
      const currentUser = await fetchCurrentAppUser();
      if (!isMounted) return;
      setUser(currentUser);
      setIsAuthResolved(true);
    };

    initAuth().catch((error) => {
      console.error('App: Failed to resolve app session', error);
      if (isMounted) {
        setUser(null);
        setIsAuthResolved(true);
      }
    });

    return () => {
      isMounted = false;
    };
  }, []);

  useEffect(() => {
    if (!isAuthResolved) return;

    let isMounted = true;
    let pollTimer: ReturnType<typeof setInterval> | undefined;

    const clearPolling = () => {
      if (pollTimer) {
        clearInterval(pollTimer);
        pollTimer = undefined;
      }
    };

    const refreshSilently = () => {
      void refreshLiveData();
    };

    if (!user) {
      setDossiers([]);
      setVisits([]);
      setIsLoading(false);
      return () => clearPolling();
    }

    const loadWorkspace = async () => {
      setIsLoading(true);
      await hydrateInitialData();
      if (isMounted) {
        setIsLoading(false);
      }
    };

    loadWorkspace().catch((error) => {
      console.error('App: Failed to hydrate user workspace', error);
      if (isMounted) {
        setIsLoading(false);
      }
    });

    const handleWindowFocus = () => refreshSilently();
    const handleWindowOnline = () => refreshSilently();
    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        refreshSilently();
      }
    };

    window.addEventListener('focus', handleWindowFocus);
    window.addEventListener('online', handleWindowOnline);
    document.addEventListener('visibilitychange', handleVisibilityChange);

    pollTimer = setInterval(refreshSilently, LIVE_REFRESH_INTERVAL_MS);

    return () => {
      isMounted = false;
      window.removeEventListener('focus', handleWindowFocus);
      window.removeEventListener('online', handleWindowOnline);
      document.removeEventListener('visibilitychange', handleVisibilityChange);
      clearPolling();
    };
  }, [hydrateInitialData, isAuthResolved, refreshLiveData, user]);

  useEffect(() => {
    if (!user) {
      setAnahStatus(null);
      setIsCheckingAnah(false);
      return;
    }

    let isMounted = true;

    const loadAnah = async () => {
      setIsCheckingAnah(true);
      try {
        const nextStatus = await fetchAnahStatus();
        if (isMounted) {
          setAnahStatus(nextStatus);
        }
      } catch (error) {
        console.error('App: Failed to resolve ANAH status', error);
        if (isMounted) {
          setAnahStatus({
            available: false,
            checkedAt: new Date().toISOString(),
            registrationUrl: 'https://monprojet.anah.gouv.fr/',
            publicUrl: 'https://www.anah.gouv.fr/',
            canEmbed: false,
            reason: 'Connexion indisponible',
          });
        }
      } finally {
        if (isMounted) {
          setIsCheckingAnah(false);
        }
      }
    };

    const handleOnline = () => {
      loadAnah().catch(() => undefined);
    };

    loadAnah().catch(() => undefined);
    window.addEventListener('online', handleOnline);

    return () => {
      isMounted = false;
      window.removeEventListener('online', handleOnline);
    };
  }, [user]);

  useEffect(() => {
    if (!user || typeof window === 'undefined') {
      return;
    }

    const preloadViews = () => {
      void Promise.allSettled([
        loadDashboardView(),
        loadDossierView(),
        loadDocumentsView(),
        loadSettingsView(),
        loadWikiView(),
        loadRetirementFundsView(),
        ...(user.role === 'ADMIN' ? [loadAdminPanel()] : []),
      ]);
    };

    const idleCallback = (window as Window & {
      requestIdleCallback?: (callback: () => void, options?: { timeout: number }) => number;
      cancelIdleCallback?: (handle: number) => void;
    }).requestIdleCallback;

    if (idleCallback) {
      const handle = idleCallback(preloadViews, { timeout: 1200 });
      return () => {
        (window as Window & { cancelIdleCallback?: (handle: number) => void }).cancelIdleCallback?.(handle);
      };
    }

    const timeoutId = window.setTimeout(preloadViews, 250);
    return () => window.clearTimeout(timeoutId);
  }, [user]);

  useEffect(() => {
    if (!user) return;
    const unregister = registerPendingRelevesSync();
    void flushPendingReleves();
    return unregister;
  }, [user]);

  const isAnahAccessible = Boolean(anahStatus?.available);
  const disabledViews = {
    ...(isCheckingAnah ? { anah: 'Vérification ANAH...' } : {}),
    ...(!isCheckingAnah && !isAnahAccessible ? { anah: anahStatus?.reason || 'Site ANAH indisponible' } : {}),
  };

  useEffect(() => {
    if (DOSSIER_VIEWS.has(currentView)) {
      setLastDossierView(currentView as 'dossiers' | 'documents' | 'visit-report');
    }
  }, [currentView]);

  useEffect(() => {
    if (keepVisitReportMounted && currentView !== 'visit-report' && !visitReportSaving) {
      setKeepVisitReportMounted(false);
    }
  }, [currentView, keepVisitReportMounted, visitReportSaving]);

  useEffect(() => {
    if (!selectedDossier) {
      setKeepVisitReportMounted(false);
      setVisitReportSaving(false);
    }
  }, [selectedDossier]);

  const confirmVisitReportInterruption = useCallback((nextDossierId?: string | null) => {
    if (!visitReportSaving || !selectedDossier?.id) {
      return true;
    }

    if (nextDossierId && nextDossierId === selectedDossier.id) {
      return true;
    }

    const shouldLeave = window.confirm(
      'Une sauvegarde du relevé de visite est encore en cours. Êtes-vous sûr de vouloir quitter ce dossier ?'
    );

    if (shouldLeave) {
      setKeepVisitReportMounted(false);
      setVisitReportSaving(false);
    }

    return shouldLeave;
  }, [selectedDossier?.id, visitReportSaving]);

  const handleNavigate = (view: string) => {
    if (view === 'anah' && !isAnahAccessible) {
      return;
    }

    if (view === 'dossiers') {
      if (!confirmVisitReportInterruption(null)) {
        return;
      }
      if (DOSSIER_VIEWS.has(currentView)) {
        setCurrentView('dossiers');
        setSelectedDossier(null);
        setLastDossierView('dossiers');
        return;
      }

      if (selectedDossier) {
        setCurrentView(lastDossierView);
        return;
      }

      setCurrentView('dossiers');
      return;
    }

    if (currentView === 'visit-report' && visitReportSaving && selectedDossier?.id) {
      setKeepVisitReportMounted(true);
    }

    setCurrentView(view);
  };

  const handleSelectDossier = (dossier: Dossier) => {
    if (!confirmVisitReportInterruption(dossier.id)) {
      return;
    }
    setSelectedDossier(dossier);
    setKeepVisitReportMounted(false);
    setLastDossierView('dossiers');
    setCurrentView('dossiers');
  };

  const handleStartVisit = (dossier: Dossier) => {
    if (!confirmVisitReportInterruption(dossier.id)) {
      return;
    }
    setSelectedDossier(dossier);
    setKeepVisitReportMounted(false);
    setLastDossierView('visit-report');
    setCurrentView('visit-report');
  };

  const handleOpenDocuments = async (dossier: Dossier) => {
    if (!confirmVisitReportInterruption(dossier.id)) {
      return;
    }
    setSelectedDossier(dossier);
    if (currentView === 'visit-report' && visitReportSaving && selectedDossier?.id === dossier.id) {
      setKeepVisitReportMounted(true);
    } else {
      setKeepVisitReportMounted(false);
    }
    setLastDossierView('documents');
    setCurrentView('documents');
    try {
      const [documents] = await Promise.all([
        preloadDocumentsView(dossier.patient.id, dossier.id),
        loadDocumentsView(),
      ]);
      setPreloadedDocumentsState({
        dossierId: dossier.id,
        documents,
        preparedAt: new Date().toISOString(),
      });
    } catch (error) {
      console.error('App: Failed to preload documents view', error);
      setPreloadedDocumentsState({
        dossierId: dossier.id,
        documents: [],
        preparedAt: new Date().toISOString(),
      });
    }
  };

  const handleBackToDossiers = () => {
    if (currentView === 'visit-report' && visitReportSaving && selectedDossier?.id) {
      setKeepVisitReportMounted(true);
    }
    setLastDossierView('dossiers');
    setCurrentView('dossiers');
  };

  const handleResetDossiers = () => {
    if (!confirmVisitReportInterruption(null)) {
      return;
    }
    setSelectedDossier(null);
    setKeepVisitReportMounted(false);
    setLastDossierView('dossiers');
    setCurrentView('dossiers');
  };

  const handleGoToVisit = () => {
    if (currentView === 'visit-report' && visitReportSaving && selectedDossier?.id) {
      setKeepVisitReportMounted(true);
    }
    setLastDossierView('dossiers');
    setCurrentView('dossiers');
  };

  const handleDossierUpdate = useCallback((updatedDossier: Dossier) => {
    console.log("App: Updating local dossier state", updatedDossier.id);
    setDossiers((prev) => {
      const next = prev.map((d) => d.id === updatedDossier.id ? updatedDossier : d);
      setVisits(generateVisitsFromDossiers(next));
      return next;
    });
    if (selectedDossier?.id === updatedDossier.id) {
      setSelectedDossier(updatedDossier);
    }
  }, [selectedDossier?.id]);

  const handleDossierCreated = (createdDossier: Dossier) => {
    console.log('App: Adding newly created dossier', createdDossier.id);
    setDossiers((prev) => {
      const next = [createdDossier, ...prev.filter((dossier) => dossier.id !== createdDossier.id)];
      setVisits(generateVisitsFromDossiers(next));
      return next;
    });
    setSelectedDossier(createdDossier);
    setCurrentView('dossiers');
  };

  const activeDossier = selectedDossier
    ? dossiers.find((dossier) => dossier.id === selectedDossier.id) || selectedDossier
    : null;

  const activeVisitReportLocation = activeDossier
    ? visitReportLocations[activeDossier.id] || createDefaultVisitReportLocation()
    : createDefaultVisitReportLocation();

  const handleVisitReportLocationChange = useCallback((dossierId: string, location: VisitReportLocation) => {
    setVisitReportLocations((previous) => {
      const current = previous[dossierId];
      if (current && JSON.stringify(current) === JSON.stringify(location)) {
        return previous;
      }
      return {
        ...previous,
        [dossierId]: location,
      };
    });
  }, []);

  const handleAuthenticated = (nextUser: AppUser) => {
    setUser(nextUser);
    setCurrentView('dashboard');
  };

  const handleUserUpdated = (nextUser: AppUser) => {
    setUser(nextUser);
  };

  const handleLogout = async () => {
    await logoutApp();
    setSelectedDossier(null);
    setCurrentView('dashboard');
    setUser(null);
  };

  const renderContent = () => {
    if (isLoading) {
      return (
        <SimpleLoader label="Connexion à la base de données" />
      );
    }

    switch (currentView) {
      case 'dashboard':
        return (
          <Suspense fallback={null}>
            <Dashboard
              visits={visits}
              dossiersCount={dossiers.length}
              dossiers={dossiers}
              onSelectDossier={handleSelectDossier}
              onNavigate={handleNavigate}
              onCreateDossier={handleDossierCreated}
              currentUser={user}
              userName={getFirstName()}
            />
          </Suspense>
        );
      case 'dossiers':
        return (
          <Suspense fallback={null}>
            <DossierView
              dossiers={dossiers}
              onSelectDossier={handleSelectDossier}
              onCreateDossier={handleDossierCreated}
              onUpdateDossier={handleDossierUpdate}
              selectedDossier={activeDossier}
              onBack={handleResetDossiers}
              onStartVisit={handleStartVisit}
              onOpenDocuments={handleOpenDocuments}
              currentUser={user}
            />
          </Suspense>
        );
      case 'documents':
        return activeDossier ? (
          <Suspense fallback={null}>
            <DocumentsView
              dossier={activeDossier}
              onBack={handleBackToDossiers}
              initialDocuments={preloadedDocumentsState?.dossierId === activeDossier.id ? preloadedDocumentsState.documents : []}
              initialPreparedAt={preloadedDocumentsState?.dossierId === activeDossier.id ? preloadedDocumentsState.preparedAt : null}
              initialIsReady={preloadedDocumentsState?.dossierId === activeDossier.id}
            />
          </Suspense>
        ) : <MissingDossierState onBack={handleBackToDossiers} />;
      case 'visit-report':
        return null;
      case 'admin':
        return user.role === 'ADMIN' ? (
          <Suspense fallback={null}>
            <AdminPanel />
          </Suspense>
        ) : (
          <div className="flex flex-col items-center justify-center h-[60vh] text-slate-500">
            <h3 className="text-xl font-bold mb-2">Accès refusé</h3>
            <p>Cette section est réservée à l’administration.</p>
          </div>
        );
      case 'settings':
        return (
          <Suspense fallback={null}>
            <SettingsView user={user} onLogout={handleLogout} onUserUpdated={handleUserUpdated} />
          </Suspense>
        );
      case 'wiki':
        return (
          <ViewErrorBoundary onBack={() => setCurrentView('dashboard')} title="Le module Bibliothèque n’a pas pu s’ouvrir" backLabel="Revenir à l'accueil">
            <Suspense fallback={null}>
              <WikiView />
            </Suspense>
          </ViewErrorBoundary>
        );
      case 'precos':
        return (
          <Suspense fallback={null}>
            <RetirementFundsView />
          </Suspense>
        );
      case 'anah':
        return <AnahView status={anahStatus} isChecking={isCheckingAnah} />;
      default:
        return (
          <Suspense fallback={null}>
            <Dashboard
              visits={visits}
              dossiersCount={dossiers.length}
              dossiers={dossiers}
              onCreateDossier={handleDossierCreated}
              currentUser={user}
            />
          </Suspense>
        );
    }
  };

  if (!isAuthResolved) {
    return (
      <div className="flex h-screen items-center justify-center bg-[#C5D2D8]">
        <SimpleLoader label="Chargement de l'application" className="px-4" />
      </div>
    );
  }

  if (!user) {
    return <LoginView onAuthenticated={handleAuthenticated} />;
  }

  const getFirstName = () => {
    return user.displayName?.split(' ')[0] || 'Ergo';
  };

  return (
    <div className="flex h-screen overflow-hidden bg-[#C5D2D8] transition-colors duration-300">
      <Sidebar
        currentView={currentView}
        onNavigate={handleNavigate}
        user={user}
        disabledViews={disabledViews}
      />

      <main className="ml-24 flex-1 h-screen overflow-hidden px-3 pb-3 pt-0 md:px-4 md:pb-4 md:pt-0">
        <div className="bg-[#FDFDFD] h-full rounded-[34px] shadow-xl overflow-hidden flex flex-col relative transition-colors duration-300">
          <div className="flex-1 overflow-y-auto px-5 pb-6 pt-4 no-scrollbar md:px-7 md:pb-7 md:pt-5 lg:px-8 lg:pb-8 lg:pt-6">
            {currentView === 'visit-report' && !activeDossier ? (
              <MissingDossierState onBack={handleBackToDossiers} />
            ) : (
              renderContent()
            )}

            {activeDossier && (currentView === 'visit-report' || keepVisitReportMounted) && (
              <div className={currentView === 'visit-report' ? 'h-full' : 'hidden'}>
                <ViewErrorBoundary onBack={handleGoToVisit} title="Le relevé de visite n’a pas pu s’ouvrir" backLabel="Revenir au dossier">
                  <VisitReportView
                    dossier={activeDossier}
                    onBack={handleGoToVisit}
                    onUpdateDossier={handleDossierUpdate}
                    onSavingChange={setVisitReportSaving}
                    location={activeVisitReportLocation}
                    onLocationChange={(location) => handleVisitReportLocationChange(activeDossier.id, location)}
                  />
                </ViewErrorBoundary>
              </div>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}

const AnahView: React.FC<{ status: AnahStatus | null; isChecking: boolean }> = ({ status, isChecking }) => {
  const checkedLabel = status?.checkedAt
    ? new Date(status.checkedAt).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })
    : '';
  const handleOpenAnah = React.useCallback(() => {
    if (!status?.registrationUrl || typeof window === 'undefined') {
      return;
    }
    window.open(status.registrationUrl, '_blank', 'noopener,noreferrer');
  }, [status?.registrationUrl]);

  if (isChecking) {
    return <SimpleLoader label="Vérification de l'accès ANAH" />;
  }

  if (!status?.available) {
    return (
      <div className="h-full flex items-center justify-center">
        <div className="max-w-2xl w-full rounded-[32px] border border-slate-200 bg-white p-10 shadow-sm text-center">
          <div className="mx-auto w-16 h-16 rounded-full bg-slate-100 text-slate-400 flex items-center justify-center">
            <WifiOff size={28} />
          </div>
          <h2 className="mt-5 text-3xl font-bold text-slate-900">Module Anah indisponible</h2>
          <p className="mt-3 text-slate-600">
            L’inscription MaPrimeAdapt’ n’est pas accessible pour le moment.
          </p>
          <p className="mt-2 text-sm text-slate-400">
            {status?.reason || 'Connexion internet indisponible'}
            {checkedLabel ? ` • Vérifié le ${checkedLabel}` : ''}
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-8 pb-8">
      <div>
        <h2 className="text-3xl font-bold text-black">Inscription au site de l&apos;Anah</h2>
      </div>

      <div className="bg-white rounded-[32px] border border-slate-200 p-8 shadow-sm">
        <div className="flex flex-col lg:flex-row lg:items-start lg:justify-between gap-6">
          <div className="max-w-3xl">
            <p className="text-xs font-bold uppercase tracking-[0.28em] text-[#907CA1]">Anah</p>
            <h2 className="mt-3 text-4xl font-bold text-slate-900">MaPrimeAdapt&apos;</h2>
            <p className="mt-3 text-slate-600 leading-relaxed">
              L’accès officiel est disponible. L’ouverture se fait sur le site de l’ANAH.
            </p>
            <p className="mt-3 text-sm text-slate-400">
              Vérifié le {checkedLabel}
            </p>
          </div>

          <button
            type="button"
            onClick={handleOpenAnah}
            className="inline-flex items-center justify-center gap-2 px-6 py-4 rounded-full bg-[#907CA1] text-white font-bold hover:bg-[#7a668a] transition-colors"
          >
            <ExternalLink size={18} />
            Ouvrir MaPrimeAdapt&apos;
          </button>
        </div>
      </div>

      <div className="bg-white rounded-[28px] border border-slate-200 p-4 shadow-sm overflow-hidden">
        <img
          src="/anah-widget-illustration.svg"
          alt=""
          className="w-full h-[260px] md:h-[320px] object-cover rounded-[22px]"
        />
      </div>
    </div>
  );
};

const MissingDossierState: React.FC<{ onBack: () => void }> = ({ onBack }) => (
  <div className="h-full flex flex-col items-center justify-center text-center space-y-4">
    <h3 className="text-xl font-bold text-slate-900">Dossier indisponible</h3>
    <p className="text-slate-500 max-w-md">Le dossier sélectionné n’est plus chargé dans la session courante.</p>
    <button
      onClick={onBack}
      className="px-6 py-3 rounded-full bg-[#907CA1] text-white font-bold hover:bg-[#7a668a] transition-colors"
    >
      Revenir aux dossiers
    </button>
  </div>
);

class ViewErrorBoundary extends React.Component<
  React.PropsWithChildren<{ onBack: () => void; title?: string; message?: string; backLabel?: string }>,
  { hasError: boolean }
> {
  declare props: React.PropsWithChildren<{ onBack: () => void; title?: string; message?: string; backLabel?: string }>;
  state = { hasError: false };

  static getDerivedStateFromError() {
    return { hasError: true };
  }

  componentDidCatch(error: Error) {
    console.error('App: Visit report crashed', error);
  }

  render() {
    if (!this.state.hasError) {
      return this.props.children;
    }

    return (
      <div className="h-full flex flex-col items-center justify-center text-center space-y-4">
        <h3 className="text-xl font-bold text-slate-900">{this.props.title || 'Le relevé n’a pas pu s’ouvrir'}</h3>
        <p className="text-slate-500 max-w-md">
          {this.props.message || 'Une erreur s’est produite au chargement de la visite à domicile. Revenez à l’étape précédente puis réessayez.'}
        </p>
        <button
          onClick={this.props.onBack}
          className="px-6 py-3 rounded-full bg-[#907CA1] text-white font-bold hover:bg-[#7a668a] transition-colors"
        >
          {this.props.backLabel || 'Revenir à la visite'}
        </button>
      </div>
    );
  }
}
