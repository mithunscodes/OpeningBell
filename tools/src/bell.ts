/**
 * The real bell: posts NVIDIA's real closing bell and real opening bell to the exchange feed, at
 * NVIDIA's real price, then times the loop on both chains.
 *
 *   BELL_PRIVATE_KEY=0x... npx tsx src/bell.ts            # post the latest real bell if it is missing
 *   npx tsx src/bell.ts --dry                              # only say what it would post
 *
 * A scheduled GitHub workflow (.github/workflows/bell.yml) runs it every few minutes on weekdays.
 * It keeps no state of its own: it asks the market what the latest bell was (the regular session's
 * real start or end, so holidays and early closes come for free), asks the feed when its last
 * update happened, and posts only when the bell is newer than the feed. The update carries the
 * bell's own time as `sourceTime`, so a second run finds nothing to do. If someone presses an
 * exchange button on the demo page after the bell, that press is newer too, and the script leaves
 * the market alone until the next bell.
 *
 * The price comes from Yahoo Finance's public chart data for NVDA (Stooq as a fallback): the first
 * regular-session minute's open for the opening bell, the regular-session close for the closing bell.
 * The account needs to be a publisher on the feed and hold a little Base Sepolia ETH for gas.
 *
 * Each posted bell is appended to BELL_LOG (default bench/live/bells.json) with every transaction
 * and the measured times, which the demo page shows.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createPublicClient, createWalletClient, http, parseEventLogs, parseUnits, type Hash } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { feedAbi } from "./abi.js";
import { chain, deployments, MARKET_ID, rpcUrl, usd, type VenueName } from "./config.js";
import { follow, hopMs, stamp, type Clients, type LoopRecord } from "./loops.js";

const CLOSED = 0;
const OPEN = 1;
const SYMBOL = process.env.BELL_SYMBOL ?? "NVDA";
/** A bell older than this is not posted any more: the next one is closer. */
const STALE_AFTER_S = Number(process.env.BELL_STALE_AFTER ?? 6 * 3600);
/** The close is posted only once the market's own closing print is in (a few seconds after 4 PM). */
const CLOSE_SETTLE_S = 60;

export interface Session {
  /** Regular session start and end, unix seconds (America/New_York 9:30 and 16:00 on a normal day). */
  start: number;
  end: number;
  /** Open of the first regular-session minute, if the session has started. */
  open?: number;
  /** Latest regular-session price and its time. */
  last: number;
  lastTime: number;
  source: string;
}

export interface Bell {
  status: typeof CLOSED | typeof OPEN;
  /** The real time of the bell, unix seconds. */
  at: number;
  /** The real price in USD. */
  price: number;
}

// -------------------------------------------------------------------------------------------------
// The real market
// -------------------------------------------------------------------------------------------------

async function fromYahoo(host: string): Promise<Session> {
  const url = `https://${host}/v8/finance/chart/${SYMBOL}?interval=1m&range=1d`;
  const res = await fetch(url, { headers: { "user-agent": "Mozilla/5.0 (OpeningBell bell job)" } });
  if (!res.ok) throw new Error(host + " answered " + res.status);
  const body = (await res.json()) as {
    chart: {
      result?: {
        meta: {
          regularMarketPrice: number;
          regularMarketTime: number;
          currentTradingPeriod: { regular: { start: number; end: number } };
        };
        timestamp?: number[];
        indicators: { quote: { open: (number | null)[] }[] };
      }[];
    };
  };
  const r = body.chart.result?.[0];
  if (!r) throw new Error(host + " returned no chart");
  const { start, end } = r.meta.currentTradingPeriod.regular;
  const times = r.timestamp ?? [];
  const opens = r.indicators.quote[0]?.open ?? [];
  const i = times.findIndex((t) => t >= start && t < start + 60);
  const open = i >= 0 && opens[i] ? opens[i]! : undefined;
  return { start, end, open, last: r.meta.regularMarketPrice, lastTime: r.meta.regularMarketTime, source: "Yahoo Finance" };
}

