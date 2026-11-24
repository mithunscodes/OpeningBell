#!/usr/bin/env python3
"""Mutation testing, step 2: reads slither-mutate's logs and writes every mutant that compiled, with
whether the tests caught it, to bench/mutation/first-pass.json.

    python3 tools/mutation/collect.py [log ...]      # default: bench/mutation/logs/*.log
"""
import glob, json, pathlib, re, sys
from collections import Counter

root = pathlib.Path(__file__).resolve().parents[2]
logs = sys.argv[1:] or sorted(glob.glob(str(root / "bench/mutation/logs/*.log")))
record = re.compile(
    r"INFO:Slither-Mutate:\[(\w+)\] Line (\d+): '(.*?)' ==> '(.*?)' --> (CAUGHT|UNCAUGHT|COMPILATION FAILURE)", re.S)

mutants, failures = [], Counter()
for log in logs:
    text = open(log, errors="replace").read()
    marks = [(m.start(), m.group(1)) for m in re.finditer(r"Mutating contract (\w+)", text)]
    for m in record.finditer(text):
        contract = [name for at, name in marks if at < m.start()][-1]
        if m.group(5) == "COMPILATION FAILURE":
            failures[contract] += 1
            continue
        mutants.append(dict(contract=contract, mutator=m.group(1), line=int(m.group(2)),
                            original=m.group(3), mutant=m.group(4), result=m.group(5).lower()))

out = root / "bench/mutation/first-pass.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps({"tool": "slither-mutate", "compileFailures": dict(failures), "mutants": mutants}, indent=1) + "\n")
per = Counter((m["contract"], m["result"]) for m in mutants)
for c in sorted({m["contract"] for m in mutants}):
    print(f"{c:14} {per[(c, 'caught')]:4} caught of {per[(c, 'caught')] + per[(c, 'uncaught')]:4}")
print(f"{'total':14} {sum(v for (c, r), v in per.items() if r == 'caught'):4} caught of {len(mutants):4}  -> {out}")
