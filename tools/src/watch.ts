/**
 * Loop stopwatch: watches the exchange feed and prints each update's trip around the loop as it
 * happens, whoever triggered it (the demo page, the benchmark, or a judge).
 *
 *   npx tsx src/watch.ts
 *
 * Read-only: it needs no wallet.
 */
import { createPublicClient, http } from "viem";
import { feedAbi, STATUS } from "./abi.js";
import { chain, deployments, MARKET_ID, rpcUrl, sleep, usd, type VenueName } from "./config.js";
import { follow, hopMs, secs, stamp, type Clients, type LoopRecord } from "./loops.js";

const d = deployments();
const venues = (Object.keys(d.venues) as VenueName[]).filter((v) => d.venues[v]);
const make = (name: "base" | "unichain" | "lasna") =>
  createPublicClient({ chain: chain(name), transport: http(rpcUrl(name), { retryCount: 4 }), cacheTime: 0 });
const clients: Clients = { base: make("base"), unichain: make("unichain"), lasna: make("lasna") };

let fromBase = await clients.base.getBlockNumber();
console.log("Watching the NVDA/USD feed on Base Sepolia from block " + fromBase + ". Ctrl-C to stop.");

for (;;) {
  try {
    const latest = await clients.base.getBlockNumber();
    if (latest >= fromBase) {
      const logs = await clients.base.getContractEvents({
        address: d.origin.feed,
        abi: feedAbi,
        eventName: "MarketUpdate",
        args: { marketId: MARKET_ID },
        fromBlock: fromBase,
        toBlock: latest,
      });
      fromBase = latest + 1n;
      for (const log of logs) void track(log.args.seq!, log.args.status!, log.args.price!, log.blockNumber, log.transactionHash);
    }
  } catch (error) {
    console.warn("read failed, retrying: " + (error instanceof Error ? error.message.split("\n")[0] : error));
  }
  await sleep(500);
}

async function track(seq: bigint, status: number, price: bigint, block: bigint, tx: `0x${string}`): Promise<void> {
  const seenAt = Date.now();
  const [unichain, lasna] = await Promise.all([clients.unichain.getBlockNumber(), clients.lasna.getBlockNumber()]);
  console.log("seq " + seq + ": exchange says " + STATUS[status] + " at " + usd(price) + "  (Base tx " + tx + ")");
  const loop: LoopRecord = { seq, origin: await stamp(clients.base, block, tx), applied: {}, seen: {} };
  // Search a little behind the current blocks, in case a hop landed while this one was being read.
  await follow(d, clients, loop, { base: block, unichain: unichain - 30n, lasna: lasna - 30n }, { sentAt: seenAt });
  const parts = venues.map((v) => {
    const h = hopMs(loop, v);
    return chain(v).name + (h ? " switched after " + (h.precise ? secs(h.ms) : "≈" + Math.round(h.ms / 1000) + " s") : " not seen");
  });
  const blocks = loop.observed && loop.closed ? loop.closed.block - loop.observed.block : undefined;
  parts.push(blocks !== undefined ? "loop closed " + blocks + " Lasna blocks after the reaction" : "loop not closed");
  console.log("seq " + seq + ": " + parts.join(" · "));
}
