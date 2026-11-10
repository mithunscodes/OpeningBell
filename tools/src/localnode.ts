/**
 * A stand-in for the Reactive Network node, for local forks only.
 *
 * Three anvil instances fork Base Sepolia, Unichain Sepolia and Reactive Lasna. A fork has the
 * real contracts but nobody runs the network: no one reads the origin chains, calls `react()` or
 * delivers callbacks. This class does exactly that, the way the node does:
 *
 * 1. watch the venue forks for logs our conductor subscribed to,
 * 2. hand each one to the real system contract (`trigger`, sent from the network's injection address),
 * 3. deliver every callback the system contract asks for through the real callback proxy on the
 *    destination fork (sent from the network's own operator), with the conductor's address written
 *    over the payload's first argument.
 *
 * Everything else (system contract, proxies, fee accounting, Uniswap v4) is the deployed code.
 * Only timing is fake, which is why latency is measured on the live networks.
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
import { proxyAbi, systemAbi, TOPIC } from "./abi.js";
import { chain, chainNameOf, SYSTEM, sleep, type ChainName, type Deployments, type VenueName } from "./config.js";

/** Reactive Network's fixed sender for node-injected reactive transactions (SystemContract.INJ_ADDR). */
export const INJECTOR: Address = "0x038E06667e42782E571EaB20432b9237F9bD6B82";
/** The account that delivers callbacks on Base Sepolia and Unichain Sepolia, read from past deliveries. */
export const OPERATOR: Address = "0xf7e866d726658f6c3f14b8ee537fe268a4d91ddb";
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

const VENUE_CHAINS = ["base", "unichain"] as const;

export interface NodeOptions {
  /** Pause before each reactive transaction and each delivery, to make the demo page's stopwatch readable. */
  hopDelayMs?: number;
  log?: (line: string) => void;
}

export class LocalNode {
  readonly stats = { reactions: 0, reactGas: 0n, deliveries: 0, deliveryGas: 0n, failures: 0 };

  readonly clients: Record<ChainName, PublicClient>;
  private readonly cursors = new Map<ChainName, bigint>();
  private readonly subscriptions: { chainName: ChainName; address: Address; topic0: Hex }[];
  private readonly hopDelayMs: number;
  private readonly log: (line: string) => void;

  constructor(
    private readonly d: Deployments,
    options: NodeOptions = {},
  ) {
    this.hopDelayMs = options.hopDelayMs ?? 0;
    this.log = options.log ?? (() => {});

    // No caching and fast polling: the forks mine a block per transaction.
    const reader = (name: ChainName) =>
      createPublicClient({ chain: chain(name), transport: http(), cacheTime: 0, pollingInterval: 50 });
    this.clients = { lasna: reader("lasna"), base: reader("base"), unichain: reader("unichain") };

    this.subscriptions = [{ chainName: "base", address: d.origin.feed, topic0: TOPIC.marketUpdate }];
    for (const name of VENUE_CHAINS) {
      const venue = d.venues[name];
      if (venue) this.subscriptions.push({ chainName: name, address: venue.guard, topic0: TOPIC.ack });
    }
  }

  /** Lets the forks send transactions as the network's own accounts, and starts watching from the current block. */
  async prepare(): Promise<void> {
    const lasna = createTestClient({ chain: chain("lasna"), mode: "anvil", transport: http() });
    await lasna.impersonateAccount({ address: INJECTOR });
    await lasna.setBalance({ address: INJECTOR, value: parseEther("100") });

    for (const name of VENUE_CHAINS) {
      const test = createTestClient({ chain: chain(name), mode: "anvil", transport: http() });
      await test.impersonateAccount({ address: OPERATOR });
      await test.setBalance({ address: OPERATOR, value: parseEther("10") });
      this.cursors.set(name, await this.clients[name].getBlockNumber());
    }
  }

  /** Processes subscribed logs until none are left. */
  async settle(maxRounds = 12): Promise<void> {
    for (let round = 0; round < maxRounds; round++) {
      const batch = await this.poll();
      if (batch.length === 0) return;
      for (const { chainName, log } of batch) await this.react(chainName, log);
    }
    throw new Error("the loop did not settle");
  }

