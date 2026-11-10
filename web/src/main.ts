import {
  createWalletClient,
  custom,
  decodeEventLog,
  numberToHex,
  type Address,
  type Hash,
  type Hex,
  type PublicClient,
  type TransactionReceipt,
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
} from "viem";
import { arenaAbi, conductorAbi, feedAbi, guardAbi, stageAbi } from "../../tools/src/abi.ts";
import {
  MARKET_ID,
  VENUES,
  blockTimeMs,
  explorerAddress,
  explorerTx,
  gapPct,
  loadConfig,
  makeClients,
  seconds,
  toChain,
  usd,
  usdShort,
  type ChainKey,
  type Clients,
  type Config,
  type VenueKey,
} from "./net.ts";

// -------------------------------------------------------------------------------------------------
// State
// -------------------------------------------------------------------------------------------------

const STATUS_NAMES = ["Closed", "Open", "Halted"] as const;
const CLOSED = 0;
const OPEN = 1;
const HALTED = 2;

interface Market {
  status: number;
  seq: bigint;
  price: bigint;
}

interface PoolView {
  poolPrice: bigint;
  refPrice: bigint;
  tradable: boolean;
  feePips: number;
  taken: bigint;
}

interface VenueView {
  guardStatus: number;
  guardSeq: bigint;
  protected: PoolView;
  twin: PoolView;
  loot: bigint;
}

interface Hop {
  block: bigint;
  tx: Hash;
  ms?: number;
  precise?: boolean;
}

interface Loop {
  seq: bigint;
  status: number;
  price: bigint;
  feed?: Hop;
  observed?: Hop;
  applied: Partial<Record<VenueKey, Hop>>;
  closed?: Hop;
  seenAt: number;
}

interface LogEntry {
  at: number;
  text: string;
  tone: "good" | "bad" | "neutral";
  chain?: ChainKey;
  tx?: Hash;
}

let config: Config;
let clients: Clients;
let market: Market | undefined;
const venues: Partial<Record<VenueKey, VenueView>> = {};
const loops = new Map<bigint, Loop>();
let latestLoop: Loop | undefined;
let account: Address | undefined;
let stageReadyAt = 0;
let stageLeft = 0n;
let busy = false;
const history: LogEntry[] = [];
/** Lowest block each chain's event searches start from. Set at start-up to a recent window. */
const scanFrom: Partial<Record<ChainKey, bigint>> = {};

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const eth = (window as unknown as { ethereum?: Eip1193 }).ethereum;

interface Eip1193 {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>;
  on?(event: string, handler: (...args: unknown[]) => void): void;
}

// -------------------------------------------------------------------------------------------------
// Reading the chains
// -------------------------------------------------------------------------------------------------

async function readMarket(): Promise<Market> {
  const [status, seq, , price] = await clients.base.readContract({
    address: config.origin.feed,
    abi: feedAbi,
    functionName: "markets",
    args: [MARKET_ID],
  });
  return { status, seq, price };
}

async function readVenue(key: VenueKey): Promise<VenueView | undefined> {
  const v = config.venues[key];
  if (!v) return undefined;
  const client = clients[key];
  const scout = (id: bigint) => client.readContract({ address: v.arena, abi: arenaAbi, functionName: "scout", args: [id] });
  const taken = (id: bigint) => client.readContract({ address: v.arena, abi: arenaAbi, functionName: "taken", args: [id] });

  const [guard, p, t, takenP, takenT, loot] = await Promise.all([
    client.readContract({ address: v.guard, abi: guardAbi, functionName: "current", args: [MARKET_ID] }),
    scout(0n),
    scout(1n),
    taken(0n),
    taken(1n),
    account
      ? client.readContract({ address: v.arena, abi: arenaAbi, functionName: "loot", args: [account] })
      : Promise.resolve(0n),
  ]);
  const pool = (s: readonly [bigint, bigint, boolean, number], tk: bigint): PoolView => ({
    poolPrice: s[0],
    refPrice: s[1],
    tradable: s[2],
    feePips: s[3],
    taken: tk,
  });
  return { guardStatus: guard[0], guardSeq: guard[4], protected: pool(p, takenP), twin: pool(t, takenT), loot };
}

async function readStage(): Promise<void> {
  const [readyAt, left] = await clients.base.readContract({
    address: config.origin.stage,
    abi: stageAbi,
    functionName: "availability",
  });
  stageReadyAt = Number(readyAt) * 1000;
  stageLeft = left;
}

