/**
 * Replays a real night through the live system: the reference market's real closing price, the
 * real quotes while it was shut, and the real opening price, each published as one exchange
 * update. After the last one it raids every pool and records what a raider found.
 *
 *   REPLAY_PRIVATE_KEY=0x... npx tsx src/replay.ts ../bench/replay/nvda-2026-11-12.json
 *
 * Add --plan to print the moves without sending anything.
 *
 * Any funded testnet account can run it: the exchange buttons are public, so the script simply
 * waits out the public cooldown between updates. `DemoStage` moves the price in whole basis points
 * from wherever it is, so the script first walks the price to the night's closing price (the
 * "lead-in") and picks those steps so that every real price is hit to the cent.
 *
 * It writes bench/replay/results/<id>.json with every transaction hash.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, http, parseEventLogs, parseUnits, type Hash, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arenaAbi, feedAbi, stageAbi, vaultAbi } from "./abi.js";
import { chain, deployments, MARKET_ID, rpcUrl, sleep, usd, type VenueName } from "./config.js";
import { follow, hopMs, isDone, secs, stamp, type Clients, type LoopRecord } from "./loops.js";

const CLOSED = 0;
const OPEN = 1;
const HALTED = 2;
const STATUS: Record<string, number> = { closed: CLOSED, open: OPEN, halted: HALTED };
const MAX_MOVE = 2000;
const PROTECTED = 0n;
const TWIN = 1n;

interface Print {
  label: string;
  when: string;
  status: "closed" | "open" | "halted";
  price: string;
}
interface Scenario {
  id: string;
  title: string;
  prints: Print[];
}

const file = process.argv.slice(2).find((a) => !a.startsWith("--"));
if (!file) throw new Error("usage: replay.ts <scenario.json> [--plan]");
const planOnly = process.argv.includes("--plan");
const scenario = JSON.parse(readFileSync(resolve(file), "utf8")) as Scenario;

const d = deployments();
const venues = (Object.keys(d.venues) as VenueName[]).filter((v) => d.venues[v]);
const make = (name: "base" | "unichain" | "lasna") =>
  createPublicClient({ chain: chain(name), transport: http(rpcUrl(name), { retryCount: 4 }), cacheTime: 0 });
const clients: Clients = { base: make("base"), unichain: make("unichain"), lasna: make("lasna") };

// -------------------------------------------------------------------------------------------------
// The plan: which basis-point moves hit every real price to the cent
// -------------------------------------------------------------------------------------------------

/** What `DemoStage` does to the price for one move. */
const step = (price: bigint, bps: number): bigint => (price * BigInt(10_000 + bps)) / 10_000n;
const cents = (price: bigint): bigint => (price + 5n * 10n ** 15n) / 10n ** 16n;

interface Plan {
  leadIn: number[];
  moves: number[];
  prices: bigint[];
}

/**
 * `moves[i]` takes print i to print i+1. Working backwards from the last print gives the window the
 * first price has to fall in for all later prices to round to the right cent; the lead-in is then
 * chosen to land in the middle of that window.
 */
function plan(from: bigint, prints: bigint[]): Plan {
  const half = 5n * 10n ** 15n;
  const moves: number[] = [];
  let lo = Number(prints[prints.length - 1] - half);
  let hi = Number(prints[prints.length - 1] + half);
  for (let i = prints.length - 2; i >= 0; i--) {
    const bps = Math.round((Number(prints[i + 1]) / Number(prints[i]) - 1) * 10_000);
    if (Math.abs(bps) > MAX_MOVE) throw new Error("a move of " + bps + " bps is more than one update can make");
    moves.unshift(bps);
    lo = Math.max(lo / (1 + bps / 10_000), Number(prints[i] - half));
    hi = Math.min(hi / (1 + bps / 10_000), Number(prints[i] + half));
    if (lo >= hi) throw new Error("no whole-basis-point path hits every price to the cent");
  }
  const target = (lo + hi) / 2;

  const check = (leadIn: number[]): Plan | undefined => {
    let price = from;
    for (const m of leadIn) price = step(price, m);
    const prices = [price];
    for (const m of moves) prices.push(step(prices[prices.length - 1], m));
    return prices.every((p, i) => cents(p) === cents(prints[i])) ? { leadIn, moves, prices } : undefined;
  };

  const start = Number(from);
  const ratio = target / start;
  const stepsNeeded = Math.max(1, Math.ceil(Math.abs(Math.log(ratio)) / Math.log(ratio > 1 ? 1.2 : 1 / 0.8) - 1e-9));
  let best: { plan: Plan; miss: number } | undefined;
  const consider = (leadIn: number[]) => {
    const p = check(leadIn);
    if (!p) return;
    const miss = Math.abs(Number(p.prices[0]) - target);
    if (!best || miss < best.miss) best = { plan: p, miss };
  };
  const last = (soFar: number[], at: number) => {
    const exact = (target / at - 1) * 10_000;
    for (const m of [Math.floor(exact), Math.ceil(exact)]) if (Math.abs(m) <= MAX_MOVE) consider([...soFar, m]);
  };
  for (let n = stepsNeeded; n <= stepsNeeded + 1 && !best; n++) {
    if (n === 1) last([], start);
    else if (n === 2) for (let a = -MAX_MOVE; a <= MAX_MOVE; a++) last([a], start * (1 + a / 10_000));
    else {
      // Fix all but the last three steps at the largest move in the right direction, then search.
      const big = ratio > 1 ? MAX_MOVE : -MAX_MOVE;
      const fixed = Array<number>(n - 3).fill(big);
      const at0 = start * (1 + big / 10_000) ** (n - 3);
      for (let a = -MAX_MOVE; a <= MAX_MOVE; a++) {
        const at1 = at0 * (1 + a / 10_000);
        const need = target / at1;
        if (need > 1.44 || need < 0.64) continue;
        for (let b = -MAX_MOVE; b <= MAX_MOVE; b++) last([...fixed, a, b], at1 * (1 + b / 10_000));
      }
    }
  }
  if (!best) throw new Error("no lead-in found from " + usd(from) + " to " + usd(prints[0]));
  return best.plan;
}

