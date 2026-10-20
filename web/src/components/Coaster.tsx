/** The launcher's loading-screen roller coaster, tiled across the page with the train riding over it. */
export function Coaster() {
  return (
    <div className="coaster" aria-hidden>
      <div className="coaster-supports" />
      <div className="coaster-track" />
      <div className="coaster-train" />
    </div>
  );
}
