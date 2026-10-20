import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import resourcesToBackend from "i18next-resources-to-backend";
import en from "../locales/en.json";
import { DEFAULT_LOCALE, LOCALES } from "./locales";

i18n
  .use(initReactI18next)
  // English is bundled as the fallback; every other locale is a lazily loaded chunk.
  .use(resourcesToBackend((lng: string) => import(`../locales/${lng}.json`)))
  .init({
    resources: { en: { translation: en } },
    partialBundledLanguages: true,
    fallbackLng: DEFAULT_LOCALE,
    supportedLngs: Object.keys(LOCALES),
    load: "currentOnly",
    interpolation: { escapeValue: false },
    react: { useSuspense: false },
  });

i18n.on("languageChanged", (lng) => {
  document.documentElement.lang = lng;
  document
    .querySelector('meta[name="description"]')
    ?.setAttribute("content", i18n.t("meta.description"));
});

export default i18n;