/** Fills in whatever hops of a loop have landed since the last look. */
async function advance(loop: Loop): Promise<void> {
  const jobs: Promise<void>[] = [];

  if (!loop.feed) {
    jobs.push(
      (async () => {
        const logs = await clients.base.getContractEvents({
          address: config.origin.feed,
          abi: feedAbi,
          eventName: "MarketUpdate",
          args: { marketId: MARKET_ID },
          fromBlock: scanFrom.base,
        });
        const log = logs.find((l) => l.args.seq === loop.seq);
        if (log) loop.feed = await hop(clients.base, log.blockNumber, log.transactionHash);
      })(),
    );
  }

  if (!loop.observed || !loop.closed) {
    jobs.push(
      (async () => {
        const find = async (eventName: "Observed" | "LoopClosed") => {
          const logs = await clients.lasna.getContractEvents({
            address: config.reactive.conductor,
            abi: conductorAbi,
            eventName,
            args: { marketId: MARKET_ID, seq: loop.seq },
            fromBlock: scanFrom.lasna,
          });
          return logs[0];
        };
        if (!loop.observed) {
          const log = await find("Observed");
          if (log) loop.observed = { block: log.blockNumber, tx: log.transactionHash };
        }
        if (loop.observed && !loop.closed) {
          const log = await find("LoopClosed");
          if (log) loop.closed = { block: log.blockNumber, tx: log.transactionHash };
        }
      })(),
    );
  }

  for (const key of VENUES) {
    const v = config.venues[key];
    if (!v || loop.applied[key]) continue;
    jobs.push(
      (async () => {
        const logs = await clients[key].getContractEvents({
          address: v.guard,
          abi: guardAbi,
          eventName: "Applied",
          args: { marketId: MARKET_ID, seq: loop.seq },
          fromBlock: scanFrom[key],
        });
        const log = logs[0];
        if (log) loop.applied[key] = await hop(clients[key], log.blockNumber, log.transactionHash);
      })(),
    );
  }

  await Promise.all(jobs);
}

async function hop(client: PublicClient, block: bigint, tx: Hash): Promise<Hop> {
  const time = await blockTimeMs(client, block);
  return { block, tx, ms: time.ms, precise: time.precise };
}

function loopDone(loop: Loop): boolean {
  return Boolean(loop.feed && loop.observed && loop.closed && VENUES.every((k) => !config.venues[k] || loop.applied[k]));
}

async function refresh(): Promise<void> {
  const [m, ...views] = await Promise.all([readMarket(), ...VENUES.map(readVenue), readStage()]);
  VENUES.forEach((key, i) => {
    const view = views[i];
    if (view) venues[key] = view;
  });

  if (!market || m.seq !== market.seq) {
    if (m.seq > 0n && !loops.has(m.seq)) {
      const loop: Loop = { seq: m.seq, status: m.status, price: m.price, applied: {}, seenAt: Date.now() };
      loops.set(m.seq, loop);
      latestLoop = loop;
    }
  }
  market = m;

  if (latestLoop && !loopDone(latestLoop)) await advance(latestLoop);
  render();
}

// -------------------------------------------------------------------------------------------------
// Wallet
// -------------------------------------------------------------------------------------------------

async function connect(): Promise<Address | undefined> {
  if (!eth) {
    toast("No wallet found. Install MetaMask to play; you can still watch.", "bad");
    return undefined;
  }
  const accounts = (await eth.request({ method: "eth_requestAccounts" })) as Address[];
  account = accounts[0];
  render();
  return account;
}

async function ensureChain(key: ChainKey): Promise<void> {
  if (!eth) throw new Error("no wallet");
  const info = config.chains[key];
  const wanted = numberToHex(info.id);
  const current = (await eth.request({ method: "eth_chainId" })) as string;
  if (current.toLowerCase() === wanted.toLowerCase()) return;
  try {
    await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: wanted }] });
  } catch (error) {
    const code = (error as { code?: number }).code;
    if (code !== 4902 && code !== -32603) throw error;
    await eth.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId: wanted,
          chainName: info.name,
          nativeCurrency: { name: info.currency, symbol: info.currency, decimals: 18 },
          rpcUrls: [info.rpc],
          blockExplorerUrls: [info.explorer],
        },
      ],
    });
  }
}

type Write = {
  key: ChainKey;
  address: Address;
  abi: typeof stageAbi | typeof arenaAbi;
  functionName: string;
  args: readonly unknown[];
};