/** Stooq only gives today's open and last price; the session times are taken from the normal NYSE day. */
async function fromStooq(): Promise<Session> {
  const res = await fetch(`https://stooq.com/q/l/?s=${SYMBOL.toLowerCase()}.us&f=sd2t2ohlcv&h&e=csv`);
  if (!res.ok) throw new Error("stooq answered " + res.status);
  const [, row] = (await res.text()).trim().split("\n");
  const [, date, , open, , , close] = row.split(",");
  if (!date || date === "N/D") throw new Error("stooq has no quote");
  const start = nyTime(date, 9, 30);
  const end = nyTime(date, 16, 0);
  return { start, end, open: Number(open), last: Number(close), lastTime: Math.min(Date.now() / 1000, end), source: "Stooq" };
}

/** Unix seconds of a wall-clock time in New York on `date` (YYYY-MM-DD). */
export function nyTime(date: string, hour: number, minute: number): number {
  const guess = Date.parse(`${date}T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:00Z`) / 1000;
  const offsetH = Number(
    new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hour: "numeric", hourCycle: "h23" })
      .format(new Date(guess * 1000)),
  ) - hour;
  // offsetH is -4 or -5 (or +19/+20 across midnight); New York is behind UTC.
  const behind = ((-offsetH % 24) + 24) % 24;
  return guess + behind * 3600;
}

