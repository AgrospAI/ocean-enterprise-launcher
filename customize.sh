#!/usr/bin/env bash
# =============================================================================
# customize.sh — interactive configurator for the Ocean Enterprise launcher.
#
# Prompts for everything the stack needs (ports, public node URL, RPC, IPFS,
# fees, owner info) and manages wallet keys:
#
#   * node key  — PRIVATE_KEY of the OE Node; its address is also used as the
#                 fee collector (MARKET_FEE_ADDRESS) and NODE_OWNER
#   * admin key — address goes into ALLOWED_ADMINS
#
# Keys are stored as Web3 Secret Storage V3 keystore JSON files in ./secrets/
# (mode 0600) encrypted with a password you provide. They are never written to
# .env: ./start.sh decrypts the node keystore at launch and exports
# PRIVATE_KEY for docker compose only for that run.
#
# Usage:
#   ./customize.sh                  # interactive (recommended)
#   ./customize.sh --non-interactive --password-file /path/pw [--yes] ...
#   ./customize.sh --help
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'error: this script needs bash — run ./customize.sh, or: bash customize.sh' >&2
  exit 1
fi
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

# ---------------------------------------------------------------- defaults ---
NONINTERACTIVE=0
RUN_START=1
FORCE_KEYS=0
PASSWORD_FILE=''
PRIVATE_KEY_IN=''
ADMIN_KEY_IN=''
IPFS_JWT_IN=''
RPC_URL_IN=''
NODE_URL_IN=''
MARKET_PORT_IN=''
NODE_PORT_IN=''
ES_PORT_IN=''
OWNER_NAME_IN=''
OWNER_EMAIL_IN=''
OWNER_URL_IN=''
OWNER_ADDR_IN=''
TERMS_URL_IN=''
PRIVACY_URL_IN=''
NODE_FEE_IN=''
NODE_FEE_UNIT_IN=''
MARKET_FEE_IN=''
MARKET_PERCENT_IN=''
DATASPACE_IN=''

usage() {
  cat <<'EOF'
Ocean Enterprise launcher — configuration helper

Usage: ./customize.sh [options]

Non-interactive / automation options:
  --non-interactive, --yes     never prompt; take defaults or the flags below
  --password-file FILE         read the keystore password from FILE (required
                               when non-interactive)
  --private-key 0x...          bring your own node/fee-collector key (BYOK);
                               otherwise one is generated
  --admin-key 0x...            bring your own admin key; otherwise generated
  --rpc-url URL                OP Sepolia RPC endpoint
  --node-url URL               URL of the node as seen from the browser
  --market-port N              host port for the marketplace UI   (default 8080)
  --node-port N                host port for the node HTTP API    (default 8000)
  --es-port N                  host port for Elasticsearch        (default 9200)
  --ipfs-jwt JWT               Pinata JWT (empty disables publishing)
  --owner-name STR             NODE_OWNER_INFO imprint.legalName
  --owner-email STR            NODE_OWNER_INFO imprint.email
  --owner-url URL              NODE_OWNER_INFO imprint.url
  --owner-address STR          NODE_OWNER_INFO imprint.address
  --terms-url URL              NODE_OWNER_INFO termsAndConditions.url
  --privacy-url URL            NODE_OWNER_INFO privacyPolicy.url
  --node-fee AMOUNT            NODE_FEE_AMOUNT.amount            (default 1)
  --node-fee-unit UNIT         NODE_FEE_AMOUNT.unit              (default MB)
  --market-fee AMOUNT          market fixed fee per order, in devEURAU
                               (default 0 = disabled)
  --market-percent FEE         market percentage fee, 0.1 = 10%    (default 0)
  --dataspace NAME             catalogue tag filter (default: empty = off)
  --force-keys                 overwrite existing keystores with new keys
  --no-start                   configure only; do not launch the stack at the end
  -h, --help                   this help

The keystore password can also be supplied via $OE_KEYSTORE_PASSWORD.
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    --non-interactive|--yes|-y) NONINTERACTIVE=1 ;;
    --password-file) PASSWORD_FILE=${2-}; shift ;;
    --password-file=*) PASSWORD_FILE=${1#*=} ;;
    --private-key) PRIVATE_KEY_IN=${2-}; shift ;;
    --private-key=*) PRIVATE_KEY_IN=${1#*=} ;;
    --admin-key) ADMIN_KEY_IN=${2-}; shift ;;
    --admin-key=*) ADMIN_KEY_IN=${1#*=} ;;
    --rpc-url) RPC_URL_IN=${2-}; shift ;;
    --rpc-url=*) RPC_URL_IN=${1#*=} ;;
    --node-url) NODE_URL_IN=${2-}; shift ;;
    --node-url=*) NODE_URL_IN=${1#*=} ;;
    --market-port) MARKET_PORT_IN=${2-}; shift ;;
    --market-port=*) MARKET_PORT_IN=${1#*=} ;;
    --node-port) NODE_PORT_IN=${2-}; shift ;;
    --node-port=*) NODE_PORT_IN=${1#*=} ;;
    --es-port) ES_PORT_IN=${2-}; shift ;;
    --es-port=*) ES_PORT_IN=${1#*=} ;;
    --ipfs-jwt) IPFS_JWT_IN=${2-}; shift ;;
    --ipfs-jwt=*) IPFS_JWT_IN=${1#*=} ;;
    --owner-name) OWNER_NAME_IN=${2-}; shift ;;
    --owner-name=*) OWNER_NAME_IN=${1#*=} ;;
    --owner-email) OWNER_EMAIL_IN=${2-}; shift ;;
    --owner-email=*) OWNER_EMAIL_IN=${1#*=} ;;
    --owner-url) OWNER_URL_IN=${2-}; shift ;;
    --owner-url=*) OWNER_URL_IN=${1#*=} ;;
    --owner-address) OWNER_ADDR_IN=${2-}; shift ;;
    --owner-address=*) OWNER_ADDR_IN=${1#*=} ;;
    --terms-url) TERMS_URL_IN=${2-}; shift ;;
    --terms-url=*) TERMS_URL_IN=${1#*=} ;;
    --privacy-url) PRIVACY_URL_IN=${2-}; shift ;;
    --privacy-url=*) PRIVACY_URL_IN=${1#*=} ;;
    --node-fee) NODE_FEE_IN=${2-}; shift ;;
    --node-fee=*) NODE_FEE_IN=${1#*=} ;;
    --node-fee-unit) NODE_FEE_UNIT_IN=${2-}; shift ;;
    --node-fee-unit=*) NODE_FEE_UNIT_IN=${1#*=} ;;
    --market-fee) MARKET_FEE_IN=${2-}; shift ;;
    --market-fee=*) MARKET_FEE_IN=${1#*=} ;;
    --market-percent) MARKET_PERCENT_IN=${2-}; shift ;;
    --market-percent=*) MARKET_PERCENT_IN=${1#*=} ;;
    --dataspace) DATASPACE_IN=${2-}; shift ;;
    --dataspace=*) DATASPACE_IN=${1#*=} ;;
    --force-keys) FORCE_KEYS=1 ;;
    --no-start) RUN_START=0 ;;
    -h|--help) usage; exit 0 ;;
    *) oe_die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------- prompts ----
