/**
 * Measures one market update's trip around the loop, from on-chain records only:
 *
 *   exchange event (Base) -> Reactive reacts (Lasna) -> each pool switches (Base, Unichain)
 *   -> both pools confirm back (Lasna, LoopClosed)
 *
 * Times come from block timestamps. Base Sepolia's RPC adds `timestampMs` (blocks are 200 ms
 * apart), so the Base-to-Base hop is exact to the block. Unichain only has whole seconds, so its
 * hop is good to about a second. Lasna's clock runs about a second behind, so it is never
 * subtracted from another chain's clock; Lasna hops are counted in blocks instead.
 */
import { toHex, type Hash, type PublicClient } from "viem";
import { conductorAbi, guardAbi } from "./abi.js";
import { MARKET_ID, sleep, type Deployments, type VenueName } from "./config.js";

export type Clients = Record<"base" | "unichain" | "lasna", PublicClient>;

export interface Stamp {
  block: bigint;
  tx: Hash;
  /** Block time in milliseconds. */
  ms: number;
  /** True when the chain gave the block time to the millisecond (Base Sepolia does). */
  precise: boolean;
}

export interface LoopRecord {
  seq: bigint;
  origin: Stamp;
  observed?: { block: bigint; tx: Hash };
  applied: Partial<Record<VenueName, Stamp>>;
  closed?: { block: bigint; tx: Hash };
  /** Wall-clock milliseconds, on this machine, from sending the exchange tx until each hop was first seen. */
  seen: Partial<Record<"origin" | "observed" | VenueName | "closed", number>>;
}

export async function stamp(client: PublicClient, block: bigint, tx: Hash): Promise<Stamp> {
  const raw = (await client.request({
    method: "eth_getBlockByNumber",
    params: [toHex(block), false],
  })) as { timestamp: `0x${string}`; timestampMs?: `0x${string}` } | null;
  if (!raw) throw new Error("block " + block + " not found");
  if (raw.timestampMs) return { block, tx, ms: Number(BigInt(raw.timestampMs)), precise: true };
  return { block, tx, ms: Number(BigInt(raw.timestamp)) * 1000, precise: false };
}

/** Milliseconds from the exchange event to a venue's switch, and whether both ends were exact. */
export function hopMs(loop: LoopRecord, venue: VenueName): { ms: number; precise: boolean } | undefined {
  const a = loop.applied[venue];
  if (!a) return undefined;
  return { ms: a.ms - loop.origin.ms, precise: a.precise && loop.origin.precise };
}

export function isDone(loop: LoopRecord, venues: VenueName[]): boolean {
  return Boolean(loop.observed && loop.closed && venues.every((v) => loop.applied[v]));
}

/**
 * Polls the three chains until every hop of `loop` has landed or `timeoutMs` passes.
 * `from` holds the block on each chain to start searching from (taken just before the exchange tx).
 */
export async function follow(
  d: Deployments,
  clients: Clients,
  loop: LoopRecord,
  from: Record<"base" | "unichain" | "lasna", bigint>,
  opts: { sentAt: number; timeoutMs?: number; pollMs?: number },
): Promise<LoopRecord> {
  const venues = (Object.keys(d.venues) as VenueName[]).filter((v) => d.venues[v]);
  const deadline = Date.now() + (opts.timeoutMs ?? 60_000);
  const pollMs = opts.pollMs ?? 400;
  const seen = (key: keyof LoopRecord["seen"]) => {
    loop.seen[key] ??= Date.now() - opts.sentAt;
  };

  while (!isDone(loop, venues) && Date.now() < deadline) {
    const jobs: Promise<void>[] = [];

    if (!loop.observed || !loop.closed) {
      jobs.push(
        (async () => {
          const find = async (eventName: "Observed" | "LoopClosed") =>
            (
              await clients.lasna.getContractEvents({
                address: d.reactive.conductor,
                abi: conductorAbi,
                eventName,
                args: { marketId: MARKET_ID, seq: loop.seq },
                fromBlock: from.lasna,
              })
            )[0];
          if (!loop.observed) {
            const log = await find("Observed");
            if (log) {
              loop.observed = { block: log.blockNumber, tx: log.transactionHash };
              seen("observed");
            }
          }
          if (loop.observed && !loop.closed) {
            const log = await find("LoopClosed");
            if (log) {
              loop.closed = { block: log.blockNumber, tx: log.transactionHash };
              seen("closed");
            }
          }
        })(),
      );
    }

    for (const venue of venues) {
      if (loop.applied[venue]) continue;
      const v = d.venues[venue]!;
      jobs.push(
        (async () => {
          const log = (
            await clients[venue].getContractEvents({
              address: v.guard,
              abi: guardAbi,
              eventName: "Applied",
              args: { marketId: MARKET_ID, seq: loop.seq },
              fromBlock: from[venue],
            })
          )[0];
          if (log) {
            seen(venue);
            loop.applied[venue] = await stamp(clients[venue], log.blockNumber, log.transactionHash);
          }
        })(),
      );
    }

    // A failed read (rate limit, timeout) is retried on the next pass.
    await Promise.allSettled(jobs);
    if (!isDone(loop, venues)) await sleep(pollMs);
  }
  return loop;
}

// -------------------------------------------------------------------------------------------------
// Statistics
// -------------------------------------------------------------------------------------------------

export function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return NaN;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[i];
}

export interface Summary {
  n: number;
  min: number;
  p50: number;
  p90: number;
  p99: number;
  max: number;
  mean: number;
}

export function summarize(values: number[]): Summary {
  const s = [...values].sort((a, b) => a - b);
  const mean = s.reduce((a, b) => a + b, 0) / (s.length || 1);
  return {
    n: s.length,
    min: s[0] ?? NaN,
    p50: percentile(s, 50),
    p90: percentile(s, 90),
    p99: percentile(s, 99),
    max: s[s.length - 1] ?? NaN,
    mean,
  };
}

export const secs = (ms: number, digits = 2) => (Number.isFinite(ms) ? (ms / 1000).toFixed(digits) + " s" : "—");
