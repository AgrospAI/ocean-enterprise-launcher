#!/usr/bin/env bash
# =============================================================================
# fund.sh — put OP Sepolia ETH into a launcher wallet, without MetaMask.
#
# Why this exists: the faucets that hand out OP Sepolia ETH directly all need
# an account with some standing (mainnet balance, onchain identity, GitHub).
# The one open path is the Sepolia PoW faucet, which pays on Sepolia L1 only —
# so somebody has to bridge it. This script does both halves:
#
#   1. shows the wallet address and opens the PoW faucet in your browser
#      (https://sepolia-faucet.pk910.de/?address=0x…) where you only press
#      "Start Mining" and leave the tab open;
#   2. waits until the Sepolia L1 balance arrives, then signs
#      L1StandardBridge.depositETHTo() with the wallet's own key — the same
#      private key controls the address on both chains — and reports when the
#      ETH shows up on OP Sepolia.
#
# The keystore password is only needed for step 2 and is never written to disk.
#
# Usage:
#   ./fund.sh                     # fund the admin wallet (default)
#   ./fund.sh --target node       # the node/fee-collector wallet instead
#   ./fund.sh --target all        # admin + node
#   ./fund.sh --dry-run           # print addresses + bridge plan, change nothing
#   ./fund.sh --bridge-only       # skip the faucet wait (L1 already funded)
#   ./fund.sh --min-eth 0.01 --keep-eth 0.005 --faucet-wait 3600
# =============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

# OP Sepolia from Sepolia L1 (superchain-registry, sepolia/op.toml)
OP_SEPOLIA_L1_BRIDGE=0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1
L1_CHAIN_ID=11155111
L1_RPC=${L1_RPC:-https://ethereum-sepolia-rpc.publicnode.com}
L1_RPC_FALLBACK=https://1rpc.io/sepolia
FAUCET=${FAUCET:-https://sepolia-faucet.pk910.de}
MIN_GAS_LIMIT=200000

TARGET=admin
MIN_ETH=0.005
SEND_TO=''             # optional OP Sepolia transfer after funding
SEND_AMOUNT=''          # what "funded enough" means on OP Sepolia
KEEP_ETH=0.002         # left on Sepolia L1 (gas for a retry)
FAUCET_MIN=0.05        # the PoW faucet's minimum claim, in Sepolia ETH
FAUCET_WAIT=1800       # seconds to wait for the claim
L2_WAIT=900            # seconds to wait for the deposit to land
DRY_RUN=0
OPEN_BROWSER=1
ASSUME_YES=0
FORCE=0
BRIDGE_ONLY=0
PASSWORD_FILE=${OE_KEYSTORE_PASSWORD_FILE:-}

usage() {
  cat <<'EOF'
usage: ./fund.sh [options]

Fund a launcher wallet with OP Sepolia ETH without MetaMask: mine Sepolia ETH
on the PoW faucet (browser), then bridge it with the wallet's own key.

Options:
  --target admin|node|all   which launcher wallet(s) to fund   (default: admin)
  --min-eth N               enough ETH on OP Sepolia          (default: 0.005)
  --keep-eth N              ETH left on L1 for gas            (default: 0.002)
  --faucet-wait SEC         how long to wait for the mining   (default: 1800)
  --l1-rpc URL              Sepolia L1 RPC                    (default: publicnode)
  --faucet URL              PoW faucet URL                    (default: pk910)
  --no-browser              do not try to open a browser
  --bridge-only             skip the faucet step (L1 already has ETH)
  --dry-run                 print addresses and the deposit plan, send nothing
  --yes                     do not ask before sending the deposit
  --force                   bridge even if OP Sepolia looks funded
  --send-to 0x…             after funding, transfer OP Sepolia ETH to this address
  --send-amount N           how much to send with --send-to (e.g. 0.02)
  --password-file F         keystore password file
Environment: OE_KEYSTORE_PASSWORD / OE_KEYSTORE_PASSWORD_FILE, L1_RPC, FAUCET
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    --target)       TARGET=${2:?--target needs a value}; shift 2 ;;
    --min-eth)      MIN_ETH=${2:?}; shift 2 ;;
    --keep-eth)     KEEP_ETH=${2:?}; shift 2 ;;
    --faucet-wait)  FAUCET_WAIT=${2:?}; shift 2 ;;
    --l2-wait)      L2_WAIT=${2:?}; shift 2 ;;
    --l1-rpc)       L1_RPC=${2:?}; shift 2 ;;
    --faucet)       FAUCET=${2:?}; shift 2 ;;
    --no-browser)   OPEN_BROWSER=0; shift ;;
    --bridge-only)  BRIDGE_ONLY=1; shift ;;
    --dry-run|-n)   DRY_RUN=1; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --force)        FORCE=1; shift ;;
    --password-file) PASSWORD_FILE=${2:?}; shift 2 ;;
    --send-to)      SEND_TO=${2:?}; shift 2 ;;
    --send-amount)  SEND_AMOUNT=${2:?}; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              oe_die "unknown option: $1 (try --help)" ;;
  esac
