# Mutation testing

Coverage says which lines the tests ran. It does not say whether the tests would notice if one of
those lines were wrong. Mutation testing checks exactly that: a tool changes the contracts one small
thing at a time (a `<` becomes `<=`, a line is deleted, a value becomes `0`), runs the whole test
suite against each changed copy, and records whether any test failed. Each changed copy is a
*mutant*. A mutant the tests catch is fine. A mutant they miss is either a gap in the tests, or a
change that makes no difference to what the contract does.

We ran [slither-mutate](https://github.com/crytic/slither) (Slither 0.11) on every contract in
`src/` except `MockToken`, the demo's test token: 2238 mutants that compile, each one run
against the full suite (`forge test`, without the fork tests).

## Result

| Contract | Mutants that compile | Caught by the old tests | Caught now | Same code | Cannot differ | Exact edge | Owner change |
|---|--:|--:|--:|--:|--:|--:|--:|
| Arena | 248 | 194 | 219 | 12 | 12 | 5 | 0 |
| BellGuard | 66 | 58 | 63 | 3 | 0 | 0 | 0 |
| BellHook | 157 | 123 | 147 | 7 | 3 | 0 | 0 |
| BellReactive | 470 | 370 | 414 | 51 | 5 | 0 | 0 |
| BellVault | 378 | 331 | 344 | 18 | 16 | 0 | 0 |
| BellWatchdog | 311 | 246 | 288 | 19 | 3 | 0 | 1 |
| DemoStage | 174 | 146 | 156 | 9 | 9 | 0 | 0 |
| MarketFeed | 58 | 53 | 57 | 1 | 0 | 0 | 0 |
| PriceMath | 376 | 270 | 356 | 20 | 0 | 0 | 0 |
| **All** | **2238** | **1791** | **2044** | **140** | **48** | **5** | **1** |

*Caught by the old tests* is the suite as submitted (128 tests). The mutants it missed showed us
where the tests were thin, so we wrote 67 more tests (195 now). *Caught now* is the
same mutants run again against the new suite. Every mutant still not caught was read by hand and
given one of four reasons:

- **Same code** (140): the change does not change the program. `i++` for `++i` when the value
  is not used, `x > 0` for `x != 0` on an unsigned number, a constant marked `immutable`, `= 0` on a
  variable that starts at zero.
- **Cannot differ** (48): the change would matter only in a state the system can never reach.
  A smaller integer type for a price that is capped at 112 bits, a check removed before paying zero
  tokens, a tick clamp at ±887,000 ticks when the price maths refuses anything past about ±443,000.
- **Exact edge** (5): the change matters, but only at one exact value that we could not set up
  in a test, all in the raid code of `Arena`:

  - line 134: a raid started with exactly `MIN_RAID_GAS` gas left
  - line 227: the pool price equal to the stop price to the wei (2 mutants)
  - line 233: the limit price equal to the pool's current price to the last bit
  - line 255: a swap that takes tokens in but pays nothing out

- **Owner change** (1): the change matters only after the owner does something the contract
  does not stop. See the next section.

So: **every mutant that changes what the contracts do is caught, except those 5 and one that
needs an owner's mistake**, which is 2044 of 2050.

## The one thing it found in a contract

The watchdog gives up on an update when `retries == maxRetries`. If the owner lowered `maxRetries`
with `setTiming` while a watch already had more rounds than the new limit, that watch would never
equal it: for as long as the lagging venue stayed down, the watchdog would keep re-sending to it
every round, and after 255 rounds the count would overflow and every tick would revert until the
owner switched the watchdog off. `>=` instead of `==` would have closed it.

We did not change the contract, because the deployed watchdog is the code in this repository and it
owns the live conductor. The owner's rule instead: switch the watchdog off (`setArmed(false)`, which
drops every open watch) before lowering `maxRetries`, then switch it back on. Nothing else in the
contracts needed a change. Every other gap mutation testing found was in the tests, and only tests
were added.

## What the old tests missed

The first pass pointed at real gaps in the tests, all closed now:

- **The conductor** (`BellReactive`): that a loop closes only with the *last* venue's confirmation,
  whichever venue is late; that a venue switched off and on again, which never got the update, keeps
  the loop open; that an older confirmation never winds the record back; sequence numbers past 32
  bits; that logs which are almost right (a neighbouring topic, a payload one word too long, the same
  sequence number twice) are ignored, and say why; that a good update is never also reported as
  ignored; that a venue whose listener runs out of gas still gets the state.
- **The pools** (`BellHook`, `BellVault`, `Arena`): the exact second the stale fee starts (the old
  tests ran at timestamp 1, so the time check was never really exercised); the band sitting exactly
  on the tick grid, negative ticks included; the twin charging its own fee and never halting, and
  being topped up to exactly what it started with; a vault placing its pool before any market data;
  an unregistered pool refused as unregistered; raids reported against the raider, blocked raids
  counted, and a market with no reference price never raided.
- **The watchdog** (`BellWatchdog`): closing or giving up on one market while the others stay
  watched; each round waiting the whole deadline again; re-sending to venue 0; which feed, chain and
  event can start a watch; a repeated or older update never restarting the count; a conductor that
  is behind never asked to re-send an older state; a venue switched back on, or never told about the
  market, being caught up; switching on again leaving open watches alone; the largest sequence number.
- **The price maths** (`PriceMath`): it had no tests of its own. Now the square root is checked
  around every power of two, prices at both ends of their range, and liquidity below, inside and
  above the band, up to the exact 128-bit limit.
- **The demo and the feed** (`DemoStage`, `MarketFeed`): the demo price snapping back when it
  leaves its corridor; the cooldown and daily cap following new limits; the feed keeping every field.
- **Everywhere**: events no test looked at (each contract's set-up and owner-change announcements),
  and `coverDebt`, which pays what a reactive contract owes the network.

## The files

| File | What it holds |
| --- | --- |
| [`bench/mutation/logs/`](../bench/mutation/logs/) | slither-mutate's own log for each contract (the repeated "Multiple frameworks detected" warning removed) |
| [`bench/mutation/first-pass.json`](../bench/mutation/first-pass.json) | Every mutant that compiled, and whether the old tests caught it |
| [`bench/mutation/second-pass.json`](../bench/mutation/second-pass.json) | Every mutant the old tests missed, run again against the new tests, and for each one still missed, its reason |
| [`tools/mutation/`](../tools/mutation/) | The four steps below |

`tools/src/claims.ts` re-counts the table above from the two JSON files.

## Running it

Needs Foundry and Slither 0.11 or newer (`pip install slither-analyzer`). The first step takes
several hours on four cores; each contract runs in its own copy of the repository, so the working
tree is never touched.

```sh
tools/mutation/run.sh               # 1. slither-mutate on each contract, logs in bench/mutation/logs/
python3 tools/mutation/collect.py   # 2. the logs, as bench/mutation/first-pass.json
python3 tools/mutation/recheck.py   # 3. re-runs every survivor against the current tests: second-pass.json
python3 tools/mutation/sort.py      # 4. gives each remaining survivor its reason, prints the table
```

After adding more tests, `recheck.py --again` re-runs only the mutants that are still missed.

`sort.py` fails if any survivor matches none of its rules, so a new survivor is read by a person
instead of being waved through. Its rules name exact lines of the current source.

Two notes on the tool. slither-mutate logs a whole statement for its `MIA` mutator but changes only
the condition of a `? :` inside it; `recheck.py` places those mutants the same way. And because
adding tests can only catch more mutants, never fewer, only the first pass's survivors need running
again.
