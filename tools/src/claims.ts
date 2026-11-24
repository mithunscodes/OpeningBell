/**
 * Checks the README's numbers against the raw data and the chains, so nobody has to trust the prose.
 *
 *   npx tsx src/claims.ts                # recompute every measured number, and the mutation counts, from bench/
 *   npx tsx src/claims.ts --chain        # also fetch every transaction the README links and check it
 *                                        #   says what the link says (succeeded, reverted, $ taken, nothing)
 *   npx tsx src/claims.ts --sourcify     # also ask Sourcify about all 25 deployed contracts
 *   npx tsx src/claims.ts --forge        # also run the tests and coverage and check the counts
 *   npx tsx src/claims.ts --all          # everything
 *
 * Read-only: no key, no wallet. Each line printed is one claim, PASS or FAIL, with what was found.
 * docs/CLAIMS.md maps every claim to the file, transaction or test behind it.
 */
import { execSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, parseEventLogs, type Address, type Hash } from "viem";
import { arenaAbi } from "./abi.js";
import { CHAIN_IDS, chain, rpcUrl, usd, type ChainName } from "./config.js";
import { summarize } from "./loops.js";

/** A loop as the result files store it (JSON: block numbers are strings). */
interface Hop {
  block: string;
  tx: string;
  ms: number;
}
interface LoopRecord {
  origin: Hop;
  applied: { base?: Hop; unichain?: Hop };
  observed?: Hop;
  closed?: Hop;
}

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const read = (path: string) => readFileSync(resolve(root, path), "utf8");
const json = <T = any>(path: string): T => JSON.parse(read(path)) as T;
const flag = (name: string) => process.argv.includes("--" + name) || process.argv.includes("--all");

let failed = 0;
let passed = 0;
function check(claim: string, ok: boolean, found: string) {
  if (ok) passed++;
  else failed++;
  console.log((ok ? "  PASS  " : "  FAIL  ") + claim + "  (" + found + ")");
}
const s = (ms: number, digits = 2) => (ms / 1000).toFixed(digits) + " s";
const wholeSeconds = (ms: number) => Math.round(ms / 1000);

// -------------------------------------------------------------------------------------------------
// 1. The benchmark: bench/results/
// -------------------------------------------------------------------------------------------------

interface BenchRun {
  started: string;
  loops: (LoopRecord & { action: string })[];
}

function hops(run: BenchRun) {
  const done = run.loops.filter((l) => l.closed && l.applied.base && l.applied.unichain);
  return {
    closed: done.length,
    base: summarize(done.map((l) => l.applied.base!.ms - l.origin.ms)),
    unichain: summarize(done.map((l) => l.applied.unichain!.ms - l.origin.ms)),
    lasna: summarize(done.map((l) => Number(l.closed!.block) - Number(l.observed!.block))),
  };
}

