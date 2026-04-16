import React, { useState } from 'react';
import { loginApp } from '../services/dataService';
import { AppUser } from '../types';
import { Lock } from 'lucide-react';
import { SimpleLoader } from './LoadingProgress';
import { uiFieldClass, uiModalClass, uiPrimaryButtonClass } from './uiTheme';

export const LoginView: React.FC<{ onAuthenticated: (user: AppUser) => void }> = ({ onAuthenticated }) => {
    const [loading, setLoading] = useState(false);
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [authError, setAuthError] = useState<string | null>(null);
    const handleLogin = async (e: React.FormEvent) => {
        e.preventDefault();
        setLoading(true);
        setAuthError(null);

        const result = await loginApp(email, password);
        if (!result.success || !result.user) {
            setAuthError(result.error || 'Connexion impossible');
        } else {
            onAuthenticated(result.user);
        }
        setLoading(false);
    };

    return (
        <div className="min-h-screen bg-[#C5D2D8] flex items-center justify-center p-4 transition-colors duration-300">
            <div className={`${uiModalClass} w-full max-w-md p-8 md:p-12`}>
                <div className="text-center mb-8">
                    <div className="w-16 h-16 bg-[#907CA1] rounded-2xl mx-auto flex items-center justify-center mb-4 shadow-lg transform rotate-3">
                        <Lock size={32} className="text-white" />
                    </div>
                    <h1 className="text-3xl font-bold text-slate-900 mb-2">Aid'Habitat</h1>
                    <p className="text-slate-500">Connectez-vous pour accéder à votre espace</p>

                    {/* Connection Diagnostic */}
                    <div className="mt-4 flex justify-center">
                    </div>
                </div>

                <form onSubmit={handleLogin} className="space-y-6">
                    <div>
                        <label className="block text-sm font-bold text-slate-500 mb-2 uppercase tracking-wider">Email</label>
                        <input
                            type="email"
                            value={email}
                            onChange={(e) => setEmail(e.target.value)}
                            className={uiFieldClass}
                            placeholder="votre@email.com"
                            required
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-bold text-slate-500 mb-2 uppercase tracking-wider">Mot de passe</label>
                        <input
                            type="password"
                            value={password}
                            onChange={(e) => setPassword(e.target.value)}
                            className={uiFieldClass}
                            placeholder="••••••••"
                            required
                        />
                    </div>

                    {authError && (
                        <div className="p-4 bg-red-50 text-red-600 rounded-xl text-sm font-medium border border-red-100">
                            {authError}
                        </div>
                    )}

                    <button
                        type="submit"
                        disabled={loading}
                        className={`${uiPrimaryButtonClass} w-full py-4 text-lg shadow-lg hover:shadow-xl hover:scale-[1.01] disabled:hover:scale-100`}
                    >
                        {loading ? (
                            <SimpleLoader
                                label="Connexion"
                                variant="button"
                                className="justify-center"
                            />
                        ) : 'Se connecter'}
                    </button>
                </form>

                <div className="mt-8 text-center">
                    <p className="text-xs text-slate-400">
                        © 2024 Aid'Habitat Manager. Tous droits réservés.
                    </p>
                </div>
            </div>
        </div>
    );
};
