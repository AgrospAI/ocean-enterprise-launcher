#!/usr/bin/env bash
# =============================================================================
# First-launch helper for the Ocean Enterprise stack.
#
# Computes the OE Node indexer START_BLOCK = (current OP Sepolia head block
# minus ~1 week) and injects it into .env, then starts the stack.
# OP Sepolia produces ~1 block every 2s → 1 week ≈ 302,400 blocks.
#
# On subsequent launches the START_BLOCK stored in .env is kept (the node
# remembers where it left off in its Elasticsearch volume).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

RPC_URL=$(grep -E '^RPC_URL=' .env | cut -d= -f2-)
CHAIN_ID=$(grep -E '^CHAIN_ID=' .env | cut -d= -f2-)
WEEK_IN_BLOCKS=$((604800 / 2))   # 604800 s / 2 s per block

# Only recompute on a fresh launch (no indexer state yet)
if [ -d ./oe-node-databases ] && [ "$(ls -A ./oe-node-databases 2>/dev/null)" ]; then
  echo "oe-node-databases/ already holds indexer state — keeping existing START_BLOCK."
else
  echo "Fetching head block from ${RPC_URL} ..."
  HEX=$(curl -sf --max-time 20 -X POST "$RPC_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')
  if [ -z "${HEX:-}" ]; then
    echo "ERROR: could not read head block from $RPC_URL." >&2
    echo "Set START_BLOCK manually in .env (head block minus ${WEEK_IN_BLOCKS}) and re-run." >&2
    exit 1
  fi
  HEAD=$((HEX))
  START_BLOCK=$((HEAD - WEEK_IN_BLOCKS))
  echo "Head block: ${HEAD}  ->  START_BLOCK: ${START_BLOCK} (~1 week earlier)"
  # Write it into .env (chainId kept for reference)
  sed -i -E "s/^START_BLOCK=.*/START_BLOCK=${START_BLOCK}/" .env
fi

echo "Starting Ocean Enterprise stack (market :8008, node :8000) ..."
docker compose up -d

echo
echo "Stack is starting. Watch with:"
echo "  docker compose logs -f oe-node"
echo "  docker compose logs -f ocean-market"
echo
echo "Marketplace:  http://localhost:${MARKET_HTTP_PORT:-8008}"
echo "OE Node API:  http://localhost:${NODE_HTTP_PORT:-8000}"
echo "Remember: the marketplace wallet needs OP Sepolia ETH (gas) and devEURAU"
echo "tokens on chain ${CHAIN_ID} to publish/consume assets."