// -------------------------------------------------------------------------------------------------
// Chain actions
// -------------------------------------------------------------------------------------------------

async function readMarket(): Promise<{ status: number; seq: bigint; price: bigint }> {
  const [status, seq, , price] = await clients.base.readContract({ address: d.origin.feed, abi: feedAbi, functionName: "markets", args: [MARKET_ID] });
  return { status, seq, price };
}

const market = await readMarket();
const targets = scenario.prints.map((p) => parseUnits(p.price, 18));
const route = plan(market.price, targets);
const pct = (bps: number) => (bps > 0 ? "+" : "") + (bps / 100).toFixed(2) + "%";

console.log("Replay: " + scenario.title);
console.log("  now " + usd(market.price) + ", lead-in " + route.leadIn.map(pct).join(", "));
scenario.prints.forEach((p, i) =>
  console.log("  " + p.label.padEnd(18) + p.when + "  " + p.status.padEnd(7) + usd(route.prices[i]) + (i ? "  (" + pct(route.moves[i - 1]) + ")" : "")),
);
if (planOnly) process.exit(0);

const key = (process.env.REPLAY_PRIVATE_KEY ?? process.env.DEPLOYER_PRIVATE_KEY) as Hex | undefined;
if (!key) throw new Error("set REPLAY_PRIVATE_KEY");
const account = privateKeyToAccount(key.startsWith("0x") ? key : (("0x" + key) as Hex));
const wallets = Object.fromEntries(
  venues.map((v) => [v, createWalletClient({ chain: chain(v), transport: http(rpcUrl(v)), account })]),
) as Record<VenueName, ReturnType<typeof createWalletClient>>;
const owner = await clients.base.readContract({ address: d.origin.stage, abi: stageAbi, functionName: "owner" });
const limited = owner.toLowerCase() !== account.address.toLowerCase();

async function cooldown(): Promise<void> {
  if (!limited) return;
  const [readyAt] = await clients.base.readContract({ address: d.origin.stage, abi: stageAbi, functionName: "availability" });
  const wait = Number(readyAt) * 1000 + 2000 - Date.now();
  if (wait > 0) await sleep(wait);
}

async function update(label: string, status: number, move: number): Promise<LoopRecord> {
  await cooldown();
  const [base, unichain, lasna] = await Promise.all([clients.base.getBlockNumber(), clients.unichain.getBlockNumber(), clients.lasna.getBlockNumber()]);
  const sentAt = Date.now();
  const hash = await wallets.base.writeContract({ address: d.origin.stage, abi: stageAbi, functionName: "act", args: [status, move], account, chain: chain("base") });
  const receipt = await clients.base.waitForTransactionReceipt({ hash, pollingInterval: 200 });
  if (receipt.status !== "success") throw new Error("the exchange transaction reverted: " + hash);
  const event = parseEventLogs({ abi: feedAbi, eventName: "MarketUpdate", logs: receipt.logs })[0];
  if (!event) throw new Error("no MarketUpdate in " + hash);
  const loop: LoopRecord = { seq: event.args.seq, origin: await stamp(clients.base, receipt.blockNumber, hash), applied: {}, seen: { origin: Date.now() - sentAt } };
  await follow(d, clients, loop, { base, unichain, lasna }, { sentAt, timeoutMs: 180_000 });
  const times = venues.map((v) => {
    const h = hopMs(loop, v);
    return chain(v).name.split(" ")[0] + " " + (h ? (h.precise ? secs(h.ms) : "≈" + Math.round(h.ms / 1000) + " s") : "missed");
  });
  console.log("  #" + loop.seq + " " + label.padEnd(18) + usd(event.args.price) + "  " + times.join(" · ") + (loop.closed ? " · loop closed" : " · LOOP NOT CLOSED"));
  if (!isDone(loop, venues)) throw new Error("update #" + loop.seq + " did not close its loop; stopping");
  return loop;
}