done

case $TARGET in node|admin|all) ;; *) oe_die "--target must be node, admin or all" ;; esac
if [ -n "$SEND_TO" ] || [ -n "$SEND_AMOUNT" ]; then
  [ -n "$SEND_TO" ] && [ -n "$SEND_AMOUNT" ] || oe_die "--send-to and --send-amount go together"
  oe_valid_address "$SEND_TO" || oe_die "--send-to must be 0x + 40 hex characters"
fi

[ -f "$ROOT/.env" ] || oe_die "no .env — run ./customize.sh first"
L2_RPC=$(oe_env_get RPC_URL '')
CHAIN_ID=$(oe_env_get CHAIN_ID 11155420)
[ -n "$L2_RPC" ] || oe_die "RPC_URL is empty in .env"
oe_have jq || oe_die "jq is required"

oe_step "Tooling"
oe_ensure_ethers >/dev/null   # keep its "installing" chatter out of captured JSON

# ---------------------------------------------------------------- helpers -----
keystore_for() {
  case $1 in
    node)  oe_abspath "$(oe_env_get NODE_KEYSTORE secrets/node.keystore.json)" ;;
    admin) oe_abspath "$(oe_env_get ADMIN_KEYSTORE secrets/admin.keystore.json)" ;;
  esac
}

address_of() { # keystore file -> checksummed 0x address (no password needed)
  local raw
  raw=$(jq -r '.address // empty' "$1" 2>/dev/null | sed -e 's/^0x//')
  [ -n "$raw" ] || return 1
  NODE_PATH="$ROOT/.tools/node_modules" node -e 'const {getAddress}=require("ethers");console.log(getAddress("0x"+process.argv[1]))' "$raw" 2>/dev/null \
    || printf '0x%s\n' "$raw"
}

ge_wei() { # ge_wei <a> <b> -> true when a >= b
  node -e 'process.exit(BigInt(process.argv[1])>=BigInt(process.argv[2])?0:1)' "$1" "$2"
}

sub_wei() { # sub_wei <a> <b> -> max(a-b, 0)
  node -e 'const [a,b]=process.argv.slice(1).map(BigInt);console.log((a>b?a-b:0n).toString())' "$1" "$2"
}

open_url() {
  [ "$OPEN_BROWSER" -eq 1 ] || return 1
  if oe_have open; then open "$1" 2>/dev/null && return 0; fi
  if oe_have xdg-open; then xdg-open "$1" >/dev/null 2>&1 && return 0; fi
  return 1
}

ask_ok() { # ask_ok "<question>" -> 0 yes, 1 no
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ ! -t 0 ]; then   # no terminal: never send without an explicit --yes
    oe_warn "stdin is not a terminal — re-run with --yes to send the deposit"
    return 1
  fi
  local a=''
  printf '%s [Y/n] ' "$1"
  IFS= read -r a || a=''
  case ${a:-y} in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

