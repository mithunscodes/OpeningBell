#!/usr/bin/env bash
# Shared by rehearse.sh and serve-local.sh: starts local forks of the three networks and deploys
# every contract onto them with the same scripts used for the real deployment.
#
# Source this file from the repository root, then call `start_forks` and `deploy_all`.
# Needs: foundry (forge, anvil, cast).

# anvil's first built-in account. This key is public and is only ever used on the local forks.
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export DEPLOYMENTS_DIR=deployments/rehearsal
export BASE_RPC=http://127.0.0.1:8545
export UNICHAIN_RPC=http://127.0.0.1:8546
export LASNA_RPC=http://127.0.0.1:8547
# Callbacks are paid from each guard's deposit at the delivery transaction's gas price. anvil adds a
# 1 gwei tip by default, about 200 times Base Sepolia's real price (0.005 gwei), so the testnet
# default of 0.002 ETH would only cover a handful of callbacks here. Fund the local guards more.
export GUARD_FUNDING=${GUARD_FUNDING:-200000000000000000}

LOGS=$(mktemp -d)
PIDS=()

stop_all() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
}
trap stop_all EXIT

start_fork() { # name upstream port
  anvil --fork-url "$2" --port "$3" --silent >"$LOGS/$1.log" 2>&1 &
  PIDS+=($!)
}

start_forks() {
  start_fork base "${BASE_UPSTREAM:-https://sepolia.base.org}" 8545
  start_fork unichain "${UNICHAIN_UPSTREAM:-https://sepolia.unichain.org}" 8546
  start_fork lasna "${LASNA_UPSTREAM:-https://lasna-rpc.rnk.dev/}" 8547

  for port in 8545 8546 8547; do
    local up=""
    for _ in $(seq 1 60); do
      if cast block-number --rpc-url "http://127.0.0.1:$port" >/dev/null 2>&1; then up=yes; break; fi
      sleep 0.5
    done
    if [ -z "$up" ]; then
      echo "the fork on port $port did not start; see $LOGS" >&2
      exit 1
    fi
  done
}

deploy() { # contract rpc
  forge script "script/Deploy.s.sol:$1" --rpc-url "$2" --broadcast >"$LOGS/$1-${2##*:}.log" 2>&1 ||
    { cat "$LOGS/$1-${2##*:}.log"; exit 1; }
  echo "deployed $1 on ${2##*:}"
}

deploy_all() {
  mkdir -p "$DEPLOYMENTS_DIR"
  find "$DEPLOYMENTS_DIR" -maxdepth 1 -name '*.json' -delete

  deploy DeployOrigin "$BASE_RPC"
  deploy DeployConductor "$LASNA_RPC"
  deploy DeployVenue "$BASE_RPC"
  deploy DeployVenue "$UNICHAIN_RPC"
  deploy WireVenues "$LASNA_RPC"
}
