#!/usr/bin/env bash
# Rehearses "Beat the bell" on local forks of the three networks, with no wallet and no testnet funds.
# Deploys everything fresh on the forks, adds the race market and pools, starts the local stand-in
# for the Reactive node (slowed down so the loop takes about as long as it does live), and runs a
# short race. Timing on forks is not real; this checks the mechanics only.
#
# Needs: foundry (forge, anvil, cast), node 20+, and `npm install` in tools/.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/forks.sh

start_forks
deploy_all
(cd tools && HOP_DELAY_MS=${HOP_DELAY_MS:-500} npx tsx src/relay.ts >"$LOGS/relay.log" 2>&1) &
PIDS+=($!)
sleep 8
forge script script/DeployRace.s.sol:DeployRace --rpc-url "$BASE_RPC" --broadcast >"$LOGS/race.log" 2>&1 || { cat "$LOGS/race.log"; exit 1; }
echo "deployed DeployRace on 8545"


(cd tools && RACE_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY npx tsx src/race.ts --delays "${RACE_DELAYS:-0,0.5,1,2,3}" --rounds 1)