export async function session(): Promise<Session> {
  // For rehearsals: a fixed session instead of the real market.
  if (process.env.BELL_SESSION) return JSON.parse(process.env.BELL_SESSION) as Session;
  const errors: string[] = [];
  for (const get of [() => fromYahoo("query1.finance.yahoo.com"), () => fromYahoo("query2.finance.yahoo.com"), fromStooq]) {
    try {
      return await get();
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
  }
  throw new Error("no price source answered: " + errors.join("; "));
}

/** The latest real bell at `now`, or undefined while there is nothing new to post yet. */
export function latestBell(s: Session, now: number): Bell | undefined {
  if (now >= s.start && now < s.end) {
    // The first minute's open is known once that minute is over; give the source a little time.
    if (s.open === undefined && now < s.start + 180) return undefined;
    return { status: OPEN, at: s.start, price: s.open ?? s.last };
  }
  if (now >= s.end + CLOSE_SETTLE_S && s.lastTime >= s.end - 60) {
    return { status: CLOSED, at: s.end, price: s.last };
  }
  return undefined;
}

// -------------------------------------------------------------------------------------------------
// The log
// -------------------------------------------------------------------------------------------------

export interface BellEntry {
  bell: "open" | "close";
  /** Real bell time, ISO. */
  at: string;
  price: string;
  source: string;
  seq: string;
  /** Exchange event on Base Sepolia, and how long after the real bell it landed (the job's own delay). */
  posted: { tx: Hash; block: string; time: string; afterBellS: number };
  /** Seconds from the exchange event to each pool switching, from block timestamps. */
  switched: Partial<Record<VenueName, { tx: Hash; seconds: number; exact: boolean }>>;
  reacted?: Hash;
  closed?: Hash;
}

const logPath = resolve(process.env.BELL_LOG ?? resolve(dirname(new URL(import.meta.url).pathname), "../../bench/live/bells.json"));

function readLog(): BellEntry[] {
  return existsSync(logPath) ? (JSON.parse(readFileSync(logPath, "utf8")) as BellEntry[]) : [];
}

// -------------------------------------------------------------------------------------------------
// Main
// -------------------------------------------------------------------------------------------------

async function main() {
  const dry = process.argv.includes("--dry");
  const now = process.env.BELL_NOW ? Number(process.env.BELL_NOW) : Math.floor(Date.now() / 1000);
  const s = await session();
  const bell = latestBell(s, now);
  const fmt = (t: number) => new Date(t * 1000).toISOString().replace(".000Z", "Z");
  console.log(`${SYMBOL} regular session ${fmt(s.start)} to ${fmt(s.end)} (${s.source}), last ${s.last} at ${fmt(s.lastTime)}`);
  if (!bell) return console.log("No bell to post right now.");
  const name = bell.status === OPEN ? "open" : "close";
  if (now - bell.at > STALE_AFTER_S) return console.log(`The ${name} at ${fmt(bell.at)} is too old to post.`);

  const d = deployments();
  const make = (n: "base" | "unichain" | "lasna") =>
    createPublicClient({ chain: chain(n), transport: http(rpcUrl(n), { retryCount: 4 }), cacheTime: 0 });
  const clients: Clients = { base: make("base"), unichain: make("unichain"), lasna: make("lasna") };

  const [, , feedSourceTime] = await clients.base.readContract({
    address: d.origin.feed,
    abi: feedAbi,
    functionName: "markets",
    args: [MARKET_ID],
  });
  if (Number(feedSourceTime) >= bell.at) {
    return console.log(`The feed already has an update from ${fmt(Number(feedSourceTime))}, at or after the ${name} at ${fmt(bell.at)}.`);
  }

  const price = parseUnits(bell.price.toFixed(2), 18);
  console.log(`Posting the real ${name} of ${fmt(bell.at)} at ${usd(price)}.`);
  if (dry) return;

  const key = process.env.BELL_PRIVATE_KEY;
  if (!key) throw new Error("BELL_PRIVATE_KEY is not set");
  const account = privateKeyToAccount((key.startsWith("0x") ? key : "0x" + key) as `0x${string}`);
  if (!(await clients.base.readContract({ address: d.origin.feed, abi: feedAbi, functionName: "publishers", args: [account.address] }))) {
    throw new Error(account.address + " is not a publisher on the feed");
  }
  const wallet = createWalletClient({ account, chain: chain("base"), transport: http(rpcUrl("base")) });

  const [uniFrom, lasnaFrom] = await Promise.all([clients.unichain.getBlockNumber(), clients.lasna.getBlockNumber()]);
  const sentAt = Date.now();
  const tx = await wallet.writeContract({
    address: d.origin.feed,
    abi: feedAbi,
    functionName: "publish",
    args: [MARKET_ID, bell.status, price, BigInt(bell.at)],
  });
  const receipt = await clients.base.waitForTransactionReceipt({ hash: tx });
  if (receipt.status !== "success") throw new Error("publish reverted: " + tx);
  const [update] = parseEventLogs({ abi: feedAbi, logs: receipt.logs, eventName: "MarketUpdate" });
  const seq = update.args.seq;

  const loop: LoopRecord = { seq, origin: await stamp(clients.base, receipt.blockNumber, tx), applied: {}, seen: {} };
  await follow(d, clients, loop, { base: receipt.blockNumber, unichain: uniFrom - 5n, lasna: lasnaFrom - 5n }, { sentAt, timeoutMs: 120_000 });

  const entry: BellEntry = {
    bell: name,
    at: fmt(bell.at),
    price: bell.price.toFixed(2),
    source: s.source,
    seq: seq.toString(),
    posted: {
      tx,
      block: receipt.blockNumber.toString(),
      time: new Date(loop.origin.ms).toISOString(),
      afterBellS: Math.round(loop.origin.ms / 1000 - bell.at),
    },
    switched: {},
    reacted: loop.observed?.tx,
    closed: loop.closed?.tx,
  };
  for (const v of Object.keys(d.venues) as VenueName[]) {
    const h = hopMs(loop, v);
    if (h) entry.switched[v] = { tx: loop.applied[v]!.tx, seconds: Math.round(h.ms / 100) / 10, exact: h.precise };
  }

  const log = readLog();
  log.push(entry);
  mkdirSync(dirname(logPath), { recursive: true });
  writeFileSync(logPath, JSON.stringify(log, null, 2) + "\n");
  console.log(JSON.stringify(entry, null, 2));
  if (!loop.closed) throw new Error("the loop did not close within two minutes; the watchdog will keep re-sending");
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname)) {
  await main();
}
