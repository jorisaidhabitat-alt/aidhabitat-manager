import React, { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Copy, KeyRound, RefreshCw, ShieldCheck, UserCog, Users } from 'lucide-react';
import { fetchAdminAccessMembers, regenerateAccessPassword } from '../../../services/dataService';
import { AdminAccessMember } from '../../../types';
import { SimpleLoader } from '../../shared/LoadingProgress';
import { uiPanelClass, uiPanelInteractiveClass, uiPrimaryButtonClass, uiSecondaryButtonClass, uiSoftPanelClass } from '../../shared/uiTheme';

export const AdminPanel: React.FC = () => {
  const [members, setMembers] = useState<AdminAccessMember[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copiedEmail, setCopiedEmail] = useState<string | null>(null);
  const [resettingEmail, setResettingEmail] = useState<string | null>(null);
  // SECURITY 2026-05-15 (audit P0 #3) : le serveur n'expose plus le
  // password dans la liste GET /api/admin/access-members. Quand l'admin
  // crée/réinitialise un membre, le password est renvoyé UNE FOIS dans
  // la response du POST — on le capture ici en state local éphémère
  // pour permettre à l'admin de le copier/communiquer. Au prochain
  // refresh ou changement de page, le password disparaît du state.
  const [revealedPasswords, setRevealedPasswords] = useState<Record<string, string>>({});

  const loadMembers = async (refreshing = false) => {
    if (refreshing) {
      setIsRefreshing(true);
    } else {
      setIsLoading(true);
    }
    setError(null);

    try {
      const data = await fetchAdminAccessMembers();
      setMembers(data);
    } catch (loadError: any) {
      setError(loadError.message || 'Impossible de charger les accès');
    } finally {
      setIsLoading(false);
      setIsRefreshing(false);
    }
  };

  useEffect(() => {
    loadMembers();
  }, []);

  const stats = useMemo(() => ({
    members: members.length,
    selectable: members.filter((member) => member.selectable).length,
    admins: members.filter((member) => member.role === 'ADMIN').length,
    passwords: members.filter((member) => member.hasPassword).length,
  }), [members]);

  const handleCopy = async (member: AdminAccessMember) => {
    // Le password à copier vient du state local (révélé lors d'un
    // create/reset récent) ; le `generatedPassword` du membre est
    // toujours vide depuis le fix audit P0 #3.
    const password = revealedPasswords[member.email] || member.generatedPassword;
    if (!password) return;
    const content = `${member.email}\n${password}`;
    try {
      await navigator.clipboard.writeText(content);
      setCopiedEmail(member.email);
      window.setTimeout(() => setCopiedEmail(null), 2000);
    } catch (copyError) {
      console.error('Clipboard write failed', copyError);
    }
  };

  const handleReset = async (member: AdminAccessMember) => {
    setResettingEmail(member.email);
    const result = await regenerateAccessPassword(member.email);
    setResettingEmail(null);

    if (!result.success) {
      setError(result.error || 'Réinitialisation impossible');
      return;
    }

    // Capture le password tout juste généré (lecture unique côté
    // serveur depuis le fix audit P0 #3) pour l'afficher dans la liste.
    // Le state local sera reset à `loadMembers(true)` ci-dessous SI
    // l'admin refresh manuellement, mais en attendant le password reste
    // visible — le temps que l'admin le note.
    if (result.password) {
      setRevealedPasswords((prev) => ({
        ...prev,
        [member.email]: result.password!,
      }));
    }

    await loadMembers(true);
  };

  return (
    <div className="space-y-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-3xl font-bold text-slate-900">Administration des accès</h2>
          <p className="text-slate-500 mt-1">Gestion des comptes applicatifs à partir des membres autorisés.</p>
        </div>
        <button
          onClick={() => loadMembers(true)}
          className={`${uiSecondaryButtonClass} rounded-full`}
          disabled={isRefreshing}
        >
          <RefreshCw size={16} className={isRefreshing ? 'animate-spin' : ''} />
          Actualiser
        </button>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
        <StatCard icon={Users} label="Membres" value={stats.members} />
        <StatCard icon={UserCog} label="Ergos sélectionnables" value={stats.selectable} />
        <StatCard icon={ShieldCheck} label="Admins" value={stats.admins} />
        <StatCard icon={KeyRound} label="Mots de passe actifs" value={stats.passwords} />
      </div>

      {error && (
        <div className="rounded-3xl border border-red-100 bg-red-50 px-5 py-4 text-sm text-red-700 flex items-start gap-3">
          <AlertTriangle size={18} className="mt-0.5" />
          <span>{error}</span>
        </div>
      )}

      <div className={`${uiPanelClass} overflow-hidden`}>
        <div className="px-6 py-5 border-b border-slate-100 flex items-center justify-between">
          <div>
            <h3 className="font-bold text-slate-900">Accès applicatifs</h3>
            <p className="text-sm text-slate-500">Les nouveaux membres autorisés apparaissent automatiquement ici.</p>
          </div>
        </div>

        {isLoading ? (
          <div className="px-6 py-8">
            <SimpleLoader label="Chargement des accès" />
          </div>
        ) : (
          <div className="divide-y divide-slate-100">
            {members.map((member) => (
              <div key={member.email} className="px-6 py-5 grid grid-cols-1 xl:grid-cols-[2fr_1fr_1fr_1.2fr_auto] gap-4 items-center">
                <div>
                  <div className="flex items-center gap-3">
                    <div className={`px-3 py-1 rounded-full text-xs font-bold uppercase tracking-wider ${member.role === 'ADMIN' ? 'bg-slate-900 text-white' : 'bg-[#D8D0DC] text-[#554a63]'}`}>
                      {member.role === 'ADMIN' ? 'Admin' : 'Ergo'}
                    </div>
                    {!member.selectable && (
                      <div className="px-3 py-1 rounded-full text-xs font-bold uppercase tracking-wider bg-slate-100 text-slate-600">
                        Non sélectionnable
                      </div>
                    )}
                  </div>
                  <p className="text-lg font-bold text-slate-900 mt-3">{member.displayName}</p>
                  <p className="text-sm text-slate-500">{member.email}</p>
                </div>

                <div>
                  <p className="text-xs font-bold uppercase tracking-wider text-slate-400 mb-1">Établissement</p>
                  <p className="text-sm font-medium text-slate-700">{member.establishmentLabel || 'Global'}</p>
                </div>

                <div>
                  <p className="text-xs font-bold uppercase tracking-wider text-slate-400 mb-1">Alias dossier</p>
                  <p className="text-sm font-medium text-slate-700">{member.ergoLabel || 'Tous les dossiers'}</p>
                </div>

                <div>
                  <p className="text-xs font-bold uppercase tracking-wider text-slate-400 mb-1">Mot de passe courant</p>
                  <div className={`${uiSoftPanelClass} px-4 py-3 font-mono text-sm text-slate-800 break-all`}>
                    {/*
                      SECURITY 2026-05-15 (audit P0 #3) : le password
                      n'est PLUS exposé dans la liste GET — `member.generatedPassword`
                      est désormais toujours vide. Pour le révéler, l'admin
                      doit cliquer « Réinitialiser » : la response du POST
                      stocke alors le nouveau password dans
                      `revealedPasswords` (state local volatile, perdu au
                      reload). Le placeholder informe l'admin qu'il faut
                      passer par le bouton Réinitialiser pour obtenir le
                      password à communiquer au membre.
                    */}
                    {revealedPasswords[member.email] || (
                      <span className="text-slate-400 italic font-sans text-xs">
                        Cliquer « Réinitialiser » pour générer un mot de passe à communiquer
                      </span>
                    )}
                  </div>
                </div>

                <div className="flex flex-col sm:flex-row xl:flex-col gap-2">
                  <button
                    onClick={() => handleCopy(member)}
                    className={`${uiSecondaryButtonClass} rounded-full`}
                  >
                    <Copy size={16} />
                    {copiedEmail === member.email ? 'Copié' : 'Copier'}
                  </button>
                  <button
                    onClick={() => handleReset(member)}
                    disabled={resettingEmail === member.email}
                    className={`${uiPrimaryButtonClass} rounded-full disabled:opacity-60`}
                  >
                    <RefreshCw size={16} className={resettingEmail === member.email ? 'animate-spin' : ''} />
                    Réinitialiser
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
};

const StatCard: React.FC<{ icon: React.ComponentType<any>; label: string; value: number }> = ({ icon: Icon, label, value }) => (
  <div className={`${uiPanelInteractiveClass} flex items-center justify-between p-5`}>
    <div>
      <p className="text-sm font-medium text-slate-500">{label}</p>
      <p className="text-3xl font-bold text-slate-900 mt-1">{value}</p>
    </div>
    <div className="w-12 h-12 rounded-2xl bg-slate-50 text-slate-600 flex items-center justify-center">
      <Icon size={22} />
    </div>
  </div>
);