do_transfer() { # do_transfer <keystore> <from-address>
  [ -n "$SEND_TO" ] || return 0
  oe_step "Sending ${SEND_AMOUNT} ETH on OP Sepolia"
  oe_info "from $2"
  oe_info "to   $SEND_TO"
  if [ "$DRY_RUN" -eq 1 ]; then
    oe_keys send --keystore "$1" --rpc "$L2_RPC" --to "$SEND_TO" --amount-eth "$SEND_AMOUNT" \
      --expect-chain-id "$CHAIN_ID" --dry-run \
      | jq -r '"  plan: transfer \(.amountEth) ETH (gas estimate \(.gasEstimate // "n/a"))"'
    return 0
  fi
  ask_ok "Send ${SEND_AMOUNT} ETH to $SEND_TO?" || { oe_warn "transfer skipped"; return 0; }
  require_password
  local res
  res=$(printf '%s' "$KEYSTORE_PASSWORD" | oe_keys send --keystore "$1" --rpc "$L2_RPC" \
          --to "$SEND_TO" --amount-eth "$SEND_AMOUNT" --expect-chain-id "$CHAIN_ID" --password-stdin)
  unset KEYSTORE_PASSWORD
  oe_ok "transfer sent: $(printf '%s' "$res" | jq -r '.txHash')"
}

require_password() {
  [ -n "${KEYSTORE_PASSWORD:-}" ] && return 0
  if [ -n "$PASSWORD_FILE" ]; then
    [ -r "$PASSWORD_FILE" ] || oe_die "$PASSWORD_FILE is not readable"
    KEYSTORE_PASSWORD=$(cat "$PASSWORD_FILE")
  fi
  [ -n "${KEYSTORE_PASSWORD:-}" ] && return 0
  [ -t 0 ] || oe_die "no keystore password: set OE_KEYSTORE_PASSWORD or OE_KEYSTORE_PASSWORD_FILE"
  printf 'Keystore password: '
  IFS= read -rs KEYSTORE_PASSWORD || true
  printf '\n'
  [ -n "$KEYSTORE_PASSWORD" ] || oe_die "empty password"
}

balance_eth() { # balance_eth <rpc> <address> -> "wei eth" (dies on wrong chain)
  local json
  json=$(oe_keys balance --rpc "$1" --address "$2") || exit 1
  printf '%s %s\n' "$(printf '%s' "$json" | jq -r '.wei')" "$(printf '%s' "$json" | jq -r '.eth')"
}

# ------------------------------------------------------------------ main -----
KEYS=()
case $TARGET in
  node)  KEYS=(node) ;;
  admin) KEYS=(admin) ;;
  all)   KEYS=(node admin) ;;
esac

oe_step "Targets"
printf '  %-6s %-44s %s\n' wallet keystore address
for k in "${KEYS[@]}"; do
  ks=$(keystore_for "$k")
  [ -f "$ks" ] || oe_die "no keystore for the $k wallet ($ks) — run ./customize.sh"
  addr=$(address_of "$ks")
  oe_valid_address "$addr" || oe_die "cannot read the address from $ks"
  printf '  %-6s %-44s %s\n' "$k" "${ks#$ROOT/}" "$addr"
done

printf '\nOP Sepolia RPC : %s (chain %s)\nSepolia L1 RPC : %s\n' "$L2_RPC" "$CHAIN_ID" "$L1_RPC"