/** Simulates first (so reverts come back readable), then sends from the player's wallet. */
async function send(write: Write): Promise<TransactionReceipt> {
  const from = account ?? (await connect());
  if (!from || !eth) throw new Error("connect a wallet first");
  await ensureChain(write.key);

  const client = clients[write.key];
  const { request } = await client.simulateContract({
    account: from,
    address: write.address,
    abi: write.abi as typeof arenaAbi,
    functionName: write.functionName as "raid",
    args: write.args as [bigint],
  });
  const wallet = createWalletClient({ chain: toChain(config.chains[write.key]), transport: custom(eth), account: from });
  const hash = await wallet.writeContract(request);
  return client.waitForTransactionReceipt({ hash });
}

function explain(error: unknown): string {
  if (error instanceof BaseError) {
    if (error.walk((e) => e instanceof UserRejectedRequestError)) return "You cancelled the transaction.";
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName;
      if (name === "CoolingDown") return "The exchange takes one action every few seconds. Try again in a moment.";
      if (name === "DailyCapReached") return "The exchange has used up today's actions. Come back tomorrow.";
      if (name === "Paused") return "The exchange is paused for maintenance.";
      if (name) return "Refused: " + name;
    }
    if (/insufficient funds/i.test(error.message)) return "Your wallet needs a little test ETH on this network to pay gas.";
    return error.shortMessage;
  }
  return error instanceof Error ? error.message : String(error);
}

// -------------------------------------------------------------------------------------------------
// Actions
// -------------------------------------------------------------------------------------------------

const ACTIONS: Record<number, { label: string; hint: string; status: number; move: number; tone: string }[]> = {
  [OPEN]: [
    { label: "Halt trading", hint: "News is coming. Freeze everything.", status: HALTED, move: 0, tone: "halt" },
    { label: "Price drops 10%", hint: "No halt: race Reactive to the stale pools.", status: OPEN, move: -1000, tone: "move" },
    { label: "Ring the closing bell", hint: "After-hours: wide range, high fee.", status: CLOSED, move: 0, tone: "bell" },
  ],
  [HALTED]: [
    { label: "Resume 10% lower", hint: "Bad news. Who sold at the old price?", status: OPEN, move: -1000, tone: "move" },
    { label: "Resume 10% higher", hint: "Good news. Who bought at the old price?", status: OPEN, move: 1000, tone: "move" },
  ],
  [CLOSED]: [
    { label: "Open 10% higher", hint: "Earnings beat overnight.", status: OPEN, move: 1000, tone: "bell" },
    { label: "Open 10% lower", hint: "Earnings miss overnight.", status: OPEN, move: -1000, tone: "bell" },
  ],
};

async function act(status: number, move: number, label: string): Promise<void> {
  if (busy) return;
  busy = true;
  render();
  try {
    const receipt = await send({
      key: "base",
      address: config.origin.stage,
      abi: stageAbi,
      functionName: "act",
      args: [status, move],
    });
    note(label + ". Reactive is on it.", "neutral", "base", receipt.transactionHash);
    await refresh();
  } catch (error) {
    toast(explain(error), "bad");
  } finally {
    busy = false;
    render();
  }
}

async function raid(key: VenueKey, target: 0 | 1): Promise<void> {
  if (busy) return;
  const v = config.venues[key];
  if (!v) return;
  busy = true;
  render();
  const pending = latestLoop && !latestLoop.applied[key];
  const name = (target === 0 ? "protected pool" : "unprotected twin") + " on " + config.chains[key].short;
  try {
    const receipt = await send({ key, address: v.arena, abi: arenaAbi, functionName: "raid", args: [BigInt(target)] });
    let text = "Raid on the " + name + ": nothing happened.";
    let tone: LogEntry["tone"] = "neutral";
    for (const entry of receipt.logs) {
      if (entry.address.toLowerCase() !== v.arena.toLowerCase()) continue;
      const event = decodeEventLog({ abi: arenaAbi, data: entry.data, topics: entry.topics as [Hex, ...Hex[]] });
      if (event.eventName === "Raid") {
        const pnl = event.args.pnl;
        if (pnl > 0n) {
          tone = target === 0 ? "bad" : "good";
          text =
            target === 0 && pending
              ? "You beat Reactive! You took " + usd(pnl) + " from the " + name + " before the update landed."
              : "You took " + usd(pnl) + " from the " + name + ".";
        } else {
          text = "Raid on the " + name + " made " + usd(pnl) + " after fees.";
        }
      } else if (event.eventName === "RaidBlocked") {
        tone = "neutral";
        text = "Blocked: the " + name + " is halted and refuses to trade.";
      } else if (event.eventName === "RaidPointless") {
        text = "Nothing to take: the " + name + " already trades at the right price.";
      }
    }
    note(text, tone, key, receipt.transactionHash);
    toast(text, tone === "bad" ? "warn" : tone === "good" ? "good" : "neutral");
    await refresh();
  } catch (error) {
    toast(explain(error), "bad");
  } finally {
    busy = false;
    render();
  }
}

