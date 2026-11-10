/**
 * Rehearsal: the whole loop on local forks, before any testnet funds are spent.
 *
 * Three anvil instances fork Base Sepolia, Unichain Sepolia and Reactive Lasna. This script plays
 * the one part a fork cannot: the Reactive Network node. It watches the forks for events our
 * conductor subscribed to, hands each one to the real system contract (`trigger`, sent from the
 * network's own injection address), then delivers every callback the system contract asks for
 * through the real callback proxy on the destination fork (sent from the network's own operator).
 *
 * So the system contract, the proxies, the fee accounting and Uniswap v4 are all the deployed code.
 * Only the timing is fake, which is why latency is measured on the live networks instead.
 *
 *   anvil --fork-url https://sepolia.base.org     --port 8545
 *   anvil --fork-url https://sepolia.unichain.org --port 8546
 *   anvil --fork-url https://lasna-rpc.rnk.dev/   --port 8547
 *   DEPLOYMENTS_DIR=deployments/rehearsal BASE_RPC=http://127.0.0.1:8545 \
 *     UNICHAIN_RPC=http://127.0.0.1:8546 LASNA_RPC=http://127.0.0.1:8547 npm run rehearse
 */
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  decodeAbiParameters,
  decodeEventLog,
  encodeAbiParameters,
  http,
  parseEther,
  parseGwei,
  type Address,
  type Hex,
  type Log,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arenaAbi, conductorAbi, feedAbi, guardAbi, proxyAbi, stageAbi, STATUS, systemAbi, TOPIC, vaultAbi } from "./abi.js";
import { chain, chainNameOf, deployments, MARKET_ID, SYSTEM, usd, type ChainName, type Venue, type VenueName } from "./config.js";

/** Reactive Network's fixed sender for node-injected reactive transactions (SystemContract.INJ_ADDR). */
const INJECTOR: Address = "0x038E06667e42782E571EaB20432b9237F9bD6B82";
/** The account that delivers callbacks on Base Sepolia and Unichain Sepolia, read from past deliveries. */
const OPERATOR: Address = "0xf7e866d726658f6c3f14b8ee537fe268a4d91ddb";
/** Every reactive transaction is sent with this gas limit. */
const REACT_GAS = 900_000n;
const LASNA_GAS_PRICE = parseGwei("100");

const CONFIG_V1 = [
  {
    type: "tuple",
    components: [
      { name: "chainId", type: "uint256" },
      { name: "recipient", type: "address" },
      { name: "gasLimit", type: "uint64" },
      { name: "payload", type: "bytes" },
    ],
  },
] as const;

const d = deployments();
const venues = Object.entries(d.venues).filter(([, v]) => v) as [VenueName, Venue][];

// No caching and fast polling: the forks mine a block per transaction.
const reader = (name: ChainName) =>
  createPublicClient({ chain: chain(name), transport: http(), cacheTime: 0, pollingInterval: 50 });
const clients = {
  lasna: reader("lasna"),
  base: reader("base"),
  unichain: reader("unichain"),
} satisfies Record<ChainName, PublicClient>;

const test = (name: ChainName) => createTestClient({ chain: chain(name), mode: "anvil", transport: http() });
const wallet = (name: ChainName, account: Address) =>
  createWalletClient({ chain: chain(name), transport: http(), account });

/** anvil's first built-in account. Its key is public; it only ever signs on the local forks. */
const dev = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const player = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

const stats = { reactions: 0, reactGas: 0n, deliveries: 0, deliveryGas: 0n, failures: 0 };

// -------------------------------------------------------------------------------------------------
// The network's part
// -------------------------------------------------------------------------------------------------

const subscriptions: { chainName: ChainName; address: Address; topic0: Hex }[] = [
  { chainName: "base", address: d.origin.feed, topic0: TOPIC.marketUpdate },
  ...venues.map(([name, v]) => ({ chainName: name, address: v.guard, topic0: TOPIC.ack })),
];

const cursors = new Map<ChainName, bigint>();

/** Collects new subscribed logs from the venue forks, oldest first per chain. */
async function poll(): Promise<{ chainName: ChainName; log: Log }[]> {
  const found: { chainName: ChainName; log: Log }[] = [];
  for (const chainName of ["base", "unichain"] as const) {
    const client = clients[chainName];
    const latest = await client.getBlockNumber();
    const from = (cursors.get(chainName) ?? latest) + 1n;
    cursors.set(chainName, latest);
    if (from > latest) continue;

    const wanted = subscriptions.filter((s) => s.chainName === chainName);
    if (wanted.length === 0) continue;
    const logs = await client.getLogs({ address: wanted.map((s) => s.address), fromBlock: from, toBlock: latest });
    for (const log of logs) {
      if (wanted.some((s) => s.address.toLowerCase() === log.address.toLowerCase() && s.topic0 === log.topics[0])) {
        found.push({ chainName, log });
      }
    }
  }
  return found;
}