for k in "${KEYS[@]}"; do
  ks=$(keystore_for "$k")
  addr=$(address_of "$ks")

  oe_step "Wallet: $k ($addr)"

  read -r L2_WEI L2_ETH <<<"$(balance_eth "$L2_RPC" "$addr")"
  MIN_WEI=$(oe_keys units --amount "$MIN_ETH" | jq -r '.amount')
  oe_info "OP Sepolia: ${L2_ETH} ETH"

  if ge_wei "$L2_WEI" "$MIN_WEI"; then
    if [ "$FORCE" -eq 0 ]; then
      oe_ok "already funded (>= ${MIN_ETH} ETH)"
      do_transfer "$ks" "$addr"
      continue
    fi
    oe_warn "already funded, but --force was given"
  fi

  read -r L1_WEI L1_ETH <<<"$(balance_eth "$L1_RPC" "$addr")"
  oe_info "Sepolia L1: ${L1_ETH} ETH"

  NEED_WEI=$(oe_keys units --amount "$FAUCET_MIN" | jq -r '.amount')
  KEEP_WEI=$(oe_keys units --amount "$KEEP_ETH" | jq -r '.amount')
  BRIDGE_WEI=$(sub_wei "$L1_WEI" "$KEEP_WEI")

  if [ "$BRIDGE_ONLY" -eq 0 ] && ! ge_wei "$L1_WEI" "$NEED_WEI"; then
    oe_step "Getting Sepolia ETH (no MetaMask needed)"
    cat <<EOF

  1. This wallet's address (already filled in on the faucet page):

         $addr

  2. In the browser: press "Start Mining" on the "$(printf '%s' "$FAUCET" | sed 's|https\?://||')"
     page and keep the tab open. It mines until you stop and claim;
     the minimum claim is ${FAUCET_MIN} SepETH (up to 2.5 per session).
  3. Come back here: this script watches the balance and continues by itself.

  Page: $FAUCET/?address=$addr

