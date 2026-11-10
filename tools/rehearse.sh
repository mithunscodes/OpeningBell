#!/usr/bin/env bash
# Runs the whole system on local forks of the three networks, with no wallet and no testnet funds.
#
# It starts three anvil forks (Base Sepolia, Unichain Sepolia, Reactive Lasna), deploys every
# contract with the same scripts used for the real deployment, and then plays a trading day:
# opening bell, halt, reopen 10% lower, closing bell, overnight gap. src/rehearse.ts plays the part
# of the Reactive Network node, using the real system contract and callback proxies on the forks.
#
# Needs: foundry (forge, anvil), node 20+, and `npm install` in this folder.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/forks.sh

start_forks
deploy_all

cd tools
npx tsx src/rehearse.ts
