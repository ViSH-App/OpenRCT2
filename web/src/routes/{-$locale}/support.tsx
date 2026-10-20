import { createFileRoute } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { CONTACT_EMAIL } from "../../config";
import { Document } from "../../components/Document";
import { EmailText } from "../../components/EmailText";
import { useDocumentTitle } from "../../useDocumentTitle";

export const Route = createFileRoute("/{-$locale}/support")({ component: Support });

const QUESTIONS = ["files", "gog", "failed", "saves", "rct1"] as const;

function Support() {
  const { t } = useTranslation();
  useDocumentTitle(`${t("support.title")} · ${t("meta.title")}`);

  return (
    <Document title={t("support.title")}>
      <p className="leading-relaxed">{t("support.intro")}</p>

      <section className="mt-8">
        <h2 className="text-lg font-extrabold">{t("support.contact.title")}</h2>
        <p className="mt-2 text-lg">
          <EmailText text={t("support.contact.body", { email: CONTACT_EMAIL })} />
        </p>
        <p className="mt-2 text-sm leading-relaxed text-ink/70">{t("support.contact.hint")}</p>
      </section>

      <section className="mt-10">
        <h2 className="text-lg font-extrabold">{t("support.faq.title")}</h2>
        <div className="mt-3 space-y-3">
          {QUESTIONS.map((key) => (
            <details key={key} className="faq">
              <summary>{t(`support.faq.${key}.q`)}</summary>
              <p className="px-4 pb-4 leading-relaxed text-ink/85">{t(`support.faq.${key}.a`)}</p>
            </details>
          ))}
        </div>
      </section>
    </Document>
  );
}
