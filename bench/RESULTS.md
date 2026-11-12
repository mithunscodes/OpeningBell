# Loop latency on the live testnets

Two runs on 12 November 2026: 230 market updates in total, and 230 of 230 loops closed.

## Run 1: 200 updates

Run started 2026-11-12T07:12:25.275Z. 200 market updates: 67 halts, 67 resumes after a halt at a new price, 66 price moves while open.
Price moves are 1%. 200 of 200 loops finished within 60 s.

| Hop | p50 | p90 | max | min | n | Clock |
| --- | --- | --- | --- | --- | --- | --- |
| Exchange event → Base Sepolia pool switched | 1.40 s | 2.00 s | 2.40 s | 1.00 s | 200 | block times in ms (Base Sepolia blocks are 200 ms apart) |
| Exchange event → Unichain Sepolia pool switched | ≈2 s | ≈3 s | ≈3 s | ≈1 s | 200 | block times in whole seconds (±1 s) |
| Reaction → both pools confirmed (Lasna blocks) | 2 | 2 | 3 | 2 | 200 | Lasna blocks, about 1 s each |
| Wall clock: tx sent → Base Sepolia switch seen | 2.7 s | 3.3 s | 3.9 s | 2.0 s | 200 | this machine's clock; includes the exchange tx's own inclusion and RPC polling |
| Wall clock: tx sent → Unichain Sepolia switch seen | 4.3 s | 4.8 s | 5.6 s | 3.0 s | 200 | this machine's clock; includes the exchange tx's own inclusion and RPC polling |

## Run 2: 30 updates, with the closing and opening bell

Run 1 never rang the closing bell (its cycle skipped it), so this run covers every kind of update.

Run started 2026-11-12T07:36:50.055Z. 30 market updates: 6 halts, 6 resumes after a halt at a new price, 6 closing bells, 6 opens at a new price, 6 price moves while open.
Price moves are 1%. 30 of 30 loops finished within 60 s.

| Hop | p50 | p90 | max | min | n | Clock |
| --- | --- | --- | --- | --- | --- | --- |
| Exchange event → Base Sepolia pool switched | 1.60 s | 2.00 s | 2.00 s | 0.80 s | 30 | block times in ms (Base Sepolia blocks are 200 ms apart) |
| Exchange event → Unichain Sepolia pool switched | ≈2 s | ≈3 s | ≈3 s | ≈2 s | 30 | block times in whole seconds (±1 s) |
| Reaction → both pools confirmed (Lasna blocks) | 2 | 2 | 3 | 2 | 30 | Lasna blocks, about 1 s each |
| Wall clock: tx sent → Base Sepolia switch seen | 2.7 s | 3.2 s | 3.4 s | 1.9 s | 30 | this machine's clock; includes the exchange tx's own inclusion and RPC polling |
| Wall clock: tx sent → Unichain Sepolia switch seen | 4.3 s | 5.0 s | 5.5 s | 3.6 s | 30 | this machine's clock; includes the exchange tx's own inclusion and RPC polling |

## How the times are taken

Times come from block timestamps, not from this machine, except the wall-clock rows. Lasna's
clock runs about a second behind the others, so Lasna hops are counted in blocks. Every loop's
transactions are listed in the matching file in `bench/results/`.
