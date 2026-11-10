#!/usr/bin/env bash
# Runs the demo page against local forks of the three networks, with no wallet and no testnet funds.
#
# Starts the forks, deploys everything, writes web/public/deployments.local.json, starts a local
# "Reactive node" (src/relay.ts) and serves the built page on http://127.0.0.1:8080/?local
# To play with MetaMask, add the three forks as networks (ports 8545, 8546, 8547) and import
# anvil's first test account. Stop with Ctrl-C.
#
# Needs: foundry, node 20+, `npm install` in tools/ and in web/.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/forks.sh

start_forks
deploy_all

(cd tools && npx tsx src/web-config.ts --local)
(cd web && node build.mjs)

(cd tools && npx tsx src/relay.ts) &
PIDS+=($!)

PORT=${PORT:-8080}
echo "demo page: http://127.0.0.1:$PORT/?local"
(cd web/dist && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
PIDS+=($!)
wait
