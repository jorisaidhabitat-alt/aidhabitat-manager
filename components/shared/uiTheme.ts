export const cx = (...parts: Array<string | false | null | undefined>) => parts.filter(Boolean).join(' ');

export const uiPanelClass = 'rounded-[28px] border border-slate-200 bg-white shadow-sm';
export const uiPanelInteractiveClass = `${uiPanelClass} transition-all duration-200 hover:border-[#907CA1] hover:shadow-md`;
export const uiModalClass = 'rounded-[32px] border border-slate-200 bg-white shadow-[0_24px_70px_rgba(15,23,42,0.18)]';
export const uiSoftPanelClass = 'rounded-[24px] border border-slate-200 bg-slate-50/75';

export const uiActionCardClass = `${uiPanelInteractiveClass} relative overflow-hidden text-left`;

export const uiLabelClass = 'mb-1 block text-[11px] font-bold uppercase tracking-[0.16em] text-slate-400';
export const uiFieldClass = 'w-full rounded-[18px] border border-slate-200 bg-slate-50 px-3.5 py-2.5 text-sm text-slate-800 outline-none transition-colors placeholder:text-slate-400 focus:border-[#907CA1] focus:ring-2 focus:ring-[#907CA1]/20';
export const uiFieldReadonlyClass = 'w-full rounded-[18px] border border-slate-200 bg-slate-50 px-3.5 py-2.5 text-sm text-slate-700';
export const uiFieldReadonlyAccentClass = 'w-full rounded-[18px] border border-[#d8cfe0] bg-[#f3edf7] px-3.5 py-2.5 text-sm text-[#554A63] shadow-[inset_0_1px_0_rgba(255,255,255,0.72)]';
export const uiFieldWarningClass = 'border-amber-400 pr-10 text-amber-700 focus:border-amber-400 focus:ring-2 focus:ring-amber-200';

export const uiBadgeNeutralClass = 'inline-flex items-center rounded-full border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-600';
export const uiBadgeAccentClass = 'inline-flex items-center rounded-full border border-[#d8cfe0] bg-[#f3edf7] px-3 py-1.5 text-xs font-semibold text-[#5c4b6d] shadow-[inset_0_1px_0_rgba(255,255,255,0.75)]';

export const uiIconButtonClass = 'flex h-11 w-11 items-center justify-center rounded-full border border-slate-200 bg-white text-slate-700 shadow-sm transition-colors hover:bg-slate-50';
export const uiPrimaryButtonClass = 'inline-flex items-center justify-center gap-2 rounded-[18px] bg-[#907CA1] px-4 py-2.5 font-semibold text-white transition-colors hover:bg-[#7a668a] disabled:cursor-not-allowed disabled:opacity-50';
export const uiSecondaryButtonClass = 'inline-flex items-center justify-center gap-2 rounded-[18px] border border-slate-200 bg-white px-4 py-2.5 font-semibold text-slate-700 transition-colors hover:bg-slate-50';
export const uiDangerButtonClass = 'inline-flex items-center justify-center gap-2 rounded-[18px] bg-red-500 px-4 py-2.5 font-semibold text-white transition-colors hover:bg-red-600 disabled:cursor-not-allowed disabled:opacity-50';

export const uiChipBaseClass = 'rounded-full border px-3 py-1.5 text-xs font-semibold transition-colors';
export const uiChipActiveClass = 'border-[#907CA1] bg-[#907CA1] text-white';
export const uiChipInactiveClass = 'border-slate-200 bg-white text-slate-600 hover:border-[#c6b8d1] hover:text-[#554A63]';