// -------------------------------------------------------------------------------------------------
// Rendering
// -------------------------------------------------------------------------------------------------

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string> = {},
  ...children: (Node | string | undefined | false)[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else node.setAttribute(k, v);
  }
  for (const child of children) if (child) node.append(child);
  return node;
}

function link(chain: ChainKey, tx: string, text = "tx"): HTMLAnchorElement {
  return el("a", { href: explorerTx(config.chains[chain], tx), target: "_blank", rel: "noopener" }, text);
}

function render(): void {
  renderWallet();
  renderExchange();
  renderStopwatch();
  renderPools();
  renderHistory();
}

function renderWallet(): void {
  const button = $<HTMLButtonElement>("connect");
  if (account) {
    button.textContent = account.slice(0, 6) + "…" + account.slice(-4);
    button.classList.add("connected");
  } else {
    button.textContent = eth ? "Connect wallet" : "No wallet: watch only";
    button.disabled = !eth;
  }
}

function renderExchange(): void {
  if (!market) return;
  const status = market.seq === 0n ? -1 : market.status;
  const pill = $("market-status");
  pill.textContent = status === -1 ? "Not started" : STATUS_NAMES[status];
  pill.dataset.status = String(status);
  $("market-price").textContent = market.seq === 0n ? "—" : usd(market.price);
  $("market-seq").textContent = market.seq === 0n ? "" : "update #" + market.seq;

  const actions = $("actions");
  actions.replaceChildren();
  const now = Date.now();
  const wait = Math.max(0, Math.ceil((stageReadyAt - now) / 1000));
  const list = ACTIONS[status === -1 ? CLOSED : status] ?? [];
  for (const a of list) {
    const button = el(
      "button",
      { class: "action " + a.tone, type: "button" },
      el("span", { class: "action-label" }, a.label),
      el("span", { class: "action-hint" }, a.hint),
    );
    button.disabled = busy || wait > 0 || stageLeft === 0n;
    button.addEventListener("click", () => act(a.status, a.move, a.label));
    actions.append(button);
  }
  $("actions-note").textContent =
    stageLeft === 0n
      ? "The exchange has used up today's actions."
      : wait > 0
        ? "Next action in " + wait + " s (shared by everyone, to keep the demo's test funds alive)."
        : "Anyone can play the exchange. " + stageLeft + " actions left today.";
}

