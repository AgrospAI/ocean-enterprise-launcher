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

# ------------------------------------------------------------ platform info ---
# -> macos | debian | rhel | arch | suse | linux | unknown
oe_os_family() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux)
      local ids=''
      if [ -r /etc/os-release ]; then
        # subshell: distro variables must not leak into the caller's scope
        ids=$(. /etc/os-release >/dev/null 2>&1; printf '%s %s' "${ID:-}" "${ID_LIKE:-}")
      fi
      case " $ids " in
        *debian*|*ubuntu*)                       printf 'debian' ;;
        *rhel*|*fedora*|*centos*|*rocky*|*alma*) printf 'rhel' ;;
        *arch*)                                  printf 'arch' ;;
        *suse*|*opensuse*)                       printf 'suse' ;;
        *)                                       printf 'linux' ;;
      esac ;;
    *) printf 'unknown' ;;
  esac
}

# package manager actually present -> apt-get|dnf|yum|pacman|zypper|apk|brew|none
# (distro IDs in /etc/os-release are unreliable on containers and appliances,
#  while the available package manager is what actually solves the problem)
oe_pkg_mgr() {
  local m
  for m in apt-get dnf yum pacman zypper apk brew; do
    if oe_have "$m"; then printf '%s' "$m"; return; fi
  done
  printf 'none'
}

# $1 = package name(s) -> copy-pasteable install command for this host
oe_install_cmd() {
  case $(oe_pkg_mgr) in
    apt-get) printf 'sudo apt-get install -y %s' "$1" ;;
    dnf|yum) printf 'sudo %s install -y %s' "$(oe_pkg_mgr)" "$1" ;;
    pacman)  printf 'sudo pacman -S --needed %s' "$1" ;;
    zypper)  printf 'sudo zypper install %s' "$1" ;;
    apk)     printf 'sudo apk add %s' "$1" ;;
    brew)    printf 'brew install %s' "$1" ;;
    *)       printf '# install %s with your package manager' "$1" ;;
  esac
}

# $1 = package/command name -> indented, copy-pasteable install instructions
oe_pkg_hint() {
  local c=$1 mgr; mgr=$(oe_pkg_mgr)
  case "$c" in
    docker)
      if [ "$mgr" = brew ]; then
        cat <<'EOF'
      Docker Desktop bundles the compose v2 plugin:
             brew install --cask docker        # then launch Docker once
             https://docs.docker.com/desktop/install/mac-install/
EOF
      else
        cat <<'EOF'
      Docker Engine + the compose v2 plugin:
             curl -fsSL https://get.docker.com | sudo sh
             sudo systemctl enable --now docker
             sudo usermod -aG docker "$USER"    # log out/in (or: newgrp docker)
EOF
        printf '             or from the distro: %s\n' \
          "$(oe_install_cmd 'docker-ce docker-ce-cli containerd.io docker-compose-plugin')"
      fi ;;
    compose)
      printf '      the compose v2 *plugin* — the standalone docker-compose v1 is not supported:\n'
      printf '             curl -fsSL https://get.docker.com | sudo sh   # engine + plugin\n'
      case $mgr in
        apt-get) printf '             # or: sudo apt-get install -y docker-compose-v2    (Ubuntu 23.04+)\n' ;;
        dnf|yum) printf '             # or: %s\n' "$(oe_install_cmd docker-compose-plugin)" ;;
        pacman)  printf '             # or: sudo pacman -S docker-compose    (v2 in Arch)\n' ;;
        *)       printf '             # packages: docker-compose-plugin (Docker repo), docker-compose-v2 (Ubuntu 23.04+), docker-compose (Arch)\n' ;;
      esac ;;
    node|npm)
      case $mgr in
        brew) printf '      brew install node@20      (or a version manager: https://github.com/nvm-sh/nvm)\n' ;;
        apt-get)
          if oe_have curl; then
            printf '      curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs\n'
            printf '             # or: %s   (18+ on recent releases)\n' "$(oe_install_cmd 'nodejs npm')"
          else
            printf '      %s   (18+ on recent releases)\n' "$(oe_install_cmd 'nodejs npm')"
          fi ;;
        dnf|yum)
          if oe_have curl; then
            printf '      curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash - && %s\n' "$(oe_install_cmd nodejs)"
            printf '             # or: %s   (18+ on recent releases)\n' "$(oe_install_cmd 'nodejs npm')"
          else
            printf '      %s   (18+ on recent releases)\n' "$(oe_install_cmd 'nodejs npm')"
          fi ;;
        pacman) printf '      sudo pacman -S --needed nodejs npm\n' ;;
        apk)    printf '      sudo apk add nodejs npm\n' ;;
        *)      printf '      install Node.js 20 LTS (npm ships with it): https://nodejs.org/en/download\n' ;;
      esac ;;
    jq|curl|openssl|bash|git|lsof)
      case "$c:$mgr" in
        curl:brew)    printf '      preinstalled on macOS (reinstall with: brew install curl)\n' ;;
        openssl:brew) printf '      preinstalled on macOS (LibreSSL is fine)\n' ;;
        bash:brew)    printf '      preinstalled (the bundled 3.2 works too)\n' ;;
        lsof:*)       printf '      optional, only port-conflict checks in ./customize.sh use it: %s\n' "$(oe_install_cmd lsof)" ;;
        *)            printf '      %s\n' "$(oe_install_cmd "$c")" ;;
      esac ;;
    *) printf '      %s\n' "$(oe_install_cmd "$c")" ;;
  esac
}

