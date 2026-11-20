# Static analysis (Slither)

Run on 20 November 2026 with Slither 0.11.6 over everything in `src/` (dependencies, tests and
scripts filtered out):

```sh
pip install slither-analyzer
slither .            # picks up slither.config.json
```

**93 results: 0 high, 24 medium, 44 low, 24 informational, 1 optimisation. None is exploitable.**
Every result is listed below by detector, with the reason it is safe or what we would change.

The contracts listed in the README are live, so we did not change their source to silence a
detector: the code in this repository is the code that is deployed. The three small items
marked *next version* are noted for a redeploy.

## Medium (24)

| Detector | Count | Where | Verdict |
|---|---|---|---|
| `unused-return` | 16 | `BellVault`, `BellHook`, `Arena`, `BellWatchdog`, `DemoStage` | Intended. These are tuple reads (`getSlot0`, `GUARD.current`, `CONDUCTOR.links`, `FEED.markets`) where only some fields are needed, plus `POOL_MANAGER.settle()` and `unlock()`, whose return values are amounts the caller has already computed. |
| `reentrancy-no-eth` | 3 | `BellVault.unlockCallback` (2), `BellWatchdog._onTick` | Safe. `unlockCallback` only runs when the Uniswap v4 `PoolManager` calls back into a vault that itself started the unlock, and the only hook the pool manager calls on the way is our own `BellHook.beforeAddLiquidity`, a `view` function. The watchdog's external call is `BellReactive.resync`, our own contract, which only asks the Reactive system contract for a callback and never calls back into the watchdog. |
| `uninitialized-local` | 3 | `BellVault.unlockCallback` (`net0`, `net1`, `sqrtPriceX96`) | Intended. They start at zero on purpose and are filled in only on the branches that need them. |
| `divide-before-multiply` | 1 | `BellVault._floor` | Intended. `tick / spacing * spacing` rounds a tick down to the pool's tick spacing; the truncation is the point. |
| `incorrect-equality` | 1 | `DemoStage.availability` | Safe. It compares day numbers (`block.timestamp / 1 days`), which are whole numbers by construction. |

## Low (44)

| Detector | Count | Verdict |
|---|---|---|
| `missing-zero-check` | 15 | Owner-only setters, `withdraw(to)` and constructors. A wrong address can only come from the owner, and every one of them can be set again except `transferOwnership` (see below). |
| `reentrancy-events` | 14 | Events emitted after calls to trusted contracts (the Reactive system contract, the v4 `PoolManager`, our own conductor and tokens). Event order cannot be abused here. |
| `calls-loop` | 7 | Loops over venues and watches, both capped at 8 (`MAX_VENUES`, `MAX_WATCHES`). The calls go to our own conductor and the system contract. |
| `timestamp` | 4 | Used for the demo's 15-second cooldown and daily cap, and the hook's staleness limit. A validator nudging the clock by a few seconds changes nothing that matters. |
| `events-access` | 3 | `transferOwnership` on `BellGuard`, `BellHook` and `BellVault` emits no event. *Next version:* add `OwnershipTransferred`, as `MarketFeed`, `BellReactive` and `BellWatchdog` already do. |
| `reentrancy-benign` | 1 | `Arena.raid` writes its scoreboard after `this.attempt(...)`. The external call is to the arena itself, made through `try` on purpose so a refused swap is reported, not bubbled up. |

## Informational (24) and optimisation (1)

| Detector | Count | Verdict |
|---|---|---|
| `naming-convention` | 18 | Immutables are written in `UPPER_CASE` on purpose. |
| `low-level-calls` | 4 | `withdraw` sends ether with `call` and checks the result; `BellWatchdog.execute` is the owner's way to run the conductor, and it reverts with the reason if the call fails. |
| `costly-loop` | 1 | `BellWatchdog._close` pops from an array of at most 8 entries. |
| `unindexed-event-address` | 1 | `BellVault.KeeperSet(address)`. *Next version:* index it. |
| `immutable-states` | 1 | `Arena.owner` could be `immutable`. *Next version.* |

## Two things Slither does not see

- `MockToken` is play money: anyone the owner allows can mint it. That is the design (see
  "Honest limits" in the README), not a bug.
- Ownership transfers are one step. A mistyped address would lose control of that contract.
  For a testnet demo run by one deployer we kept it simple; a production version would use a
  two-step transfer.
