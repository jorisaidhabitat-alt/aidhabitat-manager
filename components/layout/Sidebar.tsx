import React from 'react';
import { BookOpen, Coins, FolderOpen, Heart, Home, ShieldCheck } from 'lucide-react';
import { AppUser } from '../../types';

interface SidebarProps {
  currentView: string;
  onNavigate: (view: string) => void;
  user: AppUser | null;
  disabledViews?: Record<string, string>;
}

export const Sidebar: React.FC<SidebarProps> = ({ currentView, onNavigate, user, disabledViews = {} }) => {
  const isDossierView = ['dossiers', 'documents', 'visit-report'].includes(currentView);
  const MENU_ITEMS = [
    { id: 'dashboard', label: 'Accueil', icon: Home },
    { id: 'dossiers', label: 'Dossiers', icon: FolderOpen },
    { id: 'wiki', label: 'Bibliothèque', icon: BookOpen },
    { id: 'precos', label: 'Caisses', icon: Heart },
    { id: 'anah', label: 'Anah', icon: Coins },
    ...(user?.role === 'ADMIN' ? [{ id: 'admin', label: 'Admin', icon: ShieldCheck }] : []),
  ];

  const initials = user?.displayName
    ?.split(' ')
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase())
    .join('') || 'AH';

  return (
    <aside className="w-24 bg-white flex flex-col h-screen fixed left-0 top-0 z-50 shadow-sm rounded-r-[2rem] py-6 items-center justify-between transition-all duration-300 border-r border-slate-100">
      {/* Logo Area */}
      <div className="flex flex-col items-center gap-2">
        <button
          type="button"
          onClick={() => onNavigate('dashboard')}
          title="Retour au tableau de bord"
          className="w-12 h-12 rounded-full border-2 border-black flex items-center justify-center relative hover:bg-slate-50 transition-colors"
        >
          <div className="w-3 h-3 bg-black rounded-full absolute top-2 right-2"></div>
        </button>
      </div>

      {/* Navigation */}
      <nav className="flex-1 flex flex-col justify-center space-y-6 w-full px-4">
        {MENU_ITEMS.map((item) => {
          const isActive = currentView === item.id || (item.id === 'dossiers' && isDossierView);
          const disabledReason = disabledViews[item.id];
          const isDisabled = Boolean(disabledReason);
          return (
            <button
              key={item.id}
              type="button"
              onClick={() => {
                if (isDisabled) return;
                onNavigate(item.id);
              }}
              disabled={isDisabled}
              title={disabledReason || item.label}
              className={`w-12 h-12 mx-auto flex items-center justify-center rounded-full transition-all duration-200 group relative ${isActive
                ? 'bg-[#C5D2D8] text-black shadow-inner'
                : isDisabled
                  ? 'bg-slate-100 text-slate-300 cursor-not-allowed'
                  : 'bg-[#C5D2D8]/30 text-slate-400 hover:bg-[#C5D2D8] hover:text-black'
                }`}
            >
              <item.icon size={22} strokeWidth={isActive ? 2.5 : 2} />

              {/* Tooltip */}
              <div className="absolute left-14 bg-black text-white text-xs px-2 py-1 rounded opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity whitespace-nowrap z-50">
                {disabledReason || item.label}
              </div>
            </button>
          );
        })}
      </nav>

      {/* Profile / Bottom */}
      <div className="flex flex-col items-center gap-4 mb-4">
        <button
          onClick={() => onNavigate('settings')}
          className="relative w-10 h-10 rounded-full overflow-hidden border-2 border-white shadow-md hover:ring-2 hover:ring-[#D8D0DC] transition-all bg-[#907CA1] text-white font-bold flex items-center justify-center"
        >
          {user?.profilePhotoUrl ? (
            <img
              src={user.profilePhotoUrl}
              alt={user.displayName}
              className="w-full h-full object-cover"
            />
          ) : initials}
        </button>
      </div>
    </aside>
  );
};