ask() { # ask VAR "prompt" [default]
  local __var=$1 __prompt=$2 __def=${3-} __ans=''
  if [ "$NONINTERACTIVE" -eq 1 ]; then printf -v "$__var" '%s' "$__def"; return 0; fi
  if [ -n "$__def" ]; then printf '%s [%s]: ' "$__prompt" "$__def"; else printf '%s: ' "$__prompt"; fi
  IFS= read -r __ans || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

ask_hidden() { # ask_hidden VAR "prompt"
  local __var=$1 __prompt=$2 __ans=''
  printf '%s' "$__prompt"
  IFS= read -rs __ans || true
  printf '\n'
  printf -v "$__var" '%s' "$__ans"
}

ask_yn() { # ask_yn VAR "prompt" [Y|N] -> returns 0 for yes, 1 for no
  local __var=$1 __prompt=$2 __def=${3:-N} __ans='' __hint
  if [ "$NONINTERACTIVE" -eq 1 ]; then
    case $__def in y|Y|yes|YES|1) printf -v "$__var" 1; return 0 ;; *) printf -v "$__var" 0; return 1 ;; esac
  fi
  case $__def in y|Y|yes|YES|1) __hint='Y/n' ;; *) __hint='y/N' ;; esac
  printf '%s [%s]: ' "$__prompt" "$__hint"
  IFS= read -r __ans || true
  case "${__ans:-$__def}" in
    y|Y|yes|YES) printf -v "$__var" 1; return 0 ;;
    *) printf -v "$__var" 0; return 1 ;;
  esac
}

ask_port() { # ask_port VAR "prompt" "default" -> validated 1024..65535
  local __var=$1 __prompt=$2 __def=$3 __val='' __tries=0
  while :; do
    ask __val "$__prompt" "$__def"
    if oe_valid_port "$__val"; then printf -v "$__var" '%s' "$__val"; return 0; fi
    oe_warn "invalid port '$__val' (must be 1024..65535)"
    [ "$NONINTERACTIVE" -eq 1 ] && oe_die "invalid value for $__var"
    __tries=$((__tries + 1)); [ "$__tries" -ge 3 ] && oe_die "giving up on $__var"
  done
}

ask_hexkey() { # ask_hexkey VAR "prompt"
  local __var=$1 __prompt=$2 __val='' __tries=0
  while :; do
    ask_hidden __val "$__prompt"
    if oe_valid_hexkey "$__val"; then printf -v "$__var" '%s' "$__val"; return 0; fi
    oe_warn "that is not a private key (expected 0x followed by 64 hex characters)"
    __tries=$((__tries + 1)); [ "$__tries" -ge 3 ] && oe_die "giving up on $__var"
  done
}

# --------------------------------------------------------------- preflight ---
printf '%s\n' "${C_BOLD}Ocean Enterprise launcher — configuration${C_OFF}"
printf '%s\n' "${C_DIM}marketplace + OE Node (no SSI) on OP Sepolia${C_OFF}"

oe_step "Checking prerequisites"
oe_preflight core
oe_ensure_ethers
oe_ok "keystore tooling ready (.tools/node_modules/ethers)"

# ------------------------------------------------------- existing settings ---
ENV_FILE="$ROOT/.env"
HAVE_ENV=0
[ -f "$ENV_FILE" ] && HAVE_ENV=1

# Defaults come from a previous run (.env) or, on a fresh clone, from the
# documented template (.env.example). Secrets are only ever taken from a real
# .env — never from the example.
if [ "$HAVE_ENV" -eq 1 ]; then DEF_SOURCE=$ENV_FILE; else DEF_SOURCE="$ROOT/.env.example"; fi
DEF_X() { oe_env_get_file "$DEF_SOURCE" "$1" "${2-}"; }

