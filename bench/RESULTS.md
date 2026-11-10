# Loop latency on the live testnets

Run started 2026-11-10T20:35:48.112Z. 3 market updates, cycling through halt, close, reopen and
price moves of 1%. 3 of 3 loops finished within 60 s.

| Hop | p50 | p90 | max | min | n | Clock |
| --- | --- | --- | --- | --- | --- | --- |
| Exchange event → Base Sepolia pool switched | 1.40 s | 2.00 s | 2.00 s | 1.20 s | 3 | block times in ms (Base Sepolia blocks are 200 ms apart) |
| Exchange event → Unichain Sepolia pool switched | ≈2 s | ≈2 s | ≈2 s | ≈2 s | 3 | block times in whole seconds (±1 s) |
| Reaction → both pools confirmed (Lasna blocks) | 2 | 2 | 2 | 2 | 3 | Lasna blocks, about 1 s each |
| Wall clock: tx sent → Base Sepolia switch seen | 2.8 s | 2.9 s | 2.9 s | 2.8 s | 3 | this machine's clock; includes the exchange tx's own inclusion and RPC polling |
| Wall clock: tx sent → Unichain Sepolia switch seen | 4.0 s | 4.1 s | 4.1 s | 3.3 s | 3 | this machine's clock; includes the exchange tx's own inclusion and RPC polling |

Times come from block timestamps, not from this machine, except the wall-clock rows. Lasna's
clock runs about a second behind the others, so Lasna hops are counted in blocks. Every loop's
transactions are listed in the matching file in `bench/results/`.
