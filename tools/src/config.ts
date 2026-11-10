import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { defineChain, keccak256, toHex, type Address, type Chain, type Hex } from "viem";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");

export const MARKET_ID: Hex = keccak256(toHex("NVDA/USD"));

export const SYSTEM: Address = "0x8888888888888888888888888888888888888888";

export const CHAIN_IDS = { lasna: 5318007, base: 84532, unichain: 1301 } as const;
export type ChainName = keyof typeof CHAIN_IDS;
export type VenueName = "base" | "unichain";

const DEFAULT_RPC: Record<ChainName, string> = {
  lasna: "https://lasna-rpc.rnk.dev/",
  base: "https://sepolia.base.org",
  unichain: "https://sepolia.unichain.org",
};

const NAMES: Record<ChainName, string> = {
  lasna: "Reactive Lasna",
  base: "Base Sepolia",
  unichain: "Unichain Sepolia",
};

/** RPC endpoints can be overridden with LASNA_RPC, BASE_RPC and UNICHAIN_RPC (the rehearsal points them at local forks). */
export function rpcUrl(name: ChainName): string {
  return process.env[name.toUpperCase() + "_RPC"] ?? DEFAULT_RPC[name];
}

export function chain(name: ChainName): Chain {
  return defineChain({
    id: CHAIN_IDS[name],
    name: NAMES[name],
    nativeCurrency: { name: "Ether", symbol: name === "lasna" ? "lREACT" : "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl(name)] } },
  });
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
  poolId: Hex;
  twinPoolId: Hex;
}

export interface Deployments {
  origin: { chainId: number; block: number; feed: Address; stage: Address };
  reactive: { chainId: number; block: number; conductor: Address };
  venues: Partial<Record<VenueName, Venue>>;
}

function load<T>(dir: string, file: string): T | undefined {
  const path = resolve(dir, file);
  return existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as T) : undefined;
}

/** Reads the address files written by the deployment scripts. DEPLOYMENTS_DIR selects another folder. */
export function deployments(): Deployments {
  const dir = resolve(root, process.env.DEPLOYMENTS_DIR ?? "deployments");
  const origin = load<Deployments["origin"]>(dir, "origin.json");
  const reactive = load<Deployments["reactive"]>(dir, "reactive.json");
  if (!origin || !reactive) throw new Error("no deployment found in " + dir);
  return {
    origin,
    reactive,
    venues: {
      base: load<Venue>(dir, "venue-" + CHAIN_IDS.base + ".json"),
      unichain: load<Venue>(dir, "venue-" + CHAIN_IDS.unichain + ".json"),
    },
  };
}

export function chainNameOf(chainId: number | bigint): ChainName {
  const entry = Object.entries(CHAIN_IDS).find(([, id]) => BigInt(id) === BigInt(chainId));
  if (!entry) throw new Error("unknown chain " + chainId);
  return entry[0] as ChainName;
}

/** Formats an 18-decimal dollar amount, for example 12638911322064285233149n as "$12,638.91". */
export function usd(wei: bigint, digits = 2): string {
  const negative = wei < 0n;
  const abs = negative ? -wei : wei;
  const scale = 10n ** BigInt(18 - digits);
  const scaled = (abs + scale / 2n) / scale;
  const unit = 10n ** BigInt(digits);
  const whole = (scaled / unit).toLocaleString("en-US");
  const frac = (scaled % unit).toString().padStart(digits, "0");
  return (negative ? "-$" : "$") + whole + "." + frac;
}

export const sleep = (ms: number) => new Promise<void>((done) => setTimeout(done, ms));
