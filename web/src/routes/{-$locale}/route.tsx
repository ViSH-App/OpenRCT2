import { Link, Outlet, createFileRoute, notFound, redirect } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import i18n from "../../i18n";
import { detectLocale, toLocale } from "../../i18n/locales";
import { LanguageSelect } from "../../components/LanguageSelect";

export const Route = createFileRoute("/{-$locale}")({
  beforeLoad: async ({ params, location }) => {
    const locale = toLocale(params.locale);
    if (params.locale !== undefined) {
      if (!locale) throw notFound();
      // Canonicalise casing, e.g. /zh-hans → /zh-Hans.
      if (locale !== params.locale) {
        throw redirect({ href: location.href.replace(`/${params.locale}`, `/${locale}`), replace: true });
      }
    }
    await i18n.changeLanguage(locale ?? detectLocale());
  },
  component: Layout,
});

function Layout() {
  const { t } = useTranslation();
  const { locale } = Route.useParams();

  return (
    <div className="flex min-h-screen flex-col">
      <header className="topbar">
        <nav className="mx-auto flex h-14 max-w-5xl items-center justify-between gap-4 px-4">
          <Link to="/{-$locale}" params={{ locale }} className="flex items-center gap-2 font-extrabold text-white">
            <img src="/icon.png" alt="" className="size-7" />
            <span className="max-sm:sr-only">OpenRCT2</span>
          </Link>
          <div className="flex items-center gap-5 text-sm">
            <Link
              to="/{-$locale}/privacy"
              params={{ locale }}
              className="whitespace-nowrap text-panel-hi hover:text-white [&.active]:text-yellow"
            >
              {t("nav.privacy")}
            </Link>
            <LanguageSelect />
          </div>
        </nav>
      </header>
      <main className="flex-1">
        <Outlet />
      </main>
      <footer className="footer">
        <div className="mx-auto max-w-5xl space-y-1 px-4 py-8 text-sm">
          <p>{t("footer.license")}</p>
          <p>{t("footer.trademark")}</p>
        </div>
      </footer>
    </div>
  );
}
