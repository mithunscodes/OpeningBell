/**
 * Beat the bell: how fast does a raider have to be?
 *
 * Each attempt publishes a price move on the race market (a separate market id, with its own pools,
 * so the demo is never touched) and then raids both race pools after a set delay: the protected
 * pool, which the loop re-prices, and its twin, which nothing re-prices. The raider reads the new
 * price straight from the feed, on the same chain as the news. That is the fastest attacker there
 * can be, so the result is the real exposure window: the delay below which a raid still pays.
 *
 *   RACE_PRIVATE_KEY=0x... npx tsx src/race.ts                 # 16 delays, 0.0 to 3.0 s, twice each
 *   RACE_PRIVATE_KEY=0x... npx tsx src/race.ts --delays 0,1,2 --rounds 1 --move 500
 *
 * The key must be a publisher on the feed (the deployer is), because the race market has no public
 * buttons. The publish and both raids are sent from that one account with consecutive nonces, so a
 * raid can never land before the news it is racing.
 *
 * Delays are counted on this machine from sending the news; what is recorded and reported is the
 * gap on Base Sepolia's own clock (block times to 200 ms), from the block with the news to the
 * block with the raid. Writes bench/race/results/<time>.json with every transaction hash.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, http, parseEventLogs, type Address, type Hash, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arenaAbi, feedAbi, guardAbi, vaultAbi } from "./abi.js";
import { chain, deployments, rpcUrl, sleep, usd, type VenueName } from "./config.js";
import { follow, isDone, secs, stamp, type Clients, type LoopRecord, type Stamp } from "./loops.js";

const OPEN = 1;
const PROTECTED = 0n;
const TWIN = 1n;
const RAID_GAS = 1_200_000n;

interface RaceDeployment {
  chainId: number;
  block: number;
  marketId: Hex;
  arena: Address;
  vault: Address;
  twinVault: Address;
  stock: Address;
  dollars: Address;
}

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const arg = (name: string) => {
  const i = process.argv.indexOf("--" + name);
  return i > 0 ? process.argv[i + 1] : undefined;
};
const delays = (arg("delays") ?? Array.from({ length: 16 }, (_, i) => (i * 0.2).toFixed(1)).join(","))
  .split(",")
  .map(Number);
const rounds = Number(arg("rounds") ?? 2);
const moveBps = Number(arg("move") ?? 500);

const d = deployments();
const race = JSON.parse(
  readFileSync(resolve(root, process.env.DEPLOYMENTS_DIR ?? "deployments", "race-" + d.origin.chainId + ".json"), "utf8"),
) as RaceDeployment;
const venues = (Object.keys(d.venues) as VenueName[]).filter((v) => d.venues[v]);
const make = (name: "base" | "unichain" | "lasna") =>
  createPublicClient({ chain: chain(name), transport: http(rpcUrl(name), { retryCount: 4 }), cacheTime: 0 });
const clients: Clients = { base: make("base"), unichain: make("unichain"), lasna: make("lasna") };
const base = clients.base;

const key = (process.env.RACE_PRIVATE_KEY ?? process.env.DEPLOYER_PRIVATE_KEY) as Hex | undefined;
if (!key) throw new Error("set RACE_PRIVATE_KEY (a publisher on the feed)");
const account = privateKeyToAccount(key.startsWith("0x") ? key : (("0x" + key) as Hex));
const wallet = createWalletClient({ chain: chain("base"), transport: http(rpcUrl("base")), account });

if (!(await base.readContract({ address: d.origin.feed, abi: feedAbi, functionName: "publishers", args: [account.address] }))) {
  throw new Error(account.address + " is not a publisher on the feed");
}

interface RaidRecord {
  tx: Hash;
  at: Stamp;
  index: number;
  outcome: "taken" | "nothing" | "blocked";
  pnl: bigint;
  poolPrice?: bigint;
  refPrice?: bigint;
}

interface Attempt {
  attempt: number;
  delayTarget: number;
  moveBps: number;
  priceBefore: bigint;
  price: bigint;
  loop: LoopRecord;
  /** Base block time from the news to the raid, in milliseconds. */
  raidLagMs: number;
  /** Base block time from the news to the protected pool being re-priced, in milliseconds. */
  loopMs?: number;
  raids: { protected: RaidRecord; twin: RaidRecord };
}