function renderStopwatch(): void {
  const box = $("hops");
  const loop = latestLoop;
  if (!loop) {
    box.replaceChildren(el("p", { class: "muted" }, "Press a button on the exchange to start the clock."));
    $("headline").textContent = "";
    $("track").replaceChildren();
    return;
  }

  const t0 = loop.feed?.ms;
  const elapsed = (h?: Hop) => (h?.ms !== undefined && t0 !== undefined ? h.ms - t0 : undefined);
  const live = Date.now() - (t0 ?? loop.seenAt);

  type Row = { label: string; where: string; hop?: Hop; chain: ChainKey; time?: string };
  const rows: Row[] = [
    { label: "Exchange publishes " + STATUS_NAMES[loop.status].toLowerCase() + " at " + usd(loop.price), where: "Base Sepolia", hop: loop.feed, chain: "base", time: loop.feed ? "0.00 s" : undefined },
    { label: "Reactive Network reacts and sends both updates", where: "Reactive Lasna", hop: loop.observed, chain: "lasna", time: loop.observed ? "block " + loop.observed.block : undefined },
  ];
  for (const key of VENUES) {
    if (!config.venues[key]) continue;
    const h = loop.applied[key];
    const ms = elapsed(h);
    rows.push({
      label: "Pool on " + config.chains[key].short + " switches",
      where: config.chains[key].name,
      hop: h,
      chain: key,
      time: ms !== undefined ? (h?.precise && loop.feed?.precise ? "+" : "") + seconds(ms, Boolean(h?.precise && loop.feed?.precise)) : undefined,
    });
  }
  rows.push({ label: "Both pools confirm back to Reactive", where: "Reactive Lasna", hop: loop.closed, chain: "lasna", time: loop.closed ? "loop closed" : undefined });

  box.replaceChildren(
    ...rows.map((r) =>
      el(
        "li",
        { class: r.hop ? "done" : "waiting" },
        el("span", { class: "dot" }),
        el("span", { class: "hop-label" }, r.label, el("small", {}, r.where)),
        el("span", { class: "hop-time" }, r.time ?? (live < 60_000 ? "…" : "not seen")),
        r.hop ? link(r.chain, r.hop.tx) : el("span", { class: "tx-placeholder" }),
      ),
    ),
  );

  const base = elapsed(loop.applied.base);
  const headline = $("headline");
  if (base !== undefined && loop.applied.base?.precise && loop.feed?.precise) {
    headline.replaceChildren(
      el("strong", {}, (base / 1000).toFixed(2) + " s"),
      " from the exchange event to the Base pool switching, both on Base's own millisecond clock.",
    );
  } else if (base !== undefined) {
    headline.replaceChildren(el("strong", {}, seconds(base, false)), " from the exchange event to the Base pool switching.");
  } else {
    headline.replaceChildren(el("strong", { class: "ticking" }, (Math.max(0, live) / 1000).toFixed(1) + " s"), " and counting…");
  }

  // The track: where each pool's switch landed, on one scale.
  const marks: { key: VenueKey; ms: number }[] = [];
  for (const key of VENUES) {
    const ms = elapsed(loop.applied[key]);
    if (ms !== undefined) marks.push({ key, ms });
  }
  const span = Math.max(3000, ...marks.map((m) => m.ms + 500), loopDone(loop) ? 0 : live + 500);
  const track = $("track");
  track.replaceChildren(
    el("div", { class: "track-line" }),
    el("div", { class: "mark origin", style: "left:0%" }, el("span", {}, "event")),
    ...marks.map((m) =>
      el(
        "div",
        { class: "mark " + m.key, style: "left:" + Math.min(100, (m.ms / span) * 100).toFixed(2) + "%" },
        el("span", {}, config.chains[m.key].short),
      ),
    ),
    !loopDone(loop) && t0 !== undefined
      ? el("div", { class: "mark now", style: "left:" + Math.min(100, (live / span) * 100).toFixed(2) + "%" })
      : "",
    el("div", { class: "track-scale" }, el("span", {}, "0 s"), el("span", {}, (span / 1000).toFixed(1) + " s")),
  );
}

function poolCard(key: VenueKey, target: 0 | 1, view: PoolView): HTMLElement {
  const isProtected = target === 0;
  const gap = gapPct(view.poolPrice, view.refPrice);
  const stale = Math.abs(gap) >= 0.5;
  const state = !view.tradable ? "halted" : stale ? "stale" : "fine";
  const statusText = !view.tradable
    ? "Halted: swaps refused"
    : "Trading · fee " + (view.feePips / 10_000).toFixed(2).replace(/\.?0+$/, "") + "%";

  const button = el(
    "button",
    { class: "raid", type: "button" },
    isProtected ? "Raid the protected pool" : "Raid the twin",
  );
  button.disabled = busy;
  button.addEventListener("click", () => raid(key, target));

  return el(
    "article",
    { class: "pool " + (isProtected ? "protected" : "twin") + " " + state },
    el(
      "header",
      {},
      el("h4", {}, isProtected ? "Protected by Opening Bell" : "Twin, no Opening Bell"),
      el("span", { class: "pool-status" }, statusText),
    ),
    el(
      "dl",
      {},
      el("div", {}, el("dt", {}, "Pool price"), el("dd", {}, usd(view.poolPrice))),
      el("div", {}, el("dt", {}, "Real price"), el("dd", {}, usd(view.refPrice))),
      el(
        "div",
        { class: "gap" },
        el("dt", {}, "Gap"),
        el("dd", {}, (gap > 0 ? "+" : "") + gap.toFixed(1) + "%"),
      ),
    ),
    button,
    el(
      "p",
      { class: "taken" },
      "Raiders have taken ",
      el("strong", {}, usdShort(view.taken > 0n ? view.taken : 0n)),
      " from this pool",
    ),
  );
}

