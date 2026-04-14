import React from 'react';

const normalizeCommuneQuery = (value: string) => String(value || '')
  .normalize('NFD')
  .replace(/[\u0300-\u036f]/g, '')
  .toLowerCase()
  .replace(/['’`-]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();

export interface CommuneOption {
  id: string;
  label: string;
  zipCode: string;
  epciId?: string;
  epciLabel?: string;
}

interface CommuneFieldGroupProps {
  city: string;
  zipCode: string;
  cityId?: string;
  options?: CommuneOption[];
  onChange: (updates: { city?: string; zipCode?: string; cityId?: string }) => void;
  zipLabel?: string;
  cityLabel?: string;
  showZipField?: boolean;
}

export const CommuneFieldGroup: React.FC<CommuneFieldGroupProps> = ({
  city,
  zipCode,
  cityId,
  options = [],
  onChange,
  zipLabel = 'CP',
  cityLabel = 'Ville',
  showZipField = true,
}) => {
  const [isCityMenuOpen, setIsCityMenuOpen] = React.useState(false);
  const [isCityInputFocused, setIsCityInputFocused] = React.useState(false);
  const normalizedOptions = React.useMemo(
    () => options.filter((option) => option.id && option.label),
    [options],
  );

  const optionsById = React.useMemo(
    () => new Map(normalizedOptions.map((option) => [option.id, option])),
    [normalizedOptions],
  );

  const resolvedCityId = React.useMemo(() => {
    if (cityId && optionsById.has(cityId)) return cityId;
    const normalizedCity = normalizeCommuneQuery(city);
    const normalizedZipCode = String(zipCode || '').trim();
    if (!normalizedCity) return '';

    const exactMatches = normalizedOptions.filter(
      (option) =>
        normalizeCommuneQuery(option.label) === normalizedCity
        && (!normalizedZipCode || option.zipCode === normalizedZipCode),
    );
    if (exactMatches.length === 1) return exactMatches[0].id;
    if (normalizedZipCode && exactMatches.length > 1) return exactMatches[0].id;

    const byNameMatches = normalizedOptions.filter(
      (option) => normalizeCommuneQuery(option.label) === normalizedCity,
    );
    if (byNameMatches.length === 1) return byNameMatches[0].id;
    return '';
  }, [city, cityId, optionsById, normalizedOptions, zipCode]);

  const filteredOptions = React.useMemo(() => {
    const query = normalizeCommuneQuery(city);
    if (!query) return normalizedOptions;
    return normalizedOptions
      .filter((option) => (
        normalizeCommuneQuery(option.label).includes(query)
        || option.zipCode.includes(String(city || '').trim())
      ));
  }, [city, normalizedOptions]);

  React.useEffect(() => {
    if (!resolvedCityId) return;
    if (isCityInputFocused && !cityId) return;
    const selected = optionsById.get(resolvedCityId);
    if (!selected) return;
    if (
      cityId === selected.id
      && String(city || '').trim() === selected.label
      && String(zipCode || '').trim() === selected.zipCode
    ) {
      return;
    }
    onChange({
      cityId: selected.id,
      city: selected.label,
      zipCode: selected.zipCode,
    });
  }, [city, cityId, isCityInputFocused, onChange, optionsById, resolvedCityId, zipCode]);

  const applyCommuneSelection = React.useCallback((option: CommuneOption) => {
    onChange({
      cityId: option.id,
      city: option.label,
      zipCode: option.zipCode,
    });
    setIsCityMenuOpen(false);
  }, [onChange]);

  return (
    <div className={`mb-2.5 grid gap-2 ${showZipField ? 'grid-cols-2' : 'grid-cols-1'}`}>
      {showZipField ? (
        <div>
          <label className="mb-1 block text-xs font-bold uppercase tracking-wider text-slate-400">{zipLabel}</label>
          <input
            type="text"
            value={zipCode}
            readOnly
            className="w-full rounded-lg border border-slate-200 bg-slate-100 px-3 py-2.5 text-sm text-slate-600 outline-none"
          />
        </div>
      ) : null}
      <div className={`relative ${isCityMenuOpen ? 'z-[120]' : ''}`}>
        <label className="mb-1 block text-xs font-bold uppercase tracking-wider text-slate-400">{cityLabel}</label>
        <input
          type="text"
          value={city}
          onFocus={() => {
            setIsCityInputFocused(true);
            setIsCityMenuOpen(true);
          }}
          onBlur={() => {
            setIsCityInputFocused(false);
            window.setTimeout(() => setIsCityMenuOpen(false), 120);
          }}
          onChange={(event) => {
            const typed = event.target.value;
            setIsCityMenuOpen(true);
            if (!typed) {
              onChange({ city: '', zipCode: '', cityId: '' });
              return;
            }
            onChange({ city: typed, cityId: '', zipCode: '' });

            const exactMatches = normalizedOptions.filter(
              (option) => normalizeCommuneQuery(option.label) === normalizeCommuneQuery(typed),
            );
            const hasTrimMismatch = typed !== typed.trim();
            if (!hasTrimMismatch && exactMatches.length === 1) {
              const selected = exactMatches[0];
              onChange({
                cityId: selected.id,
                city: selected.label,
                zipCode: selected.zipCode,
              });
            }
          }}
          className="w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2.5 text-sm outline-none transition-colors focus:border-[#907CA1] focus:ring-2 focus:ring-[#907CA1]/20"
        />
        {isCityMenuOpen && filteredOptions.length > 0 ? (
          <div className="absolute left-0 right-0 z-[140] mt-1 max-h-[112px] w-full overflow-y-auto rounded-xl border border-slate-200 bg-white shadow-xl">
            {filteredOptions.map((option) => (
              <button
                key={option.id}
                type="button"
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => applyCommuneSelection(option)}
                className={`flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-slate-50 ${
                  option.id === resolvedCityId ? 'bg-[#F4EFF7] text-[#554A63]' : 'text-slate-700'
                }`}
              >
                <span className="truncate pr-2">{option.label}</span>
                <span className="text-xs text-slate-400">({option.zipCode || '—'})</span>
              </button>
            ))}
          </div>
        ) : null}
      </div>
    </div>
  );
};
