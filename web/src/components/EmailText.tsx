import { CONTACT_EMAIL } from "../config";

/** Renders a translated string, turning the interpolated contact address into a mailto link. */
export function EmailText({ text }: { text: string }) {
  const [before, ...after] = text.split(CONTACT_EMAIL);
  if (after.length === 0) return text;
  return (
    <>
      {before}
      <a href={`mailto:${CONTACT_EMAIL}`} className="font-bold underline underline-offset-4">
        {CONTACT_EMAIL}
      </a>
      {after.join(CONTACT_EMAIL)}
    </>
  );
}
