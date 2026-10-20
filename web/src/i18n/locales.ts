/** Locales shipped by the iOS launcher, with each language's name in that language. */
export const LOCALES = {
  ca: "Català",
  cs: "Čeština",
  da: "Dansk",
  de: "Deutsch",
  en: "English",
  eo: "Esperanto",
  es: "Español",
  fi: "Suomi",
  fr: "Français",
  gl: "Galego",
  hu: "Magyar",
  it: "Italiano",
  ja: "日本語",
  ko: "한국어",
  nb: "Norsk bokmål",
  nl: "Nederlands",
  pl: "Polski",
  "pt-BR": "Português (Brasil)",
  ru: "Русский",
  sv: "Svenska",
  tr: "Türkçe",
  uk: "Українська",
  vi: "Tiếng Việt",
  "zh-Hans": "简体中文",
  "zh-Hant": "繁體中文",
} as const;

export type Locale = keyof typeof LOCALES;

export const DEFAULT_LOCALE: Locale = "en";
const STORAGE_KEY = "locale";
const codes = Object.keys(LOCALES) as Locale[];

/** Matches a URL segment or browser tag case-insensitively, e.g. "zh-hans" → "zh-Hans". */
export function toLocale(tag: string | undefined): Locale | undefined {
  if (!tag) return undefined;
  const lower = tag.toLowerCase();
  const exact = codes.find((c) => c.toLowerCase() === lower);
  if (exact) return exact;
  if (lower.startsWith("zh")) {
    return /^zh-(hant|tw|hk|mo)/.test(lower) ? "zh-Hant" : "zh-Hans";
  }
  if (lower.startsWith("pt")) return "pt-BR";
  if (/^(no|nn)\b/.test(lower)) return "nb";
  return codes.find((c) => c === lower.split("-")[0]);
}

export function detectLocale(): Locale {
  try {
    const saved = toLocale(localStorage.getItem(STORAGE_KEY) ?? undefined);
    if (saved) return saved;
  } catch {
    // Storage may be unavailable; fall through to the browser languages.
  }
  for (const tag of navigator.languages ?? [navigator.language]) {
    const match = toLocale(tag);
    if (match) return match;
  }
  return DEFAULT_LOCALE;
}

export function rememberLocale(locale: Locale) {
  try {
    localStorage.setItem(STORAGE_KEY, locale);
  } catch {
    // Not persisting the choice is harmless.
  }
}
