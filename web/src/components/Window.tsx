import type { ReactNode } from "react";

/** An RCT2-style window: bevelled panel with a title bar. */
export function Window({ title, children, className = "" }: { title: string; children: ReactNode; className?: string }) {
  return (
    <section className={`window ${className}`}>
      <h2 className="window-title">{title}</h2>
      <div className="p-5 sm:p-7">{children}</div>
    </section>
  );
}
