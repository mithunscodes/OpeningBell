/**
 * Latency benchmark: plays many market updates and times each one's trip around the loop.
 *
 *   DEPLOYER_PRIVATE_KEY=0x... npx tsx src/bench.ts --rounds 100
 *
 * Options: --rounds N (required), --move BPS (price move per reopen or move, default 100 = 1%),
 * --gap MS (pause between rounds, default 2000), --timeout MS (per loop, default 60000).
 *
 * The signer should own the DemoStage (the deployer does), which skips the public cooldown.
 * Each round costs about 0.05 lREACT on Lasna (three reactive transactions), so the script stops
 * by itself if the Reactive contract runs into debt, or if two loops in a row do not finish.
 *
 * On the testnets it writes bench/results/<time>.json (every loop, with transaction hashes) and
 * bench/RESULTS.md (the summary). On local forks it writes deployments/rehearsal/bench.json only,
 * because a local relay's timings say nothing about Reactive Network.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, formatEther, http, parseEventLogs, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { feedAbi, proxyAbi, stageAbi, systemAbi } from "./abi.js";
import { chain, deployments, MARKET_ID, rpcUrl, sleep, SYSTEM, usd, type VenueName } from "./config.js";
import { follow, hopMs, isDone, secs, stamp, summarize, type Clients, type LoopRecord } from "./loops.js";

// -------------------------------------------------------------------------------------------------
// Setup
// -------------------------------------------------------------------------------------------------

function option(name: string, fallback?: number): number {
  const i = process.argv.indexOf("--" + name);
  if (i === -1) {
    if (fallback === undefined) throw new Error("missing --" + name);
    return fallback;
  }
  const value = Number(process.argv[i + 1]);
  if (!Number.isFinite(value)) throw new Error("--" + name + " needs a number");
  return value;
}

const rounds = option("rounds");
const moveBps = option("move", 100);
const gapMs = option("gap", 2000);
const timeoutMs = option("timeout", 60_000);

const key = process.env.DEPLOYER_PRIVATE_KEY as Hex | undefined;
if (!key) throw new Error("set DEPLOYER_PRIVATE_KEY");
const account = privateKeyToAccount(key);

const d = deployments();
const venues = (Object.keys(d.venues) as VenueName[]).filter((v) => d.venues[v]);
const local = rpcUrl("base").includes("127.0.0.1") || rpcUrl("base").includes("localhost");

const make = (name: "base" | "unichain" | "lasna") =>
  createPublicClient({ chain: chain(name), transport: http(rpcUrl(name), { retryCount: 4 }), cacheTime: 0 });
const clients: Clients = { base: make("base"), unichain: make("unichain"), lasna: make("lasna") };
const wallet = createWalletClient({ chain: chain("base"), transport: http(rpcUrl("base")), account });

const CLOSED = 0;
const OPEN = 1;
const HALTED = 2;

// -------------------------------------------------------------------------------------------------
// One round
// -------------------------------------------------------------------------------------------------

interface Action {
  label: string;
  status: number;
  move: number;
}

/**
 * Cycles through the moments that matter (halt, close, reopen at a new price, a move while open)
 * and always moves the price back towards where it started, so a long run does not drift.
 */
function nextAction(status: number, price: bigint, startPrice: bigint, i: number): Action {
  const towardsStart = price === 0n || startPrice === 0n || price < startPrice ? moveBps : -moveBps;
  const pct = (towardsStart > 0 ? "+" : "") + towardsStart / 100 + "%";
  if (status === OPEN) {
    const pick = i % 3;
    if (pick === 0) return { label: "halt", status: HALTED, move: 0 };
    if (pick === 1) return { label: "close", status: CLOSED, move: 0 };
    return { label: "move " + pct, status: OPEN, move: towardsStart };
  }
  return { label: (status === HALTED ? "resume " : "open ") + pct, status: OPEN, move: towardsStart };
}

async function readMarket(): Promise<{ status: number; seq: bigint; price: bigint }> {
  const [status, seq, , price] = await clients.base.readContract({
    address: d.origin.feed,
    abi: feedAbi,
    functionName: "markets",
    args: [MARKET_ID],
  });
  return { status, seq, price };
}

async function conductorDebt(): Promise<bigint> {
  return clients.lasna.readContract({ address: SYSTEM, abi: systemAbi, functionName: "debt", args: [d.reactive.conductor] });
}

/**
 * Why a loop might have stalled: a contract that owes fees is skipped by Reactive Network until the
 * debt is paid. The Reactive contract pays on Lasna; each guard pays its chain's callback proxy.
 */
