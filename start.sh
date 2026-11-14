#!/usr/bin/env bash
# =============================================================================
# Launcher for the Ocean Enterprise stack (marketplace + OE Node + Elasticsearch).
#
#   1. loads .env (written by ./customize.sh)
#   2. decrypts secrets/node.keystore.json and exports PRIVATE_KEY for compose —
#      the key is never stored in clear text on disk
#   3. picks the indexer START_BLOCK: it asks which block to start indexing from
#      (default = current OP Sepolia head) whenever there is no indexer state yet,
#      then stores the answer in .env so later launches resume from it
#   4. docker compose up -d
#
# Password sources, in order: $OE_KEYSTORE_PASSWORD, $OE_KEYSTORE_PASSWORD_FILE,
# interactive prompt.
#
# Usage: ./start.sh [options]
#   (no option)          ask for the start block on a first launch, then compose up
#   --start-block N      index from block N (no question)
#   --week               index from head − 302,400 blocks (~1 week, ~2 h of work)
#   --head               index from the current head (same as the default answer)
#   --dry-run, -n        validate config and print `docker compose config`
#                        (secrets masked); never prompts, never starts anything
#   -h, --help           this help
#
# Once the node has indexer state (./oe-node-databases), the choice no longer
# applies — the node resumes from its own index. To start over:
#   docker compose down -v && rm -rf oe-node-databases
# =============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

DRY_RUN=0
START_BLOCK_ARG=''
FORCE_WEEK=0
FORCE_HEAD=0
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run|-n) DRY_RUN=1 ;;
    --start-block) START_BLOCK_ARG=${2-}; shift ;;
    --start-block=*) START_BLOCK_ARG=${1#*=} ;;
    --week|-w) FORCE_WEEK=1 ;;
    --head) FORCE_HEAD=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) oe_die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

WEEK_IN_BLOCKS=$((604800 / 2))   # 604800 s / 2 s per block
EXPECTED_RATE=45                 # blocks/s observed on a free OP Sepolia RPC

# ------------------------------------------------------------------- config ---
[ -f "$ROOT/.env" ] || oe_die "no .env found — run ./customize.sh first to generate the configuration"

RPC_URL=$(oe_env_get RPC_URL)
CHAIN_ID=$(oe_env_get CHAIN_ID 11155420)
CHAIN_NAME=$(oe_env_get CHAIN_NAME optimism_sepolia)
START_BLOCK=$(oe_env_get START_BLOCK 0)
MARKET_HTTP_PORT=$(oe_env_get MARKET_HTTP_PORT 8080)
NODE_HTTP_PORT=$(oe_env_get NODE_HTTP_PORT 8000)
OE_NODE_URL=$(oe_env_get OE_NODE_URL "http://localhost:${NODE_HTTP_PORT}")
NODE_KEYSTORE=$(oe_env_get NODE_KEYSTORE '')
IPFS_JWT=$(oe_env_get IPFS_JWT '')

[ -n "$RPC_URL" ] || oe_die "RPC_URL is empty in .env"
[[ $START_BLOCK =~ ^[0-9]+$ ]] || START_BLOCK=0

oe_have docker || oe_die "docker is required"
docker compose version >/dev/null 2>&1 || oe_die "docker compose v2 is required"

if [ -z "$IPFS_JWT" ]; then
  oe_warn "IPFS_JWT is empty in .env — publishing assets from the marketplace will fail"
elif ! oe_is_pinata_jwt "$IPFS_JWT"; then
  oe_warn "IPFS_JWT is not a Pinata JWT (${#IPFS_JWT} chars, no 'eyJ…' segments) — uploads fail with [uploadToIPFS]"
  oe_warn "Get one: https://app.pinata.cloud -> API Keys -> New Key -> Create Key, copy the JWT field"
elif [ "$(oe_pinata_auth_status "$IPFS_JWT")" = invalid ]; then
  oe_warn "Pinata rejected IPFS_JWT (revoked, expired or out of uses) — publishing will fail"
fi

