import React from 'react';
import { AppUser, Visit, Dossier } from '../../../types';
import { Calendar, CheckCircle, Clock, MapPin, TrendingUp, Users, ArrowRight, Folder } from 'lucide-react';
import { formatCityLabel, mapVirtualDossierFromBeneficiary } from '../../../services/dataService'; // Import mapper
import { CreateDossierFab } from '../dossier/DossierView';
import { uiPanelInteractiveClass } from '../../shared/uiTheme';

interface DashboardProps {
  visits: Visit[];
  dossiersCount: number;
  dossiers: Dossier[];
  onSelectDossier?: (dossier: Dossier) => void;
  onNavigate?: (view: string) => void;
  onCreateDossier?: (dossier: Dossier) => void;
  currentUser?: AppUser;
  userName?: string;
}

const activityData = [
  { name: 'Jan', dossiers: 4 },
  { name: 'Fév', dossiers: 7 },
  { name: 'Mar', dossiers: 5 },
  { name: 'Avr', dossiers: 9 },
  { name: 'Mai', dossiers: 12 },
  { name: 'Juin', dossiers: 8 },
];

export const Dashboard: React.FC<DashboardProps> = ({ visits, dossiersCount, dossiers, onSelectDossier, onNavigate, onCreateDossier, currentUser,
  userName = 'Ergo'
}) => {
  // Local state for direct snapshot fetch (Manual Fallback)
  const [localDossiers, setLocalDossiers] = React.useState<Dossier[]>([]);

  React.useEffect(() => {
    // If no props passed, fetch snapshot directly
    if (!dossiers || dossiers.length === 0) {
      console.log("Dashboard: Fetching snapshot directly...");
      fetch('/snapshot.json')
        .then(res => res.json())
        .then(data => {
          if (data.beneficiaries) {
            console.log("Dashboard: Snapshot loaded.", data.beneficiaries.length);
            // Use the shared mapper to ensure full object structure required for Detail View
            const mapped = data.beneficiaries.map(mapVirtualDossierFromBeneficiary);
            setLocalDossiers(mapped as Dossier[]);
          }
        })
        .catch(err => console.error("Dashboard: Direct fetch failed", err));
    }
  }, [dossiers]);

  // Fallback: Props -> Local State
  const safeDossiers = (dossiers && dossiers.length > 0) ? dossiers : localDossiers;
  const recentDossiers = safeDossiers.slice(0, 4);


  // Calculate stats
  const stats = {
    total: safeDossiers.length,
    validated: 12, // Hardcoded for now per design
    processing: safeDossiers.filter(d => d.status === 'En cours' || d.status === 'Nouveau').length
  };

  const today = new Date();
  const dateOptions: Intl.DateTimeFormatOptions = { weekday: 'long', day: 'numeric', month: 'long' };
  const dateString = today.toLocaleDateString('fr-FR', dateOptions);
  const capitalizedDate = dateString.charAt(0).toUpperCase() + dateString.slice(1);

  return (
    <div className="flex h-full min-h-0 flex-col gap-5 animate-fade-in">

      {/* Welcome Header */}
      <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 md:text-3xl">Bonjour, {userName || 'Ergo'}</h1>
          <p className="text-slate-500 mt-1">Voici le résumé de votre activité aujourd'hui.</p>
        </div>
        <div className="text-left md:text-right">
          <p className="text-xl font-bold text-slate-900 md:text-2xl">{capitalizedDate}</p>
        </div>
      </div>

      {/* KPI Cards */}
      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <KPICard
          icon={Users}
          label="Dossiers en cours"
          value={safeDossiers.filter(d => d.status !== 'Clos').length}
          color="bg-blue-100 text-blue-600"
          trend="+12%"
          onClick={() => onNavigate?.('dossiers')}
        />
        <KPICard
          icon={Calendar}
          label="Visites semaine"
          value={visits.length}
          color="bg-purple-100 text-purple-600"
          trend="+5%"
        />
        <KPICard
          icon={CheckCircle}
          label="Dossiers validés"
          value={12}
          color="bg-emerald-100 text-emerald-600"
          trend="+8%"
          onClick={() => onNavigate?.('dossiers')}
        />
      </div>

      <div className="grid min-h-0 flex-1 grid-cols-1 gap-5 lg:grid-cols-[minmax(0,1.6fr)_minmax(280px,0.9fr)]">
        {/* Recent Dossiers */}
        <div className={`${uiPanelInteractiveClass} flex min-h-0 flex-col p-6`}>
          <div className="flex justify-between items-center mb-5">
            <h2 className="text-xl font-bold text-slate-800">Dossiers Récents ({safeDossiers.length})</h2>
            <button
              className="text-sm font-bold text-[#907CA1] hover:text-[#7a668a]"
              onClick={() => onNavigate?.('dossiers')}
            >
              Voir tout
            </button>
          </div>


          <div className="space-y-3 overflow-y-auto pr-1 no-scrollbar">
            {recentDossiers.map((dossier) => (
              <div
                key={dossier.id}
                className="flex items-center justify-between p-4 rounded-2xl bg-slate-50 hover:bg-slate-100 transition-colors group cursor-pointer"
                onClick={() => onSelectDossier?.(dossier)}
              >
                <div className="flex items-center gap-4">
                  <div className="w-12 h-12 bg-white rounded-full flex items-center justify-center shadow-sm text-slate-700 font-bold">
                    {dossier.patient.firstName[0]}{dossier.patient.lastName[0]}
                  </div>
                  <div>
                    <h3 className="font-bold text-slate-800 group-hover:text-[#907CA1] transition-colors">
                      {dossier.patient.lastName} {dossier.patient.firstName}
                    </h3>
                    <div className="flex items-center gap-2 text-xs text-slate-500">
                      <MapPin size={12} />
                      <span>{formatCityLabel(dossier.patient.city)}</span>
                    </div>
                  </div>
                </div>
                <div className="flex items-center gap-4">
                  <span className={`px-3 py-1 rounded-full text-xs font-bold ${dossier.status === 'Validé' ? 'bg-emerald-100 text-emerald-700' :
                    dossier.status === 'À visiter' ? 'bg-amber-100 text-amber-700' :
                      'bg-slate-200 text-slate-600'
                    }`}>
                    {dossier.status}
                  </span>
                  <ArrowRight size={18} className="text-slate-300 group-hover:text-[#907CA1] transition-colors" />
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Chart */}
        <div className={`${uiPanelInteractiveClass} flex min-h-0 flex-col p-6`}>
          <h2 className="text-xl font-bold text-slate-800 mb-5">Activité</h2>
          <ActivityChart data={activityData} />
        </div>
      </div>

      {currentUser && onCreateDossier ? (
        <CreateDossierFab currentUser={currentUser} onCreate={onCreateDossier} />
      ) : null}
    </div>
  );
};

const ActivityChart: React.FC<{ data: Array<{ name: string; dossiers: number }> }> = ({ data }) => {
  const maxValue = Math.max(...data.map((entry) => entry.dossiers), 1);

  return (
    <div className="flex-1 min-h-[220px]">
      <div className="flex h-full items-end gap-3 border-b border-slate-100 pb-6">
        {data.map((entry, index) => {
          const height = `${Math.max((entry.dossiers / maxValue) * 100, 8)}%`;
          const isHighlighted = index === data.length - 1;

          return (
            <div key={entry.name} className="flex min-w-0 flex-1 flex-col items-center justify-end gap-3">
              <div className="text-xs font-semibold text-slate-400">{entry.dossiers}</div>
              <div className="flex h-44 w-full items-end justify-center rounded-2xl bg-slate-50 px-2 py-3">
                <div
                  className={`w-full max-w-[32px] rounded-full transition-all duration-300 ${isHighlighted ? 'bg-[#907CA1]' : 'bg-slate-200'}`}
                  style={{ height }}
                />
              </div>
              <div className="text-xs font-medium text-slate-400">{entry.name}</div>
            </div>
          );
        })}
      </div>
    </div>
  );
};

const KPICard: React.FC<{ icon: any, label: string, value: number, color: string, trend: string, onClick?: () => void }> = ({ icon: Icon, label, value, color, trend, onClick }) => (
  <div
    className={`${uiPanelInteractiveClass} p-5 ${onClick ? 'cursor-pointer' : ''}`}
    onClick={onClick}
  >
    <div className="flex justify-between items-start mb-4">
      <div className={`p-3 rounded-2xl ${color} bg-opacity-20`}>
        <Icon size={24} />
      </div>
      <span className="flex items-center gap-1 text-emerald-600 font-bold text-sm bg-emerald-50 px-2 py-1 rounded-full">
        <TrendingUp size={14} />
        {trend}
      </span>
    </div>
    <h3 className="text-3xl font-bold text-slate-800 mb-1">{value}</h3>
    <p className="text-slate-500 font-medium">{label}</p>
  </div>
);
