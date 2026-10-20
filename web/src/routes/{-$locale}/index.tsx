import { createFileRoute } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { AppStoreButton } from "../../components/AppStoreButton";
import { Coaster } from "../../components/Coaster";
import { Window } from "../../components/Window";
import { useDocumentTitle } from "../../useDocumentTitle";

export const Route = createFileRoute("/{-$locale}/")({ component: Home });

const STEPS = ["buy", "transfer", "import"] as const;
const FEATURES = ["rct1", "metal", "saves", "languages", "mac", "offline"] as const;

function Home() {
  const { t } = useTranslation();
  useDocumentTitle(t("meta.title"));

  return (
    <>
      <section className="sky">
        <div className="mx-auto flex max-w-5xl flex-col items-center px-4 pt-14 pb-6 text-center">
          <img src="/sprites/logo_text.png" alt="" width={252} height={232} className="pixelated w-[189px] sm:w-[252px]" />
          <h1 className="mt-6 text-4xl font-extrabold tracking-tight text-ink sm:text-5xl">{t("hero.title")}</h1>
          <p className="mt-4 max-w-xl text-lg text-ink/80 text-balance">{t("hero.tagline")}</p>
          <div className="mt-8">
            <AppStoreButton />
          </div>
          <p className="mt-5 max-w-md text-sm text-ink/70 text-balance">{t("hero.requirement")}</p>
        </div>
        <Coaster />
      </section>

      <div className="bg-grass">
        <div className="mx-auto max-w-5xl space-y-10 px-4 py-14">
          <Window title={t("steps.title")}>
            <ol className="grid gap-6 md:grid-cols-3">
              {STEPS.map((key, i) => (
                <li key={key} className="flex gap-4">
                  <span className="step-number">{i + 1}</span>
                  <div>
                    <h3 className="font-extrabold">{t(`steps.${key}.title`)}</h3>
                    <p className="mt-1 leading-relaxed text-ink/80">{t(`steps.${key}.body`)}</p>
                  </div>
                </li>
              ))}
            </ol>
          </Window>

          <Window title={t("features.title")}>
            <dl className="grid gap-x-8 gap-y-6 sm:grid-cols-2 lg:grid-cols-3">
              {FEATURES.map((key) => (
                <div key={key} className="groove pt-4">
                  <dt className="font-extrabold">{t(`features.${key}.title`)}</dt>
                  <dd className="mt-1 leading-relaxed text-ink/80">{t(`features.${key}.body`)}</dd>
                </div>
              ))}
            </dl>
          </Window>
        </div>
      </div>
    </>
  );
}
