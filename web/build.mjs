// Bundles the demo page into web/dist: a static folder that any host can serve.
//   node build.mjs          one build
//   node build.mjs --watch  rebuild on change
import { build, context } from "esbuild";
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const watch = process.argv.includes("--watch");
mkdirSync("dist", { recursive: true });

// The benchmark runs reported in bench/RESULTS.md. The page draws them and can replay any loop.
const BENCH_RUNS = ["2026-11-12T07-12-25-275Z.json", "2026-11-12T07-36-50-055Z.json"];

/** Shrinks the benchmark's raw results to what the page needs: one small record per loop. */
function recordedLoops() {
  const dir = resolve("../bench/results");
  const loops = [];
  for (const file of BENCH_RUNS) {
    const path = join(dir, file);
    if (!existsSync(path)) continue;
    const run = JSON.parse(readFileSync(path, "utf8"));
    if (run.local) continue;
    for (const l of run.loops) {
      const t0 = l.origin?.ms;
      const base = l.applied?.base;
      const unichain = l.applied?.unichain;
      const seen = l.seen ?? {};
      loops.push({
        seq: Number(l.seq),
        action: l.action,
        at: t0,
        feed: l.origin?.tx,
        observed: l.observed?.tx,
        observedBlock: l.observed ? Number(l.observed.block) : undefined,
        base: base?.tx,
        baseMs: base && t0 !== undefined ? base.ms - t0 : undefined,
        unichain: unichain?.tx,
        unichainMs: unichain && t0 !== undefined ? unichain.ms - t0 : undefined,
        closed: l.closed?.tx,
        closedBlock: l.closed ? Number(l.closed.block) : undefined,
        // When the benchmark script itself noticed each Reactive step, in ms after the exchange
        // event. Lasna blocks carry no millisecond time, so a replay paces those two steps by this.
        sawObserved: seen.observed !== undefined && seen.origin !== undefined ? seen.observed - seen.origin : undefined,
        sawClosed: seen.closed !== undefined && seen.origin !== undefined ? seen.closed - seen.origin : undefined,
      });
    }
  }
  return loops;
}

const copyStatic = () => {
  cpSync("index.html", "dist/index.html");
  cpSync("style.css", "dist/style.css");
  if (existsSync("public")) cpSync("public", "dist", { recursive: true });
  writeFileSync("dist/loops.json", JSON.stringify(recordedLoops()));
};

const options = {
  entryPoints: ["src/main.ts"],
  bundle: true,
  // The page imports the contract ABIs from ../tools/src; this lets that file find viem here.
  nodePaths: [resolve("node_modules")],
  format: "esm",
  target: "es2022",
  minify: !watch,
  sourcemap: watch,
  outfile: "dist/main.js",
  logLevel: "info",
  plugins: [{ name: "static", setup: (b) => b.onEnd(copyStatic) }],
};

if (watch) await (await context(options)).watch();
else await build(options);
