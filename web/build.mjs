// Bundles the demo page into web/dist: a static folder that any host can serve.
//   node build.mjs          one build
//   node build.mjs --watch  rebuild on change
import { build, context } from "esbuild";
import { cpSync, existsSync, mkdirSync } from "node:fs";

const watch = process.argv.includes("--watch");
mkdirSync("dist", { recursive: true });
const copyStatic = () => {
  cpSync("index.html", "dist/index.html");
  cpSync("style.css", "dist/style.css");
  if (existsSync("public")) cpSync("public", "dist", { recursive: true });
};

const options = {
  entryPoints: ["src/main.ts"],
  bundle: true,
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
