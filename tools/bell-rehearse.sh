#!/usr/bin/env bash
# Rehearses the real-bell job (src/bell.ts) on local forks of the three networks, with no wallet:
# a made-up session posts an opening bell, a second run finds nothing to do, then the closing bell.
#
# Needs: foundry (forge, anvil), node 20+, and `npm install` in tools/.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/forks.sh

start_forks
deploy_all

cd tools
npx tsx src/relay.ts >"$LOGS/relay.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 120); do grep -q "node running" "$LOGS/relay.log" && break; sleep 0.5; done

export BELL_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY
export BELL_LOG=$LOGS/bells.json
now=$(date +%s)
session() { # start end
  echo "{\"start\":$1,\"end\":$2,\"open\":151.01,\"last\":149.30,\"lastTime\":$2,\"source\":\"rehearsal\"}"
}

echo "--- the opening bell"
BELL_SESSION=$(session $((now - 300)) $((now + 3600))) npx tsx src/bell.ts
echo "--- the same bell again: nothing to do"
BELL_SESSION=$(session $((now - 300)) $((now + 3600))) npx tsx src/bell.ts
echo "--- the closing bell"
BELL_SESSION=$(session $((now - 3600)) $((now - 120))) npx tsx src/bell.ts
echo "--- log"
node -e "const l=require(process.argv[1]); console.log(l.map(b=>b.bell+' \$'+b.price+' base '+b.switched.base?.seconds+' s, unichain '+b.switched.unichain?.seconds+' s, closed '+Boolean(b.closed)).join('\n'))" "$BELL_LOG"
