import React, { useRef, useState } from 'react';
import { Camera, LogOut, Shield } from 'lucide-react';
import { uploadProfilePhoto } from '../services/dataService';
import { AppUser } from '../types';
import { SimpleLoader } from './LoadingProgress';

interface SettingsViewProps {
    user: AppUser | null;
    onLogout: () => Promise<void> | void;
    onUserUpdated: (user: AppUser) => void;
}

const readFileAsDataUrl = (file: File) => new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ''));
    reader.onerror = () => reject(new Error('Lecture du fichier impossible'));
    reader.readAsDataURL(file);
});

export const SettingsView: React.FC<SettingsViewProps> = ({ user, onLogout, onUserUpdated }) => {
    const inputRef = useRef<HTMLInputElement | null>(null);
    const [isUploading, setIsUploading] = useState(false);
    const [feedback, setFeedback] = useState<{ type: 'success' | 'error'; message: string } | null>(null);
    const initials = user?.displayName
        ?.split(' ')
        .filter(Boolean)
        .slice(0, 2)
        .map((part) => part[0]?.toUpperCase())
        .join('') || 'AH';

    const handlePickPhoto = () => {
        inputRef.current?.click();
    };

    const handleFileChange = async (event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        event.target.value = '';
        if (!file || !user) return;

        setFeedback(null);
        setIsUploading(true);

        try {
            const imageDataUrl = await readFileAsDataUrl(file);
            const result = await uploadProfilePhoto(imageDataUrl);
            if (!result.success || !result.user) {
                throw new Error(result.error || 'Enregistrement impossible');
            }
            onUserUpdated(result.user);
            setFeedback({ type: 'success', message: 'Photo de profil mise à jour.' });
        } catch (error: any) {
            setFeedback({ type: 'error', message: error.message || 'Enregistrement impossible' });
        } finally {
            setIsUploading(false);
        }
    };

    return (
        <div className="mx-auto max-w-2xl space-y-8 pb-20">
            <h2 className="text-3xl font-bold text-black">Paramètres du compte</h2>

            {user && (
                <div className="bg-white rounded-3xl p-8 shadow-sm space-y-8">
                    <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-6">
                        <div className="flex items-center gap-5">
                            <div className="relative">
                                <div className="w-24 h-24 rounded-full overflow-hidden bg-[#907CA1] text-white font-bold text-2xl flex items-center justify-center">
                                    {user.profilePhotoUrl ? (
                                        <img
                                            src={user.profilePhotoUrl}
                                            alt={user.displayName}
                                            className="w-full h-full object-cover"
                                        />
                                    ) : initials}
                                </div>
                                <button
                                    type="button"
                                    onClick={handlePickPhoto}
                                    disabled={isUploading}
                                    className="absolute -bottom-1 -right-1 w-10 h-10 rounded-full bg-slate-900 text-white flex items-center justify-center shadow-lg hover:bg-black transition-colors disabled:opacity-60"
                                    title="Modifier la photo"
                                >
                                    <Camera size={18} />
                                </button>
                                <input
                                    ref={inputRef}
                                    type="file"
                                    accept="image/png,image/jpeg,image/webp,image/gif"
                                    className="hidden"
                                    onChange={handleFileChange}
                                />
                            </div>

                            <div>
                                <h3 className="text-2xl font-bold text-slate-900">{user.displayName}</h3>
                                <p className="text-slate-500">{user.email}</p>
                                <div className="mt-2 flex items-center gap-2 text-xs font-bold uppercase tracking-wider text-slate-500">
                                    <Shield size={14} />
                                    <span>{user.role === 'ADMIN' ? 'Administrateur' : 'Ergothérapeute'}</span>
                                </div>
                            </div>
                        </div>

                        <button
                            onClick={() => onLogout()}
                            className="px-4 py-3 rounded-full bg-slate-100 hover:bg-slate-200 text-slate-700 font-bold flex items-center gap-2 transition-colors"
                        >
                            <LogOut size={16} />
                            Se déconnecter
                        </button>
                    </div>

                    <div className="rounded-2xl border border-slate-200 bg-slate-50 px-5 py-4 text-sm text-slate-600">
                        <p className="font-semibold text-slate-900">Photo de profil</p>
                        <p className="mt-1">Choisis une image pour personnaliser ton compte. Elle sera réutilisée dans la barre latérale et dans l’espace paramètres.</p>
                        {isUploading && (
                            <SimpleLoader
                                label="Photo"
                                variant="button"
                                className="mt-3 w-fit text-[#907CA1]"
                            />
                        )}
                    </div>

                    {feedback && (
                        <div className={`rounded-2xl px-4 py-3 text-sm font-medium ${feedback.type === 'success' ? 'bg-emerald-50 text-emerald-700 border border-emerald-100' : 'bg-red-50 text-red-700 border border-red-100'}`}>
                            {feedback.message}
                        </div>
                    )}
                </div>
            )}
        </div>
    );
};