# ------------------------------------------------------------- node key -------
NODE_KEY=''
if [ -n "$NODE_KEYSTORE" ] && [ -f "$(oe_abspath "$NODE_KEYSTORE")" ]; then
  KEYSTORE_FILE=$(oe_abspath "$NODE_KEYSTORE")
  KEYSTORE_PASSWORD=${OE_KEYSTORE_PASSWORD:-}
  KEY_IS_DUMMY=0
  if [ -z "$KEYSTORE_PASSWORD" ] && [ -n "${OE_KEYSTORE_PASSWORD_FILE:-}" ]; then
    [ -r "$OE_KEYSTORE_PASSWORD_FILE" ] || oe_die "OE_KEYSTORE_PASSWORD_FILE is not readable"
    KEYSTORE_PASSWORD=$(cat "$OE_KEYSTORE_PASSWORD_FILE")
  fi
  if [ -z "$KEYSTORE_PASSWORD" ]; then
    if [ -t 0 ]; then
      printf 'Keystore password (%s): ' "$(basename "$KEYSTORE_FILE")"
      IFS= read -rs KEYSTORE_PASSWORD || true
      printf '\n'
    elif [ "$DRY_RUN" -eq 1 ]; then
      # dry-run only prints the resolved compose file, so a placeholder is enough
      oe_warn "no keystore password (dry-run): using a placeholder key"
      KEY_IS_DUMMY=1
    else
      oe_die "no keystore password: set OE_KEYSTORE_PASSWORD or OE_KEYSTORE_PASSWORD_FILE (stdin is not a terminal)"
    fi
  fi
  if [ "$KEY_IS_DUMMY" -eq 1 ]; then
    NODE_KEY="0x$(printf '11%.0s' $(seq 32))"
  else
    if ! KEY_JSON=$(printf '%s' "$KEYSTORE_PASSWORD" | oe_keys decrypt --keystore "$KEYSTORE_FILE" --password-stdin 2>/dev/null); then
      oe_die "cannot decrypt $NODE_KEYSTORE — wrong password?"
    fi
    NODE_KEY=$(printf '%s' "$KEY_JSON" | jq -r '.privateKey // empty')
    oe_valid_hexkey "$NODE_KEY" || oe_die "keystore did not yield a valid private key"
    oe_ok "node key unlocked ($(printf '%s' "$KEY_JSON" | jq -r '.address'))"
  fi
  unset KEYSTORE_PASSWORD
else
  # Legacy fallback: a plaintext key in .env (pre-keystore configurations).
  NODE_KEY=$(oe_env_get NODE_PRIVATE_KEY '')
  if [ -n "$NODE_KEY" ]; then
    oe_warn "using the plaintext NODE_PRIVATE_KEY from .env — run ./customize.sh to move it into ./secrets/"
  else
    oe_die "no keystore ($NODE_KEYSTORE) and no NODE_PRIVATE_KEY in .env — run ./customize.sh"
  fi
fi
export NODE_PRIVATE_KEY="$NODE_KEY"

# ------------------------------------------------------------ start block ----
# Ask which block to index from. "head" means: only events that happen from now
# on (instant, no backfill); "week" replays the last ~7 days (~2 h at ~45 blk/s).
choose_start_block() { # choose_start_block <head> -> prints the chosen block
  local head=$1 answer='' n='' max_week=$WEEK_IN_BLOCKS
  if [ -n "$START_BLOCK_ARG" ]; then
    answer=$START_BLOCK_ARG
    if [[ $answer =~ ^[0-9]+$ ]] && [ "$answer" -ge 0 ] && [ "$answer" -le "$head" ]; then
      printf '%s' "$answer"; return 0
    fi
    oe_die "--start-block '$START_BLOCK_ARG' is not a block number between 0 and the current head $head"
  fi
  if [ "$FORCE_WEEK" -eq 1 ]; then
    n=$((head - max_week)); [ "$n" -lt 0 ] && n=0
    printf '%s' "$n"; return 0
  fi
  if [ "$FORCE_HEAD" -eq 1 ] || [ ! -t 0 ]; then
    printf '%s' "$head"; return 0
  fi
  while :; do
    # The prompt goes to stderr: this function's stdout is captured by the
    # caller (CHOSEN=$(choose_start_block ...)), so anything printed to stdout
    # would end up inside the chosen value.
    printf 'Start indexing from block [%s]  (Enter = current head, "week" = head-%s = %s, or a block number): ' \
      "$head" "$max_week" "$((head - max_week))" >&2
    IFS= read -r answer || answer=''
    case $answer in
      ''|head|HEAD|now) printf '%s' "$head"; return 0 ;;
      week|WEEK|w)      n=$((head - max_week)); [ "$n" -lt 0 ] && n=0; printf '%s' "$n"; return 0 ;;
      *[!0-9]*)         oe_warn "'$answer' is not a block number (or 'week')" ;;
      *)
        if [ "$answer" -le "$head" ]; then printf '%s' "$answer"; return 0; fi
        oe_warn "$answer is above the current head ($head)"
        ;;
    esac
  done
}