function renderPools(): void {
  const box = $("venues");
  box.replaceChildren(
    ...VENUES.filter((k) => config.venues[k]).map((key) => {
      const view = venues[key];
      const info = config.chains[key];
      return el(
        "section",
        { class: "venue" },
        el(
          "header",
          {},
          el("h3", {}, info.name),
          view && account ? el("span", { class: "loot" }, "Your loot here: " + usd(view.loot)) : undefined,
        ),
        view ? poolCard(key, 0, view.protected) : el("p", { class: "muted" }, "Loading…"),
        view ? poolCard(key, 1, view.twin) : undefined,
      );
    }),
  );
}

function renderHistory(): void {
  const box = $("history");
  if (history.length === 0) {
    box.replaceChildren(el("li", { class: "muted" }, "Your moves will show up here."));
    return;
  }
  box.replaceChildren(
    ...history.slice(0, 8).map((h) =>
      el(
        "li",
        { class: h.tone },
        el("time", {}, new Date(h.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })),
        el("span", {}, h.text),
        h.tx && h.chain ? link(h.chain, h.tx) : undefined,
      ),
    ),
  );
}

function note(text: string, tone: LogEntry["tone"], chain?: ChainKey, tx?: Hash): void {
  history.unshift({ at: Date.now(), text, tone, chain, tx });
}

let toastTimer: number | undefined;
function toast(text: string, tone: "good" | "bad" | "warn" | "neutral"): void {
  const box = $("toast");
  box.textContent = text;
  box.dataset.tone = tone;
  box.hidden = false;
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => (box.hidden = true), 7000);
}

function renderContracts(): void {
  const rows: [string, ChainKey, string][] = [
    ["Market feed", "base", config.origin.feed],
    ["Exchange buttons (DemoStage)", "base", config.origin.stage],
    ["Reactive contract (BellReactive)", "lasna", config.reactive.conductor],
  ];
  for (const key of VENUES) {
    const v = config.venues[key];
    if (!v) continue;
    rows.push(
      ["Guard on " + config.chains[key].short, key, v.guard],
      ["Pool hook on " + config.chains[key].short, key, v.hook],
      ["Protected vault on " + config.chains[key].short, key, v.vault],
      ["Twin vault on " + config.chains[key].short, key, v.twinVault],
      ["Raid arena on " + config.chains[key].short, key, v.arena],
    );
  }
  $("contracts").replaceChildren(
    ...rows.map(([label, key, address]) =>
      el(
        "li",
        {},
        el("span", {}, label),
        el("a", { href: explorerAddress(config.chains[key], address), target: "_blank", rel: "noopener" }, address),
      ),
    ),
  );
}

// -------------------------------------------------------------------------------------------------
// Start
// -------------------------------------------------------------------------------------------------

async function main(): Promise<void> {
  try {
    config = await loadConfig();
  } catch (error) {
    $("boot").textContent = error instanceof Error ? error.message : String(error);
    return;
  }
  clients = makeClients(config);
  document.body.dataset.mode = config.mode;
  if (config.mode === "local") $("mode").hidden = false;

  // Search only a recent window for loop events: about 5 minutes on Base, 25 on Unichain and Lasna.
  const [b, u, l] = await Promise.all([
    clients.base.getBlockNumber(),
    clients.unichain.getBlockNumber(),
    clients.lasna.getBlockNumber(),
  ]);
  const floor = (latest: bigint, window: bigint, deployed: number) =>
    latest - window > BigInt(deployed) ? latest - window : BigInt(deployed);
  scanFrom.base = floor(b, 1500n, config.origin.block);
  scanFrom.unichain = floor(u, 1500n, config.venues.unichain?.block ?? 0);
  scanFrom.lasna = floor(l, 1500n, config.reactive.block);

  $("connect").addEventListener("click", () => connect().catch((e) => toast(explain(e), "bad")));
  eth?.on?.("accountsChanged", (accounts) => {
    account = (accounts as Address[])[0];
    render();
  });

  renderContracts();
  $("boot").hidden = true;
  $("app").hidden = false;

  const tick = async () => {
    try {
      await refresh();
      $("offline").hidden = true;
    } catch (error) {
      console.warn(error);
      $("offline").hidden = false;
    }
    window.setTimeout(tick, config.mode === "local" ? 700 : 1200);
  };
  await tick();
  // Keep the live counters moving between reads.
  window.setInterval(() => {
    renderStopwatch();
    renderExchange();
  }, 100);
}

main();