  /** Runs until the process is stopped. */
  async runForever(pollMs = 250): Promise<never> {
    for (;;) {
      try {
        await this.settle(1_000);
      } catch (error) {
        this.log("node error: " + (error instanceof Error ? error.message : String(error)));
      }
      await sleep(pollMs);
    }
  }

  /** Collects new subscribed logs from the venue forks, oldest first per chain. */
  private async poll(): Promise<{ chainName: ChainName; log: Log }[]> {
    const found: { chainName: ChainName; log: Log }[] = [];
    for (const chainName of VENUE_CHAINS) {
      const client = this.clients[chainName];
      const latest = await client.getBlockNumber();
      const from = (this.cursors.get(chainName) ?? latest) + 1n;
      if (from > latest) continue;

      const wanted = this.subscriptions.filter((s) => s.chainName === chainName);
      if (wanted.length !== 0) {
        const logs = await client.getLogs({ address: wanted.map((s) => s.address), fromBlock: from, toBlock: latest });
        for (const log of logs) {
          const match = wanted.some(
            (s) => s.address.toLowerCase() === log.address.toLowerCase() && s.topic0 === log.topics[0],
          );
          if (match) found.push({ chainName, log });
        }
      }
      this.cursors.set(chainName, latest);
    }
    return found;
  }

  /** What the node does with a matching log: one reactive transaction through the system contract. */
  private async react(chainName: ChainName, log: Log): Promise<void> {
    if (this.hopDelayMs) await sleep(this.hopDelayMs);

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

    const hash = await createWalletClient({ chain: chain("lasna"), transport: http(), account: INJECTOR }).writeContract({
      address: SYSTEM,
      abi: systemAbi,
      functionName: "trigger",
      args: [this.d.reactive.conductor, record],
      gas: REACT_GAS,
      gasPrice: LASNA_GAS_PRICE,
    });
    const receipt = await this.clients.lasna.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error("trigger reverted: " + hash);
    this.stats.reactions += 1;
    this.stats.reactGas += receipt.gasUsed;
    this.log("reaction on Lasna for a log from " + chain(chainName).name + ": " + receipt.gasUsed + " gas");

    for (const entry of receipt.logs) {
      if (entry.address.toLowerCase() !== SYSTEM.toLowerCase()) continue;
      const event = decodeEventLog({ abi: systemAbi, data: entry.data, topics: entry.topics });
      if (event.eventName === "ReactiveContractReverted") throw new Error("react() reverted on the fork");
      if (event.eventName === "CallbackRequest") {
        await this.deliver(event.args.sender_, event.args.configuration_);
      }
    }
  }

  /** What the node does with a callback request: one transaction through the destination's proxy. */
  private async deliver(sender: Address, configuration: Hex): Promise<void> {
    if (this.hopDelayMs) await sleep(this.hopDelayMs);

    const [config] = decodeAbiParameters(CONFIG_V1, configuration);
    const chainName = chainNameOf(config.chainId);
    const venue = this.d.venues[chainName as VenueName];
    if (!venue) throw new Error("callback for a chain with no venue: " + config.chainId);

    // The node writes the requesting contract's address over the first argument of the payload.
    const payload = (config.payload.slice(0, 10) +
      sender.slice(2).toLowerCase().padStart(64, "0") +
      config.payload.slice(74)) as Hex;
    const injected = encodeAbiParameters(CONFIG_V1, [{ ...config, payload }]);

    // Real deliveries use the requested gas limit as the transaction's gas limit.
    const hash = await createWalletClient({ chain: chain(chainName), transport: http(), account: OPERATOR }).writeContract({
      address: venue.callbackProxy,
      abi: proxyAbi,
      functionName: "deliverCallback",
      args: [0, injected],
      gas: config.gasLimit,
    });
    const receipt = await this.clients[chainName].waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error("deliverCallback reverted: " + hash);
    this.stats.deliveries += 1;
    this.stats.deliveryGas += receipt.gasUsed;

    const failed = receipt.logs.some(
      (entry) =>
        entry.address.toLowerCase() === venue.callbackProxy.toLowerCase() && entry.topics[0] === TOPIC.callbackFailure,
    );
    if (failed) this.stats.failures += 1;
    this.log(
      "callback on " + chain(chainName).name + ": " + receipt.gasUsed + " gas of " + config.gasLimit + (failed ? "  FAILED" : ""),
    );
  }
}