HAS_STATE=0
if [ -d ./oe-node-databases ] && [ -n "$(ls -A ./oe-node-databases 2>/dev/null || true)" ]; then
  HAS_STATE=1
fi

if [ "$HAS_STATE" -eq 1 ] && [ -z "$START_BLOCK_ARG" ] && [ "$FORCE_WEEK" -eq 0 ] && [ "$FORCE_HEAD" -eq 0 ]; then
  oe_info "oe-node-databases/ already holds indexer state — the node resumes from its own index."
  oe_info "The start-block question only applies to a fresh index; to start over:"
  oe_info "  docker compose down -v && rm -rf oe-node-databases && ./start.sh"
else
  oe_info "Reading head block from ${RPC_URL} ..."
  NETINFO=$(oe_keys netinfo --rpc "$RPC_URL" 2>/dev/null) \
    || oe_die "could not read the head block from $RPC_URL — pass --start-block N to skip the check"
  HEAD=$(printf '%s' "$NETINFO" | jq -r '.head')
  LIVE_CHAIN=$(printf '%s' "$NETINFO" | jq -r '.chainId')
  [ "$LIVE_CHAIN" = "$CHAIN_ID" ] || oe_die "RPC chainId $LIVE_CHAIN does not match CHAIN_ID $CHAIN_ID in .env"

  if [ "$DRY_RUN" -eq 1 ] && [ -z "$START_BLOCK_ARG" ] && [ "$FORCE_WEEK" -eq 0 ] && [ "$FORCE_HEAD" -eq 0 ] \
     && [ "$START_BLOCK" -gt 0 ]; then
    oe_info "dry-run: keeping START_BLOCK=${START_BLOCK} from .env (head is ${HEAD})"
  else
    oe_info "Current ${CHAIN_NAME} head: ${HEAD}"
    CHOSEN=$(choose_start_block "$HEAD")
    START_BLOCK=$CHOSEN
    if [ "$DRY_RUN" -eq 1 ]; then
      oe_info "dry-run: would store START_BLOCK=${START_BLOCK} in .env (not written)"
    else
      oe_env_set .env START_BLOCK "$START_BLOCK"
      oe_ok "START_BLOCK=${START_BLOCK} stored in .env"
    fi
  fi

  BEHIND=$((HEAD - START_BLOCK))
  [ "$BEHIND" -lt 0 ] && BEHIND=0
  if [ "$BEHIND" -eq 0 ]; then
    oe_info "Nothing to backfill: the node indexes events from now on."
  else
    oe_info "${BEHIND} blocks to backfill (~$((BEHIND / EXPECTED_RATE / 60)) min at ~${EXPECTED_RATE} blk/s)"
  fi
fi

# ---------------------------------------------------------------- compose ----
# Guarantee compose sees the chosen value even when .env was not rewritten
# (dry-run) or already carried another one.
export START_BLOCK

if [ "$DRY_RUN" -eq 1 ]; then
  oe_step "docker compose config (secrets masked)"
  ELASTIC_PW_VALUE=$(oe_env_get ELASTIC_PASSWORD '')
  MASK_ARGS=(-e "s/${NODE_KEY}/<NODE_PRIVATE_KEY>/g")
  if [ -n "$ELASTIC_PW_VALUE" ]; then
    MASK_ARGS+=(-e "s/${ELASTIC_PW_VALUE}/<ELASTIC_PASSWORD>/g")
  fi
  if [ -n "$IPFS_JWT" ]; then
    MASK_ARGS+=(-e "s/${IPFS_JWT}/<IPFS_JWT>/g")
  fi
  docker compose config | sed "${MASK_ARGS[@]}"
  exit 0
fi

oe_step "Starting the stack"
docker compose up -d

cat <<EOF

Stack is starting.
  watch:        docker compose logs -f oe-node
                docker compose logs -f ocean-market
  marketplace:  http://localhost:${MARKET_HTTP_PORT}
  node API:     http://localhost:${NODE_HTTP_PORT}
  node (public): ${OE_NODE_URL}
  indexing from block: ${START_BLOCK}

The marketplace wallet needs OP Sepolia ETH (gas) and devEURAU tokens on
chain ${CHAIN_ID} to publish or consume assets.
EOF