async function readRace(): Promise<{ seq: bigint; price: bigint }> {
  const [, seq, , price] = await base.readContract({ address: d.origin.feed, abi: feedAbi, functionName: "markets", args: [race.marketId] });
  return { seq, price };
}

async function settle(hash: Hash): Promise<{ at: Stamp; index: number; logs: Parameters<typeof parseEventLogs>[0]["logs"] }> {
  const r = await base.waitForTransactionReceipt({ hash, pollingInterval: 200, timeout: 120_000 });
  if (r.status !== "success") throw new Error("transaction reverted: " + hash);
  return { at: await stamp(base, r.blockNumber, hash), index: r.transactionIndex, logs: r.logs };
}

function readRaid(hash: Hash, s: Awaited<ReturnType<typeof settle>>): RaidRecord {
  const logs = parseEventLogs({ abi: arenaAbi, logs: s.logs });
  const took = logs.find((l) => l.eventName === "Raid");
  const none = logs.find((l) => l.eventName === "RaidPointless");
  const r = { tx: hash, at: s.at, index: s.index };
  if (took?.eventName === "Raid") return { ...r, outcome: "taken", pnl: took.args.pnl, poolPrice: took.args.poolPriceBefore, refPrice: took.args.refPrice };
  if (none?.eventName === "RaidPointless") return { ...r, outcome: "nothing", pnl: 0n, poolPrice: none.args.poolPrice, refPrice: none.args.refPrice };
  return { ...r, outcome: "blocked", pnl: 0n };
}

async function attempt(n: number, delay: number, bps: number): Promise<Attempt> {
  const before = await readRace();
  const price = (before.price * BigInt(10_000 + bps)) / 10_000n;
  const [b, u, l] = await Promise.all([base.getBlockNumber(), clients.unichain.getBlockNumber(), clients.lasna.getBlockNumber()]);
  const nonce = await base.getTransactionCount({ address: account.address, blockTag: "pending" });
  const fees = await base.estimateFeesPerGas();
  const fee = { maxFeePerGas: fees.maxFeePerGas * 2n, maxPriorityFeePerGas: fees.maxPriorityFeePerGas * 2n + 1n };

  const sentAt = Date.now();
  const news = wallet.writeContract({
    address: d.origin.feed, abi: feedAbi, functionName: "publish",
    args: [race.marketId, OPEN, price, BigInt(Math.floor(sentAt / 1000))],
    nonce, gas: 120_000n, ...fee, account, chain: chain("base"),
  });
  await sleep(Math.max(0, sentAt + delay * 1000 - Date.now()));
  const raid = (target: bigint, k: number) =>
    wallet.writeContract({ address: race.arena, abi: arenaAbi, functionName: "raid", args: [target], nonce: nonce + k, gas: RAID_GAS, ...fee, account, chain: chain("base") });
  const [newsTx, protTx, twinTx] = await Promise.all([news, raid(PROTECTED, 1), raid(TWIN, 2)]);

  const [newsR, protR, twinR] = await Promise.all([settle(newsTx), settle(protTx), settle(twinTx)]);
  const event = parseEventLogs({ abi: feedAbi, eventName: "MarketUpdate", logs: newsR.logs })[0];
  if (!event) throw new Error("no MarketUpdate in " + newsTx);

  const loop: LoopRecord = { seq: event.args.seq, origin: newsR.at, applied: {}, seen: {} };
  await follow(d, clients, loop, { base: b, unichain: u, lasna: l }, { sentAt, timeoutMs: 180_000, marketId: race.marketId });
  if (!isDone(loop, venues)) throw new Error("race update #" + loop.seq + " did not close its loop; stopping");

  // The twin only moves when somebody trades it. Line it up with the new price for the next attempt,
  // the way its liquidity provider eventually would.
  await settle(await wallet.writeContract({ address: race.twinVault, abi: vaultAbi, functionName: "catchUp", account, chain: chain("base") }));

  const result: Attempt = {
    attempt: n, delayTarget: delay, moveBps: bps, priceBefore: before.price, price, loop,
    raidLagMs: protR.at.ms - newsR.at.ms,
    loopMs: loop.applied.base ? loop.applied.base.ms - newsR.at.ms : undefined,
    raids: { protected: readRaid(protTx, protR), twin: readRaid(twinTx, twinR) },
  };
  const show = (r: RaidRecord) => (r.outcome === "taken" ? usd(r.pnl).padStart(11) : r.outcome.padStart(11));
  console.log(
    "  " + String(n).padStart(2) + "  wait " + delay.toFixed(1) + " s  raid at +" + secs(result.raidLagMs, 1).padEnd(6) +
      " pool safe at +" + (result.loopMs === undefined ? "?" : secs(result.loopMs, 1)).padEnd(6) +
      " protected " + show(result.raids.protected) + "   twin " + show(result.raids.twin),
  );
  return result;
}