/** What the node does with a matching log: one reactive transaction through the system contract. */
async function react(chainName: ChainName, log: Log): Promise<void> {
  const topic = (i: number) => (log.topics[i] ? BigInt(log.topics[i] as Hex) : 0n);
  const record = {
    chainId: BigInt(chain(chainName).id),
    contractAddress: log.address,
    topic0: topic(0),
    topic1: topic(1),
    topic2: topic(2),
    topic3: topic(3),
    data: log.data,
    blockNumber: log.blockNumber ?? 0n,
    opCode: BigInt(log.topics.length),
    blockHash: BigInt(log.blockHash ?? "0x0"),
    txHash: BigInt(log.transactionHash ?? "0x0"),
    logIndex: BigInt(log.logIndex ?? 0),
  };

  const hash = await wallet("lasna", INJECTOR).writeContract({
    address: SYSTEM,
    abi: systemAbi,
    functionName: "trigger",
    args: [d.reactive.conductor, record],
    gas: REACT_GAS,
    gasPrice: LASNA_GAS_PRICE,
  });
  const receipt = await clients.lasna.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("trigger reverted: " + hash);
  stats.reactions += 1;
  stats.reactGas += receipt.gasUsed;

  for (const entry of receipt.logs) {
    if (entry.address.toLowerCase() !== SYSTEM.toLowerCase()) continue;
    const event = decodeEventLog({ abi: systemAbi, data: entry.data, topics: entry.topics });
    if (event.eventName === "ReactiveContractReverted") throw new Error("react() reverted on the fork");
    if (event.eventName === "CallbackRequest") {
      await deliver(event.args.sender_, event.args.configuration_);
    }
  }
}

/** What the node does with a callback request: one transaction through the destination's proxy. */
async function deliver(sender: Address, configuration: Hex): Promise<void> {
  const [config] = decodeAbiParameters(CONFIG_V1, configuration);
  const chainName = chainNameOf(config.chainId);
  const venue = d.venues[chainName as VenueName];
  if (!venue) throw new Error("callback for a chain with no venue: " + config.chainId);

  // The node writes the requesting contract's address over the first argument of the payload.
  const payload = (config.payload.slice(0, 10) + sender.slice(2).toLowerCase().padStart(64, "0") + config.payload.slice(74)) as Hex;
  const injected = encodeAbiParameters(CONFIG_V1, [{ ...config, payload }]);

  // Real deliveries use the requested gas limit as the transaction's gas limit.
  const hash = await wallet(chainName, OPERATOR).writeContract({
    address: venue.callbackProxy,
    abi: proxyAbi,
    functionName: "deliverCallback",
    args: [0, injected],
    gas: config.gasLimit,
  });
  const receipt = await clients[chainName].waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("deliverCallback reverted: " + hash);
  stats.deliveries += 1;
  stats.deliveryGas += receipt.gasUsed;

  const failed = receipt.logs.some(
    (entry) =>
      entry.address.toLowerCase() === venue.callbackProxy.toLowerCase() &&
      entry.topics[0] === TOPIC.callbackFailure,
  );
  if (failed) stats.failures += 1;
  console.log(
    "    callback on " + chain(chainName).name + ": " + receipt.gasUsed + " gas of " + config.gasLimit + (failed ? "  FAILED" : ""),
  );
}

/** Runs the network until no subscribed log is left to process. */
async function settle(): Promise<void> {
  for (let round = 0; round < 12; round++) {
    const batch = await poll();
    if (batch.length === 0) return;
    for (const { chainName, log } of batch) await react(chainName, log);
  }
  throw new Error("the loop did not settle");
}

// -------------------------------------------------------------------------------------------------
// The scenario
// -------------------------------------------------------------------------------------------------

async function act(status: 0 | 1 | 2, moveBps: number, label: string): Promise<void> {
  const hash = await createWalletClient({ chain: chain("base"), transport: http(), account: dev }).writeContract({
    address: d.origin.stage,
    abi: stageAbi,
    functionName: "act",
    args: [status, moveBps],
  });
  await clients.base.waitForTransactionReceipt({ hash });
  const [, seq, , price] = await clients.base.readContract({
    address: d.origin.feed,
    abi: feedAbi,
    functionName: "markets",
    args: [MARKET_ID],
  });
  console.log("\n" + label + "  (feed: " + STATUS[status] + " at " + usd(price) + ", seq " + seq + ")");
  await settle();
  await report(price);
}

async function report(refPrice: bigint): Promise<void> {
  for (const [name, v] of venues) {
    const client = clients[name];
    const [status, price, fee, range, seq] = await client.readContract({
      address: v.guard,
      abi: guardAbi,
      functionName: "current",
      args: [MARKET_ID],
    });
    const read = (address: Address, functionName: "poolPrice") =>
      client.readContract({ address, abi: vaultAbi, functionName });
    const value = (address: Address) =>
      client.readContract({ address, abi: vaultAbi, functionName: "valueAt", args: [refPrice] });
    console.log(
      "    " + chain(name).name.padEnd(17) + "guard " + STATUS[status] + " " + usd(price) + " seq " + seq +
        " fee " + Number(fee) / 10_000 + "% band +-" + Number(range) / 100 + "%",
    );
    const taken = await client.readContract({ address: v.arena, abi: arenaAbi, functionName: "taken", args: [1n] });
    console.log(
      "      protected pool " + usd(await read(v.vault, "poolPrice")) + ", vault worth " + usd(await value(v.vault)) +
        "   |   twin pool " + usd(await read(v.twinVault, "poolPrice")) + ", lost to raiders so far " + usd(taken),
    );
  }
}

