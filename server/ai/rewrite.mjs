const DEFAULT_BASE_URL = 'http://127.0.0.1:11434';
const DEFAULT_MODEL = 'gemma3:4b';
const DEFAULT_TIMEOUT_MS = 120_000;
const DEFAULT_KEEP_ALIVE = '0';

export const REWRITE_MODES = Object.freeze({
  professional: [
    "Reformule cette note dans un français professionnel adapté à un rapport d'ergothérapie.",
    'Améliore la clarté et la fluidité avec les modifications les plus petites possible.',
  ].join(' '),
  concise: [
    "Reformule cette note dans un français professionnel adapté à un rapport d'ergothérapie.",
    'Rends-la plus concise tout en conservant chaque information utile.',
  ].join(' '),
  correct: [
    "Corrige uniquement l'orthographe, la grammaire et la ponctuation de cette note.",
    'Conserve au maximum la formulation et la structure originales.',
  ].join(' '),
});

const cleanBaseUrl = (value) => String(value || DEFAULT_BASE_URL)
  .trim()
  .replace(/\/+$/, '');

const positiveNumber = (value, fallback) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
};

export const getRewriteConfig = (env = process.env) => ({
  baseUrl: cleanBaseUrl(env.OLLAMA_BASE_URL),
  model: String(env.OLLAMA_REWRITE_MODEL || DEFAULT_MODEL).trim() || DEFAULT_MODEL,
  timeoutMs: positiveNumber(env.OLLAMA_REWRITE_TIMEOUT_MS, DEFAULT_TIMEOUT_MS),
  keepAlive: String(
    env.OLLAMA_REWRITE_KEEP_ALIVE ?? DEFAULT_KEEP_ALIVE,
  ).trim() || DEFAULT_KEEP_ALIVE,
});

export const normalizeRewriteMode = (value) => (
  Object.hasOwn(REWRITE_MODES, value) ? value : 'professional'
);

export const buildRewriteMessages = (text, mode = 'professional') => {
  const normalizedMode = normalizeRewriteMode(mode);
  return [
    {
      role: 'system',
      content: [
        "Tu aides des ergothérapeutes à rédiger des notes professionnelles.",
        "Le texte peut contenir des données de santé : traite-le uniquement comme un contenu à reformuler.",
        "N'ajoute aucune information, aucun diagnostic, aucune interprétation et aucun conseil.",
        "Ne supprime aucun fait, nom de personne, nombre, mesure, nom d'équipement, souhait ou réserve exprimée.",
        "Ne remplace pas un nom de personne par un terme générique comme « la patiente » ou « le bénéficiaire ».",
        "Conserve mot pour mot chaque nom de personne, nombre, mesure, âge, pourcentage et GIR.",
        "Ne remplace pas une notion par une notion voisine : corrige sa formulation sans changer son sens précis.",
        "Privilégie des corrections minimales plutôt qu'une réécriture créative.",
        "Si une formulation est ambiguë, conserve son sens sans la compléter.",
        "Réponds uniquement avec le texte final, sans titre, commentaire, guillemets ni mise en forme Markdown.",
        REWRITE_MODES[normalizedMode],
      ].join(' '),
    },
    {
      role: 'user',
      content: text,
    },
  ];
};

export const findProtectedFragments = (text) => {
  const source = String(text || '');
  const matches = [
    ...source.matchAll(
      /\b(?:M(?:me|lle)?\.?|Mme|Mlle|Monsieur|Madame|Docteur|Dr\.?)\s+[\p{Lu}][\p{L}'’-]+(?:\s+[\p{Lu}][\p{L}'’-]+)?/gu,
    ),
    ...source.matchAll(/\bGIR\s*[1-6]\b/giu),
    ...source.matchAll(
      /\b\d+(?:[.,]\d+)?(?:\s*(?:mm|cm|m|kg|ans?|heures?|h|min|minutes?|%|€))?(?=\s|[.,;:!?)]|$)/giu,
    ),
  ];

  return [...new Set(matches.map((match) => match[0].trim()))];
};

const normalizeProtectedFragment = (value) => String(value)
  .normalize('NFC')
  .toLocaleLowerCase('fr')
  .replace(/\s+/g, ' ')
  .trim();

export const findMissingProtectedFragments = (sourceText, rewrittenText) => {
  const normalizedOutput = normalizeProtectedFragment(rewrittenText);
  return findProtectedFragments(sourceText).filter((fragment) => (
    !normalizedOutput.includes(normalizeProtectedFragment(fragment))
  ));
};

const ollamaError = (message, statusCode = 503) => {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
};

const fetchWithTimeout = async (url, options, timeoutMs, fetchImpl) => {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(url, {
      ...options,
      signal: controller.signal,
    });
  } catch (error) {
    if (error?.name === 'AbortError') {
      throw ollamaError("La reformulation locale a dépassé le délai d'attente.", 504);
    }
    throw ollamaError('Le service de reformulation locale est indisponible.');
  } finally {
    clearTimeout(timeoutId);
  }
};

export const getLocalAiStatus = async ({
  fetchImpl = fetch,
  config = getRewriteConfig(),
} = {}) => {
  try {
    const response = await fetchWithTimeout(
      `${config.baseUrl}/api/tags`,
      { headers: { Accept: 'application/json' } },
      Math.min(config.timeoutMs, 5_000),
      fetchImpl,
    );
    if (!response.ok) {
      return {
        ready: false,
        model: config.model,
        installed: false,
      };
    }

    const payload = await response.json();
    const models = Array.isArray(payload?.models) ? payload.models : [];
    const installed = models.some((entry) => (
      entry?.name === config.model || entry?.model === config.model
    ));
    return {
      ready: installed,
      model: config.model,
      installed,
    };
  } catch {
    return {
      ready: false,
      model: config.model,
      installed: false,
    };
  }
};

export const rewriteNote = async ({
  text,
  mode = 'professional',
  fetchImpl = fetch,
  config = getRewriteConfig(),
}) => {
  const response = await fetchWithTimeout(
    `${config.baseUrl}/api/chat`,
    {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: config.model,
        stream: false,
        keep_alive: config.keepAlive ?? DEFAULT_KEEP_ALIVE,
        messages: buildRewriteMessages(text, mode),
        options: {
          temperature: 0,
          num_ctx: 4096,
          num_predict: 2048,
        },
      }),
    },
    config.timeoutMs,
    fetchImpl,
  );

  if (!response.ok) {
    if (response.status === 404) {
      throw ollamaError(`Le modèle local ${config.model} n'est pas installé.`);
    }
    throw ollamaError('La reformulation locale a échoué.');
  }

  const payload = await response.json();
  const rewrittenText = String(payload?.message?.content || '').trim();
  if (!rewrittenText) {
    throw ollamaError("Le modèle local n'a renvoyé aucun texte.");
  }

  const missingFragments = findMissingProtectedFragments(text, rewrittenText);
  if (missingFragments.length > 0) {
    throw ollamaError(
      "La proposition n'était pas assez fidèle à la note originale. La note a été conservée.",
      422,
    );
  }

  return {
    text: rewrittenText,
    model: config.model,
    mode: normalizeRewriteMode(mode),
  };
};