// -------------------------------------------------------------------------------------------------

const started = new Date();
const out = resolve(root, "bench/race/results", started.toISOString().replace(/[:.]/g, "-") + ".json");
const attempts: Attempt[] = [];
const save = () => {
  mkdirSync(dirname(out), { recursive: true });
  const body = { started: started.toISOString(), signer: account.address, race, delays, rounds, moveBps, attempts };
  writeFileSync(out, JSON.stringify(body, (_, v: unknown) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
};

// The race market's first state is published by DeployRace. Until the guard has it, the protected
// race pool refuses every trade, which would make the first attempts look safer than they are.
{
  const guard = d.venues.base!.guard;
  const until = Date.now() + 120_000;
  for (;;) {
    const feedSeq = (await readRace()).seq;
    const [, , , , guardSeq] = await base.readContract({ address: guard, abi: guardAbi, functionName: "current", args: [race.marketId] });
    if (feedSeq > 0n && guardSeq === feedSeq) break;
    if (Date.now() > until) throw new Error("the guard has race update #" + guardSeq + " but the feed is at #" + feedSeq + "; is the loop running?");
    await sleep(2000);
  }
}

const plan: number[] = [];
for (let r = 0; r < rounds; r++) plan.push(...delays);
console.log("Beat the bell: " + plan.length + " attempts, moves of " + (moveBps / 100).toFixed(2) + "%, race market " + race.marketId.slice(0, 10) + "…");
console.log("  start price " + usd((await readRace()).price));

for (let i = 0; i < plan.length; i++) {
  // Alternate down and up so the price stays near where it started.
  attempts.push(await attempt(i + 1, plan[i], i % 2 === 0 ? -moveBps : moveBps));
  save();
}

const got = attempts.filter((a) => a.raids.protected.outcome === "taken");
const missed = attempts.filter((a) => a.raids.protected.outcome === "nothing");
const twinPaid = attempts.filter((a) => a.raids.twin.outcome === "taken");
const sum = (xs: Attempt[], k: "protected" | "twin") => xs.reduce((s, a) => s + a.raids[k].pnl, 0n);
console.log("");
console.log("Protected pool: " + got.length + " of " + attempts.length + " raids paid, " + usd(sum(attempts, "protected")) + " in total");
console.log("Twin pool:      " + twinPaid.length + " of " + attempts.length + " raids paid, " + usd(sum(attempts, "twin")) + " in total");
if (got.length) console.log("Slowest raid that still paid:  +" + secs(Math.max(...got.map((a) => a.raidLagMs)), 1));
if (missed.length) console.log("Fastest raid that got nothing: +" + secs(Math.min(...missed.map((a) => a.raidLagMs)), 1));
console.log("Saved " + out);
