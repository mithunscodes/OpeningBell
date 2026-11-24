#!/usr/bin/env python3
"""Mutation testing, step 3: puts every mutant that survived the first pass back into a fresh copy of
the repository, as it is now (with any tests added since), and runs the suite again. Adding tests can
only catch more, so mutants caught the first time stay caught; only the survivors need re-running.

    python3 tools/mutation/recheck.py [--workers 2] [--again] [Contract ...]   # writes bench/mutation/second-pass.json

Naming contracts re-runs only theirs and keeps the other results already in second-pass.json.
--again re-runs only the mutants second-pass.json still lists as not caught, after more tests were added.
"""
import argparse, json, os, pathlib, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

root = pathlib.Path(__file__).resolve().parents[2]
ap = argparse.ArgumentParser()
ap.add_argument("--workers", type=int, default=2)
ap.add_argument("--again", action="store_true")
ap.add_argument("contracts", nargs="*")
args = ap.parse_args()

out = root / "bench/mutation/second-pass.json"
key = lambda m: (m["contract"], m["line"], m["mutator"], m["original"], m["mutant"])
mine = lambda m: not args.contracts or m["contract"] in args.contracts
if args.again:
    previous = json.loads(out.read_text())["mutants"]
    survivors = [{k: v for k, v in m.items() if k not in ("second", "kind", "why")}
                 for m in previous if m["second"] != "caught" and mine(m)]
else:
    first = json.loads((root / "bench/mutation/first-pass.json").read_text())
    survivors = [m for m in first["mutants"] if m["result"] == "uncaught" and mine(m)]
files = {p.stem: p.relative_to(root) for p in (root / "src").rglob("*.sol")}
work = pathlib.Path(tempfile.mkdtemp())


def copy(i):
    d = work / f"w{i}"
    d.mkdir()
    for item in ["src", "test", "script", "foundry.toml", "remappings.txt"]:
        p = root / item
        if p.is_dir():
            shutil.copytree(p, d / item)
        elif p.exists():
            shutil.copy2(p, d / item)
    os.symlink(root / "lib", d / "lib")
    return d


def tests(d):
    r = subprocess.run("forge test --no-match-path 'test/fork/*' --fail-fast", shell=True, cwd=d,
                       capture_output=True, text=True, timeout=900)
    return r.returncode, r.stdout[-4000:] + r.stderr[-3000:]


def placement(m):
    """slither-mutate's MIA swaps only a ternary's condition, but logs the whole statement."""
    original, mutant = m["original"], m["mutant"]
    if m["mutator"] == "MIA" and "?" in original and (mutant.strip() in ("true", "false") or mutant.startswith("!(")):
        pre = original.split("?")[0]
        if " = " in pre:
            pre = pre.split(" = ", 1)[1]
        if pre.startswith("return "):
            pre = pre[len("return "):]
        original = pre.strip()
    return original, mutant


def recheck(job):
    i, batch = job
    d = copy(i)
    code, out = tests(d)
    if code != 0:
        sys.exit("the suite fails without any mutant:\n" + out)
    done = []
    for m in batch:
        rel = files[m["contract"]]
        text = (root / rel).read_text()
        original, mutant = placement(m)
        start = sum(len(l) + 1 for l in text.split("\n")[: m["line"] - 1])
        at = text.find(original, start)
        if at < 0 or text[start:at].count("\n") > 2:
            done.append({**m, "second": "not placed"})
            continue
        (d / rel).write_text(text[:at] + mutant + text[at + len(original):])
        code, out = tests(d)
        (d / rel).write_text(text)
        compiled = not ("Compiler run failed" in out or "Error (" in out) or "[FAIL" in out
        done.append({**m, "second": ("caught" if code != 0 else "uncaught") if compiled else "no compile"})
        print(done[-1]["second"].ljust(9), m["contract"], m["line"], m["mutator"], flush=True)
    return done


jobs = [(i, survivors[i :: args.workers]) for i in range(args.workers)]
with ThreadPoolExecutor(args.workers) as pool:
    results = [m for batch in pool.map(recheck, jobs) for m in batch]
rerun = {key(m) for m in survivors}
if (args.contracts or args.again) and out.exists():
    results += [m for m in json.loads(out.read_text())["mutants"] if key(m) not in rerun and (args.again or not mine(m))]
results.sort(key=lambda m: (m["contract"], m["line"], m["mutator"], m["mutant"]))
out.write_text(json.dumps({"mutants": results}, indent=1) + "\n")
shutil.rmtree(work)
print(sum(m["second"] == "caught" for m in results), "of", len(results), "survivors now caught")
