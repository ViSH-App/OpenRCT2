import { createFileRoute } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { CONTACT_EMAIL, PRIVACY_UPDATED } from "../../config";
import { useDocumentTitle } from "../../useDocumentTitle";

export const Route = createFileRoute("/{-$locale}/privacy")({ component: Privacy });

const SECTIONS = [
  "collection",
  "device",
  "imports",
  "thirdParties",
  "retention",
  "permissions",
  "children",
  "changes",
] as const;

function Privacy() {
  const { t, i18n } = useTranslation();
  useDocumentTitle(`${t("privacy.title")} · ${t("meta.title")}`);
  const date = new Intl.DateTimeFormat(i18n.resolvedLanguage, { dateStyle: "long", timeZone: "UTC" }).format(
    PRIVACY_UPDATED,
  );

  return (
    <div className="bg-grass px-4 py-12">
      <article className="window mx-auto max-w-3xl">
        <h1 className="window-title">{t("privacy.title")}</h1>
        <div className="paper m-2 px-6 py-8 sm:px-10">
          <p className="text-sm text-ink/60">{t("privacy.updated", { date })}</p>
          <p className="mt-5 leading-relaxed">{t("privacy.intro")}</p>
          {SECTIONS.map((key) => (
            <section key={key} className="mt-8">
              <h2 className="text-lg font-extrabold">{t(`privacy.${key}.title`)}</h2>
              <p className="mt-2 leading-relaxed text-ink/85">{t(`privacy.${key}.body`)}</p>
            </section>
          ))}
          <section className="mt-8">
            <h2 className="text-lg font-extrabold">{t("privacy.contact.title")}</h2>
            <p className="mt-2 leading-relaxed text-ink/85">
              {t("privacy.contact.body", { email: CONTACT_EMAIL }).split(CONTACT_EMAIL).flatMap((part, i) =>
                i === 0 ? [part] : [<a key={i} href={`mailto:${CONTACT_EMAIL}`} className="underline underline-offset-4">{CONTACT_EMAIL}</a>, part],
              )}
            </p>
          </section>
        </div>
      </article>
    </div>
  );
}
