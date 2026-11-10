/**
 * Writes the address file the demo page reads.
 *
 *   npx tsx src/web-config.ts            testnet deployment -> web/public/deployments.json
 *   npx tsx src/web-config.ts --local    local forks        -> web/public/deployments.local.json
 *
 * The page opens the local file when its address ends in `?local`.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { CHAIN_IDS, deployments, rpcUrl, type ChainName } from "./config.js";

const local = process.argv.includes("--local");
const d = deployments();

const CHAINS: Record<ChainName, { name: string; short: string; explorer: string; currency: string }> = {
  base: { name: "Base Sepolia", short: "Base", explorer: "https://sepolia.basescan.org", currency: "ETH" },
  unichain: { name: "Unichain Sepolia", short: "Unichain", explorer: "https://sepolia.uniscan.xyz", currency: "ETH" },
  lasna: { name: "Reactive Lasna", short: "Reactive", explorer: "https://lasna.reactscan.net", currency: "lREACT" },
};

const chains = Object.fromEntries(
  (Object.keys(CHAINS) as ChainName[]).map((key) => [key, { id: CHAIN_IDS[key], rpc: rpcUrl(key), ...CHAINS[key] }]),
);

const config = {
  mode: local ? "local" : "testnet",
  repo: process.env.REPO_URL ?? "",
  chains,
  origin: d.origin,
  reactive: d.reactive,
  venues: d.venues,
};

const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(here, "../../web/public", local ? "deployments.local.json" : "deployments.json");
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(config, null, 2) + "\n");
console.log("wrote " + out);
