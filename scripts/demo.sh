#!/usr/bin/env bash
# Start a throwaway anvil, deploy the EntryPoint, factory, a test token and an AgentWallet with a
# session key, then run the agent script against it.
set -euo pipefail

cd "$(dirname "$0")/.."
PORT="${PORT:-8545}"
export RPC_URL="http://127.0.0.1:${PORT}"

anvil --silent --port "$PORT" &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break
  sleep 0.1
done

# Full build first: the script deploys the EntryPoint from its artifact in out/.
forge build
forge script script/DeployLocal.s.sol --rpc-url "$RPC_URL" --broadcast

if [ ! -d agent/node_modules ]; then
  npm --prefix agent ci --silent
fi
node agent/demo.ts
