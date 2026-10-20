import { useNavigate } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { LOCALES, rememberLocale, type Locale } from "../i18n/locales";

export function LanguageSelect() {
  const { t, i18n } = useTranslation();
  const navigate = useNavigate();

  return (
    <label className="flex items-center gap-2">
      <span className="sr-only">{t("nav.language")}</span>
      <select
        className="lang-select"
        value={i18n.resolvedLanguage}
        onChange={(e) => {
          const locale = e.target.value as Locale;
          rememberLocale(locale);
          navigate({ to: ".", params: (prev) => ({ ...prev, locale }) });
        }}
      >
        {Object.entries(LOCALES).map(([code, name]) => (
          <option key={code} value={code} lang={code}>
            {name}
          </option>
        ))}
      </select>
    </label>
  );
}
