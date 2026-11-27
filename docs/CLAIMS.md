# Every claim, and what backs it

Each number in the [README](../README.md) is listed here with the file, transaction or test it comes
from. Most of them are checked by a script, so you don't have to take the prose on trust:

```sh
cd tools && npm install
npx tsx src/claims.ts            # re-derives every measured number from the raw files in bench/
npx tsx src/claims.ts --chain    # also fetches all 51 linked transactions and checks each says what its link says
npx tsx src/claims.ts --sourcify # also asks Sourcify about all 25 deployed contracts
npx tsx src/claims.ts --forge    # also runs the tests and coverage and checks the counts
npx tsx src/claims.ts --all      # everything
```

It needs no key and no wallet. Each line it prints is one claim, PASS or FAIL, with what it found.
Last full run: 24 November 2026, **112 passed, 0 failed**.

The script found two mistakes when it was first run, and both are fixed in the README: the real-night total
was $54,908.75 (the two rounded raids added up), while the exact sum is **$54,908.76**; and the README
counted 5 fuzz tests where the suite had 6 (one fuzz test runs once for each token order).

"Script" in the tables below names the check that covers the claim. "By hand" means the claim is backed
by the linked evidence but the script does not recompute it.

## Speed

| Claim | Evidence | Checked |
| --- | --- | --- |
| 230 market updates in two runs, 230 of 230 loops closed | [`bench/results/`](../bench/results/) (200-update and 30-update runs), [`bench/RESULTS.md`](../bench/RESULTS.md) | script |
| Run 1: 67 halts, 67 resumes, 66 moves | the `action` of each loop in the 200-update file | script |
| Base pool switched p50 1.40 s, p90 2.00 s, max 2.40 s, min 1.00 s | Base Sepolia block timestamps (ms) of the origin and callback blocks of every loop | script |
| Unichain pool switched ≈2 s (p50), ≈3 s (p90, max), ≈1 s (min) | Unichain block timestamps (whole seconds) against Base origin blocks | script |
| Both pools confirmed 2 Lasna blocks after the reaction (max 3) | Lasna block numbers of the reactive transaction and of `LoopClosed` | script |
| Run 2: 30 updates (6 each of halt, resume, close, open, move), Base p50 1.60 s, max 2.00 s, 30 of 30 closed | the 30-update file | script |
| 233 recorded loops in `bench/results/` | the three files: 3 + 200 + 30 | script |
| On ~7 s blocks: about 4.4 s median and 8.4 s worst | measured 1.4 s and 2.4 s plus the average (3 s) and worst (6 s) extra wait for a 7 s block | script (arithmetic) |
| 1.4 s is about 7 Base blocks; at ~7 s Reactive blocks about 22 | 200 ms Base blocks | script (arithmetic) |
| Watchdog re-send took 10 Lasna blocks, 10 s (update #275) | the recovery table in the README: Lasna blocks 8429091 and 8429101, the failed and the landed Unichain callbacks | `--chain` checks the transactions; the block numbers by hand |

## Beat the bell

| Claim | Evidence | Checked |
| --- | --- | --- |
| 32 attempts on a separate race market | [`bench/race/results/2026-11-23-live.json`](../bench/race/results/2026-11-23-live.json), [`deployments/race-84532.json`](../deployments/race-84532.json) | script |
| Protected pool: 13 of 13 raids that landed before the re-price paid | each attempt's raid block against the block where the loop re-priced the pool | script |
| Protected pool: 0 of 19 raids that landed after it paid | same | script |
| Twin pool: 32 of 32 paid | same file | script |
| The loop re-priced the pool a median of 1.0 s after the news (0.6 s to 1.6 s) | Base Sepolia block timestamps | script |
| $87,040.46 taken from the protected pool, $189,039.06 from the twin | `pnl` of every raid in the same file | script |
| The race used the live conductor, watchdog and guards, unchanged | [`script/DeployRace.s.sol`](../script/DeployRace.s.sol) deploys only new tokens, vaults and an arena | by hand |

## A real night, replayed

| Claim | Evidence | Checked |
| --- | --- | --- |
| NVIDIA closed at $173.73 on 11 Nov 2026 and opened at $151.01, 13.1% lower; $154.68 at 8:55 am pre-market | [`bench/replay/nvda-2026-11-12.json`](../bench/replay/nvda-2026-11-12.json) with its three sources | script (the numbers), by hand (the sources) |
| On-chain the prices were $173.7343, $154.6756 and $151.0098 | `onChainPrice` in [`bench/replay/results/nvda-2026-11-12.json`](../bench/replay/results/nvda-2026-11-12.json) | script |
| Base pool switched 1.40 s, 1.00 s and 1.60 s after each update; Unichain about 2, 2 and 3 s | the three loops in the same file | script |
| Twins lost $21,661.53 (Base) and $33,247.22 (Unichain), $54,908.76 in all | the twins' raids, in the file and in their `Raid` events on-chain | script, and `--chain` reads the events |
| Every protected pool raid found nothing | four raids, each with a `RaidPointless` event | script, and `--chain` |

## The demo, live on 12 November

| Claim | Evidence | Checked |
| --- | --- | --- |
| Halted, then resumed 10% lower; the twins were still at $140.00 and one raid took $13,577.95 from each | the two twin raid transactions: `Raid` events with pool price $140.00, real price $125.05 and pnl $13,577.95 | `--chain` |
| The protected pools had nothing to take | the two `RaidPointless` transactions | `--chain` |
| Exchange buttons: one action every 15 s, 100 a day | `STAGE_COOLDOWN` and `STAGE_DAILY_CAP` in [`script/Config.sol`](../script/Config.sol), passed to `DemoStage` in [`script/Deploy.s.sol`](../script/Deploy.s.sol); tested in `test/DemoStage.t.sol` | by hand, and the tests |
| Open: 0.05% fee, ±2% band; closed: 3% fee, ±15% band; halted: swaps refused | `OPEN_FEE`, `OPEN_RANGE_BPS`, `CLOSED_FEE`, `CLOSED_RANGE_BPS` in [`script/Config.sol`](../script/Config.sol); tested in `test/BellPool.t.sol` | by hand, and the tests |

## When a chain misses an update

| Claim | Evidence | Checked |
| --- | --- | --- |
| Every transaction of the recovery (origin, reactive tx, watchdog, ack, the reverted callback, `Retried`, the landed callback, `LoopClosed`, `Settled`, the two gas-limit changes) | the links in the README table | `--chain` (each succeeded, and the failed callback really reverted) |
| Clock is `Cron10`; a venue gets 8 blocks to confirm; at most 3 rounds, then `GaveUp` | constants in [`src/reactive/BellWatchdog.sol`](../src/reactive/BellWatchdog.sol); tested in `test/BellWatchdog.t.sol`, including a fuzz test of any run of outages | by hand, and the tests |

## On-chain proof and contracts

| Claim | Evidence | Checked |
| --- | --- | --- |
| Three full loops, every hop linked | the README table | `--chain` |
| 25 contracts deployed, all verified on Sourcify, 24 exact matches, the watchdog a full bytecode match | [`deployments/`](../deployments/) | `--sourcify` |

## Tests and analysis

| Claim | Evidence | Checked |
| --- | --- | --- |
| 195 tests, all passing; 8 of them fuzz tests | `forge test` | `--forge` |
| 100% of lines (662/662) and 95.9% of branches (141/147) covered | `forge coverage --no-match-coverage "(test|script|lib)"` | `--forge` |
| Mutation testing: 2238 mutants compile; the old tests caught 1791, the current ones 2044; each of the other 194 has a reason (140 same code, 48 cannot differ, 5 exact value, 1 owner change) | [`bench/mutation/`](../bench/mutation/), [`docs/mutation.md`](mutation.md) | script |
| Lowering the watchdog's `maxRetries` mid-watch would keep it re-sending until the count overflows | the surviving mutant at `BellWatchdog` line 201, explained in [`docs/mutation.md`](mutation.md#the-one-thing-it-found-in-a-contract) | by hand |
| Slither: 93 results, none high, none exploitable | [`docs/static-analysis.md`](static-analysis.md), `slither .` | by hand |
| Every push runs tests, coverage, format, Slither and the page build | [`.github/workflows/test.yml`](../.github/workflows/test.yml) | by hand |

## Costs

| Claim | Evidence | Checked |
| --- | --- | --- |
| 0.046 lREACT per market update; the watchdog adds about 0.035 and paid 0.054 for the recovery | the contracts' Lasna balances before and after the 200-update run and the recovery | by hand (balances were read during the runs; not in the repo) |
| About 0.0000022 ETH per update on Base, 0.0000005 ETH on Unichain | the guards' callback-proxy balances during the same run | by hand |

## Outside figures

These are other people's numbers, quoted for context. Nothing in this repo measures them.

| Claim | Evidence | Checked |
| --- | --- | --- |
| Robinhood's stock tokens traded $15 billion in their first 100 days | [Finance Magnates, 13 Oct 2026](https://www.financemagnates.com/fintech/robinhood-puts-stock-token-trading-at-15-billion-as-its-blockchain-turns-100-days/) (figure reported via The Defiant) | by hand, 27 Nov 2026 |
| Kraken's xStocks passed $25 billion in transaction volume | [Kraken blog, 19 Feb 2026](https://blog.kraken.com/product/xstocks/25-billion-in-total-transaction-volume) (CEX, DEX, mint and redemption combined) | by hand, 27 Nov 2026 |
| US stock exchanges trade about 32.5 of the week's 168 hours | RedStone's COO in [crypto.news, 18 Sep 2026](https://crypto.news/tokenized-stocks-face-24-7-pricing-gap-redstone-coo/); 6.5 h × 5 days | by hand (arithmetic) |
