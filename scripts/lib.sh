#!/usr/bin/env bash
# =============================================================================
# Shared helpers for customize.sh / start.sh.
# Sourced, never executed directly. Expects $ROOT to point at the repo root.
# =============================================================================

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_CYAN=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_OFF=''
fi

oe_info() { printf '%s\n' "$*"; }
oe_step() { printf '\n%s== %s ==%s\n' "$C_CYAN" "$*" "$C_OFF"; }
oe_ok()   { printf '%s  ok  %s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
oe_warn() { printf '%sWARN:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
oe_die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

oe_have() { command -v "$1" >/dev/null 2>&1; }

oe_require_cmd() {
  local missing=() c
  for c in "$@"; do oe_have "$c" || missing+=("$c"); done
  if [ ${#missing[@]} -gt 0 ]; then
    oe_die "missing required command(s): ${missing[*]}"
  fi
}

# Read a KEY=value from .env (last definition wins, like docker compose).
oe_env_get() {
  local key=$1 def=${2-} val=''
  if [ -f "$ROOT/.env" ]; then
    val=$(grep -E "^${key}=" "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi
  printf '%s' "${val:-$def}"
}

# Same, but from an explicit file (used to seed defaults from .env.example).
oe_env_get_file() {
  local file=$1 key=$2 def=${3-} val=''
  if [ -f "$file" ]; then
    val=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi
  printf '%s' "${val:-$def}"
}

# Set/replace a KEY=value in an env file (appends the key when missing).
oe_is_pinata_jwt() { # 0 when the value has the three-segment JWT shape Pinata issues
  printf '%s' "${1:-}" | grep -Eq '^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'
}

oe_pinata_auth_status() { # -> ok | invalid | unreachable   (no token is echoed)
  local tok=${1:-} code
  [ -n "$tok" ] || { printf 'invalid'; return 0; }
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
           -H "Authorization: Bearer $tok" \
           https://api.pinata.cloud/data/testAuthentication 2>/dev/null) || code=000
  case $code in
    2??)     printf 'ok' ;;
    401|403) printf 'invalid' ;;
    *)       printf 'unreachable' ;;
  esac
}

oe_env_set() {
  local file=$1 key=$2 val=$3
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i '' -E "s|^${key}=.*|${key}=${val}|" "$file" 2>/dev/null \
      || sed -i -E "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# Install ethers once into .tools/ (keystore + chain tooling).
oe_ensure_ethers() {
  if [ -d "$ROOT/.tools/node_modules/ethers" ]; then return 0; fi
  oe_have npm || oe_die "npm is required to install the keystore tooling (ethers)"
  oe_info "Installing keystore tooling (ethers) into .tools/ ..."
  mkdir -p "$ROOT/.tools"
  if [ ! -f "$ROOT/.tools/package.json" ]; then
    # npm refuses to derive a package name from a dot-directory, so seed it.
    printf '{\n  "name": "oe-launcher-tools",\n  "private": true,\n  "version": "0.0.0",\n  "description": "keystore/chain tooling for the Ocean Enterprise launcher"\n}\n' > "$ROOT/.tools/package.json"
  fi
  if ! ( cd "$ROOT/.tools" && npm install --no-audit --no-fund --silent --save-exact ethers@6 >/dev/null ); then
    oe_die "could not install ethers into $ROOT/.tools (network?)"
  fi
  [ -d "$ROOT/.tools/node_modules/ethers" ] || oe_die "ethers install failed"
}

# Wrapper around scripts/oe-keys.cjs with NODE_PATH wired to .tools/.
oe_keys() {
  oe_ensure_ethers
  NODE_PATH="$ROOT/.tools/node_modules" node "$ROOT/scripts/oe-keys.cjs" "$@"
}

oe_valid_hexkey() { [[ $1 =~ ^0x[0-9a-fA-F]{64}$ ]]; }
oe_valid_address() { [[ $1 =~ ^0x[0-9a-fA-F]{40}$ ]]; }
oe_valid_port() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }

# Absolute path helper for keystore references stored in .env.
oe_abspath() { case $1 in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$ROOT" "${1#./}" ;; esac; }
