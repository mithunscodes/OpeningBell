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
  /** Base Sepolia block time of the update, in seconds. */
  sourceTime: bigint;
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
  /**
   * How old the update already was when this page first saw it, on Base's clock. An update that is
   * older than `LIVE_WINDOW_MS` is shown as history: public RPCs only search a short stretch of
   * blocks for events, so its transactions are not looked up.
   */
  ageMs: number;
  old: boolean;
  /** Where the next event search starts on each chain. */
  cursor: Partial<Record<ChainKey, bigint>>;
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
let stageOwner: Address | undefined;
let busy = false;
/** What the Reactive contract itself reports: the last update it saw, and whether every chain confirmed it. */
let conductor: { seq: bigint; inSync: boolean } | undefined;
const history: LogEntry[] = [];
/** Latest block seen on each chain. */
const heads: Partial<Record<ChainKey, bigint>> = {};

/**
 * The public RPCs cap how many blocks one event search may cover: 200 on Base Sepolia (40 seconds),
 * 1000 on Unichain Sepolia, a few thousand on Lasna. Searches stay under these and slide forward.
 */
const MAX_RANGE: Record<ChainKey, bigint> = { base: 190n, unichain: 900n, lasna: 2000n };
const BLOCK_MS: Record<ChainKey, number> = { base: 200, unichain: 1000, lasna: 1000 };
const RAID_GAS = 1_200_000n;
/** An update older than this when the page first sees it is not timed. Keeps Base's first search under its cap. */
const LIVE_WINDOW_MS = 20_000;
/** How far before the update the first search starts, to allow for clocks that disagree. */
const SEARCH_MARGIN_MS = 15_000;

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
  const [status, seq, sourceTime, price] = await clients.base.readContract({
    address: config.origin.feed,
    abi: feedAbi,
    functionName: "markets",
    args: [MARKET_ID],
  });
  return { status, seq, sourceTime, price };
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

async function readConductor(): Promise<void> {
  const [state, inSync] = await Promise.all([
    clients.lasna.readContract({ address: config.reactive.conductor, abi: conductorAbi, functionName: "markets", args: [MARKET_ID] }),
    clients.lasna.readContract({ address: config.reactive.conductor, abi: conductorAbi, functionName: "inSync", args: [MARKET_ID] }),
  ]);
  conductor = { seq: state[1], inSync };
}

/** The stretch of blocks to search on a chain for a loop's events on this pass, kept under the RPC's cap. */
function searchWindow(loop: Loop, key: ChainKey): { fromBlock: bigint; toBlock: bigint; full: boolean } | undefined {
  const fromBlock = loop.cursor[key];
  const head = heads[key];
  if (fromBlock === undefined || head === undefined || head < fromBlock) return undefined;
  const cap = config.mode === "local" ? head : fromBlock + MAX_RANGE[key];
  return head > cap ? { fromBlock, toBlock: cap, full: true } : { fromBlock, toBlock: head, full: false };
}