async function funds(): Promise<string[]> {
  const lines: string[] = [];
  const debt = await conductorDebt().catch(() => undefined);
  const held = await clients.lasna.getBalance({ address: d.reactive.conductor }).catch(() => undefined);
  lines.push(
    "Reactive contract on Lasna: holds " + (held === undefined ? "?" : formatEther(held)) + " lREACT, owes " +
      (debt === undefined ? "?" : formatEther(debt)),
  );
  for (const v of venues) {
    const venue = d.venues[v]!;
    const [owed, held] = await Promise.all([
      clients[v].readContract({ address: venue.callbackProxy, abi: proxyAbi, functionName: "debt", args: [venue.guard] }).catch(() => undefined),
      clients[v].getBalance({ address: venue.guard }).catch(() => undefined),
    ]);
    lines.push(
      "Guard on " + chain(v).name + ": holds " + (held === undefined ? "?" : formatEther(held)) + " ETH, owes " +
        (owed === undefined ? "?" : formatEther(owed)) + (owed && owed > 0n ? "  <- in debt: send it ETH, then call coverDebt()" : ""),
    );
  }
  return lines;
}

async function play(action: Action): Promise<LoopRecord> {
  const [base, unichain, lasna] = await Promise.all([
    clients.base.getBlockNumber(),
    clients.unichain.getBlockNumber(),
    clients.lasna.getBlockNumber(),
  ]);
  const sentAt = Date.now();
  const hash = await wallet.writeContract({
    address: d.origin.stage,
    abi: stageAbi,
    functionName: "act",
    args: [action.status, action.move],
  });
  const receipt = await clients.base.waitForTransactionReceipt({ hash, pollingInterval: 200 });
  if (receipt.status !== "success") throw new Error("the exchange transaction reverted: " + hash);
  const update = parseEventLogs({ abi: feedAbi, eventName: "MarketUpdate", logs: receipt.logs })[0];
  if (!update) throw new Error("no MarketUpdate in " + hash);

  const loop: LoopRecord = {
    seq: update.args.seq,
    origin: await stamp(clients.base, receipt.blockNumber, hash),
    applied: {},
    seen: { origin: Date.now() - sentAt },
  };
  return follow(d, clients, loop, { base, unichain, lasna }, { sentAt, timeoutMs, pollMs: local ? 200 : 400 });
}

function line(i: number, action: Action, loop: LoopRecord): string {
  const parts = venues.map((v) => {
    const h = hopMs(loop, v);
    if (!h) return chain(v).name.split(" ")[0] + " missed";
    return chain(v).name.split(" ")[0] + " " + (h.precise ? secs(h.ms) : "≈" + Math.round(h.ms / 1000) + " s");
  });
  const blocks = loop.observed && loop.closed ? loop.closed.block - loop.observed.block : undefined;
  parts.push(blocks !== undefined ? "loop closed " + blocks + " Lasna blocks after the reaction" : "loop not closed");
  return "#" + String(i + 1).padStart(3) + " " + action.label.padEnd(12) + " seq " + loop.seq + ": " + parts.join(" · ");
}

// -------------------------------------------------------------------------------------------------
// Report
// -------------------------------------------------------------------------------------------------

