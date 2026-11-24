#!/usr/bin/env python3
"""Mutation testing, step 4: gives every mutant still uncaught after the second pass a reason, writes it
into bench/mutation/second-pass.json, and prints the table in docs/mutation.md. Each survivor must match
a rule below. Anything that matches none is printed and the script fails, so a new survivor gets read by
a person instead of being waved through.

    python3 tools/mutation/sort.py

The rules name exact lines: they describe the source as it is in this commit.
"""
import json, pathlib, re, sys
from collections import Counter, defaultdict

root = pathlib.Path(__file__).resolve().parents[2]
SAME = "same code, written differently"
CANNOT = "cannot differ given how the system is built"
EDGE = "differs only at an exact value we could not set up in a test"
OWNER = "differs only after an owner change the contract does not guard against"
UNSIGNED = "`x != 0` as `x > 0`, or `x == 0` as `x <= 0`, on an unsigned number"
ZERO_MOVE = "paying, minting, taking or counting zero tokens: a no-op either way"


def rule(m):
    c, l, mu = m["contract"], m["line"], m["mutator"]
    o, n = " ".join(m["original"].split()), " ".join(m["mutant"].split())

    # --- the same code, written differently ---------------------------------------------------------
    if mu == "SBR" and " constant " in o and (" immutable " in n or re.search(r"\buint(128|64|32)\b|\bint128\b", n)):
        return SAME, "a constant declared `immutable`, or given a smaller type its value still fits"
    if mu == "SBR" and re.search(r"\b(memory|storage)\b", o) and re.sub(r"\b(memory|storage)\b", "X", o) == re.sub(r"\b(memory|storage)\b", "X", n):
        return SAME, "a copy that is read but never written, kept in memory instead of storage or the reverse"
    if mu == "UOR" and re.fullmatch(r"(\+\+|--)\w+|\w+(\+\+|--)", o):
        return SAME, "`++i` written as `i++` (or `--i` as `i--`) where the value is not used"
    if mu in ("MVIV", "LIR") and o.endswith("= 0") and n in (o, o[:-3].strip()):
        return SAME, "`= 0` left out, or replaced by itself: variables start at zero"
    if mu == "SBR" and (re.search(r"for \(uint(256|128) ", o) or re.fullmatch(r"uint256 \w+ = 0", o)) and "uint128" in n:
        return SAME, "a loop counter with a smaller type: no loop runs more than 8 times"
    if mu == "ROR" and re.search(r"(\w|\])\s*(!=|==) 0\b", o) and not re.search(r"\bint(256|128)\b", o) and n in (o.replace("!= 0", "> 0"), o.replace("== 0", "<= 0")):
        return SAME, UNSIGNED
    if mu == "ROR" and re.fullmatch(r"\w+ != (3|count)", o) and n == o.replace("!=", "<"):
        return SAME, "`i != n` as `i < n` in a loop that counts up to n"
    if mu == "BOR" and "| LPFeeLibrary.OVERRIDE_FEE_FLAG" in o and "^ LPFeeLibrary.OVERRIDE_FEE_FLAG" in n:
        return SAME, "`fee | FLAG` as `fee ^ FLAG`: a fee never has the flag's bit set"
    if c == "BellVault" and mu == "CR" and o == 'return ""':
        return SAME, '`return ""` left out: the function returns empty bytes anyway'
    if c == "BellVault" and mu == "ASOR" and l in (145, 146):
        return SAME, "`net += x` as `net = x`, `|=` or `^=` while `net` is still zero"
    if c == "BellVault" and mu == "ROR" and l == 230:
        return SAME, "two equal numbers swapped, or left in place"
    if c == "BellVault" and mu == "ROR" and l == 243 and n in ("tick <= 0 && tick % spacing != 0", "tick < 0 && tick % spacing < 0"):
        return SAME, "rounding down to the tick grid: for a negative tick `% spacing != 0` means `< 0`, and tick 0 has no remainder"
    if c == "BellReactive" and l == 357 and "sentSeq <= 0" in n:
        return SAME, UNSIGNED
    if c == "MarketFeed" and l == 64:
        return SAME, UNSIGNED
    if c == "Arena" and mu == "ROR" and l == 227 and "refPrice <= 0" in n:
        return SAME, UNSIGNED
    if c == "PriceMath" and mu == "ROR" and (l, n) in ((62, "sqrtP < sqrtA"), (64, "sqrtP <= sqrtB")):
        return SAME, "at the band's edge both formulas give the same amounts (the other side's share is zero)"
    if c == "PriceMath" and l in (107, 110) and mu in ("CR", "BOR", "MIA", "ROR"):
        return SAME, "a larger first guess for the square root, which seven rounds still turn into the exact root"
    if c == "PriceMath" and mu == "SBR" and l == 19 and "uint128(1) << 64" in n:
        return SAME, "`uint256(1) << 64` as `uint128(1) << 64`: the same number, which fits"
    if c == "BellWatchdog" and mu == "AOR" and l == 254:
        return SAME, "switching off closes every watch from the front instead of the back: they all close either way"
    if c == "BellWatchdog" and mu == "ROR" and l == 152 and n.startswith("seq < 0 ||"):
        return SAME, "the `seq == 0` check dropped: a zero `seq` is turned away two lines later anyway, by `seq <= w.seq`"

    # --- cannot differ given how the system is built ------------------------------------------------
    if mu == "SBR" and re.search(r"uint(128|64|32)|int128", n):
        return CANNOT, "a smaller integer type for a value that always fits (prices are capped at uint112, pool amounts are 128-bit, block numbers and timestamps fit 32 bits for decades)"
    if c == "BellReactive" and l == 344:
        return CANNOT, "the `minMoveBps == 0` check removed: with a zero minimum the formula says 'moved enough' anyway"
    if c == "BellReactive" and mu == "ROR" and l == 284:
        return CANNOT, "`seq != sent` as `seq < sent`: a larger `seq` was already turned away two lines up"
    if (c, l) in (("BellReactive", 377), ("BellWatchdog", 160)) and mu == "ROR" and ">= MAX" in n:
        return CANNOT, "`length == MAX` as `length >= MAX`: the list can never grow past MAX"
    if c == "BellHook" and mu == "ROR" and l in (126, 162) and ("status >= MarketTypes.OPEN" in n or "c.maxStale > 0" in n):
        return CANNOT, "`status == OPEN` as `>= OPEN` (HALTED was already refused), or `maxStale != 0` as `> 0` (unsigned)"
    if c == "BellHook" and mu == "ROR" and l == 159:
        return CANNOT, "`status == HALTED` as `>= HALTED`: HALTED is the highest status"
    if c == "DemoStage" and mu == "ROR" and l == 118:
        return CANNOT, "`today != countedDay` as `today > countedDay`: the day number only goes up"
    if c == "DemoStage" and l == 128:
        return CANNOT, "the `price == 0` check removed: a zero price falls below the corridor and snaps to the same reset price"
    if c == "BellVault" and mu == "RR" and l in (237, 238):
        return CANNOT, "the tick clamps: PriceMath refuses prices that far out (beyond about 443,000 ticks) long before the 887,000 limit"
    if c == "BellVault" and mu == "CR" and l in (163, 164):
        return CANNOT, "moving an empty pool moves no tokens: only the vault can add liquidity, and it took all of it out first"
    if c == "BellVault" and l == 207:
        return CANNOT, "the `total > 0` check removed: what the vault is owed here is never negative"
    if c == "BellVault" and (l in (212, 214, 257) or (mu == "ROR" and l in (92, 134, 151, 178))):
        return CANNOT, ZERO_MOVE
    if c == "Arena" and l in (182, 183, 245, 251) and mu in ("MIA", "ROR"):
        return CANNOT, ZERO_MOVE

    # --- differs only after an owner change the contract does not guard against -------------------
    if c == "BellWatchdog" and mu == "ROR" and l == 201 and "w.retries >= maxRetries" in n:
        return OWNER, "`retries == maxRetries` as `>=`: differs only if the owner lowers maxRetries below a watch's count, which `setTiming` allows"

    # --- differs only at an exact edge -------------------------------------------------------------
    if c == "Arena" and mu == "ROR" and l == 227:
        return EDGE, "the pool price equal to the stop price to the wei"
    if c == "Arena" and mu == "RR" and l == 233:
        return EDGE, "the limit price equal to the pool's current price to the last bit"
    if c == "Arena" and mu == "LOR" and l == 255:
        return EDGE, "a swap that takes tokens in but pays nothing out"
    if c == "Arena" and mu == "ROR" and l == 134:
        return EDGE, "a raid started with exactly MIN_RAID_GAS gas left"
    return None, None


