# OpeningBell

[![test](https://github.com/mithunscodes/OpeningBell/actions/workflows/test.yml/badge.svg)](https://github.com/mithunscodes/OpeningBell/actions/workflows/test.yml)

**Tokenized stocks that keep market hours, on every chain at once.**

A share of NVIDIA stops trading at 4pm New York time. A token that tracks NVIDIA does not. Every
close, trading halt and overnight gap leaves the token's on-chain pools at a price that is no longer
true, and the first bot to notice trades against them and keeps the difference. The people who
supplied the pool pay for it. When the token trades on several chains, every chain is exposed at the
same moment. Reactive names the same gap in its own
[Robinhood Chain post](https://blog.reactive.network/reactivexrobinhood/): stock tokens trade around
the clock, the stocks behind them do not.

This is already real money. Robinhood's stock tokens traded **$15 billion in their first 100 days**
([Finance Magnates, 13 Oct 2026](https://www.financemagnates.com/fintech/robinhood-puts-stock-token-trading-at-15-billion-as-its-blockchain-turns-100-days/)) and Kraken's xStocks passed
**$25 billion** in transaction volume ([Kraken, 19 Feb 2026](https://blog.kraken.com/product/xstocks/25-billion-in-total-transaction-volume)), while the stocks behind them trade about
**32.5 of the week's 168 hours** ([RedStone's COO in crypto.news, 18 Sep 2026](https://crypto.news/tokenized-stocks-face-24-7-pricing-gap-redstone-coo/)). Every
close, weekend and overnight gap in the other 135 hours is a window for the pools to be picked off.

OpeningBell puts the stock exchange's hours on-chain. A Reactive Network contract watches the
exchange's state and, in a single reactive transaction, switches the token's pools on Base Sepolia
and Unichain Sepolia into the right mode: re-priced the moment the market reopens, refusing swaps
during a halt, wide and expensive after hours. A second Reactive contract, the watchdog, checks that
every chain confirmed, and re-sends by itself to one that did not.

Built for the Reactive Omni Buildathon, track **Every Second Counts**.

**The reactive contract is the product, not a relay.** The trading rules live on Reactive:
`BellReactive` holds each market's policy (the fee and liquidity band for open, closed and halted),
decides venue by venue whether an update is worth a callback, drops stale and out-of-order feed
events, and keeps the only record of which chain has confirmed which state. The pools hold no rules
of their own; they apply what it sends. One market event has to reach pools on two chains within
the same second, and be sent again if a chain misses it. That needs one place that sees every
chain: a contract on Base cannot see Unichain, and a keeper per chain cannot prove the chains agree.
The feed stands in for a licensed exchange feed, and it already carries the real market: every
trading day it posts NVIDIA's real bell at the real price ([The real bell](#the-real-bell)).

### For judges: where each criterion is answered

| Criterion | Look here |
| --- | --- |
| **Execution** | [Three full loops with every hash](#on-chain-proof-three-full-loops) (origin, reactive tx, both callbacks, loop closed), all 233 loops in [`bench/results/`](bench/results/), [live contracts](#live-contracts), and the [demo](https://openingbell-two.vercel.app) to run one yourself |
| **Integration** | [Why Reactive](#why-reactive), [`BellReactive`](src/reactive/BellReactive.sol) (rules, per-venue filter, confirmations, `LoopClosed`) and the [watchdog](#when-a-chain-misses-an-update) that re-sends by itself on a Reactive `Cron` clock |
| **Usefulness** | [The money at stake](#openingbell) ($15 billion of stock-token trades in 100 days, real market open 32.5 of 168 hours), [A real night, replayed](#a-real-night-replayed) ($54,908.76 lost unprotected, nothing protected), [Beat the bell](#beat-the-bell-how-fast-does-a-raider-have-to-be), [The real bell](#the-real-bell), [Speed](#speed) |
| **Craft** | [`docs/CLAIMS.md`](docs/CLAIMS.md) (every number linked to its proof), [mutation testing](docs/mutation.md), [CI](.github/workflows/test.yml), [build, test and run](#build-test-and-run), [honest limits](#honest-limits) |

Live on Base Sepolia, Unichain Sepolia and Reactive Lasna, with all 25 contracts source-verified on
Sourcify. 195 tests cover every line of the contracts and catch 2044 of the 2238 small changes
[mutation testing](docs/mutation.md) made to them, and every change they miss is explained. Every push
runs them on CI. Over 230 market updates on the live testnets, the Base pool switched a median of **1.4 s** after the exchange
event (2.4 s at worst), the Unichain pool about **2 s** after, and **230 of 230** loops closed. On Reactive's earlier ~7 s blocks
the same loop would leave the old price tradable about three times as long. See [Speed](#speed).

A bot that raced the live loop 32 times, reading each new price on the same chain as the news,
got paid by the protected pool only when it landed before the loop re-priced it (median 1.0 s after
the news): **0 of 19** raids after that point paid, while the unprotected twin paid **32 of 32**. See
[Beat the bell](#beat-the-bell-how-fast-does-a-raider-have-to-be).

Fed the real prices of NVIDIA's night of 11 to 12 November 2026, when the share opened 13.1% lower,
the pools that ignore market hours lost **$54,908.76** to one raid each and the protected pools lost
**nothing**. See [A real night, replayed](#a-real-night-replayed).

And it rings on the real market: every trading day a scheduled job posts NVIDIA's real closing bell
and real opening bell, at the real price, and the pools on both chains follow on their own. See
[The real bell](#the-real-bell).

Don't take these numbers on trust: [`docs/CLAIMS.md`](docs/CLAIMS.md) links every one of them to the file,
transaction or test behind it, and `tools/src/claims.ts` re-checks them, read-only, against the raw data,
the chains and Sourcify.

**[Play the demo](https://openingbell-two.vercel.app)** with any wallet and a little test ETH.

[![The OpeningBell demo page: play the exchange, watch the clock, raid the pools](docs/demo.png)](https://openingbell-two.vercel.app)

**[Watch the three-minute video](https://youtu.be/8YB6nJwq09I)**: the benchmark, a live halt on two chains, a raid, a real NVIDIA night and the watchdog recovering a missed update.

## How it works

```mermaid
sequenceDiagram
    participant X as Exchange feed<br/>(Base Sepolia)
    participant R as BellReactive<br/>(Reactive Lasna)
    participant W as BellWatchdog<br/>(Reactive Lasna)
    participant B as Pools on Base Sepolia
    participant U as Pools on Unichain Sepolia
    X->>R: MarketUpdate (open, closed or halted + price)
    X->>W: the same MarketUpdate
    R->>B: callback: new mode and price
    R->>U: callback: new mode and price
    B-->>R: Ack
    U-->>R: Ack
    Note over R: LoopClosed: both chains in sync
    W->>R: on a clock tick: has every chain confirmed?
    Note over W: if one has not, BellReactive sends to it again
```

1. **`MarketFeed`** (Base Sepolia) publishes the reference market's state: open, closed or halted,
   plus the reference price. Nobody publishes equity prices on a testnet, so in the demo the
   exchange is played by `DemoStage`: the price moves when someone presses an exchange button, and
   it has also been fed [a real night of NVIDIA prices](#a-real-night-replayed). In production the
   feed is replaced by an existing equity feed; the rest of the system only depends on the
   `MarketUpdate` event.
2. **`BellReactive`** (Reactive Lasna) subscribes to the feed. For each update it decides what every
   venue should do and sends one callback per venue chain from the same reactive transaction.
3. On each venue chain, **`BellGuard`** records the state (it accepts writes only through Reactive
   Network's callback proxy, and only from our `BellReactive`), **`BellVault`** pulls the pool's liquidity, moves the empty pool to the
   new price and puts the liquidity back in a band around it, and **`BellHook`**, a Uniswap v4 hook,
   applies the mode to every swap.
4. Each guard confirms with an `Ack` event, which `BellReactive` also subscribes to. When every venue
   has confirmed, it emits `LoopClosed`: an on-chain record that all chains agree.
5. **`BellWatchdog`** (Reactive Lasna) makes sure the loop closes. It hears the same update, switches on
   the network's own clock (`Cron10`, one event every ten blocks) and looks at `BellReactive`'s books
   on the next tick. A venue that still owes a confirmation eight blocks after the send is sent the
   state again, up to three rounds, with nobody pressing anything. Once every loop is closed the
   watchdog unsubscribes from the clock, so a quiet market costs nothing.

| Exchange state | Swaps | Fee | Liquidity band |
| --- | --- | --- | --- |
| Open | allowed | 0.05% | ±2% around the reference price |
| Closed (after hours, weekends) | allowed | 3% | ±15% |
| Halted | refused | | |

## The demo: play the villain

Each venue chain has two identical Uniswap v4 pools of the pretend stock token. One is protected by
OpeningBell. The other, the *twin*, ignores market hours, as most pools do today.

1. **Play the exchange.** Halt trading, ring the closing bell, or reopen 10% higher or lower.
2. **Watch the stopwatch.** Every hop of the loop appears with its transaction, timed from block
   timestamps.
3. **Raid a pool.** `Arena.raid()` does in one transaction what an arbitrage bot does: it trades
   against the pool until the pool's price matches the real one and keeps the difference. It uses
   play money minted for the occasion, so any wallet can play with no tokens or approvals.

No wallet? The chart at the top of the page holds every loop of the benchmark below. Click a bar and
one of those loops replays on the stopwatch, with a link to each of its real transactions.

Live on the testnets on 12 November 2026, played from a fresh wallet through the demo page: trading
was halted at $138.94 and resumed 10% lower at $125.05. The twins were still quoting $140.00, and one
raid took **$13,577.95 from the twin on each chain**. The same raid on the protected pools found
nothing to take: they were already at the new price.

| | Base Sepolia | Unichain Sepolia |
| --- | --- | --- |
| Raid on the twin | [$13,577.95 taken](https://sepolia.basescan.org/tx/0x2112a21b98413ae139ba3c950a3d9381c2b616488c2d7c5a262dfa28cd2261f3) | [$13,577.95 taken](https://sepolia.uniscan.xyz/tx/0xb5c157087eca20fa340441d9788ce2cf3a7fbcf06fd59a689ab2681eea9ad2f7) |
| Raid on the protected pool | [nothing to take](https://sepolia.basescan.org/tx/0x7b2db110a9cb6c785443b0d1692a91df873b4080ee8d1362e6ecde830ec15fb5) | [nothing to take](https://sepolia.uniscan.xyz/tx/0x80e6ee85f48695e2badffa3ef01568500dcc725bcdc5e870c16fa56bfb870656) |

Exchange actions are shared by everyone and rate-limited (one every 15 seconds, 100 a day), because
each one costs the project testnet funds on Reactive Network. Playing needs a little test ETH for gas
on Base Sepolia or Unichain Sepolia, for example from the [Superchain faucet](https://app.optimism.io/faucet).

## A real night, replayed

On 11 November 2026 NVIDIA closed at **$173.73**. News about its chief executive broke after the
bell. The share could not trade again until 9:30 the next morning, when it opened at **$151.01**,
13.1% lower. A token that tracks NVIDIA trades through all of that.

On 16 November we played that night's real prices through the live system, with
[`tools/src/replay.ts`](tools/src/replay.ts) and an ordinary wallet pressing the public exchange
buttons. The twins started the night where the protected pools did, at the closing price.

| New York time | Real price | Exchange event (Base Sepolia) | Reactive reacts (Lasna) | Base pool switched | Unichain pool switched | Both confirmed (Lasna) |
| --- | --- | --- | --- | --- | --- | --- |
| 11 Nov, 4:00 pm: closing bell | **$173.73** | [update #285](https://sepolia.basescan.org/tx/0x712d32f55519aab42961ca784583b26c2aa5ab90cfd7a5a9f20a8ed38e4eb282) | [reactive tx](https://lasna.reactscan.net/tx/0xdeabc42e7f9b3c351eb97179b24a90c211fe4c321c91c5de05745c30c352fc32) | [1.40 s](https://sepolia.basescan.org/tx/0x73bc1c6f93d9bc5780f78c087cc3dec19bb634448782411cf9854b929a65db67) | [≈2 s](https://sepolia.uniscan.xyz/tx/0x64a98734d628ddbf3661d2eb1f7f092951bb64d3822ef30ac59ddec112175c47) | [loop closed](https://lasna.reactscan.net/tx/0xa3a180a5af738406876afad340520b57395dbbdf79a8545502b87280fa1166b3) |
| 12 Nov, 8:55 am: pre-market quote, market still shut | **$154.68** | [update #286](https://sepolia.basescan.org/tx/0x157953b733885e5926820f023ff5d5983afcd58d37337438c6c49de30c627e04) | [reactive tx](https://lasna.reactscan.net/tx/0xee64696fa7928f118e3fe97dccf8d70df2d595b4bc6d46bcefb4620adfae47c8) | [1.00 s](https://sepolia.basescan.org/tx/0xedca06533e44e888df58d0876d2a35b1873b881dbd5a01fcf8ed5438f304a880) | [≈2 s](https://sepolia.uniscan.xyz/tx/0x409382c26dffb19ddecfda6f96947aceb56f0ecb3b28cb9edbe722bf743978aa) | [loop closed](https://lasna.reactscan.net/tx/0x29798e8108921c5dff262c9eb09f24e8c6023a0cf10da0158f22a37418d62233) |
| 12 Nov, 9:30 am: opening bell | **$151.01** | [update #287](https://sepolia.basescan.org/tx/0x36d14dceed0b96ac0b9244b0f16be8e886bf6c6404303dec74e5693779845cd9) | [reactive tx](https://lasna.reactscan.net/tx/0x992f75c32d0dca67dd4d0cc1eebcf3c90f1651579d682765aabf19903fab38ed) | [1.60 s](https://sepolia.basescan.org/tx/0x80405fca829ea3f956e615772d9b33ab9be6f3342d6dba661e117748e8b07b4b) | [≈3 s](https://sepolia.uniscan.xyz/tx/0x214ccf8bc26f0cf1945f57a3dd4ad3bf52c65395b7b79529fba75c8f793e513c) | [loop closed](https://lasna.reactscan.net/tx/0x8c4848c9bb5c7d1dcc2325a11334adad7cab5c97bb124fa889a7708c70e72f6c) |

After the opening bell, one raid on every pool:

| | Base Sepolia | Unichain Sepolia |
| --- | --- | --- |
| Twin, still quoting $173.73 | [$21,661.53 taken](https://sepolia.basescan.org/tx/0x3c4cbc4c1302bc0d0b75911cf99d59f49fccf14fa861225f5b30f338c7c23bd9) | [$33,247.22 taken](https://sepolia.uniscan.xyz/tx/0x29a6640cef8c3d813680d24ea55d92c56d26f19ec7a57eee81f44eb277e54748) |
| Protected pool, already at $151.01 | [nothing to take](https://sepolia.basescan.org/tx/0x2d37bb2ef2b237d15e2a8234f49777e79008f445e3f0f2132ac737a9456ea80c) | [nothing to take](https://sepolia.uniscan.xyz/tx/0x18281bdbb836afe2d399f1f9e34975f57eb737f506f2764e1c4d6dace87855e1) |
| Protected pool before the open, at the pre-market $154.68 | [nothing to take](https://sepolia.basescan.org/tx/0x32b134067a1d2f7e0af82021aec1a66e314ee0678d1df4987e9ffd0b581d139f) | [nothing to take](https://sepolia.uniscan.xyz/tx/0x14da48e65787dfdd333b490c2c9c48e941fa2b18934f25fcc6b0d47f1e7d396b) |

**$54,908.76 left the two pools that ignored the bell. Nothing left the two that followed it.** To
take anything from a protected pool, a raider had to trade inside the 1.6 seconds between the opening
bell and the Base pool's switch (about 3 seconds on Unichain).

What is real here and what is not:

- **The three prices are real.** The close and the open are from NVIDIA's daily price history
  ([StockAnalysis](https://stockanalysis.com/stocks/nvda/history/), checked against
  [TipRanks](https://www.tipranks.com/stocks/nvda/historical-prices)). The pre-market quote is the one
  [Business Upturn](https://businessupturn.com/finance/stock-market/us-market/nvidia-shares-extend-slide-to-nearly-11-in-pre-market-trade-after-jensen-huang-resigns-as-ceo-trading-below-52-week-low/)
  reported at 8:55 am.
- **The feed is still ours.** `DemoStage` moves the price in whole basis points, so the script picked
  moves that hit every real price to the cent: on-chain the three prices are $173.7343, $154.6756
  and $151.0098.
- **The night was played in under a minute, not seventeen and a half hours.** The three updates
  went out one after the other. What is measured is each update's trip around the loop.
- **The pools hold play money.** The dollar figures show the proportion between the two kinds of
  pool, not what a mainnet pool would lose; the two twins held different amounts by then, which is
  why their figures differ.

The scenario is [`bench/replay/nvda-2026-11-12.json`](bench/replay/nvda-2026-11-12.json), and every
transaction of the run, lead-in included, is in
[`bench/replay/results/nvda-2026-11-12.json`](bench/replay/results/nvda-2026-11-12.json). The demo
page shows the same night, and each of its three updates replays on the stopwatch.

## The real bell

The system follows the real market every trading day. A scheduled GitHub
workflow ([`.github/workflows/bell.yml`](.github/workflows/bell.yml)) runs
[`tools/src/bell.ts`](tools/src/bell.ts), which:

1. asks Yahoo Finance for NVDA's regular session (Stooq as a fallback). That gives the real opening
   and closing time of the day, so weekends, holidays and early closes need no calendar of ours;
2. picks the latest real bell: the 9:30 am open at the first regular minute's opening price, or the
   4:00 pm close at the closing price;
3. reads the feed, and posts the bell only if the feed has nothing as new. The update carries the
   bell's own time as its source time, so a second run finds nothing to do, and an exchange button
   pressed on the demo page after the bell is left alone until the next one;
4. times the loop on both chains, as the benchmark does, and adds the bell with every transaction
   to a log on the [`live-log`](https://github.com/mithunscodes/OpeningBell/tree/live-log) branch,
   which the demo page lists, bell by bell with every transaction, under "On the real market".

The job is an ordinary publisher on `MarketFeed`, with its own key holding a little Base Sepolia
ETH; everything after the exchange event is the same reactive loop as everywhere else. It is the
stand-in for a licensed exchange feed, not a keeper: it never touches a pool. GitHub starts
scheduled runs a few minutes late, so the log says how long after the real bell each update was
posted; the switch times are measured from the exchange event, like every other number here.
Rehearse it on forks with `tools/bell-rehearse.sh`.

## Speed

`tools/src/bench.ts` plays many market updates on the live testnets and times each loop from
on-chain records only:

- **Exchange event → Base pool switched** uses Base Sepolia's millisecond block timestamps. Both ends
  are on the same chain and clock, so the number is exact to the 200 ms block.
- **Exchange event → Unichain pool switched** compares two chains' clocks. Unichain only has whole
  seconds, so this hop is good to about a second.
- **Reaction → both pools confirmed** is counted in Lasna blocks. Lasna's clock runs about a second
  behind the others, so it is never subtracted from another chain's clock.

Live run, 12 November 2026: 200 market updates (67 halts, 67 resumes at a new price, 66 price
moves while open). **200 of 200 loops closed.**

| Hop | p50 | p90 | max | min | Clock |
| --- | --- | --- | --- | --- | --- |
| Exchange event → Base Sepolia pool switched | **1.40 s** | 2.00 s | 2.40 s | 1.00 s | Base Sepolia block times in ms |
| Exchange event → Unichain Sepolia pool switched | **≈2 s** | ≈3 s | ≈3 s | ≈1 s | whole seconds (±1 s) |
| Reaction → both pools confirmed | 2 Lasna blocks | 2 | 3 | 2 | Lasna blocks, about 1 s each |

A second run of 30 updates added the closing bell and the next day's open (6 of each, which the
first run's cycle skipped): Base p50 1.60 s, max 2.00 s, and 30 of 30 loops closed.

Full results are in [`bench/RESULTS.md`](bench/RESULTS.md), and every loop's transaction hashes are
in `bench/results/`.

### Why it needs Omni's one-second blocks

Between the exchange event and the pool switching, a bot can still trade at the old price. That
window is what OpeningBell exists to shrink, and its length is set mostly by Reactive's block time:
the reaction waits for the next Lasna block, and the confirmation takes two more.

The same loops on Reactive's earlier ~7 s blocks, estimated by keeping every measured leg and
changing only the Lasna block time (so the estimate is a lower bound):

| | On Omni (measured) | On ~7 s blocks (estimate) |
| --- | --- | --- |
| Exchange event → Base pool switched, median | **1.4 s** | about 4.4 s |
| Exchange event → Base pool switched, worst | **2.4 s** | about 8.4 s |
| Exchange event → Unichain pool switched, median | **≈2 s** | about 5 s |
| Both pools confirmed back on Reactive | **2 blocks, ≈2 s** | 2 blocks, ≈14 s |
| Watchdog re-sends to a chain that missed an update | **10 blocks, 10 s** (measured, update #275) | 10 blocks, ≈70 s |

How the estimate works: with blocks every *T* seconds, an event waits on average *T*/2 for the next
block and at most *T*. Going from ~1 s to ~7 s adds about 3 s on average and up to 6 s at worst.
Legs counted in Lasna blocks scale with the block time.

On Base Sepolia, whose blocks are 200 ms apart, a 1.4 s window is about 7 blocks in which a raid can
still land. At ~7 s Reactive blocks it would be about 22. The window is three times longer, every
time the market moves.

### Beat the bell: how fast does a raider have to be?

The numbers above say when the pool switches. This asks the question a raider asks: how quickly do I
have to act on the news to still get paid? A bot raced the live loop 32 times on a separate market
with its own pair of pools (the demo is untouched). It read each new price from the feed itself, on
the same chain as the news, which is the fastest attacker there can be, and raided both pools after
a set wait from 0 to 3 seconds.

| 23 November 2026, 32 attempts, 5% moves | Raids that paid |
| --- | --- |
| Protected pool, raid landed **before** the loop re-priced it | **13 of 13** |
| Protected pool, raid landed **after** the loop re-priced it | **0 of 19** |
| Twin pool, which nothing re-prices | **32 of 32** |

![Each attempt: when the raid landed against when the loop re-priced the protected pool](docs/beat-the-bell.svg)

The loop re-priced the protected pool a median of **1.0 s** after the news (0.6 s to 1.6 s, Base
Sepolia block times). A raider that acts within about 0.8 s always wins, and that is the honest
limit of any cross-chain loop; one that takes longer than 1.6 s never does. The twin keeps paying
every raider, however slow, until somebody re-prices it by hand. Every attempt, with its
transactions: [`bench/race/RESULTS.md`](bench/race/RESULTS.md).

## On-chain proof: three full loops

Each row is one market update, from the origin event to the callbacks and back.

| Update | Exchange event (Base Sepolia) | Reactive reacts (Lasna) | Pool switched (Base Sepolia) | Pool switched (Unichain Sepolia) | Both confirmed (Lasna) |
| --- | --- | --- | --- | --- | --- |
| Halt (update #4) | [origin](https://sepolia.basescan.org/tx/0x897768526e96f342566524cb9f7e3122b6537f75822556f0d78b15581093e2b3) | [reactive tx](https://lasna.reactscan.net/tx/0xe31c145252dbca98234c90b938704e7cda9db9f459136da4701edc30c774a81d) | [callback](https://sepolia.basescan.org/tx/0xc1bf64cf6243455897a90dff257987a54f1f6cda57ee4fb0d9d24ce01a2339a9) | [callback](https://sepolia.uniscan.xyz/tx/0x903a79517951fcaabf74de27d6733a3565b3c17eee221094562df210af8471af) | [loop closed](https://lasna.reactscan.net/tx/0xa7507db51f9ce502dfdc41806cb98bf90082fb8ab8e230c23454dc85d6d237e2) |
| Resume 1% lower (update #5) | [origin](https://sepolia.basescan.org/tx/0xeea27f0b2f2cef9254fbb986452a48d2542ec45545b06adf7bde58b56cf62f05) | [reactive tx](https://lasna.reactscan.net/tx/0x40de9bfc4d897c5d4310b290af61c8b4cb970779be6e3db3acd949380e52a4f4) | [callback](https://sepolia.basescan.org/tx/0xf31c62e812c30bed894df0610bcdb1aafd8de857a26a7eea80374cf0a664dddb) | [callback](https://sepolia.uniscan.xyz/tx/0x166dbce255dbad7b7ddf15769d805e782661bd694fcdf5a3b55aab8ecf54f2a3) | [loop closed](https://lasna.reactscan.net/tx/0x27f7580c6dda639a41a377a597d97dc7406011a0ef148b96b4e1176901738ef5) |
| Closing bell (update #206) | [origin](https://sepolia.basescan.org/tx/0x5fb8c0815d2621810c599f1de3ac9edbb7735b39d49ee960bb58addae2b2024c) | [reactive tx](https://lasna.reactscan.net/tx/0xedb35dc6582236d0b658fbbbd4a352ee87ec09a08f996571fbc3a7a7f49a9d5c) | [callback](https://sepolia.basescan.org/tx/0xfe6c085a2ceec12e303177306b360c7660fd0dd5c64ad2d15d7c5d50bb435598) | [callback](https://sepolia.uniscan.xyz/tx/0x4d5f93ae9a977020a8ada5f3544a18e8e9081829de3da4ad8f5cac2dcf4b81ce) | [loop closed](https://lasna.reactscan.net/tx/0x667b0f637013e1dbfecab2e88b17e29172abecf5a040d9673ba7d5dcb595fb9f) |

All 233 recorded loops are listed the same way in `bench/results/`.

## When a chain misses an update

A callback can fail: the venue chain is congested, the callback runs out of gas, the guard is out
of funds. Without a second look, that venue would stay on the old state until the next market
update. `BellWatchdog` is that second look, and it is a reactive contract too.

We broke one callback on purpose on the live testnets (15 November 2026, update #275, a resume after
a halt). The Unichain venue's callback gas was set to 100,000, far too little, for one update:

| Time (UTC) | What happened | Transaction |
| --- | --- | --- |
| 18:38:42 | The exchange resumes trading | [origin](https://sepolia.basescan.org/tx/0x14c3a2e7a0e868c2961a707ac6c86b14f9369d6cfcb832ea663d7b1d0ee823d2) |
| Lasna block 8429091 | `BellReactive` sends to both venues; `BellWatchdog` starts watching and switches the clock on | [reactive tx](https://lasna.reactscan.net/tx/0xe39b7622a22fef2e86780e3201fd77de65a48c299d9d2f63b927c2b4d19a88f6), [watchdog](https://lasna.reactscan.net/tx/0x6869bf6313f231bb5de6e9430598b6c55438af56305d544731ae7c363979755f) |
| Lasna block 8429092 | Base confirms | [ack](https://lasna.reactscan.net/tx/0xb83c9f943a33fd15acfb54f60aa8806ade2fee0d29232af5f47ea4a6100056ae) |
| 18:38:44 | The callback to Unichain fails: out of gas | [reverted](https://sepolia.uniscan.xyz/tx/0xbd34a68ba2b9f458c704a2f0020c52692c2e4644137632caf9f6f44889a66ef4) |
| Lasna block 8429101 | The clock ticks. The watchdog sees Unichain still owes a confirmation and has the conductor send again | [`Retried`](https://lasna.reactscan.net/tx/0x63e6f2398834a6256ea6092a9c7fd194d8f9350550c5fc53195be1cb0361b0e5) |
| 18:38:54 | The second callback lands on Unichain, ten seconds after the first one failed | [callback](https://sepolia.uniscan.xyz/tx/0x78fc1d2e278b59ad2539b471189181bf7ea95b2bb99f977e1a26fb9f905c3b44) |
| Lasna block 8429103 | Unichain confirms: `LoopClosed` | [loop closed](https://lasna.reactscan.net/tx/0x02bedad9705148bb8f5853b5de4c41a015d99712d9cfcae42463a27b13509c17) |
| Lasna block 8429111 | Next tick: the watchdog records `Settled` after one round and switches the clock off | [`Settled`](https://lasna.reactscan.net/tx/0xa47e565a8060ef8d0e7f7437388a11f6f719ad23369d302c2d4b41d3926a17ce) |

The gas limit was put back to 1,000,000 four seconds after the update
([setting it low](https://lasna.reactscan.net/tx/0x7992f13b113ad8ad93e6ad94ca7028800e2cabd89b5dd214a35b7cc2bfdff004),
[putting it back](https://lasna.reactscan.net/tx/0x64d2a5511daaaec983548c51e70df8344074cf25fc67354852ca1f859e74798e)).
Nobody called `resync`: the re-send came from the watchdog's own reactive transaction.

The demo page shows it when it happens: the late chain's box on the stopwatch gets a "2nd try" tag,
and the line under it says the watchdog had the update sent again.

What it does not do: if the venue is still broken after three rounds it emits `GaveUp` and stops, so
a dead venue cannot drain it. And it re-sends through `BellReactive`, so it has to own that
contract; the deployer still reaches every owner function through the watchdog's `execute`.

The benchmark in [Speed](#speed) was measured before the watchdog existed. It does not sit in the
path of the first callback, which still leaves in `BellReactive`'s own reactive transaction.

## Why Reactive

- The decision is made on Reactive. `BellReactive` holds the fee and liquidity band for each market
  status, filters small price moves per venue, ignores stale and out-of-order feed events, and keeps
  the ledger of which venue confirmed which update. The pools only apply what it sends.
- A keeper bot per chain is off-chain and trusted, has to be run and funded on every chain
  separately, and leaves no on-chain proof that the chains agree.
- A price oracle read on each swap fixes the price but not the mode: it does not halt swaps, widen
  the band or move the liquidity away from the stale price.
- With Reactive, one on-chain decision reaches every venue chain from a single reactive transaction,
  and the confirmations come back to the same contract, which records `LoopClosed`.
- The safety net is on Reactive too. The watchdog's clock is a Reactive `Cron` event, it subscribes
  and unsubscribes from inside `react()`, and it reads and calls `BellReactive` directly because both
  live on Reactive Network. No keeper, no server.

## Live contracts

| Network | Contract | Address |
| --- | --- | --- |
| Base Sepolia | `MarketFeed` | `0x8ddc373617e2D83348fE72eAcF8C4ffB58e9C46E` |
| Base Sepolia | `DemoStage` | `0x5E61Ad5f07de8E8c6438036FC7315Ebf783c4Ba2` |
| Reactive Lasna | `BellReactive` | `0x8ddc373617e2D83348fE72eAcF8C4ffB58e9C46E` |
| Reactive Lasna | `BellWatchdog` | `0xF462b2cA056d52E762F3434789fDe040FE2964Eb` |
| Base Sepolia | `BellGuard` | `0xac2b5Be3B5208D8f5bC91BEd7465da46954e2CEE` |
| Base Sepolia | `BellHook` | `0x6E4b43f2B25851D0FAeDe788C41fc1B467e64880` |
| Base Sepolia | `BellVault` | `0xE5a33BfF43DDB8c1518B883A8662c245958cAAd5` |
| Base Sepolia | `Arena` | `0x3D783C81828EB1718143C0e84375B8F680982F04` |
| Unichain Sepolia | `BellGuard` | `0x8ddc373617e2D83348fE72eAcF8C4ffB58e9C46E` |
| Unichain Sepolia | `BellHook` | `0x2026BACF74615ca0c767b885C891067356E0C880` |
| Unichain Sepolia | `BellVault` | `0x513a29Ed7091BCF66490AcA9Dc04e52B3198142f` |
| Unichain Sepolia | `Arena` | `0xE5a33BfF43DDB8c1518B883A8662c245958cAAd5` |
| Base Sepolia | `BellVault` (race) | `0x68f5B42DA827e1945018340C2A5d9a6C35622A5A` |
| Base Sepolia | `Arena` (race) | `0x326b04659aaafA70e6Ec2F2430f622fadEdFB45F` |

Twin pools, tokens and pool ids are in [`deployments/`](deployments/); the race pools of Beat the bell are in `deployments/race-84532.json`.

**All 25 deployed contracts are source-verified on [Sourcify](https://sourcify.dev)**: the 14 above,
plus both twin hooks, the three twin vaults and the six play-money tokens. 24 are exact matches. The
watchdog is a full match on its bytecode; only comment text changed after it was deployed. Look any
address up at `https://repo.sourcify.dev/<chain id>/<address>` (Base Sepolia 84532, Unichain Sepolia
1301, Reactive Lasna 5318007).

## Honest limits

- **Two seconds is not zero.** OpeningBell shrinks the window from "until someone notices" to about
  two seconds, on every chain at once. A bot that acts within about a second of the news can still
  win, and [Beat the bell](#beat-the-bell-how-fast-does-a-raider-have-to-be) measures exactly where
  that line falls. The after-hours fee and wide band make a closed market a poor place to bet on
  overnight news, which is where the largest gaps happen.
- **The feed is a stand-in.** In the demo, prices are set by whoever plays the exchange, not by a
  licensed exchange feed. The replayed night and [the real bell](#the-real-bell) use NVIDIA's real
  prices, but we publish them, and the real bell lands a few minutes after the real one.
- **Testnets and play money only.** The stock token is a mock with no value.
- **One owner rule the watchdog does not enforce.** Mutation testing showed that lowering the
  watchdog's `maxRetries` while a watch already has more rounds would make it re-send to a venue
  that stays down until its round count overflows. The owner switches the watchdog off before
  lowering it ([details](docs/mutation.md#the-one-thing-it-found-in-a-contract)).

## Repository

| Path | What it holds |
| --- | --- |
| `src/origin/` | `MarketFeed`, and `DemoStage`, which lets anyone play the exchange in the demo |
| `src/reactive/` | `BellReactive`, the conductor on Reactive Network, and `BellWatchdog`, which re-sends to a venue that never confirmed |
| `src/venue/` | `BellGuard`, `BellHook`, `BellVault`, `Arena`, `MockToken` and the price maths |
| `script/` | Deployment scripts, the same ones the local rehearsal uses |
| `test/` | Foundry tests (195, including fuzz tests), with a local simulator of Reactive Omni and the real Uniswap v4 PoolManager bytecode from Base Sepolia |
| `tools/` | Fork rehearsal, latency benchmark, real-night replay, the raider-speed sweep ("Beat the bell"), the real-bell job, the claims checker, mutation testing, loop watcher, and a local relay for trying the demo offline |
| `bench/` | The benchmark's results, the replayed night with its sources and transactions, the raider-speed sweep, and the mutation testing results |
| `web/` | The demo page, a static build that Vercel deploys using `vercel.json` |
| `docs/` | Every claim with its evidence (`CLAIMS.md`), the mutation testing report, the static analysis report and the page screenshot |
| `.github/workflows/` | CI (tests, coverage, Slither, demo page build) and the daily real bell |

## Build, test and run

Needs [Foundry](https://book.getfoundry.sh/) and Node 20 or newer.

```sh
git clone --recurse-submodules https://github.com/mithunscodes/OpeningBell
cd OpeningBell
forge test                     # 195 tests, 8 of them fuzz tests
forge coverage --no-match-coverage "(test|script|lib)"
slither .                      # static analysis, see docs/static-analysis.md
```

| Coverage of `src/` | Lines | Statements | Branches | Functions |
| --- | --- | --- | --- | --- |
| All contracts | **100%** (662/662) | 99.4% (782/787) | **95.9%** (141/147) | 100% (113/113) |

The six branches left uncovered are two token transfers returning `false` (our tokens never do), two
tick clamps that only matter at prices the price maths already refuses, the raid's early return when
its limit equals the pool's price to the last bit, and the conductor's owner check, which
`test_OwnerOnlyControls` trips but the coverage tool does not count.

Every push runs the tests, coverage, a format check, Slither and the demo page's build on GitHub
Actions (`.github/workflows/test.yml`).

**Static analysis:** Slither reports 93 results, none of them high and none exploitable. Each one is
explained in [`docs/static-analysis.md`](docs/static-analysis.md).

**Mutation testing:** slither-mutate changed the contracts one small thing at a time, 2238 times, and
ran the tests against each change. The tests as submitted caught 1791. The misses showed where they were
thin, and with 67 new tests they now catch 2044. Of the other 194, 140 change nothing, 48 matter
only in states the system cannot reach, 5 only at one exact value, and one only if the owner lowers
the watchdog's retry limit mid-watch (see [Honest limits](#honest-limits)). Each is listed with its reason
in [`docs/mutation.md`](docs/mutation.md).

Every number in this README, re-checked from the raw data, the chains and Sourcify (read-only, no key):

```sh
cd tools && npm install && npx tsx src/claims.ts --all
```

The whole system on local forks of all three networks, with no wallet and no testnet funds. A
local relay plays the part of the Reactive Network node, using the real system contract and
callback proxies on the forks:

```sh
(cd tools && npm install)
tools/rehearse.sh              # a trading day: open, halt, reopen lower, close, overnight gap
```

The demo page on local forks:

```sh
(cd web && npm install)
tools/serve-local.sh           # then open http://127.0.0.1:8080/?local
```

On the live testnets, with the deployer's key:

```sh
cd tools
npx tsx src/watch.ts                                         # print each loop as it happens
DEPLOYER_PRIVATE_KEY=0x... npx tsx src/bench.ts --rounds 100 # timed benchmark
```

The real night, from any funded testnet wallet (it uses the public exchange buttons):

```sh
REPLAY_PRIVATE_KEY=0x... npx tsx src/replay.ts ../bench/replay/nvda-2026-11-12.json
```

Beat the bell, with a key that may publish on the feed (the race market has no public buttons).
Rehearse it on forks first, then add the race pools on Base Sepolia once and run the sweep:

```sh
tools/race-rehearse.sh                                                   # on forks, five attempts
forge script script/DeployRace.s.sol:DeployRace --rpc-url https://sepolia.base.org --broadcast
cd tools && RACE_PRIVATE_KEY=0x... npx tsx src/race.ts                   # 32 attempts, 0.0 to 3.0 s
```

The real bell, with a key that may publish on the feed. The workflow runs it on a schedule; by hand:

```sh
tools/bell-rehearse.sh                                   # on forks: open, a repeat that does nothing, close
cd tools && npx tsx src/bell.ts --dry                    # which bell is due right now, sends nothing
BELL_PRIVATE_KEY=0x... npx tsx src/bell.ts               # post it if the feed does not have it yet
```

## Costs

Measured over the live 200-update run:

- 0.046 lREACT per market update on Lasna, at its 100 gwei gas price. One update is three reactive
  transactions: the update itself and the two confirmations.
- The watchdog adds about 0.035 lREACT to a healthy update (one reactive transaction to start
  watching, one clock tick to see the loop closed) and paid 0.054 for the recovery above. It has its
  own balance and can be switched off with `setArmed(false)`.
- Each guard pays for its own callbacks through the callback proxy: about 0.0000022 ETH per update on
  Base Sepolia and 0.0000005 ETH on Unichain Sepolia at current testnet gas prices.

## Built with

[Reactive Network](https://reactive.network) Omni (`reactive-lib-omni`), Uniswap v4 (`v4-core`),
Foundry, viem.
