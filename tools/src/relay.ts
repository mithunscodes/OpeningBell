/**
 * Keeps a local "Reactive Network" running against the forks, for trying the demo page locally.
 * Started by ./serve-local.sh. HOP_DELAY_MS slows each hop down so the stopwatch has something to show.
 */
import { deployments } from "./config.js";
import { LocalNode } from "./localnode.js";

const node = new LocalNode(deployments(), {
  hopDelayMs: Number(process.env.HOP_DELAY_MS ?? 400),
  log: (line) => console.log(new Date().toISOString().slice(11, 23) + "  " + line),
});

await node.prepare();
console.log("local Reactive node running");
await node.runForever();