# $1 = command -> "MISSING <cmd> — <what it is for>" + install hint
oe_missing_tool() {
  local c=$1 why=''
  case "$c" in
    bash)    why='the scripts are bash' ;;
    curl)    why='RPC / Pinata / faucet HTTP calls' ;;
    jq)      why='parsing JSON from the RPC, keystore and compose' ;;
    openssl) why='generating the Elasticsearch password' ;;
    node)    why='chain + keystore tooling (scripts/oe-keys.cjs) — Node.js 18 or newer' ;;
    npm)     why='installing the keystore tooling (ethers) into .tools/' ;;
    docker)  why='running the stack (Docker Engine + compose v2 plugin)' ;;
    *)       why="required by the scripts" ;;
  esac
  printf '%sMISSING%s %s — %s\n' "$C_RED" "$C_OFF" "$c" "$why" >&2
  oe_pkg_hint "$c" >&2
}

# 0 when version $1 >= $2 (dotted numeric, missing parts count as 0)
oe_ver_ge() {
  local have="${1#v}.0.0" need="${2#v}.0.0" i a b
  for i in 1 2 3; do
    a=$(printf '%s' "$have" | cut -d. -f"$i"); a=${a%%[!0-9]*}
    b=$(printf '%s' "$need" | cut -d. -f"$i"); b=${b%%[!0-9]*}
    [ -n "$a" ] || a=0; [ -n "$b" ] || b=0
    if [ "$a" -gt "$b" ]; then return 0; fi
    if [ "$a" -lt "$b" ]; then return 1; fi
  done
  return 0
}

# Preflight with per-tool fix instructions.
#   oe_preflight core  — customize.sh: everything incl. node/npm/docker + daemon
#   oe_preflight run   — start.sh: docker, compose, node, jq, curl
#   oe_preflight fund  — fund.sh: node, npm, jq, curl
oe_preflight() {
  local mode=${1:-core} c os missing=() problems=0
  local need=(bash curl jq)
  case $mode in
    core) need=(bash curl jq openssl node npm docker) ;;
    run)  need=(bash curl jq node npm docker) ;;
    fund) need=(bash curl jq node npm) ;;
  esac
  os=$(oe_os_family)
  oe_info "  ${C_DIM}host: $(uname -s) $(uname -r) $(uname -m) — ${os}, pkg: $(oe_pkg_mgr)${C_OFF}"
  if oe_have findmnt && findmnt -T "${ROOT:-$PWD}" -o OPTIONS -n 2>/dev/null | grep -q 'noexec'; then
    oe_warn "this directory is on a noexec mount — ./start.sh cannot be executed directly; run: bash start.sh"
  fi

  for c in "${need[@]}"; do
    oe_have "$c" || missing+=("$c")
  done

  # node/npm: presence + version floor
  if oe_have node; then
    local nv; nv=$(node --version 2>/dev/null | tr -d 'v')
    if oe_ver_ge "$nv" 18; then
      oe_ok "node $(node --version)$(oe_have npm && printf ' / npm %s' "$(npm --version 2>/dev/null)")"
    else
      oe_warn "node $(node --version) is too old — the keystore tooling needs Node.js 18 or newer"
      oe_pkg_hint node >&2
      problems=$((problems + 1))
    fi
  fi
  if oe_have jq;   then oe_ok "jq $(jq --version 2>/dev/null | sed 's/^jq-//')"; fi
  if oe_have curl; then oe_ok "curl $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"; fi
  if [[ " ${need[*]} " == *" openssl "* ]] && oe_have openssl; then
    oe_ok "openssl $(openssl version 2>/dev/null | awk '{print $2}')"
  fi

  # docker: version, compose v2 plugin, reachable daemon
  if [[ " ${need[*]} " == *" docker "* ]] && oe_have docker; then
    local dv; dv=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)
    oe_ok "docker ${dv}"
    if docker compose version >/dev/null 2>&1; then
      oe_ok "docker compose $(docker compose version --short 2>/dev/null)"
    else
      printf '%sMISSING%s docker compose v2 (the "docker-compose" v1 binary is not supported)\n' "$C_RED" "$C_OFF" >&2
      oe_pkg_hint compose >&2
      problems=$((problems + 1))
    fi
    if docker info >/dev/null 2>&1; then
      oe_ok "docker daemon reachable"
    else
      printf '%sMISSING%s docker daemon not reachable (permission denied or not running)\n' "$C_RED" "$C_OFF" >&2
      case $os in
        macos) printf '      start Docker Desktop (or: open -a Docker) and re-run\n' >&2 ;;
        *)     printf '      sudo systemctl enable --now docker\n      sudo usermod -aG docker "$USER"   # then log out/in (or: newgrp docker)\n' >&2 ;;
      esac
      problems=$((problems + 1))
    fi
  fi

  for c in ${missing[@]+"${missing[@]}"}; do oe_missing_tool "$c"; done
  problems=$((problems + ${#missing[@]}))

  # optional, never fatal
  oe_have lsof || oe_warn "lsof not found — port-conflict checks in ./customize.sh will be skipped"

  if [ "$problems" -gt 0 ]; then
    oe_die "$problems prerequisite problem(s) — fix the items above and re-run. Full list: README → Requirements"
  fi
  oe_ok "all prerequisites present"
}

oe_require_cmd() {
  local missing=() c
  for c in "$@"; do oe_have "$c" || missing+=("$c"); done
  if [ ${#missing[@]} -gt 0 ]; then
    for c in ${missing[@]+"${missing[@]}"}; do oe_missing_tool "$c"; done
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