function report(loops: { action: Action; loop: LoopRecord }[], started: Date): { text: string; json: unknown } {
  const done = loops.filter((l) => isDone(l.loop, venues));
  const rows: string[] = [];
  const stats: Record<string, unknown> = {};

  const row = (label: string, values: number[], clock: string, fmt: (ms: number) => string) => {
    const s = summarize(values);
    stats[label] = s;
    rows.push("| " + [label, fmt(s.p50), fmt(s.p90), fmt(s.max), fmt(s.min), String(s.n), clock].join(" | ") + " |");
  };

  for (const v of venues) {
    const hops = loops.map((l) => hopMs(l.loop, v)).filter((h) => h !== undefined);
    const precise = hops.length > 0 && hops.every((h) => h.precise);
    row(
      "Exchange event → " + chain(v).name + " pool switched",
      hops.map((h) => h.ms),
      precise ? "block times in ms (" + chain(v).name + " blocks are 200 ms apart)" : "block times in whole seconds (±1 s)",
      precise ? (ms) => secs(ms) : (ms) => (Number.isFinite(ms) ? "≈" + Math.round(ms / 1000) + " s" : "—"),
    );
  }
  row(
    "Reaction → both pools confirmed (Lasna blocks)",
    done.map((l) => Number(l.loop.closed!.block - l.loop.observed!.block)),
    "Lasna blocks, about 1 s each",
    (n) => (Number.isFinite(n) ? String(n) : "—"),
  );
  for (const v of venues) {
    row(
      "Wall clock: tx sent → " + chain(v).name + " switch seen",
      loops.map((l) => l.loop.seen[v]).filter((ms): ms is number => ms !== undefined),
      "this machine's clock; includes the exchange tx's own inclusion and RPC polling",
      (ms) => secs(ms, 1),
    );
  }

  const text = [
    "# Loop latency" + (local ? " (local forks, not meaningful)" : " on the live testnets"),
    "",
    "Run started " + started.toISOString() + ". " + loops.length + " market updates, cycling through halt, close, reopen and",
    "price moves of " + moveBps / 100 + "%. " + done.length + " of " + loops.length + " loops finished within " + timeoutMs / 1000 + " s.",
    "",
    "| Hop | p50 | p90 | max | min | n | Clock |",
    "| --- | --- | --- | --- | --- | --- | --- |",
    ...rows,
    "",
    "Times come from block timestamps, not from this machine, except the wall-clock rows. Lasna's",
    "clock runs about a second behind the others, so Lasna hops are counted in blocks. Every loop's",
    "transactions are listed in the matching file in `bench/results/`.",
    "",
  ].join("\n");

  const json = {
    started: started.toISOString(),
    local,
    moveBps,
    timeoutMs,
    stats,
    loops: loops.map(({ action, loop }) => ({ action: action.label, ...loop })),
  };
  return { text, json };
}

// -------------------------------------------------------------------------------------------------
// Run
// -------------------------------------------------------------------------------------------------

const owner = await clients.base.readContract({ address: d.origin.stage, abi: stageAbi, functionName: "owner" });
if (owner.toLowerCase() !== account.address.toLowerCase()) {
  throw new Error("the signer " + account.address + " does not own the DemoStage (" + owner + "), so the cooldown would apply");
}
const balance = await clients.lasna.getBalance({ address: d.reactive.conductor });
console.log(
  "Benchmark: " + rounds + " rounds on " + (local ? "local forks" : "the live testnets") + ", venues: " + venues.join(", "),
);
console.log(
  "Reactive contract holds " + formatEther(balance) + " lREACT; this run needs about " + (rounds * 0.05).toFixed(2) + ".",
);
for (const l of await funds()) console.log("  " + l);

const started = new Date();
const loops: { action: Action; loop: LoopRecord }[] = [];
let startPrice = 0n;
let misses = 0;

const stamped = started.toISOString().replace(/[:.]/g, "-");
const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const save = () => {
  const { text, json } = report(loops, started);
  const replacer = (_: string, v: unknown) => (typeof v === "bigint" ? v.toString() : v);
  if (local) {
    const out = resolve(root, process.env.DEPLOYMENTS_DIR ?? "deployments/rehearsal", "bench.json");
    writeFileSync(out, JSON.stringify(json, replacer, 2) + "\n");
  } else {
    const out = resolve(root, "bench/results", stamped + ".json");
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, JSON.stringify(json, replacer, 2) + "\n");
    writeFileSync(resolve(root, "bench/RESULTS.md"), text);
  }
  return text;
};

for (let i = 0; i < rounds; i++) {
  const market = await readMarket();
  if (!startPrice && market.price > 0n) startPrice = market.price;
  const action = nextAction(market.seq === 0n ? CLOSED : market.status, market.price, startPrice, i);
  let loop: LoopRecord;
  try {
    loop = await play(action);
  } catch (error) {
    console.error("#" + (i + 1) + " " + action.label + " failed: " + (error instanceof Error ? error.message : error));
    if (++misses >= 2) break;
    continue;
  }
  loops.push({ action, loop });
  console.log(line(i, action, loop) + "   (" + usd((await readMarket()).price) + ")");

  misses = isDone(loop, venues) ? 0 : misses + 1;
  if (misses > 0) for (const l of await funds()) console.error("  " + l);
  if (misses >= 2) {
    console.error("Two loops in a row did not finish; stopping.");
    break;
  }
  const debt = await conductorDebt().catch(() => 0n);
  if (debt > 0n) {
    console.error("The Reactive contract owes " + formatEther(debt) + " lREACT; top it up before running more. Stopping.");
    break;
  }
  if (i % 10 === 9) save();
  await sleep(gapMs);
}

console.log("\n" + save());
