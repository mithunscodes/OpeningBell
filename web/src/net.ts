import { createPublicClient, defineChain, http, keccak256, toHex, type Address, type Chain, type Hex, type PublicClient } from "viem";

export const MARKET_ID: Hex = keccak256(toHex("NVDA/USD"));

export type ChainKey = "base" | "unichain" | "lasna";
export type VenueKey = "base" | "unichain";
export const VENUES: VenueKey[] = ["base", "unichain"];

export interface ChainInfo {
  id: number;
  name: string;
  short: string;
  rpc: string;
  explorer: string;
  currency: string;
}

export interface Venue {
  chainId: number;
  block: number;
  guard: Address;
  vault: Address;
  twinVault: Address;
  arena: Address;
  hook: Address;
  twinHook: Address;
  stock: Address;
  dollars: Address;
  callbackProxy: Address;
  poolManager: Address;
}

/** What `deployments.json` holds. Written by tools/src/web-config.ts from the deployment scripts' output. */
export interface Config {
  mode: "testnet" | "local";
  chains: Record<ChainKey, ChainInfo>;
  origin: { chainId: number; block: number; feed: Address; stage: Address };
  reactive: { chainId: number; block: number; conductor: Address };
  venues: Partial<Record<VenueKey, Venue>>;
}

export async function loadConfig(): Promise<Config> {
  const local = new URLSearchParams(location.search).has("local");
  const response = await fetch(local ? "deployments.local.json" : "deployments.json", { cache: "no-store" });
  if (!response.ok) throw new Error("This copy of the page has no deployment yet.");
  return (await response.json()) as Config;
}

export function toChain(info: ChainInfo): Chain {
  return defineChain({
    id: info.id,
    name: info.name,
    nativeCurrency: { name: info.currency, symbol: info.currency, decimals: 18 },
    rpcUrls: { default: { http: [info.rpc] } },
    blockExplorers: { default: { name: "Explorer", url: info.explorer } },
  });
}

export type Clients = Record<ChainKey, PublicClient>;

export function makeClients(config: Config): Clients {
  const make = (key: ChainKey) =>
    createPublicClient({
      chain: toChain(config.chains[key]),
      transport: http(config.chains[key].rpc, { batch: { wait: 16 } }),
      cacheTime: 0,
      pollingInterval: config.mode === "local" ? 100 : 400,
    });
  return { base: make("base"), unichain: make("unichain"), lasna: make("lasna") };
}

/**
 * A block's time in milliseconds. Base Sepolia's RPC adds `timestampMs` (its blocks are 200 ms
 * apart); other chains only have whole seconds, so their times are rounded down to the second.
 */
export async function blockTimeMs(client: PublicClient, blockNumber: bigint): Promise<{ ms: number; precise: boolean }> {
  const block = (await client.request({
    method: "eth_getBlockByNumber",
    params: [toHex(blockNumber), false],
  })) as { timestamp: Hex; timestampMs?: Hex } | null;
  if (!block) throw new Error("block " + blockNumber + " not found");
  if (block.timestampMs) return { ms: Number(BigInt(block.timestampMs)), precise: true };
  return { ms: Number(BigInt(block.timestamp)) * 1000, precise: false };
}

export function explorerTx(info: ChainInfo, hash: string): string {
  return info.explorer.replace(/\/$/, "") + "/tx/" + hash;
}

export function explorerAddress(info: ChainInfo, address: string): string {
  return info.explorer.replace(/\/$/, "") + "/address/" + address;
}

// -------------------------------------------------------------------------------------------------
// Formatting
// -------------------------------------------------------------------------------------------------

const WAD = 10n ** 18n;

export function toNumber(wad: bigint): number {
  return Number(wad / 10n ** 12n) / 1e6;
}

export function usd(wad: bigint, digits = 2): string {
  const n = toNumber(wad);
  return (n < 0 ? "-$" : "$") + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function usdShort(wad: bigint): string {
  const n = Math.abs(toNumber(wad));
  const sign = wad < 0n ? "-" : "";
  if (n >= 1_000_000) return sign + "$" + (n / 1_000_000).toFixed(2) + "M";
  if (n >= 10_000) return sign + "$" + Math.round(n / 1000).toLocaleString("en-US") + "k";
  return sign + "$" + n.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

/** Signed percentage gap between a pool's price and the reference price. */
export function gapPct(pool: bigint, ref: bigint): number {
  if (ref === 0n) return 0;
  return (Number(((pool - ref) * 1_000_000n) / ref) / 1_000_000) * 100;
}

export function seconds(ms: number, precise: boolean): string {
  return precise ? (ms / 1000).toFixed(2) + " s" : "≈ " + Math.max(0, Math.round(ms / 1000)) + " s";
}

export { WAD };