function benchmark() {
  console.log("\nSpeed: the live benchmark (bench/results/)");
  const files = readdirSync(resolve(root, "bench/results")).filter((f) => f.endsWith(".json")).sort();
  const runs = files.map((f) => json<BenchRun>("bench/results/" + f));
  const all = runs.reduce((n, r) => n + r.loops.length, 0);
  check("233 recorded loops are listed in bench/results/", all === 233, all + " loops in " + files.length + " files");

  const big = runs.find((r) => r.loops.length === 200);
  const small = runs.find((r) => r.loops.length === 30);
  if (!big || !small) {
    check("the 200-update and 30-update runs are present", false, "missing");
    return;
  }
  const kinds = (r: BenchRun, prefix: string) => r.loops.filter((l) => l.action.startsWith(prefix)).length;
  check(
    "run 1: 200 updates, 67 halts, 67 resumes, 66 moves",
    kinds(big, "halt") === 67 && kinds(big, "resume") === 67 && kinds(big, "move") === 66,
    kinds(big, "halt") + " / " + kinds(big, "resume") + " / " + kinds(big, "move"),
  );
  const a = hops(big);
  check("run 1: 200 of 200 loops closed", a.closed === 200, a.closed + " closed");
  check(
    "run 1: Base pool switched p50 1.40 s, p90 2.00 s, max 2.40 s, min 1.00 s",
    a.base.p50 === 1400 && a.base.p90 === 2000 && a.base.max === 2400 && a.base.min === 1000,
    [a.base.p50, a.base.p90, a.base.max, a.base.min].map((x) => s(x)).join(", "),
  );
  check(
    "run 1: Unichain pool switched about 2 s (p50), 3 s (p90 and max), 1 s (min), whole seconds",
    wholeSeconds(a.unichain.p50) === 2 &&
      wholeSeconds(a.unichain.p90) === 3 &&
      wholeSeconds(a.unichain.max) === 3 &&
      wholeSeconds(a.unichain.min) === 1,
    [a.unichain.p50, a.unichain.p90, a.unichain.max, a.unichain.min].map((x) => s(x, 1)).join(", "),
  );
  check(
    "run 1: both pools confirmed 2 Lasna blocks after the reaction (p50 2, p90 2, max 3, min 2)",
    a.lasna.p50 === 2 && a.lasna.p90 === 2 && a.lasna.max === 3 && a.lasna.min === 2,
    [a.lasna.p50, a.lasna.p90, a.lasna.max, a.lasna.min].join(", ") + " blocks",
  );
  const b = hops(small);
  check(
    "run 2: 30 updates, 6 each of halt, resume, close, open and move",
    ["halt", "resume", "close", "open", "move"].every((k) => kinds(small, k) === 6),
    ["halt", "resume", "close", "open", "move"].map((k) => kinds(small, k)).join(" / "),
  );
  check("run 2: 30 of 30 loops closed", b.closed === 30, b.closed + " closed");
  check(
    "run 2: Base pool switched p50 1.60 s, max 2.00 s",
    b.base.p50 === 1600 && b.base.max === 2000,
    s(b.base.p50) + ", " + s(b.base.max),
  );
  check("230 of 230 loops closed over both runs", a.closed + b.closed === 230, a.closed + b.closed + " closed");

  // The ~7 s estimate keeps every measured leg and adds the average (3 s) and worst (6 s) extra wait.
  check(
    "~7 s blocks estimate: 1.4 s becomes about 4.4 s, 2.4 s becomes about 8.4 s",
    (a.base.p50 + 3000) / 1000 === 4.4 && (a.base.max + 6000) / 1000 === 8.4,
    s(a.base.p50 + 3000, 1) + ", " + s(a.base.max + 6000, 1),
  );
  check(
    "a 1.4 s window is about 7 Base blocks; at ~7 s Reactive blocks it is about 22",
    Math.round(a.base.p50 / 200) === 7 && Math.round((a.base.p50 + 3000) / 200) === 22,
    Math.round(a.base.p50 / 200) + " and " + Math.round((a.base.p50 + 3000) / 200) + " blocks",
  );
}

// -------------------------------------------------------------------------------------------------
// 2. Beat the bell: bench/race/results/
// -------------------------------------------------------------------------------------------------

interface RaceAttempt {
  raidLagMs: number;
  loopMs: number;
  loop: LoopRecord;
  raids: Record<"protected" | "twin", { outcome: string; pnl: string; at: { block: string } }>;
}