path = root / "bench/mutation/second-pass.json"
first = json.loads((root / "bench/mutation/first-pass.json").read_text())["mutants"]
second = json.loads(path.read_text())
bad = []
for m in second["mutants"]:
    m.pop("kind", None), m.pop("why", None)
    if m["second"] == "caught":
        continue
    kind, why = rule(m) if m["second"] == "uncaught" else (None, None)
    if not kind:
        bad.append(m)
        continue
    m["kind"], m["why"] = kind, why
path.write_text(json.dumps(second, indent=1) + "\n")

rows = defaultdict(Counter)
for m in first:
    rows[m["contract"]]["mutants"] += 1
    rows[m["contract"]]["first"] += m["result"] == "caught"
for m in second["mutants"]:
    rows[m["contract"]]["second"] += m["second"] == "caught"
    rows[m["contract"]][m.get("kind")] += 1
print("| Contract | Mutants that compile | Caught by the old tests | Caught now | Same code | Cannot differ | Exact edge | Owner change |")
print("|---|--:|--:|--:|--:|--:|--:|--:|")
total = Counter()
for c in sorted(rows):
    r = rows[c]
    total.update(r)
    print(f"| {c} | {r['mutants']} | {r['first']} | {r['first'] + r['second']} | {r[SAME]} | {r[CANNOT]} | {r[EDGE]} | {r[OWNER]} |")
t = total
print(f"| **All** | **{t['mutants']}** | **{t['first']}** | **{t['first'] + t['second']}** | **{t[SAME]}** | **{t[CANNOT]}** | **{t[EDGE]}** | **{t[OWNER]}** |")
print()
groups = Counter((m["kind"], m["why"]) for m in second["mutants"] if "kind" in m)
for (kind, why), n in sorted(groups.items(), key=lambda kv: (kv[0][0], -kv[1])):
    print(f"{n:4}  [{kind}] {why}")
for m in bad:
    print("UNSORTED", m["second"], m["contract"], m["line"], m["mutator"], m["original"][:80], "==>", m["mutant"][:60])
sys.exit(1 if bad else 0)
