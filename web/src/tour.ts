/** "How to play": a short guided tour, a few words per step, that points at each part of the page. */

interface Stop {
  target?: string;
  title: string;
  text: string;
}

const STOPS: Stop[] = [
  { title: "You play the villain", text: "Three moves. One minute." },
  { target: "step-1", title: "1 · Move the market", text: "You run the stock exchange. Pick a move." },
  { target: "step-2", title: "2 · Watch the clock", text: "Reactive switches both pools in ~2 s. No wallet? Press Replay." },
  { target: "step-3", title: "3 · Raid a pool", text: "Buy at the old price. Protected pool: safe. Twin: robbed." },
  { target: "bell-log", title: "Real market", text: "Same contracts. Real NVIDIA bells, every trading day." },
];

let at = -1;
let shade: HTMLDivElement | undefined;
let ring: HTMLDivElement | undefined;
let card: HTMLDivElement | undefined;

function visible(id?: string): HTMLElement | undefined {
  const node = id ? document.getElementById(id) : null;
  return node && !node.hidden && node.offsetParent !== null ? node : undefined;
}

function place(): void {
  if (!ring || !card || at < 0) return;
  const node = visible(STOPS[at].target);
  if (!node) {
    ring.hidden = true;
    shade!.classList.add("solid");
    card.style.top = "50%";
    card.style.transform = "translate(-50%, -50%)";
    return;
  }
  shade!.classList.remove("solid");
  const r = node.getBoundingClientRect();
  const pad = 6;
  ring.hidden = false;
  Object.assign(ring.style, { top: r.top - pad + "px", left: r.left - pad + "px", width: r.width + pad * 2 + "px", height: r.height + pad * 2 + "px" });
  const h = card.offsetHeight;
  const below = r.bottom + pad + 12;
  const above = r.top - pad - 12 - h;
  const top = below + h < window.innerHeight - 8 ? below : above > 8 ? above : window.innerHeight - h - 16;
  card.style.top = Math.max(8, top) + "px";
  card.style.transform = "translateX(-50%)";
}

function show(i: number): void {
  at = i;
  const stop = STOPS[i];
  card!.replaceChildren(
    Object.assign(document.createElement("span"), { className: "tour-count", textContent: i + 1 + " / " + STOPS.length }),
    Object.assign(document.createElement("strong"), { className: "tour-title", textContent: stop.title }),
    Object.assign(document.createElement("p"), { className: "tour-text", textContent: stop.text }),
    buttons(i),
  );
  const node = visible(stop.target);
  if (node) node.scrollIntoView({ block: "center", behavior: "smooth" });
  place();
  window.setTimeout(place, 450);
  (card!.querySelector(".tour-next") as HTMLButtonElement | null)?.focus({ preventScroll: true });
}

function buttons(i: number): HTMLDivElement {
  const row = Object.assign(document.createElement("div"), { className: "tour-buttons" });
  const skip = Object.assign(document.createElement("button"), { type: "button", className: "tour-skip", textContent: i === 0 ? "Skip" : "Back" });
  skip.onclick = () => (i === 0 ? end() : show(i - 1));
  const last = i === STOPS.length - 1;
  const next = Object.assign(document.createElement("button"), { type: "button", className: "tour-next", textContent: last ? "Play" : "Next" });
  next.onclick = () => (last ? end(true) : show(i + 1));
  row.append(skip, next);
  return row;
}

function onKey(e: KeyboardEvent): void {
  if (e.key === "Escape") end();
  else if (e.key === "ArrowRight") at < STOPS.length - 1 ? show(at + 1) : end(true);
  else if (e.key === "ArrowLeft" && at > 0) show(at - 1);
}

function end(play = false): void {
  at = -1;
  shade?.remove();
  ring?.remove();
  card?.remove();
  shade = ring = card = undefined;
  window.removeEventListener("resize", place);
  window.removeEventListener("scroll", place);
  window.removeEventListener("keydown", onKey);
  if (play) document.getElementById("step-1")?.scrollIntoView({ block: "center", behavior: "smooth" });
}

export function startTour(): void {
  if (card) return;
  shade = Object.assign(document.createElement("div"), { className: "tour-shade" });
  shade.onclick = () => end();
  ring = Object.assign(document.createElement("div"), { className: "tour-ring" });
  card = Object.assign(document.createElement("div"), { className: "tour-card" });
  card.setAttribute("role", "dialog");
  card.setAttribute("aria-label", "How to play");
  document.body.append(shade, ring, card);
  window.addEventListener("resize", place);
  window.addEventListener("scroll", place, { passive: true });
  window.addEventListener("keydown", onKey);
  show(0);
}