function race() {
  console.log("\nBeat the bell (bench/race/results/2026-11-23-live.json)");
  const { attempts } = json<{ attempts: RaceAttempt[] }>("bench/race/results/2026-11-23-live.json");
  const raidBlock = (a: RaceAttempt) => Number(a.raids.protected.at.block);
  const safeBlock = (a: RaceAttempt) => Number(a.loop.applied.base!.block);
  const paid = attempts.filter((a) => a.raids.protected.outcome === "taken");
  const nothing = attempts.filter((a) => a.raids.protected.outcome === "nothing");
  check("32 attempts", attempts.length === 32, attempts.length + " attempts");
  check(
    "protected pool: 13 raids paid, all landed before the loop re-priced it (or earlier in that block)",
    paid.length === 13 && paid.every((a) => raidBlock(a) <= safeBlock(a)),
    paid.length + " paid, " + paid.filter((a) => raidBlock(a) <= safeBlock(a)).length + " of them at or before the re-price block",
  );
  check(
    "protected pool: 0 of 19 raids paid after the re-price",
    nothing.length === 19 && nothing.every((a) => raidBlock(a) >= safeBlock(a)),
    nothing.length + " got nothing, " + nothing.filter((a) => raidBlock(a) >= safeBlock(a)).length + " of them at or after the re-price block",
  );
  const twin = attempts.filter((a) => a.raids.twin.outcome === "taken").length;
  check("twin pool: 32 of 32 raids paid", twin === 32, twin + " paid");
  const safe = summarize(attempts.map((a) => a.loopMs));
  check(
    "the loop re-priced the protected pool a median of 1.0 s after the news (0.6 s to 1.6 s)",
    safe.p50 === 1000 && safe.min === 600 && safe.max === 1600,
    s(safe.p50, 1) + ", " + s(safe.min, 1) + " to " + s(safe.max, 1),
  );
  const closed = attempts.filter((a) => a.loop.closed).length;
  check("all 32 loops closed", closed === 32, closed + " closed");
  const sum = (k: "protected" | "twin") => attempts.reduce((t, a) => t + BigInt(a.raids[k].pnl), 0n);
  check(
    "taken in total: $87,040.46 from the protected pool, $189,039.06 from the twin (bench/race/RESULTS.md)",
    usd(sum("protected")) === "$87,040.46" && usd(sum("twin")) === "$189,039.06",
    usd(sum("protected")) + ", " + usd(sum("twin")),
  );
}

// -------------------------------------------------------------------------------------------------
// 3. The real night: bench/replay/
// -------------------------------------------------------------------------------------------------

function replay() {
  console.log("\nA real night, replayed (bench/replay/)");
  const scenario = json("bench/replay/nvda-2026-11-12.json");
  const run = json("bench/replay/results/nvda-2026-11-12.json");
  const prices = scenario.prints.map((p: { price: string }) => p.price).join(", ");
  check("the three real prices are $173.73, $154.68 and $151.01", prices === "173.73, 154.68, 151.01", prices);
  const drop = ((151.01 - 173.73) / 173.73) * 100;
  check("the open was 13.1% below the close", drop.toFixed(1) === "-13.1", drop.toFixed(2) + "%");
  const onChain = run.prints.map((p: { onChainPrice: string }) => "$" + (Number(p.onChainPrice) / 1e18).toFixed(4));
  check(
    "on-chain the prices were $173.7343, $154.6756 and $151.0098",
    onChain.join(", ") === "$173.7343, $154.6756, $151.0098",
    onChain.join(", "),
  );
  const switched = run.prints.map((p: { loop: LoopRecord }) => s(p.loop.applied.base!.ms - p.loop.origin.ms));
  check("Base pool switched 1.40 s, 1.00 s and 1.60 s after each update", switched.join(", ") === "1.40 s, 1.00 s, 1.60 s", switched.join(", "));
  const uni = run.prints.map((p: { loop: LoopRecord }) => wholeSeconds(p.loop.applied.unichain!.ms - p.loop.origin.ms));
  check("Unichain pool switched about 2, 2 and 3 s after each update", uni.join(",") === "2,2,3", uni.join(", ") + " s");
  const closed = run.prints.filter((p: { loop: { closed?: unknown } }) => p.loop.closed).length;
  check("all three loops closed", closed === 3, closed + " closed");
  const base = BigInt(run.twins.base.raid.pnl);
  const uniPnl = BigInt(run.twins.unichain.raid.pnl);
  check(
    "twins lost $21,661.53 (Base) and $33,247.22 (Unichain), $54,908.76 in all",
    usd(base) === "$21,661.53" && usd(uniPnl) === "$33,247.22" && usd(base + uniPnl) === "$54,908.76",
    usd(base) + " + " + usd(uniPnl) + " = " + usd(base + uniPnl),
  );
  const prot = run.prints.flatMap((p: { protected?: Record<string, { outcome: string }> }) => Object.values(p.protected ?? {}));
  check(
    "every raid on a protected pool found nothing to take",
    prot.length >= 4 && prot.every((r: { outcome: string }) => r.outcome === "nothing"),
    prot.length + " raids: " + [...new Set(prot.map((r: { outcome: string }) => r.outcome))].join(", "),
  );
}

// -------------------------------------------------------------------------------------------------
// 4. Every transaction the README links (--chain)
// -------------------------------------------------------------------------------------------------