interface RaidResult {
  tx: Hash;
  outcome: "taken" | "nothing" | "blocked";
  pnl: bigint;
  poolPrice?: bigint;
  refPrice?: bigint;
}

async function raid(venue: VenueName, target: bigint): Promise<RaidResult> {
  const v = d.venues[venue]!;
  const tx = await wallets[venue].writeContract({ address: v.arena, abi: arenaAbi, functionName: "raid", args: [target], gas: 1_200_000n, account, chain: chain(venue) });
  const receipt = await clients[venue].waitForTransactionReceipt({ hash: tx });
  if (receipt.status !== "success") throw new Error("raid reverted: " + tx);
  const logs = parseEventLogs({ abi: arenaAbi, logs: receipt.logs });
  const took = logs.find((l) => l.eventName === "Raid");
  const none = logs.find((l) => l.eventName === "RaidPointless");
  let result: RaidResult;
  if (took && took.eventName === "Raid") result = { tx, outcome: "taken", pnl: took.args.pnl, poolPrice: took.args.poolPriceBefore, refPrice: took.args.refPrice };
  else if (none && none.eventName === "RaidPointless") result = { tx, outcome: "nothing", pnl: 0n, poolPrice: none.args.poolPrice, refPrice: none.args.refPrice };
  else result = { tx, outcome: "blocked", pnl: 0n };
  console.log("    raid " + chain(venue).name.split(" ")[0].padEnd(9) + (target === TWIN ? "twin      " : "protected ") + (result.outcome === "taken" ? usd(result.pnl) + " taken (pool was at " + usd(result.poolPrice!) + ")" : result.outcome));
  return result;
}

const everyVenue = async <T>(job: (v: VenueName) => Promise<T>): Promise<Record<VenueName, T>> =>
  Object.fromEntries(await Promise.all(venues.map(async (v) => [v, await job(v)]))) as Record<VenueName, T>;

// -------------------------------------------------------------------------------------------------
// Run
// -------------------------------------------------------------------------------------------------

const started = new Date();
const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(here, "../../bench/replay/results", scenario.id + ".json");
const result: Record<string, unknown> = { scenario, started: started.toISOString(), signer: account.address };
const save = () => {
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(result, (_, v: unknown) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
};

console.log("Lead-in: walking the price to " + usd(targets[0]));
const leadIn: unknown[] = [];
result.leadIn = leadIn;
for (const move of route.leadIn) {
  const loop = await update("move " + pct(move), OPEN, move);
  leadIn.push({ move, loop });
  save();
}
// The twins ignore market hours, so nothing moves them but a trade. One raid each brings them to the
// closing price, which is where a pool that nobody manages would be sitting at the bell.
console.log("  lining the twins up with the market");
result.lineUp = await everyVenue((v) => raid(v, TWIN));
save();

console.log("The night:");
const prints: unknown[] = [];
result.prints = prints;
for (let i = 0; i < scenario.prints.length; i++) {
  const p = scenario.prints[i];
  const loop = await update(p.label, STATUS[p.status], i === 0 ? 0 : route.moves[i - 1]);
  const entry: Record<string, unknown> = { ...p, move: i === 0 ? 0 : route.moves[i - 1], onChainPrice: (await readMarket()).price, loop };
  prints.push(entry);
  save();
  if (i === 0) continue;
  if (i === scenario.prints.length - 1) {
    const stale = route.prices[0];
    result.twins = await everyVenue(async (v) => {
      const venue = d.venues[v]!;
      const [poolPrice] = await clients[v].readContract({ address: venue.arena, abi: arenaAbi, functionName: "scout", args: [TWIN] });
      const valueBefore = await clients[v].readContract({ address: venue.twinVault, abi: vaultAbi, functionName: "valueAt", args: [stale] });
      return { poolPrice, valueBefore, raid: await raid(v, TWIN) };
    });
    save();
  }
  entry.protected = await everyVenue((v) => raid(v, PROTECTED));
  save();
}
console.log("Saved " + out);
