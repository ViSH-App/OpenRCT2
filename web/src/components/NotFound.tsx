import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { useDocumentTitle } from "../useDocumentTitle";

export function NotFound() {
  const { t } = useTranslation();
  useDocumentTitle(t("notFound.title"));
  return (
    <div className="grid min-h-screen place-items-center bg-grass p-4">
      <div className="window max-w-sm">
        <h1 className="window-title">{t("notFound.title")}</h1>
        <div className="p-6">
          <Link to="/{-$locale}" className="underline underline-offset-4">
            {t("notFound.back")}
          </Link>
        </div>
      </div>
    </div>
  );
}