const EXPLORERS: Record<string, ChainName> = {
  "sepolia.basescan.org": "base",
  "sepolia.uniscan.xyz": "unichain",
  "lasna.reactscan.net": "lasna",
};

async function links() {
  console.log("\nEvery transaction linked from the README (--chain)");
  const clients = Object.fromEntries(
    (Object.keys(CHAIN_IDS) as ChainName[]).map((n) => [
      n,
      createPublicClient({ chain: chain(n), transport: http(rpcUrl(n), { retryCount: 5, retryDelay: 400 }) }),
    ]),
  ) as Record<ChainName, ReturnType<typeof createPublicClient>>;

  const text = read("README.md");
  const re = /\[([^\]]+)\]\(https:\/\/([a-z.]+)\/tx\/(0x[0-9a-fA-F]{64})\)/g;
  const found = [...text.matchAll(re)].map((m) => ({ label: m[1], chain: EXPLORERS[m[2]], hash: m[3] as Hash }));
  const unknown = found.filter((f) => !f.chain);
  check("every linked transaction is on Base Sepolia, Unichain Sepolia or Lasna", unknown.length === 0, found.length + " links");

  let i = 0;
  const results: { label: string; ok: boolean; found: string }[] = [];
  async function worker() {
    while (i < found.length) {
      const f = found[i++];
      try {
        const r = await clients[f.chain].getTransactionReceipt({ hash: f.hash });
        const wantRevert = /reverted/i.test(f.label);
        let ok = r.status === (wantRevert ? "reverted" : "success");
        let note = r.status;
        const taken = f.label.match(/\$([\d,]+\.\d\d) taken/);
        if (taken || /nothing to take/i.test(f.label)) {
          const logs = parseEventLogs({ abi: arenaAbi, logs: r.logs });
          const raid = logs.find((l) => l.eventName === "Raid");
          const none = logs.find((l) => l.eventName === "RaidPointless");
          if (taken) {
            const pnl = raid?.eventName === "Raid" ? usd(raid.args.pnl) : "no Raid event";
            ok &&= pnl === "$" + taken[1];
            note += ", Raid pnl " + pnl;
            if (raid?.eventName === "Raid") note += " (pool at " + usd(raid.args.poolPriceBefore) + ", real price " + usd(raid.args.refPrice) + ")";
          } else {
            ok &&= none !== undefined;
            note += none ? ", RaidPointless" : ", no RaidPointless event";
          }
        }
        results.push({ label: f.chain + " " + f.hash.slice(0, 10) + "… [" + f.label + "]", ok, found: note });
      } catch (e) {
        results.push({ label: f.chain + " " + f.hash.slice(0, 10) + "… [" + f.label + "]", ok: false, found: (e as Error).message.split("\n")[0] });
      }
    }
  }
  await Promise.all(Array.from({ length: 6 }, worker));
  for (const r of results) check(r.label, r.ok, r.found);
}

// -------------------------------------------------------------------------------------------------
// 5. Source verification (--sourcify)
// -------------------------------------------------------------------------------------------------

async function sourcify() {
  console.log("\nSource verification on Sourcify (--sourcify)");
  const skip = new Set(["block", "chainId", "callbackProxy", "poolManager", "poolId", "twinPoolId", "marketId"]);
  const list: { chainId: number; name: string; address: Address }[] = [];
  for (const file of readdirSync(resolve(root, "deployments")).filter((f) => f.endsWith(".json"))) {
    const d = json<Record<string, unknown>>("deployments/" + file);
    for (const [k, v] of Object.entries(d)) {
      if (!skip.has(k) && typeof v === "string" && /^0x[0-9a-fA-F]{40}$/.test(v)) {
        list.push({ chainId: d.chainId as number, name: file.replace(".json", "") + "." + k, address: v as Address });
      }
    }
  }
  let exact = 0;
  let matched = 0;
  for (const c of list) {
    const res = await fetch("https://sourcify.dev/server/v2/contract/" + c.chainId + "/" + c.address);
    const body = (await res.json().catch(() => ({}))) as { match?: string; runtimeMatch?: string };
    const m = body.match ?? "none";
    if (m === "exact_match") exact++;
    if (m === "exact_match" || m === "match") matched++;
    check(c.name + " " + c.address, m === "exact_match" || m === "match", m);
  }
  check("25 contracts deployed, all verified, 24 exact matches", list.length === 25 && matched === 25 && exact === 24, list.length + " contracts, " + matched + " verified, " + exact + " exact");
}