DEF_OE_NODE_URL=$(DEF_X OE_NODE_URL '')
DEF_MARKET_PORT=$(DEF_X MARKET_HTTP_PORT 8080)
DEF_NODE_PORT=$(DEF_X NODE_HTTP_PORT 8000)
DEF_ES_PORT=$(DEF_X ES_HTTP_PORT 9200)
DEF_RPC_URL=$(DEF_X RPC_URL 'https://sepolia.optimism.io')
DEF_CHAIN_ID=$(DEF_X CHAIN_ID 11155420)
DEF_CHAIN_NAME=$(DEF_X CHAIN_NAME optimism_sepolia)
DEF_DEVEURAU=$(DEF_X DEVEURAU_ADDRESS 0xD35141583f374d401fee1BFdDc35910E1D33a588)
DEF_START_BLOCK=$(DEF_X START_BLOCK 0)
DEF_IPFS_GATEWAY=$(DEF_X IPFS_GATEWAY 'https://gateway.pinata.cloud/')
DEF_IPFS_UPLOAD=$(DEF_X IPFS_UPLOAD_URL 'https://api.pinata.cloud/pinning/pinJSONToIPFS')
DEF_IPFS_DELETE=$(DEF_X IPFS_DELETE_URL 'https://api.pinata.cloud/pinning/unpin')
DEF_NODE_FEE=$(DEF_X NODE_FEE_AMOUNT '')
DEF_MARKET_FEE_MAP=$(DEF_X MARKET_ORDER_FEE_MAP '')
DEF_MARKET_PERCENT=$(DEF_X MARKET_PERCENT_FEE 0)
DEF_DATASPACE=$(DEF_X DATASPACE '')
DEF_OWNER_INFO=$(DEF_X NODE_OWNER_INFO '')
DEF_ELASTIC_PW=$(oe_env_get ELASTIC_PASSWORD '')
DEF_IPFS_JWT=$(oe_env_get IPFS_JWT '')

def_owner() { # def_owner <jq-path> <default>
  local out=''
  if [ -n "$DEF_OWNER_INFO" ]; then
    out=$(printf '%s' "$DEF_OWNER_INFO" | jq -r "$1 // empty" 2>/dev/null || true)
  fi
  printf '%s' "${out:-$2}"
}

DEF_OWNER_NAME=$(def_owner '.imprint.legalName' '')
DEF_OWNER_EMAIL=$(def_owner '.imprint.email' '')
DEF_OWNER_URL=$(def_owner '.imprint.url' '')
DEF_OWNER_ADDR=$(def_owner '.imprint.address' '')
DEF_TERMS=$(def_owner '.termsAndConditions.url' '')
DEF_PRIVACY=$(def_owner '.privacyPolicy.url' '')
DEF_NODE_FEE_AMOUNT=$(printf '%s' "$DEF_NODE_FEE" | jq -r '.amount // empty' 2>/dev/null || true)
DEF_NODE_FEE_UNIT=$(printf '%s' "$DEF_NODE_FEE" | jq -r '.unit // empty' 2>/dev/null || true)

if [ "$HAVE_ENV" -eq 1 ]; then
  oe_info
  oe_info "Existing .env found — its values are used as defaults (press Enter to keep)."
else
  oe_info
  oe_info "${C_DIM}No .env yet: defaults come from .env.example and from the generated secrets.${C_OFF}"
fi

# ------------------------------------------------------------------- ports ---
oe_step "Ports and public URL"
MARKET_HTTP_PORT=${MARKET_PORT_IN:-}
[ -n "$MARKET_HTTP_PORT" ] || ask_port MARKET_HTTP_PORT "Marketplace UI host port" "$DEF_MARKET_PORT"
NODE_HTTP_PORT=${NODE_PORT_IN:-}
[ -n "$NODE_HTTP_PORT" ] || ask_port NODE_HTTP_PORT "OE Node HTTP API host port" "$DEF_NODE_PORT"
ES_HTTP_PORT=${ES_PORT_IN:-}
[ -n "$ES_HTTP_PORT" ] || ask_port ES_HTTP_PORT "Elasticsearch host port (diagnostics; drop in production)" "$DEF_ES_PORT"
for p in "$MARKET_HTTP_PORT" "$NODE_HTTP_PORT" "$ES_HTTP_PORT"; do
  oe_valid_port "$p" || oe_die "invalid port: $p"
done
if [ "$MARKET_HTTP_PORT" = "$NODE_HTTP_PORT" ] || [ "$MARKET_HTTP_PORT" = "$ES_HTTP_PORT" ] || [ "$NODE_HTTP_PORT" = "$ES_HTTP_PORT" ]; then
  oe_die "the three host ports must differ"
fi
for p in "$MARKET_HTTP_PORT" "$NODE_HTTP_PORT" "$ES_HTTP_PORT"; do
  if oe_have lsof && lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    oe_warn "port $p is already in use on this host (an existing stack?)"
  fi
done

# The browser calls the node directly, so this must be reachable from the user's
# machine, not just from the containers.
DEFAULT_NODE_URL=${DEF_OE_NODE_URL:-}
if [ -z "${NODE_URL_IN}" ] && [ -z "$DEFAULT_NODE_URL" ]; then
  DEFAULT_NODE_URL="http://localhost:${NODE_HTTP_PORT}"