type Outcome = "took" | "blocked" | "pointless" | "none";

async function raid(name: VenueName, targetId: 0n | 1n): Promise<{ pnl: bigint; outcome: Outcome }> {
  const v = d.venues[name]!;
  const hash = await createWalletClient({ chain: chain(name), transport: http(), account: player }).writeContract({
    address: v.arena,
    abi: arenaAbi,
    functionName: "raid",
    args: [targetId],
    gas: 1_500_000n,
  });
  const receipt = await clients[name].waitForTransactionReceipt({ hash });
  let outcome: Outcome = "none";
  let text = "nothing happened";
  let pnl = 0n;
  for (const entry of receipt.logs) {
    if (entry.address.toLowerCase() !== v.arena.toLowerCase()) continue;
    const event = decodeEventLog({ abi: arenaAbi, data: entry.data, topics: entry.topics });
    if (event.eventName === "Raid") {
      pnl = event.args.pnl;
      outcome = "took";
      text = "took " + usd(pnl);
    } else if (event.eventName === "RaidBlocked") {
      outcome = "blocked";
      text = "BLOCKED, the pool is shut";
    } else if (event.eventName === "RaidPointless") {
      outcome = "pointless";
      text = "nothing to take";
    }
  }
  console.log(
    "    raid on " + chain(name).name + " " + (targetId === 0n ? "protected" : "twin     ") + " pool: " + text +
      "  (" + receipt.gasUsed + " gas)",
  );
  return { pnl, outcome };
}

function expect(condition: boolean, message: string): void {
  if (!condition) throw new Error("rehearsal check failed: " + message);
}

async function main(): Promise<void> {
  console.log("Rehearsing with the conductor at " + d.reactive.conductor + " and " + venues.length + " venue(s)");

  // Let the forks send transactions as the network's own accounts.
  await test("lasna").impersonateAccount({ address: INJECTOR });
  await test("lasna").setBalance({ address: INJECTOR, value: parseEther("100") });
  for (const [name] of venues) {
    await test(name).impersonateAccount({ address: OPERATOR });
    await test(name).setBalance({ address: OPERATOR, value: parseEther("10") });
    await test(name).setBalance({ address: player.address, value: parseEther("1") });
  }
  for (const name of ["base", "unichain"] as const) cursors.set(name, await clients[name].getBlockNumber());

  const reservesBefore = await clients.lasna.getBalance({ address: d.reactive.conductor });

  await act(1, 0, "Opening bell");
  for (const [name] of venues) {
    expect((await raid(name, 0n)).outcome === "pointless", "a pool that is in step has nothing to take");
  }

  await act(2, 0, "Trading halted");
  for (const [name] of venues) {
    expect((await raid(name, 0n)).outcome === "blocked", "a halted pool refuses to trade");
  }

  await act(1, -1000, "Trading resumes 10% lower");
  for (const [name] of venues) {
    expect((await raid(name, 0n)).pnl <= 0n, "the protected pool gave nothing away");
    expect((await raid(name, 1n)).pnl > 0n, "the twin was raided");
  }

  await act(0, 0, "Closing bell");
  await act(1, 1000, "Next morning: opens 10% higher");
  for (const [name] of venues) {
    expect((await raid(name, 0n)).pnl <= 0n, "the protected pool followed the overnight gap");
    expect((await raid(name, 1n)).pnl > 0n, "the twin did not");
  }

  for (const [name, v] of venues) {
    const taken = (targetId: bigint) =>
      clients[name].readContract({ address: v.arena, abi: arenaAbi, functionName: "taken", args: [targetId] });
    console.log(
      "\n  " + chain(name).name + ": raiders took " + usd(await taken(1n)) + " from the twin and " +
        usd(await taken(0n)) + " from the protected pool",
    );
  }
  await settle();

  const inSync = await clients.lasna.readContract({
    address: d.reactive.conductor,
    abi: conductorAbi,
    functionName: "inSync",
    args: [MARKET_ID],
  });
  expect(inSync, "the conductor saw every venue confirm");
  expect(stats.failures === 0, "no callback failed");

  const debt = await clients.lasna.readContract({ address: SYSTEM, abi: systemAbi, functionName: "debt", args: [d.reactive.conductor] });
  const spent = reservesBefore - (await clients.lasna.getBalance({ address: d.reactive.conductor }));
  console.log("\nAll checks passed.");
  console.log(
    "  reactive transactions: " + stats.reactions + ", average " + stats.reactGas / BigInt(stats.reactions) + " gas, cost " +
      Number(spent) / 1e18 + " lREACT in total (" + Number(spent) / 1e18 / stats.reactions + " each), debt " + debt,
  );
  console.log("  callbacks delivered:   " + stats.deliveries + ", average " + stats.deliveryGas / BigInt(stats.deliveries) + " gas");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