// -------------------------------------------------------------------------------------------------
// 6. Tests and coverage (--forge)
// -------------------------------------------------------------------------------------------------

function forge() {
  console.log("\nTests and coverage (--forge)");
  const out = execSync("forge test --no-match-path 'test/fork/*' --json", { cwd: root, encoding: "utf8", maxBuffer: 1 << 28 });
  const suites = JSON.parse(out.slice(out.indexOf("{"))) as Record<string, { test_results: Record<string, { status: string; kind: Record<string, unknown> }> }>;
  const tests = Object.values(suites).flatMap((s) => Object.values(s.test_results));
  const ok = tests.filter((t) => t.status === "Success").length;
  const fuzz = tests.filter((t) => "Fuzz" in t.kind).length;
  check("195 tests, all passing", tests.length === 195 && ok === 195, ok + " of " + tests.length + " passed");
  check("8 of them are fuzz tests", fuzz === 8, fuzz + " fuzz tests");
  const cov = execSync('forge coverage --no-match-coverage "(test|script|lib)" --report summary', { cwd: root, encoding: "utf8", maxBuffer: 1 << 28 });
  const total = cov.split("\n").find((l) => /\|\s*Total\s*\|/.test(l)) ?? "";
  const cells = total.split("|").map((c) => c.trim()).filter(Boolean);
  check("100% of lines (662/662) and 95.9% of branches (141/147) are covered", /100\.00% \(662\/662\)/.test(cells[1] ?? "") && /95\.9\d*% \(141\/147\)/.test(cells[3] ?? ""), cells.slice(1).join(", "));
}

// -------------------------------------------------------------------------------------------------
// 7. Mutation testing: bench/mutation/ (docs/mutation.md)
// -------------------------------------------------------------------------------------------------

interface Mutant {
  contract: string;
  result: "caught" | "uncaught";
  second?: string;
  kind?: string;
}

function mutation() {
  console.log("\nMutation testing (bench/mutation/)");
  const first = json<{ mutants: Mutant[] }>("bench/mutation/first-pass.json").mutants;
  const second = json<{ mutants: Mutant[] }>("bench/mutation/second-pass.json").mutants;
  const contracts = new Set(first.map((m) => m.contract));
  const oldCaught = first.filter((m) => m.result === "caught").length;
  check(
    "2238 mutants of 9 contracts compile, and the old tests caught 1791 of them",
    contracts.size === 9 && first.length === 2238 && oldCaught === 1791,
    first.length + " mutants of " + contracts.size + " contracts, " + oldCaught + " caught",
  );
  check(
    "every mutant the old tests missed was run again against the new tests",
    second.length === first.length - oldCaught && second.every((m) => m.result === "uncaught"),
    second.length + " run again, of " + (first.length - oldCaught) + " missed",
  );
  const kind = (k: string) => second.filter((m) => m.kind === k).length;
  const now = oldCaught + second.filter((m) => m.second === "caught").length;
  const same = kind("same code, written differently");
  const cannot = kind("cannot differ given how the system is built");
  const edge = kind("differs only at an exact value we could not set up in a test");
  const owner = kind("differs only after an owner change the contract does not guard against");
  check(
    "2044 caught now; of the other 194, 140 are the same code, 48 cannot differ, 5 differ only at an exact value, 1 only after an owner change",
    now === 2044 && same === 140 && cannot === 48 && edge === 5 && owner === 1 && now + same + cannot + edge + owner === first.length,
    now + " caught, " + same + " same code, " + cannot + " cannot differ, " + edge + " exact values, " + owner + " owner change",
  );
  const unexplained = second.filter((m) => m.second !== "caught" && !m.kind).length;
  check("no mutant is left uncaught without a reason", unexplained === 0, unexplained + " without a reason");
}

// -------------------------------------------------------------------------------------------------

console.log("Checking the README's claims (" + (process.argv.slice(2).join(" ") || "offline") + ")");
benchmark();
race();
replay();
mutation();
if (flag("chain")) await links();
if (flag("sourcify")) await sourcify();
if (flag("forge")) forge();
console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed ? 1 : 0);
