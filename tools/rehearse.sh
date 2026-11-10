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

# anvil's first built-in account. This key is public and is only ever used on the local forks.
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export DEPLOYMENTS_DIR=deployments/rehearsal
export BASE_RPC=http://127.0.0.1:8545
export UNICHAIN_RPC=http://127.0.0.1:8546
export LASNA_RPC=http://127.0.0.1:8547

LOGS=$(mktemp -d)
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

start_fork() { # name upstream port
  anvil --fork-url "$2" --port "$3" --silent >"$LOGS/$1.log" 2>&1 &
  PIDS+=($!)
}

start_fork base "${BASE_UPSTREAM:-https://sepolia.base.org}" 8545
start_fork unichain "${UNICHAIN_UPSTREAM:-https://sepolia.unichain.org}" 8546
start_fork lasna "${LASNA_UPSTREAM:-https://lasna-rpc.rnk.dev/}" 8547

for port in 8545 8546 8547; do
  for _ in $(seq 1 60); do
    cast block-number --rpc-url "http://127.0.0.1:$port" >/dev/null 2>&1 && break
    sleep 0.5
  done
done

mkdir -p "$DEPLOYMENTS_DIR"
find "$DEPLOYMENTS_DIR" -maxdepth 1 -name '*.json' -delete

deploy() { # contract rpc
  forge script "script/Deploy.s.sol:$1" --rpc-url "$2" --broadcast >"$LOGS/$1-${2##*:}.log" 2>&1 ||
    { cat "$LOGS/$1-${2##*:}.log"; exit 1; }
  echo "deployed $1 on ${2##*:}"
}

deploy DeployOrigin "$BASE_RPC"
deploy DeployConductor "$LASNA_RPC"
deploy DeployVenue "$BASE_RPC"
deploy DeployVenue "$UNICHAIN_RPC"
deploy WireVenues "$LASNA_RPC"

cd tools
npx tsx src/rehearse.ts