EOF
    if ! open_url "$FAUCET/?address=$addr"; then
      oe_warn "could not open a browser — paste that URL manually"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      oe_info "dry-run: would wait up to ${FAUCET_WAIT}s for >= ${FAUCET_MIN} ETH on Sepolia L1, then bridge it"
      continue
    fi

    oe_info "Waiting for the claim (Ctrl-C to abort)..."
    WATCH=$(oe_keys watch-balance --rpc "$L1_RPC" --address "$addr" --min-eth "$FAUCET_MIN" --timeout "$FAUCET_WAIT")
    if ! printf '%s' "$WATCH" | jq -e '.reached == true' >/dev/null 2>&1; then
      read -r L1_WEI L1_ETH <<<"$(balance_eth "$L1_RPC" "$addr")"
      if node -e 'process.exit(BigInt(process.argv[1])>BigInt(process.argv[2])?0:1)' "$L1_WEI" "$KEEP_WEI"; then  # more than the reserve
        oe_warn "no claim after ${FAUCET_WAIT}s, but L1 already holds ${L1_ETH} ETH — bridging what is there"
      else
        oe_die "nothing to bridge yet (waited ${FAUCET_WAIT}s). Re-run with --bridge-only once the claim lands."
      fi
    else
      L1_ETH=$(printf '%s' "$WATCH" | jq -r '.eth')
      L1_WEI=$(printf '%s' "$WATCH" | jq -r '.wei')
      oe_ok "claimed: ${L1_ETH} ETH on Sepolia L1"
    fi
  fi

  BRIDGE_WEI=$(sub_wei "$L1_WEI" "$KEEP_WEI")
  if ! node -e 'process.exit(BigInt(process.argv[1])>0n?0:1)' "$BRIDGE_WEI"; then
    oe_die "nothing to bridge: L1 balance is ${L1_ETH} ETH and --keep-eth is ${KEEP_ETH}"
  fi
  BRIDGE_ETH=$(node -e 'const w=BigInt(process.argv[1]);const i=w/10n**18n;let f=(w%10n**18n).toString().padStart(18,"0").replace(/0+$/,"");console.log(f?i+"."+f:String(i))' "$BRIDGE_WEI")

  oe_step "Bridging to OP Sepolia"
  oe_info "from  $addr (Sepolia L1)"
  oe_info "to    $addr (OP Sepolia)"
  oe_info "value ${BRIDGE_ETH} ETH   keep ${KEEP_ETH} ETH on L1 for gas"

  if [ "$DRY_RUN" -eq 1 ]; then
    PLAN=$(oe_keys bridge --keystore "$ks" --rpc "$L1_RPC" --bridge "$OP_SEPOLIA_L1_BRIDGE" \
             --to "$addr" --amount-wei "$BRIDGE_WEI" --expect-chain-id "$L1_CHAIN_ID" \
             --min-gas-limit "$MIN_GAS_LIMIT" --dry-run)
    printf '%s' "$PLAN" | jq -r '"  plan: depositETHTo value=\(.amountEth) ETH gasLimit=\(.minGasLimit) (estimate \(.gasEstimate // "n/a"))\n  data: \(.data[0:10])…"'
    do_transfer "$ks" "$addr"
    continue
  fi

  ask_ok "Send the deposit from $addr?" || { oe_warn "skipped by the user"; continue; }
  require_password

  RESULT=$(printf '%s' "$KEYSTORE_PASSWORD" | oe_keys bridge --keystore "$ks" --rpc "$L1_RPC" \
            --bridge "$OP_SEPOLIA_L1_BRIDGE" --to "$addr" --amount-wei "$BRIDGE_WEI" \
            --expect-chain-id "$L1_CHAIN_ID" --min-gas-limit "$MIN_GAS_LIMIT" --password-stdin)
  unset KEYSTORE_PASSWORD
  oe_ok "deposit sent: $(printf '%s' "$RESULT" | jq -r '.txHash')"
  oe_info "gas used $(printf '%s' "$RESULT" | jq -r '.gasUsed'), fee $(printf '%s' "$RESULT" | jq -r '.fee') ETH"

  oe_info "Waiting for it to land on OP Sepolia (usually 1-3 min)..."
  WATCH=$(oe_keys watch-balance --rpc "$L2_RPC" --address "$addr" --min-eth "$MIN_ETH" --timeout "$L2_WAIT" --interval 10)
  if printf '%s' "$WATCH" | jq -e '.reached == true' >/dev/null 2>&1; then
    oe_ok "OP Sepolia balance: $(printf '%s' "$WATCH" | jq -r '.eth') ETH — funded"
  else
    oe_warn "still not credited after ${L2_WAIT}s (balance $(printf '%s' "$WATCH" | jq -r '.eth // "?"') ETH)."
    oe_warn "The deposit is on its way; re-check with: ./fund.sh --bridge-only"
  fi
  do_transfer "$ks" "$addr"
done

oe_step "Done"
for k in "${KEYS[@]}"; do
  addr=$(address_of "$(keystore_for "$k")")
  read -r _ eth <<<"$(balance_eth "$L2_RPC" "$addr")" || true
  printf '  %-6s %s  %s ETH\n' "$k" "$addr" "${eth:-?}"
done
oe_info ""
oe_info "Gas is only half of it: publishing/consuming also needs devEURAU tokens on OP Sepolia."

# how to sign in to the marketplace with the admin wallet (the keystore is a
# standard V3 JSON file, so the market can open it directly — no MetaMask)
ADMIN_KS_FILE=$(keystore_for admin)
ADMIN_KS_REL=${ADMIN_KS_FILE#"$ROOT"/}
oe_step "Signing in to the marketplace with the admin wallet"
oe_info "Account menu → Connect web3 wallet → Wallet file, then"
oe_info "  file      ${ADMIN_KS_REL}"
oe_info "  password  the keystore password you chose (it is not stored in .env)"
oe_info "The file must be funded on OP Sepolia (chain ${CHAIN_ID}) to publish or consume."
if [ "${ADMIN_KS_REL}" != "secrets/admin.keystore.json" ]; then
  oe_info "You brought your own admin key, so ${ADMIN_KS_REL} is the file to import;"
  oe_info "any other V3 keystore works the same way (wallet file + its password)."
else
  oe_info "If you had your own admin keystore already, import that file instead — the flow is the same."
fi
