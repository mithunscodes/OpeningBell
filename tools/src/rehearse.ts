/**
 * Rehearsal: the whole loop on local forks, before any testnet funds are spent.
 *
 * `LocalNode` plays the Reactive Network node against the real system contract and callback
 * proxies on the forks. This script plays a trading day on top and checks the outcome.
 * Run it with ./rehearse.sh, which starts the forks and deploys everything first.
 */
import { createTestClient, createWalletClient, decodeEventLog, http, parseEther, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arenaAbi, conductorAbi, feedAbi, guardAbi, stageAbi, STATUS, systemAbi, vaultAbi } from "./abi.js";
import { chain, deployments, MARKET_ID, SYSTEM, usd, type Venue, type VenueName } from "./config.js";
import { LocalNode } from "./localnode.js";

const d = deployments();
const venues = Object.entries(d.venues).filter(([, v]) => v) as [VenueName, Venue][];

const node = new LocalNode(d, { log: (line) => console.log("    " + line) });
const clients = node.clients;
const stats = node.stats;
const settle = () => node.settle();

/** anvil's first built-in account. Its key is public; it only ever signs on the local forks. */
const dev = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const player = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

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

  await node.prepare();
  for (const [name] of venues) {
    const test = createTestClient({ chain: chain(name), mode: "anvil", transport: http() });
    await test.setBalance({ address: player.address, value: parseEther("1") });
  }

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
