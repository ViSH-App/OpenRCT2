import type { ReactNode } from "react";

/** A long-form page: a single window on the grass with a sunken text area. */
export function Document({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="bg-grass px-4 py-12">
      <article className="window mx-auto max-w-3xl">
        <h1 className="window-title">{title}</h1>
        <div className="paper m-2 px-6 py-8 sm:px-10">{children}</div>
      </article>
    </div>
  );
}
