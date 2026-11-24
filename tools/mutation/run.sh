#!/usr/bin/env bash
# Mutation testing, step 1: slither-mutate on each contract, one log per contract.
#
#   tools/mutation/run.sh                    # every contract (several hours on 4 cores)
#   tools/mutation/run.sh BellHook Arena     # just these
#
# Needs Slither (pip install slither-analyzer, 0.11 or newer) and Foundry. Each contract runs in its
# own copy of the repository, so several can run at once and the working tree is never touched.
# Then: python3 tools/mutation/collect.py, recheck.py and sort.py (see docs/mutation.md).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
logs="${MUTATION_LOGS:-$root/bench/mutation/logs}"
work="${MUTATION_WORK:-$(mktemp -d)}"
mkdir -p "$logs"

contracts=("$@")
[ ${#contracts[@]} -eq 0 ] && contracts=(MarketFeed DemoStage BellReactive BellWatchdog BellGuard BellHook BellVault Arena PriceMath)

for c in "${contracts[@]}"; do
  dir="$work/$c"
  rm -rf "$dir" && mkdir -p "$dir"
  cp -a "$root/src" "$root/test" "$root/script" "$root/foundry.toml" "$dir/"
  [ -f "$root/remappings.txt" ] && cp "$root/remappings.txt" "$dir/"
  ln -s "$root/lib" "$dir/lib"
  echo "mutating $c in $dir, log in $logs/$c.log"
  (cd "$dir" && slither-mutate src \
      --test-cmd "forge test --no-match-path 'test/fork/*' --fail-fast" \
      --contract-names "$c" --timeout 240 --compile-force-framework foundry \
      --output-dir mutation_campaign -v > "$logs/$c.log" 2>&1) &
done
wait