fi
OE_NODE_URL=${NODE_URL_IN:-$DEFAULT_NODE_URL}
[ -n "${NODE_URL_IN}" ] || ask OE_NODE_URL "URL of the OE Node as seen from the browser" "$DEFAULT_NODE_URL"
OE_NODE_URL=${OE_NODE_URL%/}
[[ $OE_NODE_URL =~ ^https?:// ]] || oe_die "OE_NODE_URL must start with http:// or https://"
oe_ok "node URL: $OE_NODE_URL"

# --------------------------------------------------------------- RPC / net ---
oe_step "Blockchain (OP Sepolia)"
RPC_URL=${RPC_URL_IN:-}
[ -n "$RPC_URL" ] || ask RPC_URL "RPC endpoint" "$DEF_RPC_URL"
[[ $RPC_URL =~ ^https?:// ]] || oe_die "RPC_URL must start with http:// or https://"

CHAIN_ID=$DEF_CHAIN_ID
CHAIN_NAME=$DEF_CHAIN_NAME
DEVEURAU_ADDRESS=$DEF_DEVEURAU
oe_info "chainId $CHAIN_ID ($CHAIN_NAME), payment token devEURAU $DEVEURAU_ADDRESS"

NETINFO=''
if NETINFO_RAW=$(oe_keys netinfo --rpc "$RPC_URL" 2>/dev/null); then
  NETINFO=$NETINFO_RAW
  LIVE_CHAIN=$(printf '%s' "$NETINFO" | jq -r '.chainId')
  if [ "$LIVE_CHAIN" != "$CHAIN_ID" ]; then
    oe_die "the RPC reports chainId $LIVE_CHAIN but this stack is configured for $CHAIN_ID"
  fi
  oe_ok "RPC reachable, head block $(printf '%s' "$NETINFO" | jq -r '.head')"
else
  oe_warn "could not reach $RPC_URL — continuing, but the stack will not index until the RPC works"
fi

# ------------------------------------------------------------------- keys ---
oe_step "Wallet keys"
oe_info "Two keys are managed here:"
oe_info "  1. ${C_BOLD}node key${C_OFF}   signs/decrypts on the OE Node; its address collects node fees"
oe_info "  2. ${C_BOLD}admin key${C_OFF}  allowed to administer the node (ALLOWED_ADMINS)"
oe_info "${C_DIM}Keystores live in ./secrets/ (mode 0600). Bring your own key or let this script"
oe_info "generate one; either way it is stored only as a password-protected keystore.${C_OFF}"

SECRETS_DIR="$ROOT/secrets"
KEYSTORE_NODE="$SECRETS_DIR/node.keystore.json"
KEYSTORE_ADMIN="$SECRETS_DIR/admin.keystore.json"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR" 2>/dev/null || true

if [ -n "$PASSWORD_FILE" ]; then
  [ -r "$PASSWORD_FILE" ] || oe_die "--password-file is not readable: $PASSWORD_FILE"
  KEYSTORE_PASSWORD=$(cat "$PASSWORD_FILE")
elif [ -n "${OE_KEYSTORE_PASSWORD:-}" ]; then
  KEYSTORE_PASSWORD=$OE_KEYSTORE_PASSWORD
elif [ "$NONINTERACTIVE" -eq 1 ]; then
  oe_die "non-interactive mode needs --password-file FILE (or OE_KEYSTORE_PASSWORD)"
else
  while :; do
    ask_hidden KEYSTORE_PASSWORD "Keystore password: "
    [ ${#KEYSTORE_PASSWORD} -ge 8 ] || { oe_warn "use at least 8 characters"; continue; }
    ask_hidden PW_CONFIRM "Repeat password: "
    [ "$KEYSTORE_PASSWORD" = "$PW_CONFIRM" ] || { oe_warn "passwords do not match"; continue; }
    break
  done
  unset PW_CONFIRM
fi
[ -n "$KEYSTORE_PASSWORD" ] || oe_die "refusing to use an empty keystore password"

keystore_address() { # keystore_address <file> <password> -> address or rc=1
  local addr=''
  addr=$(printf '%s' "$2" | oe_keys address --keystore "$1" --password-stdin 2>/dev/null | jq -r '.address // empty' || true)
  [ -n "$addr" ] || return 1
  printf '%s' "$addr"
}

# --- node key
NODE_ADDRESS=''
NODE_KEY=''

write_node_keystore() { # $1 = private key, or empty to generate a random one
  local out=''
  if [ -n "${1:-}" ]; then
    out=$(printf '%s' "$KEYSTORE_PASSWORD" | oe_keys encrypt --key "$1" --out "$KEYSTORE_NODE" --password-stdin) || return 1
  else
    out=$(printf '%s' "$KEYSTORE_PASSWORD" | oe_keys encrypt --random --out "$KEYSTORE_NODE" --password-stdin) || return 1
  fi
  NODE_ADDRESS=$(printf '%s' "$out" | jq -r '.address // empty')
  [ -n "$NODE_ADDRESS" ]
}

if [ -n "$PRIVATE_KEY_IN" ]; then
  oe_valid_hexkey "$PRIVATE_KEY_IN" || oe_die "--private-key must be 0x followed by 64 hex characters"
  write_node_keystore "$PRIVATE_KEY_IN" || oe_die "could not write $KEYSTORE_NODE"
  oe_ok "node key imported -> $NODE_ADDRESS (keystore: secrets/node.keystore.json)"
elif [ "$FORCE_KEYS" -eq 0 ] && [ -f "$KEYSTORE_NODE" ]; then
  NODE_ADDRESS=$(keystore_address "$KEYSTORE_NODE" "$KEYSTORE_PASSWORD") \
    || oe_die "cannot unlock secrets/node.keystore.json with that password — use the original password, or --force-keys to replace the key"
  oe_ok "reusing existing node keystore -> $NODE_ADDRESS"
elif [ "$NONINTERACTIVE" -eq 0 ] \
     && ask_yn BYOK_NODE "Do you have your own private key for the node/fee-collector wallet?" N; then
  ask_hexkey NODE_KEY "Node private key (hidden): "
  write_node_keystore "$NODE_KEY" || oe_die "could not write $KEYSTORE_NODE"
  oe_ok "node key imported -> $NODE_ADDRESS (keystore: secrets/node.keystore.json)"
  unset NODE_KEY
else
  oe_info "Generating node private key ..."
  write_node_keystore "" || oe_die "could not write $KEYSTORE_NODE"
  oe_ok "node key generated -> $NODE_ADDRESS (keystore: secrets/node.keystore.json)"
fi
oe_valid_address "$NODE_ADDRESS" || oe_die "failed to determine the node address"

# --- admin key
ADMIN_PASSWORD=$KEYSTORE_PASSWORD
ADMIN_ADDRESS=''
ADMIN_KEY=''

write_admin_keystore() { # $1 = private key, or empty to generate a random one
  local out=''
  if [ -n "${1:-}" ]; then
    out=$(printf '%s' "$ADMIN_PASSWORD" | oe_keys encrypt --key "$1" --out "$KEYSTORE_ADMIN" --password-stdin) || return 1
  else
    out=$(printf '%s' "$ADMIN_PASSWORD" | oe_keys encrypt --random --out "$KEYSTORE_ADMIN" --password-stdin) || return 1
  fi
  ADMIN_ADDRESS=$(printf '%s' "$out" | jq -r '.address // empty')
  [ -n "$ADMIN_ADDRESS" ]
}

if [ -n "$ADMIN_KEY_IN" ]; then
  oe_valid_hexkey "$ADMIN_KEY_IN" || oe_die "--admin-key must be 0x followed by 64 hex characters"
  write_admin_keystore "$ADMIN_KEY_IN" || oe_die "could not write $KEYSTORE_ADMIN"
  oe_ok "admin key imported -> $ADMIN_ADDRESS (keystore: secrets/admin.keystore.json)"
elif [ "$FORCE_KEYS" -eq 0 ] && [ -f "$KEYSTORE_ADMIN" ]; then
  if ADMIN_ADDRESS=$(keystore_address "$KEYSTORE_ADMIN" "$ADMIN_PASSWORD"); then
    oe_ok "reusing existing admin keystore -> $ADMIN_ADDRESS"
  elif [ "$NONINTERACTIVE" -eq 0 ]; then
    while :; do
      ask_hidden ADMIN_PASSWORD "Password for the existing admin keystore: "
      if ADMIN_ADDRESS=$(keystore_address "$KEYSTORE_ADMIN" "$ADMIN_PASSWORD"); then break; fi
      oe_warn "wrong password, try again"
    done
    oe_ok "reusing existing admin keystore -> $ADMIN_ADDRESS"
  else
    oe_die "cannot unlock secrets/admin.keystore.json with the given password — pass its password or use --force-keys"
  fi
else
  # A brand-new admin key: it may have its own password.
  if [ "$NONINTERACTIVE" -eq 0 ] && [ -z "$PASSWORD_FILE" ] && [ -z "${OE_KEYSTORE_PASSWORD:-}" ]; then
    if ! ask_yn SAME_ADMIN_PW "Use the same password for the admin keystore?" Y; then
      while :; do
        ask_hidden ADMIN_PASSWORD "Admin keystore password: "
        [ ${#ADMIN_PASSWORD} -ge 8 ] || { oe_warn "use at least 8 characters"; continue; }
        ask_hidden PW_CONFIRM "Repeat password: "
        [ "$ADMIN_PASSWORD" = "$PW_CONFIRM" ] || { oe_warn "passwords do not match"; continue; }
        break
      done
      unset PW_CONFIRM
    fi
  fi
  if [ "$NONINTERACTIVE" -eq 0 ] \
     && ask_yn BYOK_ADMIN "Do you have your own private key for the admin wallet?" N; then
    ask_hexkey ADMIN_KEY "Admin private key (hidden): "
    write_admin_keystore "$ADMIN_KEY" || oe_die "could not write $KEYSTORE_ADMIN"
    oe_ok "admin key imported -> $ADMIN_ADDRESS (keystore: secrets/admin.keystore.json)"
    unset ADMIN_KEY
  else
    oe_info "Generating admin private key ..."
    write_admin_keystore "" || oe_die "could not write $KEYSTORE_ADMIN"
    oe_ok "admin key generated -> $ADMIN_ADDRESS (keystore: secrets/admin.keystore.json)"
  fi
fi
oe_valid_address "$ADMIN_ADDRESS" || oe_die "failed to determine the admin address"

if [ "$ADMIN_ADDRESS" = "$NODE_ADDRESS" ]; then
  oe_warn "the admin and node addresses are identical (one key used for both)"
fi

if [ "$FORCE_KEYS" -eq 1 ] && [ -d "$ROOT/oe-node-databases" ] \
   && [ -n "$(ls -A "$ROOT/oe-node-databases" 2>/dev/null || true)" ]; then
  oe_warn "keys rotated while oe-node-databases/ holds indexer state — the node keeps its index, but the previous node wallet no longer controls it (docker compose down -v to re-index)"
fi

# The marketplace fee collector is the node wallet (see the request this stack
# was built for) — no extra key to manage.
MARKET_FEE_ADDRESS=$NODE_ADDRESS
oe_info "fee collector (MARKET_FEE_ADDRESS) = node wallet $MARKET_FEE_ADDRESS"

# ------------------------------------------------------------------- IPFS ---
oe_step "IPFS / Pinata"
IPFS_GATEWAY=$DEF_IPFS_GATEWAY
IPFS_UPLOAD_URL=$DEF_IPFS_UPLOAD
IPFS_DELETE_URL=$DEF_IPFS_DELETE
ask IPFS_GATEWAY "Public IPFS gateway" "$DEF_IPFS_GATEWAY"
ask IPFS_UPLOAD_URL "Pinata upload endpoint" "$DEF_IPFS_UPLOAD"
ask IPFS_DELETE_URL "Pinata unpin endpoint" "$DEF_IPFS_DELETE"

IPFS_JWT=${IPFS_JWT_IN:-}
if [ -z "$IPFS_JWT" ]; then
  IPFS_JWT=$DEF_IPFS_JWT
  if [ "$NONINTERACTIVE" -eq 0 ]; then
    oe_info "A Pinata JWT is required to publish assets (free: https://app.pinata.cloud -> API Keys -> JWT)."
    ask IPFS_JWT "Pinata JWT (input is visible; leave empty to skip)" "$DEF_IPFS_JWT"
  fi
fi
if [ -z "$IPFS_JWT" ]; then
  oe_warn "no IPFS_JWT set — consuming works, publishing assets from the marketplace will fail"
elif ! oe_is_pinata_jwt "$IPFS_JWT"; then
  oe_warn "IPFS_JWT is not a Pinata JWT: ${#IPFS_JWT} chars, no 'eyJ…' segments — publishing will fail"
  oe_info "        When you create a key Pinata shows pinata_api_key, pinata_api_secret_key AND JWT."
  oe_info "        Paste the JWT (or 'Copy All' and take the JWT), not the API key."
  oe_info "        https://app.pinata.cloud → API Keys → New Key → Create Key"
else
  oe_ok "Pinata JWT set (${#IPFS_JWT} chars)"
  case "$IPFS_UPLOAD_URL" in
    *pinata.cloud*)
      case "$(oe_pinata_auth_status "$IPFS_JWT")" in
        ok)    oe_ok "Pinata accepted the JWT" ;;
        invalid) oe_warn "Pinata rejected the JWT (revoked/expired/limited) — publishing will fail" ;;
        *)     oe_info "could not reach api.pinata.cloud to verify the JWT (offline?)" ;;
      esac
      ;;
  esac
fi

# ------------------------------------------------------------ fees / owner ---
oe_step "Fees, dataspace and owner info"
NODE_FEE_AMOUNT_VAL=${NODE_FEE_IN:-${DEF_NODE_FEE_AMOUNT:-0}}
NODE_FEE_UNIT_VAL=${NODE_FEE_UNIT_IN:-${DEF_NODE_FEE_UNIT:-MB}}
[ -n "$NODE_FEE_IN" ] || ask NODE_FEE_AMOUNT_VAL "Node fee amount per purchase" "$NODE_FEE_AMOUNT_VAL"
[ -n "$NODE_FEE_UNIT_IN" ] || ask NODE_FEE_UNIT_VAL "Node fee unit (e.g. MB, or 'unit')" "$NODE_FEE_UNIT_VAL"
NODE_FEE_AMOUNT=$(jq -nc --argjson a "${NODE_FEE_AMOUNT_VAL:-0}" --arg u "$NODE_FEE_UNIT_VAL" '{amount:$a,unit:$u}') \
  || oe_die "node fee amount must be a number"

MARKET_FEE_HUMAN=${MARKET_FEE_IN:-}
if [ -z "$MARKET_FEE_HUMAN" ]; then
  DEF_MARKET_FEE_HUMAN='0'
  PREV_AMOUNT=$(printf '%s' "$DEF_MARKET_FEE_MAP" | jq -r --argjson c "$CHAIN_ID" '.[($c|tostring)][0].amount // empty' 2>/dev/null || true)
  if [ -n "$PREV_AMOUNT" ]; then
    DEF_MARKET_FEE_HUMAN=$(printf '%s' "$PREV_AMOUNT" | awk '{printf "%.18g", $1/1e18}' 2>/dev/null || echo 0)
  fi
  ask MARKET_FEE_HUMAN "Fixed market fee per order, in devEURAU (0 = disabled)" "$DEF_MARKET_FEE_HUMAN"
fi
MARKET_FEE_WEI=$(oe_keys units --amount "$MARKET_FEE_HUMAN" | jq -r .amount) || oe_die "invalid market fee amount '$MARKET_FEE_HUMAN'"

MARKET_PERCENT_FEE=${MARKET_PERCENT_IN:-}
[ -n "$MARKET_PERCENT_FEE" ] || ask MARKET_PERCENT_FEE "Percentage market fee (0.1 = 10%, 0 = disabled)" "$DEF_MARKET_PERCENT"
[[ $MARKET_PERCENT_FEE =~ ^[0-9]+([.][0-9]+)?$ ]] || oe_die "percentage fee must be a number"

DATASPACE=${DATASPACE_IN:-}
[ -n "$DATASPACE_IN" ] || ask DATASPACE "Dataspace id (catalogue tag filter, empty = off)" "$DEF_DATASPACE"

OWNER_NAME=${OWNER_NAME_IN:-}
[ -n "$OWNER_NAME_IN" ] || ask OWNER_NAME "Owner legal name" "$DEF_OWNER_NAME"
OWNER_EMAIL=${OWNER_EMAIL_IN:-}
[ -n "$OWNER_EMAIL_IN" ] || ask OWNER_EMAIL "Owner contact email" "$DEF_OWNER_EMAIL"
OWNER_URL=${OWNER_URL_IN:-}
[ -n "$OWNER_URL_IN" ] || ask OWNER_URL "Owner website" "$DEF_OWNER_URL"
OWNER_ADDR=${OWNER_ADDR_IN:-}
[ -n "$OWNER_ADDR_IN" ] || ask OWNER_ADDR "Owner postal address" "$DEF_OWNER_ADDR"
TERMS_URL=${TERMS_URL_IN:-}
[ -n "$TERMS_URL_IN" ] || ask TERMS_URL "Terms & conditions URL" "$DEF_TERMS"
PRIVACY_URL=${PRIVACY_URL_IN:-}
[ -n "$PRIVACY_URL_IN" ] || ask PRIVACY_URL "Privacy policy URL" "$DEF_PRIVACY"

NODE_OWNER_INFO=$(jq -nc \
  --arg name "$OWNER_NAME" --arg email "$OWNER_EMAIL" --arg url "$OWNER_URL" --arg addr "$OWNER_ADDR" \
  --arg terms "$TERMS_URL" --arg privacy "$PRIVACY_URL" \
  '{imprint:{legalName:$name,email:$email,url:$url,address:$addr},
    termsAndConditions:{url:$terms},
    privacyPolicy:{url:$privacy}}') || oe_die "could not build NODE_OWNER_INFO"

# Values derived from the chain / keys above
MARKET_ORDER_FEE_MAP=$(jq -nc --argjson c "$CHAIN_ID" --arg token "$DEVEURAU_ADDRESS" --arg amount "$MARKET_FEE_WEI" \
  '{($c|tostring):[{token:$token,amount:$amount}]}') || oe_die "could not build MARKET_ORDER_FEE_MAP"
ALLOWED_ADMINS=$(jq -nc --arg a "$ADMIN_ADDRESS" '[$a]')

ELASTIC_PASSWORD=${DEF_ELASTIC_PW:-}
if [ -z "$ELASTIC_PASSWORD" ]; then
  ELASTIC_PASSWORD=$(openssl rand -hex 24)
elif [ "$FORCE_KEYS" -eq 1 ]; then
  oe_warn "keeping the existing ELASTIC_PASSWORD: changing it would require wiping the esdata volume (docker compose down -v)"
fi

START_BLOCK=${DEF_START_BLOCK:-0}
[[ $START_BLOCK =~ ^[0-9]+$ ]] || START_BLOCK=0
# Only a fallback for people who run `docker compose up` by hand: ./start.sh
# asks for the real value at launch (default = current head, i.e. no backfill).
if [ -n "${NETINFO:-}" ]; then
  LIVE_HEAD=$(printf '%s' "$NETINFO" | jq -r '.head // empty' 2>/dev/null || true)
  [ -n "$LIVE_HEAD" ] && START_BLOCK=$LIVE_HEAD
fi

# -------------------------------------------------------------- write .env ---
oe_step "Writing configuration"
if [ "$HAVE_ENV" -eq 1 ]; then
  BACKUP="$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$ENV_FILE" "$BACKUP"
  chmod 600 "$BACKUP" 2>/dev/null || true
  oe_info "previous .env backed up to $(basename "$BACKUP")"
fi

umask 077
cat > "$ENV_FILE" <<EOF
# =============================================================================
# Ocean Enterprise stack — generated by ./customize.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# Marketplace + OE Node (registry.agrospai.udl.cat, tag latest) + Elasticsearch 8.19.x
# Network: OP Sepolia (chainId ${CHAIN_ID}) — payment token devEURAU
#
# Secrets in this file (IPFS_JWT, ELASTIC_PASSWORD) are plain text: keep it
# mode 0600 and out of version control. Wallet keys are NOT here — they live
# encrypted in ./secrets/ and are injected by ./start.sh at launch.
# =============================================================================

# -----------------------------------------------------------------------------
# PUBLIC HOSTNAMES / PORTS
# -----------------------------------------------------------------------------
# URL of the OE Node as seen from the user's browser (the market calls it
# directly from the client). Use the public hostname + TLS proxy for anything
# beyond a single-machine trial.
OE_NODE_URL=${OE_NODE_URL}

MARKET_HTTP_PORT=${MARKET_HTTP_PORT}
NODE_HTTP_PORT=${NODE_HTTP_PORT}
ES_HTTP_PORT=${ES_HTTP_PORT}

# -----------------------------------------------------------------------------
# BLOCKCHAIN — OP Sepolia (chainId ${CHAIN_ID})
# -----------------------------------------------------------------------------
RPC_URL=${RPC_URL}
CHAIN_ID=${CHAIN_ID}
CHAIN_NAME=${CHAIN_NAME}

# devEURAU (EURAU on OP Sepolia) — the payment/fee token
DEVEURAU_ADDRESS=${DEVEURAU_ADDRESS}

# Indexer start block. ./start.sh asks at launch (default = current head) and
# rewrites this line; the value here is only a fallback for a hand-run
# "docker compose up".
START_BLOCK=${START_BLOCK}

# -----------------------------------------------------------------------------
# IPFS — Pinata
# -----------------------------------------------------------------------------
IPFS_GATEWAY=${IPFS_GATEWAY}
IPFS_UPLOAD_URL=${IPFS_UPLOAD_URL}
IPFS_DELETE_URL=${IPFS_DELETE_URL}
# Required to publish assets from the marketplace.
IPFS_JWT=${IPFS_JWT}

# -----------------------------------------------------------------------------
# ELASTICSEARCH (indexer DB for the OE Node)
# -----------------------------------------------------------------------------
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}

# -----------------------------------------------------------------------------
# WALLET KEYS (encrypted keystores; decrypted by ./start.sh, never stored here)
# -----------------------------------------------------------------------------
# Node key: PRIVATE_KEY of the OE Node and fee collector of the marketplace.
NODE_KEYSTORE=secrets/node.keystore.json
NODE_ADDRESS=${NODE_ADDRESS}

# Admin key: address allowed to administer the node (ALLOWED_ADMINS).
ADMIN_KEYSTORE=secrets/admin.keystore.json
ADMIN_ADDRESS=${ADMIN_ADDRESS}

# -----------------------------------------------------------------------------
# OE NODE
# -----------------------------------------------------------------------------
# Operator fee per purchase (paid in devEURAU).
NODE_FEE_AMOUNT=${NODE_FEE_AMOUNT}

# Addresses allowed to administer the node through its API.
ALLOWED_ADMINS=${ALLOWED_ADMINS}

# Public owner info shown by the marketplace.
NODE_OWNER_INFO=${NODE_OWNER_INFO}

# -----------------------------------------------------------------------------
# MARKETPLACE
# -----------------------------------------------------------------------------
# Fee collector wallet (= node wallet).
MARKET_FEE_ADDRESS=${MARKET_FEE_ADDRESS}

# Fixed fee per order, in devEURAU smallest units (18 decimals).
MARKET_ORDER_FEE_MAP=${MARKET_ORDER_FEE_MAP}

# Percentage fee (0.1 = 10%).
MARKET_PERCENT_FEE=${MARKET_PERCENT_FEE}

# Catalogue tag filter (empty = disabled).
DATASPACE=${DATASPACE}
EOF
chmod 600 "$ENV_FILE"
oe_ok ".env written (mode 0600, $(wc -c < "$ENV_FILE" | tr -d ' ') bytes)"

chmod 700 "$SECRETS_DIR" 2>/dev/null || true
chmod 600 "$KEYSTORE_NODE" "$KEYSTORE_ADMIN" 2>/dev/null || true

# ------------------------------------------------------------- chain check ---
oe_step "Funding check (${NODE_ADDRESS})"
if BAL_JSON=$(oe_keys netinfo --rpc "$RPC_URL" --address "$NODE_ADDRESS" --token "$DEVEURAU_ADDRESS" 2>/dev/null); then
  ETH_BAL=$(printf '%s' "$BAL_JSON" | jq -r '.eth // "?"')
  TOK_BAL=$(printf '%s' "$BAL_JSON" | jq -r '.token.formatted // "?"')
  TOK_SYM=$(printf '%s' "$BAL_JSON" | jq -r '.token.symbol // "devEURAU"')
  oe_info "OP Sepolia ETH:      $ETH_BAL"
  oe_info "${TOK_SYM}: $TOK_BAL"
  case "$ETH_BAL" in 0*|"?")
    oe_warn 'node wallet has no OP Sepolia ETH — fund it for gas'
    oe_info "        ./fund.sh                      # no MetaMask: PoW faucet + automatic bridge (admin wallet)"
    oe_info "        ./fund.sh --target node        # fund the node wallet instead"
    oe_info "        or a faucet: https://console.optimism.io/faucet , https://ethglobal.com/faucet"
    ;;
  esac
else
  oe_warn "could not read balances from the RPC (offline?)"
fi

# ------------------------------------------------------------------ summary ---
oe_step "Configured"
printf '  %-22s %s\n' "node / fee collector" "$NODE_ADDRESS"
printf '  %-22s %s\n' "admin"               "$ADMIN_ADDRESS"
printf '  %-22s %s\n' "marketplace"         "http://localhost:${MARKET_HTTP_PORT}"
printf '  %-22s %s\n' "node API"            "http://localhost:${NODE_HTTP_PORT}"
printf '  %-22s %s\n' "node URL (browser)"  "$OE_NODE_URL"
printf '  %-22s %s\n' "keystores"           "secrets/node.keystore.json, secrets/admin.keystore.json"
printf '\n'
oe_info "${C_DIM}The node key signs and decrypts assets, so keep ./secrets/ backed up and offline."
oe_info "Import the admin keystore into MetaMask (account import -> JSON) to administer the node.${C_OFF}"

if [ -n "$(printf '%s' "$NODE_OWNER_INFO" | grep -o '<[a-z_]*>' || true)" ]; then
  oe_warn "NODE_OWNER_INFO still contains placeholder <...> fields — edit .env before going public"
fi

if [ "$RUN_START" -eq 1 ]; then
  if [ "$NONINTERACTIVE" -eq 0 ]; then
    ask_yn START_NOW "Start the stack now?" Y || true
  else
    START_NOW=1
  fi
  if [ "$START_NOW" -eq 1 ]; then
    oe_info
    OE_KEYSTORE_PASSWORD=$KEYSTORE_PASSWORD exec "$ROOT/start.sh"
  fi
fi

oe_info
oe_info "Next: ${C_BOLD}./start.sh${C_OFF} (asks for the keystore password, then docker compose up -d)"