/** Fills in whatever hops of a loop have landed since the last look. */
async function advance(loop: Loop): Promise<void> {
  if (loop.old) return;
  const windows: Partial<Record<ChainKey, ReturnType<typeof searchWindow>>> = {};
  for (const key of ["base", "unichain", "lasna"] as const) windows[key] = searchWindow(loop, key);
  const jobs: { key: ChainKey; run: Promise<void> }[] = [];

  const base = windows.base;
  if (!loop.feed && base) {
    jobs.push({
      key: "base",
      run: (async () => {
        const logs = await clients.base.getContractEvents({
          address: config.origin.feed,
          abi: feedAbi,
          eventName: "MarketUpdate",
          args: { marketId: MARKET_ID },
          fromBlock: base.fromBlock,
          toBlock: base.toBlock,
        });
        const log = logs.find((l) => l.args.seq === loop.seq);
        if (log) loop.feed = await hop(clients.base, log.blockNumber, log.transactionHash);
      })(),
    });
  }

  const lasna = windows.lasna;
  if ((!loop.observed || !loop.closed) && lasna) {
    jobs.push({
      key: "lasna",
      run: (async () => {
        const find = async (eventName: "Observed" | "LoopClosed") => {
          const logs = await clients.lasna.getContractEvents({
            address: config.reactive.conductor,
            abi: conductorAbi,
            eventName,
            args: { marketId: MARKET_ID, seq: loop.seq },
            fromBlock: lasna.fromBlock,
            toBlock: lasna.toBlock,
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
    });
  }

  for (const key of VENUES) {
    const v = config.venues[key];
    const window = windows[key];
    if (!v || loop.applied[key] || !window) continue;
    jobs.push({
      key,
      run: (async () => {
        const logs = await clients[key].getContractEvents({
          address: v.guard,
          abi: guardAbi,
          eventName: "Applied",
          args: { marketId: MARKET_ID, seq: loop.seq },
          fromBlock: window.fromBlock,
          toBlock: window.toBlock,
        });
        const log = logs[0];
        if (log) loop.applied[key] = await hop(clients[key], log.blockNumber, log.transactionHash);
      })(),
    });
  }

  // A failed read (rate limit, timeout) is retried on the next pass. A chain whose stretch was
  // searched in full without trouble moves on to the next stretch, with a small overlap.
  const results = await Promise.allSettled(jobs.map((j) => j.run));
  const failed = new Set(jobs.filter((_, i) => results[i].status === "rejected").map((j) => j.key));
  for (const key of ["base", "unichain", "lasna"] as const) {
    const window = windows[key];
    if (window?.full && !failed.has(key)) loop.cursor[key] = window.toBlock - 5n;
  }
  const firstError = results.find((r) => r.status === "rejected");
  if (firstError) console.warn((firstError as PromiseRejectedResult).reason);
}

async function hop(client: PublicClient, block: bigint, tx: Hash): Promise<Hop> {
  const time = await blockTimeMs(client, block);
  return { block, tx, ms: time.ms, precise: time.precise };
}

function loopDone(loop: Loop): boolean {
  return Boolean(loop.feed && loop.observed && loop.closed && VENUES.every((k) => !config.venues[k] || loop.applied[k]));
}

/** The block each chain's deployment went in at, below which no search needs to go. */
function deployedAt(key: ChainKey): bigint {
  if (key === "lasna") return BigInt(config.reactive.block);
  if (key === "base") return BigInt(config.origin.block);
  return BigInt(config.venues[key]?.block ?? 0);
}

async function refresh(): Promise<void> {
  const [m, baseHead, unichainHead, lasnaHead, ...views] = await Promise.all([
    readMarket(),
    clients.base.getBlock({ blockTag: "latest" }),
    clients.unichain.getBlockNumber(),
    clients.lasna.getBlockNumber(),
    ...VENUES.map(readVenue),
    readStage(),
    // Only the settled view uses this, so a failed read is not worth failing the whole pass for.
    readConductor().catch(() => undefined),
  ]);
  heads.base = baseHead.number;
  heads.unichain = unichainHead;
  heads.lasna = lasnaHead;
  VENUES.forEach((key, i) => {
    const view = views[i];
    if (view) venues[key] = view;
  });

  if (!market || m.seq !== market.seq) {
    if (m.seq > 0n && !loops.has(m.seq)) {
      // Both times are Base's own, so the player's clock does not matter.
      const ageMs = Math.max(0, Number(baseHead.timestamp - m.sourceTime) * 1000);
      const old = ageMs > LIVE_WINDOW_MS;
      const cursor: Loop["cursor"] = {};
      for (const key of ["base", "unichain", "lasna"] as const) {
        const back = BigInt(Math.ceil((ageMs + SEARCH_MARGIN_MS) / BLOCK_MS[key]));
        const head = heads[key]!;
        cursor[key] = head - back > deployedAt(key) ? head - back : deployedAt(key);
      }
      const loop: Loop = { seq: m.seq, status: m.status, price: m.price, applied: {}, seenAt: Date.now(), ageMs, old, cursor };
      loops.set(m.seq, loop);
      latestLoop = loop;
      if (!old) replay = undefined; // a live loop takes the stopwatch back from a replay
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

/** True for a wallet's "this page is not allowed to do that" answer (EIP-1193 code 4100). */
function unauthorized(error: unknown): boolean {
  const is = (e: unknown) => (e as { code?: number } | null)?.code === 4100;
  return error instanceof BaseError ? Boolean(error.walk(is)) : is(error);
}

/** Asks the wallet to connect this page again, which also renews the networks it may use. */
async function reauthorize(): Promise<Address | undefined> {
  if (!eth) return undefined;
  await eth.request({ method: "wallet_requestPermissions", params: [{ eth_accounts: {} }] });
  const accounts = (await eth.request({ method: "eth_accounts" })) as Address[];
  account = accounts[0];
  render();
  return account;
}

type Write = {
  key: ChainKey;
  address: Address;
  abi: typeof stageAbi | typeof arenaAbi;
  functionName: string;
  args: readonly unknown[];
  /** Fixed gas limit, for calls whose wallet estimate could land too low. */
  gas?: bigint;
};

/** Simulates first (so reverts come back readable), then sends from the player's wallet. */
async function send(write: Write): Promise<TransactionReceipt> {
  try {
    return await sendOnce(write);
  } catch (error) {
    // The wallet no longer lets this page use the account or the network (it happens after the
    // account or the site's networks were changed in the wallet). Ask once, then try again.
    if (!unauthorized(error)) throw error;
    await reauthorize();
    return sendOnce(write);
  }
}

async function sendOnce(write: Write): Promise<TransactionReceipt> {
  if (!eth) throw new Error("connect a wallet first");
  // The wallet's own answer wins over what the page remembers: the player may have changed accounts.
  const allowed = account ? ((await eth.request({ method: "eth_accounts" })) as Address[]) : [];
  if (allowed.length > 0 && !allowed.some((a) => a.toLowerCase() === account?.toLowerCase())) {
    account = allowed[0];
    render();
  }
  const from = allowed.length > 0 ? account : await connect();
  if (!from) throw new Error("connect a wallet first");
  await ensureChain(write.key);

  const client = clients[write.key];
  // Wallets word this failure in many ways, so it is checked here and said plainly.
  if ((await client.getBalance({ address: from })) === 0n) {
    throw new Error("Your wallet has no test ETH on " + config.chains[write.key].name + " to pay gas. The faucet link is at the bottom of the page.");
  }
  const { request } = await client.simulateContract({
    account: from,
    address: write.address,
    abi: write.abi as typeof arenaAbi,
    functionName: write.functionName as "raid",
    args: write.args as [bigint],
  });
  const wallet = createWalletClient({ chain: toChain(config.chains[write.key]), transport: custom(eth), account: from });
  const hash = await wallet.writeContract(write.gas ? { ...request, gas: write.gas } : request);
  // The transaction is out. A public RPC that stumbles while we wait must not read as a failure.
  for (let attempt = 0; ; attempt++) {
    try {
      return await client.waitForTransactionReceipt({ hash });
    } catch (error) {
      if (attempt >= 3) throw error;
      await new Promise((r) => setTimeout(r, 1500));
    }
  }
}

function explain(error: unknown): string {
  if (unauthorized(error)) return "Your wallet has not allowed this page to use that account or network. Disconnect this site in your wallet, then press Connect wallet again.";
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
  // Wallets answer a refused request with a plain object, not an Error.
  const raw = error as { code?: number; message?: unknown } | null;
  if (raw?.code === 4001) return "You cancelled the request in your wallet.";
  if (raw?.code === -32002) return "Your wallet already has a request waiting. Open it to answer.";
  if (error instanceof Error) return error.message;
  return typeof raw?.message === "string" ? raw.message : String(error);
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
  replay = undefined;
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
    await refresh().catch((e) => console.warn(e));
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
    // The arena refuses a raid that arrives with too little gas, so the limit is set here rather than
    // left to the wallet's estimate. Unused gas is not charged.
    const receipt = await send({ key, address: v.arena, abi: arenaAbi, functionName: "raid", args: [BigInt(target)], gas: RAID_GAS });
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
    await refresh().catch((e) => console.warn(e));
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

/**
 * What was last drawn into each part of the page. A part is only rebuilt when what it shows has
 * changed: the page redraws many times a second, and a button that is replaced between the press
 * and the release of a click never hears the click.
 */
const drawn = new Map<string, string>();
function changed(part: string, state: unknown): boolean {
  const key = JSON.stringify(state, (_, v) => (typeof v === "bigint" ? v.toString() : v));
  if (drawn.get(part) === key) return false;
  drawn.set(part, key);
  return true;
}

function render(): void {
  renderWallet();
  renderExchange();
  renderStopwatch();
  renderPools();
  renderHistory();
  renderSteps();
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
  document.body.dataset.status = String(status);
  $("market-price").textContent = market.seq === 0n ? "—" : usd(market.price);
  $("market-seq").textContent = market.seq === 0n ? "" : "update #" + market.seq;

  const actions = $("actions");
  const now = Date.now();
  const wait = Math.max(0, Math.ceil((stageReadyAt - now) / 1000));
  const list = ACTIONS[status === -1 ? CLOSED : status] ?? [];
  const blocked = busy || wait > 0 || stageLeft === 0n;
  if (changed("actions", [status, blocked])) actions.replaceChildren();
  for (const a of actions.childElementCount === 0 ? list : []) {
    const button = el("button", { class: "action " + a.tone, type: "button", title: a.hint }, el("span", { class: "action-label" }, a.label));
    button.disabled = blocked;
    button.addEventListener("click", () => act(a.status, a.move, a.label));
    actions.append(button);
  }
  $("actions-note").textContent = !eth
    ? "No wallet here, so watch only. Replay a recorded loop instead."
    : stageLeft === 0n
      ? "The exchange has used up today's actions."
      : wait > 0
        ? "Next action in " + wait + " s."
        : account && stageOwner && account.toLowerCase() === stageOwner.toLowerCase()
          ? "Owner account: no daily limit."
          : stageLeft + " actions left today.";
}

// --- The stopwatch -------------------------------------------------------------------------------

type StageKey = "feed" | "observed" | "base" | "unichain" | "closed";
type StageState = "idle" | "waiting" | "done" | "behind";
interface StageView {
  state: StageState;
  value: string;
  chain: ChainKey;
  tx?: Hash;
}
interface WatchView {
  kind: "none" | "settled" | "live" | "replay";
  /** The big number, and whether it is still running. */
  clock: string;
  clockState: "idle" | "ticking" | "done";
  headline: (Node | string)[];
  tag: string;
  note: string;
  stages: Record<StageKey, StageView>;
}

const STAGE_CHAIN: Record<StageKey, ChainKey> = { feed: "base", observed: "lasna", base: "base", unichain: "unichain", closed: "lasna" };

function blankStages(): Record<StageKey, StageView> {
  const stage = (key: StageKey): StageView => ({ state: "idle", value: "—", chain: STAGE_CHAIN[key] });
  return { feed: stage("feed"), observed: stage("observed"), base: stage("base"), unichain: stage("unichain"), closed: stage("closed") };
}

/** A loop being timed, live or replayed: each hop lights up as it lands. */
function timedView(loop: Loop, live: number, kind: "live" | "replay"): WatchView {
  const t0 = loop.feed?.ms;
  const elapsed = (h?: Hop) => (h?.ms !== undefined && t0 !== undefined ? h.ms - t0 : undefined);
  const stages = blankStages();
  const hops: Record<StageKey, Hop | undefined> = {
    feed: loop.feed,
    observed: loop.observed,
    base: loop.applied.base,
    unichain: loop.applied.unichain,
    closed: loop.closed,
  };
  const landed = (key: StageKey) => Boolean(hops[key]);
  const venuesIn = VENUES.filter((k) => config.venues[k]);
  // The signal has reached a stage once the stage before it has landed. Hops are looked up on three
  // chains at once and can be found out of order, so a later stage landing counts as well.
  const reached: Record<StageKey, boolean> = {
    feed: true,
    observed: landed("feed") || landed("observed") || venuesIn.some(landed) || landed("closed"),
    base: landed("observed") || venuesIn.some(landed) || landed("closed"),
    unichain: landed("observed") || venuesIn.some(landed) || landed("closed"),
    closed: venuesIn.every(landed) || landed("closed"),
  };
  const values: Record<StageKey, string | undefined> = {
    feed: loop.feed ? "0.00 s" : undefined,
    observed: loop.observed ? "reacted" : undefined,
    base: undefined,
    unichain: undefined,
    closed: loop.closed ? "loop closed" : undefined,
  };
  for (const key of venuesIn) {
    const h = loop.applied[key];
    const ms = elapsed(h);
    const precise = Boolean(h?.precise && loop.feed?.precise);
    if (ms !== undefined) values[key] = (precise ? "+" : "") + seconds(ms, precise);
  }
  for (const key of Object.keys(stages) as StageKey[]) {
    const hop = hops[key];
    stages[key] = hop
      ? { state: "done", value: values[key] ?? "landed", chain: STAGE_CHAIN[key], tx: hop.tx }
      : live > 60_000
        ? { state: "behind", value: "not seen", chain: STAGE_CHAIN[key] }
        : { state: reached[key] ? "waiting" : "idle", value: reached[key] ? "…" : "—", chain: STAGE_CHAIN[key] };
  }

  const base = elapsed(loop.applied.base);
  const precise = Boolean(loop.applied.base?.precise && loop.feed?.precise);
  return {
    kind,
    clock: base === undefined ? (Math.max(0, live) / 1000).toFixed(1) : precise ? (base / 1000).toFixed(2) : "≈ " + Math.max(0, Math.round(base / 1000)),
    clockState: base === undefined ? "ticking" : "done",
    headline: base === undefined ? ["and counting…"] : ["exchange event to ", el("b", {}, "Base pool switched")],
    tag: (kind === "live" ? "Live" : "Replay") + " · update #" + loop.seq,
    note: kind === "live" ? "Timed from block timestamps." : "",
    stages,
  };
}

/** An update that landed before this page was watching: no timings, only whether each chain has it. */
function settledView(loop: Loop): WatchView {
  const stages = blankStages();
  stages.feed = { state: "done", value: "update #" + loop.seq, chain: "base" };
  if (conductor) {
    const saw = conductor.seq >= loop.seq;
    stages.observed = { state: saw ? "done" : "behind", value: saw ? "in sync" : "behind", chain: "lasna" };
    const closed = saw && conductor.inSync;
    stages.closed = { state: closed ? "done" : "waiting", value: closed ? "loop closed" : "…", chain: "lasna" };
  }
  for (const key of VENUES) {
    const view = venues[key];
    if (!config.venues[key] || !view) continue;
    const ok = view.guardSeq >= loop.seq;
    stages[key] = { state: ok ? "done" : "behind", value: ok ? "in sync" : "behind", chain: key };
  }
  return {
    kind: "settled",
    clock: "—",
    clockState: "idle",
    headline: ["Press an exchange button to start the clock."],
    tag: "",
    note: "Update #" + loop.seq + " landed " + ago(loop.ageMs + (Date.now() - loop.seenAt)) + " ago.",
    stages,
  };
}

function watchView(): WatchView {
  if (replay) {
    const { loop, live } = replayLoop(replay, Date.now());
    const view = timedView(loop, live, "replay");
    const r = replay.loop;
    view.note = "Replay of update #" + r.seq + ", recorded " + recordedDate(r.at) + ".";
    return view;
  }
  const loop = latestLoop;
  if (!loop) {
    return {
      kind: "none",
      clock: "—",
      clockState: "idle",
      headline: ["Press an exchange button to start the clock."],
      tag: "",
      note: "",
      stages: blankStages(),
    };
  }
  return loop.old ? settledView(loop) : timedView(loop, Date.now() - (loop.feed?.ms ?? loop.seenAt), "live");
}

function renderStopwatch(): void {
  const view = watchView();

  const clock = $("clock");
  if (clock.textContent !== view.clock) clock.textContent = view.clock;
  (clock.closest(".clock") as HTMLElement).dataset.state = view.clockState;
  if (changed("headline", [view.kind, view.clockState, view.headline.map((p) => (typeof p === "string" ? p : p.textContent))])) {
    $("headline").replaceChildren(...view.headline);
  }
  const tag = $("watch-tag");
  if (changed("watch-tag", [view.kind, view.tag])) {
    tag.hidden = view.tag === "";
    tag.textContent = view.tag;
    tag.dataset.kind = view.kind;
  }
  if ($("watch-note").textContent !== view.note) $("watch-note").textContent = view.note;

  const button = $<HTMLButtonElement>("replay");
  const canReplay = replayable().length > 0 && view.kind !== "live";
  if (changed("replay", [canReplay, view.kind])) {
    button.hidden = !canReplay;
    button.textContent = view.kind === "replay" ? "Replay another" : "Replay a loop";
  }

  const route = $("route");
  for (const key of Object.keys(view.stages) as StageKey[]) {
    const stage = view.stages[key];
    const node = route.querySelector<HTMLElement>('.node[data-stage="' + key + '"]');
    if (!node) continue;
    if (key !== "feed" && key !== "observed" && key !== "closed") node.hidden = !config.venues[key];
    if (changed("stage-" + key, stage)) {
      const was = node.dataset.state;
      node.dataset.state = stage.state;
      node.querySelector(".node-value")!.textContent = stage.value;
      node.querySelector(".node-tx")!.replaceChildren(stage.tx ? link(stage.chain, stage.tx, "tx ↗") : "");
      if (was === "waiting" && stage.state === "done") {
        node.classList.remove("landed");
        void node.offsetWidth;
        node.classList.add("landed");
      }
    }
    // The wire into a stage runs while the signal is on its way and stays lit once it has landed.
    const leg = stage.state === "done" ? "done" : stage.state === "waiting" && key !== "feed" ? "waiting" : "idle";
    for (const path of route.querySelectorAll<SVGPathElement>('path[data-leg="' + key + '"]')) {
      if (path.dataset.state !== leg) path.dataset.state = leg;
      path.style.display = node.hidden ? "none" : "";
    }
  }
}

function ago(ms: number): string {
  const s = Math.round(ms / 1000);
  if (s < 90) return s + " seconds";
  if (s < 90 * 60) return Math.round(s / 60) + " minutes";
  if (s < 36 * 3600) return Math.round(s / 3600) + " hours";
  return Math.round(s / 86400) + " days";
}

// --- Recorded loops: the benchmark, drawn and replayable -------------------------------------------

/** One loop from the benchmark runs in bench/results, as web/build.mjs writes it to loops.json. */
interface Recorded {
  seq: number;
  action: string;
  /** Base block time of the exchange event, in ms. */
  at: number;
  feed?: Hash;
  observed?: Hash;
  observedBlock?: number;
  base?: Hash;
  baseMs?: number;
  unichain?: Hash;
  unichainMs?: number;
  closed?: Hash;
  closedBlock?: number;
  sawObserved?: number;
  sawClosed?: number;
}
interface Replay {
  loop: Recorded;
  startedAt: number;
  /** When each hop lights up, in ms after the start. */
  at: { observed: number; base: number; unichain: number; closed: number };
}

let recorded: Recorded[] = [];
let replay: Replay | undefined;
let autoplayed = false;
const BIN_MS = 200;

function replayable(): Recorded[] {
  return recorded.filter((r) => r.feed && r.observed && r.base && r.unichain && r.closed && r.baseMs !== undefined && r.unichainMs !== undefined);
}

function recordedDate(ms: number): string {
  return new Date(ms).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
}

function statusOf(action: string): number {
  if (action.startsWith("halt")) return HALTED;
  if (action.startsWith("close")) return CLOSED;
  return OPEN;
}

function startReplay(loop?: Recorded): void {
  // A loop that is being timed live keeps the stopwatch until it has closed.
  const live = latestLoop;
  if (live && !live.old && !loopDone(live) && Date.now() - live.seenAt < 60_000) return;
  const pool = replayable();
  const r = loop ?? pool[Math.floor(Math.random() * pool.length)];
  if (!r) return;
  const base = r.baseMs!;
  const unichain = r.unichainMs!;
  // The two pool hops play back at their real block times. Lasna blocks carry no millisecond time,
  // so the Reactive hops are paced by when the benchmark saw them, kept in their true order.
  const first = Math.min(base, unichain);
  const observed = Math.max(150, Math.min(r.sawObserved ?? first / 2, first - 250));
  const closed = Math.max(r.sawClosed ?? 0, Math.max(base, unichain) + 400);
  replay = { loop: r, startedAt: Date.now(), at: { observed, base, unichain, closed } };
  renderStopwatch();
  renderSteps();
  renderProof();
}

function replayLoop(play: Replay, now: number): { loop: Loop; live: number } {
  const r = play.loop;
  const since = now - play.startedAt;
  const loop: Loop = { seq: BigInt(r.seq), status: statusOf(r.action), price: 0n, applied: {}, seenAt: play.startedAt, ageMs: 0, old: false, cursor: {} };
  loop.feed = { block: 0n, tx: r.feed!, ms: r.at, precise: true };
  if (since >= play.at.observed) loop.observed = { block: BigInt(r.observedBlock ?? 0), tx: r.observed! };
  if (since >= play.at.base) loop.applied.base = { block: 0n, tx: r.base!, ms: r.at + r.baseMs!, precise: true };
  if (since >= play.at.unichain) loop.applied.unichain = { block: 0n, tx: r.unichain!, ms: r.at + r.unichainMs!, precise: false };
  if (since >= play.at.closed) loop.closed = { block: BigInt(r.closedBlock ?? 0), tx: r.closed! };
  return { loop, live: since };
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/** The numbers and the histogram at the top of the page, straight from the recorded loops. */
function renderProof(): void {
  const done = replayable();
  if (done.length === 0) return;
  const playing = replay ? Math.round(replay.loop.baseMs! / BIN_MS) * BIN_MS : undefined;
  if (!changed("proof", [recorded.length, done.length, playing])) return;

  const mid = median(done.map((r) => r.baseMs!));
  $("proof-count").textContent = done.length + " of " + recorded.length;
  $("proof-base").textContent = (mid / 1000).toFixed(1) + " s";
  $("proof-unichain").textContent = "≈ " + Math.round(median(done.map((r) => r.unichainMs!)) / 1000) + " s";
  $("hist-hint").hidden = false;

  const bins = new Map<number, Recorded[]>();
  for (const r of done) {
    const bin = Math.round(r.baseMs! / BIN_MS) * BIN_MS;
    bins.set(bin, [...(bins.get(bin) ?? []), r]);
  }
  const keys = [...bins.keys()];
  const from = Math.min(...keys);
  const to = Math.max(...keys);
  const tallest = Math.max(...[...bins.values()].map((b) => b.length));
  const medianBin = Math.round(mid / BIN_MS) * BIN_MS;
  const columns: HTMLElement[] = [];
  for (let bin = from; bin <= to; bin += BIN_MS) {
    const loopsIn = bins.get(bin) ?? [];
    const label = (bin / 1000).toFixed(1) + " s";
    const count = loopsIn.length;
    const column = el(
      count ? "button" : "div",
      {
        class: "bin" + (bin === medianBin ? " median" : "") + (bin === playing ? " on" : ""),
        ...(count ? { type: "button", "data-tip": count + (count === 1 ? " loop" : " loops") + " took " + label + ". Click to replay one.", "aria-label": count + " of " + done.length + " loops took " + label + ". Replay one." } : {}),
      },
      el(
        "span",
        { class: "bin-col", style: "height:" + ((count / tallest) * 100).toFixed(1) + "%" },
        count ? el("span", { class: "bin-count" }, String(count)) : undefined,
        count ? el("span", { class: "bin-bar", style: "height:100%" }) : undefined,
      ),
      el("span", { class: "bin-label" }, (bin / 1000).toFixed(1), el("i", {}, " s")),
    );
    if (count) {
      column.addEventListener("click", () => {
        startReplay(loopsIn[Math.floor(Math.random() * loopsIn.length)]);
        $("step-2").scrollIntoView({ behavior: "smooth", block: "nearest" });
      });
    }
    columns.push(column);
  }
  $("hist").replaceChildren(...columns);
}

async function loadRecorded(): Promise<void> {
  try {
    const response = await fetch("loops.json");
    if (!response.ok) return;
    recorded = (await response.json()) as Recorded[];
  } catch {
    return; // The page works without the recording; it only loses the replay and the histogram.
  }
  renderProof();
  renderStopwatch();
  // A visitor who arrives between updates sees one typical recorded loop play, clearly marked as a replay.
  // It waits until the tab is actually being looked at, and until no live loop holds the stopwatch.
  let seenFor = 0;
  const timer = window.setInterval(() => {
    if (autoplayed || replay) return window.clearInterval(timer);
    const live = latestLoop;
    const liveNow = live && !live.old && Date.now() - live.seenAt < 60_000;
    if (document.visibilityState !== "visible" || liveNow) return void (seenFor = 0);
    seenFor += 300;
    if (seenFor < 1500) return;
    window.clearInterval(timer);
    autoplayed = true;
    const done = replayable();
    if (done.length === 0) return;
    const mid = Math.round(median(done.map((r) => r.baseMs!)) / BIN_MS) * BIN_MS;
    const typical = done.filter((r) => Math.round(r.baseMs! / BIN_MS) * BIN_MS === mid);
    startReplay(typical[Math.floor(Math.random() * typical.length)]);
  }, 300);
}

// --- The three steps ---------------------------------------------------------------------------------

function isStale(view: PoolView): boolean {
  return view.tradable && Math.abs(gapPct(view.poolPrice, view.refPrice)) >= 0.5;
}

/** Which step the page points at: the clock while a loop runs, the pools while one is stale, else the exchange. */
function currentStep(): 1 | 2 | 3 {
  if (replay && Date.now() - replay.startedAt < replay.at.closed + 400) return 2;
  const loop = latestLoop;
  if (loop && !loop.old && !loopDone(loop) && Date.now() - loop.seenAt < 60_000) return 2;
  const stale = VENUES.some((key) => {
    const view = venues[key];
    return view !== undefined && (isStale(view.twin) || isStale(view.protected));
  });
  return stale ? 3 : 1;
}

function renderSteps(): void {
  const step = currentStep();
  if (!changed("step", step)) return;
  for (const n of [1, 2, 3]) $("step-" + n).classList.toggle("lit", n === step);
}

// --- The pools ------------------------------------------------------------------------------------------

function poolCard(key: VenueKey, target: 0 | 1, view: PoolView, afterHours: boolean): HTMLElement {
  const isProtected = target === 0;
  const gap = gapPct(view.poolPrice, view.refPrice);
  const state = !view.tradable ? "halted" : isStale(view) ? "stale" : "fine";
  const fee = (view.feePips / 10_000).toFixed(2).replace(/\.?0+$/, "") + "%";
  const statusText = !view.tradable ? "Halted" : isProtected && afterHours ? "After hours · " + fee + " fee" : "Trading";
  const lost = view.taken > 0n ? view.taken : 0n;

  const button = el("button", { class: "raid", type: "button", "aria-label": isProtected ? "Raid the protected pool" : "Raid the twin" }, "Raid");
  button.disabled = busy;
  button.addEventListener("click", () => raid(key, target));

  return el(
    "article",
    { class: "pool " + (isProtected ? "protected" : "twin") + " " + state },
    el(
      "header",
      {},
      el("h4", {}, isProtected ? "Protected" : "Unprotected twin"),
      el("span", { class: "pool-status" }, statusText),
    ),
    el(
      "div",
      { class: "lost" },
      el("span", {}, "Lost to raiders"),
      el("strong", { class: lost === 0n ? "zero" : "" }, usd(lost, 0)),
    ),
    el(
      "dl",
      {},
      el("div", {}, el("dt", {}, "Pool price"), el("dd", {}, usd(view.poolPrice))),
      el(
        "div",
        { class: "gap" },
        el("dt", {}, "Gap"),
        el("dd", {}, (gap > 0 ? "+" : "") + gap.toFixed(1) + "%"),
      ),
    ),
    button,
  );
}

function renderPools(): void {
  const box = $("venues");
  if (!changed("pools", [venues, busy, account])) return;
  box.replaceChildren(
    ...VENUES.filter((k) => config.venues[k]).map((key) => {
      const view = venues[key];
      const info = config.chains[key];
      return el(
        "section",
        { class: "venue", "data-chain": key },
        el(
          "header",
          {},
          el("h3", {}, info.name),
          view && account ? el("span", { class: "loot" }, "Your loot ", el("b", {}, usd(view.loot))) : undefined,
        ),
        view
          ? el("div", { class: "duel" }, poolCard(key, 0, view.protected, view.guardStatus === CLOSED), poolCard(key, 1, view.twin, false))
          : el("p", { class: "muted" }, "Loading…"),
      );
    }),
  );
}

function renderHistory(): void {
  const box = $("history");
  if (!changed("history", [history.length, history[0]?.at])) return;
  // The list only takes up room once there is a move to show.
  $("moves").hidden = history.length === 0;
  $("lower").classList.toggle("solo", history.length === 0);
  if (history.length === 0) return;
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

  $("connect").addEventListener("click", () => connect().catch((e) => toast(explain(e), "bad")));
  eth?.on?.("accountsChanged", (accounts) => {
    account = (accounts as Address[])[0];
    render();
  });
  // A wallet that already trusts this page reconnects without asking again.
  eth
    ?.request({ method: "eth_accounts" })
    .then((accounts) => {
      account ??= (accounts as Address[])[0];
      render();
    })
    .catch(() => undefined);

  $("replay").addEventListener("click", () => startReplay());
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
    // While a live loop is being timed the page looks more often, so the clock stops close to the real landing.
    const timing = latestLoop && !latestLoop.old && !loopDone(latestLoop) && Date.now() - latestLoop.seenAt < 30_000;
    window.setTimeout(tick, timing ? 400 : config.mode === "local" ? 700 : 1200);
  };
  await tick();
  void loadRecorded();
  clients.base
    .readContract({ address: config.origin.stage, abi: stageAbi, functionName: "owner" })
    .then((owner) => {
      stageOwner = owner;
      render();
    })
    .catch(() => undefined);
  // Keep the live counters moving between reads.
  window.setInterval(() => {
    renderStopwatch();
    renderExchange();
    renderSteps();
  }, 100);
}

main();
