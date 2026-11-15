# Ocean Enterprise Launcher — Marketplace + OE Node (no SSI)

Docker Compose stack deploying the [Ocean Enterprise](https://docs.oceanenterprise.io/infrastructure)
core for a working dataspace where assets can be **published and consumed**, with
**SSI-based access control disabled** (address-based verification only).

| Component     | Image                                                         | URL                      |
|---------------|---------------------------------------------------------------|--------------------------|
| Marketplace   | `registry.agrospai.udl.cat/library/enterprise-market:latest`  | http://localhost:8080    |
| OE Node       | `registry.agrospai.udl.cat/library/oe-node:latest`            | http://localhost:8000    |
| Elasticsearch | `elasticsearch:9.3.4` (internal)                              | :9200 (diagnostics only) |

## Requirements

Everything here is checked before anything is written or started: `./customize.sh`
and `./start.sh` run a preflight that lists every tool with its version and, for
anything missing, the exact install command for your OS.

### Host

| | Minimum | Recommended |
|---|---------|-------------|
| OS | Ubuntu 22.04+/Debian 12, RHEL/Rocky 9, macOS 13+ (anything running Docker) | Ubuntu 24.04 LTS |
| CPU | 2 vCPU, `x86_64` or `arm64` | 4 vCPU |
| RAM | 4 GB free for Docker | 8 GB |
| Disk | 20 GB free | 40 GB (+ C2D storage) |
| Shell | bash 3.2+ | bash 5 |

Elasticsearch is capped at a 1 GB heap by `docker-compose.yml` and the node keeps
its DDO cache in RAM, so ~2 GB is used at rest — keep headroom for publishing and
for C2D jobs, which need extra disk for the datasets they stage.

### Software

| Tool | Version | Needed for | Ubuntu/Debian install |
|------|---------|-----------|------------------------|
| `docker` | Engine 24+ | running the stack | `curl -fsSL https://get.docker.com \| sudo sh` |
| `docker compose` | **v2 plugin** (not the old `docker-compose` v1) | `docker compose up` | ships with Docker Desktop; on Linux: `sudo apt-get install -y docker-compose-plugin` |
| `node` | 18+ (20 LTS tested) | keystore + chain tooling (`scripts/oe-keys.cjs`) | `curl -fsSL https://deb.nodesource.com/setup_20.x \| sudo -E bash - && sudo apt-get install -y nodejs` |
| `npm` | ships with `node` | installs `ethers` once into `.tools/` | ↑ same package |
| `jq` | 1.6+ | parsing RPC / keystore / compose JSON | `sudo apt-get install -y jq` |
| `curl` | any | RPC, Pinata, faucet calls | `sudo apt-get install -y curl` |
| `openssl` | any (`LibreSSL` is fine) | generating the Elasticsearch password | `sudo apt-get install -y openssl` |
| `git` | any | cloning this repo | `sudo apt-get install -y git` |
| `lsof` | optional | port-conflict checks in `customize.sh` (skipped if absent) | `sudo apt-get install -y lsof` |

macOS: `brew install --cask docker && brew install node@20 jq` — `curl`, `openssl`
and `lsof` are preinstalled.

### Docker post-install (Linux hosts)

The scripts must run as your own user, never under `sudo` (otherwise `.env`,
keystores and `oe-node-databases/` end up root-owned). On a fresh VM:

```bash
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"      # then log out and back in, or: newgrp docker
docker run --rm hello-world          # must not need sudo
```

On macOS, start Docker Desktop before running the scripts — the preflight reports
`docker daemon not reachable` otherwise.

### Windows

Native Windows is **not** supported: the launcher is a set of bash scripts that
assume POSIX paths and use `chmod 600` to protect `.env` and the keystores —
neither exists on NTFS. Use **WSL2**, where everything runs unmodified:

```powershell
wsl --install -d Ubuntu-24.04     # then open "Ubuntu 24.04" from the Start menu
```

Inside that shell, follow [Starting from a fresh cloud VM](#starting-from-a-fresh-cloud-vm)
with either Docker Desktop (enable *Settings → Resources → WSL integration* for
the distro — it provides `docker` plus the `/var/run/docker.sock` that C2D needs)
or Docker Engine installed in the distro itself.

Keep the repo in the Linux filesystem (`~/ocean-enterprise-launcher`), **not**
under `/mnt/c/…`: the relative bind mounts (`oe-node-databases/`, `oe-node-logs/`,
`oe-node-c2d-storage/`) are very slow on DrvFs, and `chmod` is a no-op there, so
private keys would stay world-readable.

Git Bash / MSYS mostly runs the scripts but is unsupported: `chmod` on NTFS does
nothing, MSYS path conversion can mangle the relative volume paths handed to
`docker compose`, and the preflight cannot identify the OS (it reports
`unknown`, so the hints are generic). Use WSL2.

### Network

* Outbound **HTTPS 443** to: `registry.agrospai.udl.cat` (node/market images),
  `registry-1.docker.io` + `auth.docker.io` (Elasticsearch image), `docker.elastic.co`,
  `api.pinata.cloud` / `gateway.pinata.cloud` (asset publishing), your RPC endpoint
  (default `https://sepolia.optimism.io`), `sepolia-faucet.pk910.de` (only for `./fund.sh`).
* Inbound: **8080** (marketplace UI) and **8000** (node HTTP API — the browser talks
  to it directly, and it carries the P2P endpoints used to federate with other
  nodes). Both are configurable in `customize.sh`. Keep **9200** (Elasticsearch)
  closed to the internet; it is published on localhost for diagnostics only.
* Publish assets only if the node URL is publicly reachable; using `localhost`
  works for a single-machine demo but other nodes cannot fetch from it.

### Starting from a fresh cloud VM

```bash
# 1. tools
sudo apt-get update && sudo apt-get install -y curl jq openssl lsof git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER" && newgrp docker
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs

# 2. code
git clone <this repo> ocean-enterprise-launcher && cd ocean-enterprise-launcher

# 3. configure (prompts; needs a Pinata JWT — see below), then launch
./customize.sh
./start.sh
```

Open the security-group / firewall for 8080 and 8000, then browse to
`http://<vm-ip>:8080`. Fully unattended installs:

```bash
echo 'my-keystore-password' > /root/oe.pw      # keep it out of the repo
./customize.sh --non-interactive --password-file /root/oe.pw \
  --node-url http://<vm-ip>:8000 --rpc-url https://sepolia.optimism.io \
  --ipfs-jwt "$PINATA_JWT" --no-start
./start.sh --head
```

See `./customize.sh --help` for every flag, `./start.sh --help` for launch
options, and [Troubleshooting](#troubleshooting) for the errors seen most often.

## Quick start

```bash
./customize.sh     # one-time setup: answers → .env + two encrypted keystores
./fund.sh          # optional: get test ETH without MetaMask (faucet + bridge)
./start.sh         # unlock the node key, ask the start block, compose up -d
```

`customize.sh` walks through every value the stack needs (ports, public node URL,
RPC, IPFS/Pinata, fees, owner info), **generates the wallet keys** and writes
`.env`. `start.sh` decrypts the node keystore at launch, so the private key is
never stored in clear text. The Docker daemon (Docker Desktop) must be running.

Requirements: `bash`, `docker` + `docker compose` v2, `curl`, `jq`, `openssl`,
`node`/`npm` (used once to install `ethers` into `.tools/` for keystore and
chain tooling). See [Requirements](#requirements) for versions, install commands
and the network/ports to open — the scripts refuse to run with a checklist of
what is missing.

## Configuration

* **Network:** OP Sepolia (`chainId 11155420`)
* **Main token:** devEURAU `0xD35141583f374d401fee1BFdDc35910E1D33a588`
  (from the [Supported Currencies](https://docs.oceanenterprise.io/developers/networks/supported-currencies) list)
* **RPC:** free public `https://sepolia.optimism.io` (swap in Alchemy/Infura key if rate-limited)
* **IPFS:** Pinata (`gateway.pinata.cloud` public gateway + pin/unpin endpoints)
* **Indexer start block:** on a first launch `start.sh` **asks** which block to
  start indexing from — Enter accepts the current head (index only new events),
  `week` replays ~7 days (302,400 blocks, ~2 h at ~45 blk/s), or type any block
  number. Non-interactive launches: `--start-block N` / `--week` / `--head`.
  The answer is stored in `.env`; afterwards the node resumes from its own index.

### Getting the Pinata JWT

Ocean's node pins DDOs as JSON, so `IPFS_JWT` must be a Pinata **JWT**, not an
API key. A Pinata API key is a short 20-character string; a JWT is one long
`eyJ….eyJ….…` token with two dots (~300–700 chars). Pasting the API key is the
usual cause of `IPFS upload has failed [uploadToIPFS]` at publish time (Pinata
answers `token is malformed: token contains an invalid number of segments`).

1. Sign in at <https://app.pinata.cloud> (free tier is enough).
2. Left sidebar → **API Keys** → **New Key** (top right).
3. Name it, and either tick **Admin**, or scope it to the endpoints the market
   needs: `pinJSONToIPFS`, `pinFileToIPFS`, `unpin`, `pinList`.
4. **Create Key** — the modal shows `pinata_api_key`, `pinata_api_secret_key`
   **and JWT**. Copy the **JWT** (or *Copy All*). It is shown only once.
5. Paste it and restart the market:

```bash
# fastest: rewrite just that line
sed -i.bak 's|^IPFS_JWT=.*|IPFS_JWT=eyJhbGciOi…|' .env && docker compose up -d --force-recreate ocean-market
# or re-run the configurator (keeps everything else)
./customize.sh --ipfs-jwt "eyJhbGciOi…"
```

`customize.sh` and `start.sh` now validate the value: they warn when it is not
JWT-shaped and, for `*.pinata.cloud` endpoints, when Pinata rejects it
(`data/testAuthentication`). To check by hand:

```bash
curl -s -H "Authorization: Bearer $IPFS_JWT" https://api.pinata.cloud/data/testAuthentication
```

### Interactive

```bash
./customize.sh
```

Press Enter to accept the default shown in brackets. On a re-run the current
`.env` is used as defaults and the previous file is kept as `.env.bak.<timestamp>`.

### Non-interactive

```bash
./customize.sh --non-interactive --password-file /run/secrets/oe-keystore-pw \
  --rpc-url https://sepolia.optimism.io \
  --node-url https://node.example.org \
  --ipfs-jwt "$PINATA_JWT" \
  --owner-name "Acme Data SL" --owner-email ops@acme.test \
  --market-fee 0.5 --market-percent 0.1 --dataspace acme
```

All flags are listed by `./customize.sh --help`. The keystore password can also
come from `$OE_KEYSTORE_PASSWORD` / `$OE_KEYSTORE_PASSWORD_FILE`, which is what
`start.sh` reads when it runs unattended.

### Variables written to `.env`

| Variable | Meaning |
|---|---|
| `OE_NODE_URL` | Node URL **as seen by the browser** (the market calls it client-side). No trailing slash: it is written into the DDO *and* used to filter the catalogue, so both must match |
| `MARKET_HTTP_PORT` / `NODE_HTTP_PORT` / `ES_HTTP_PORT` | Host ports (8080 / 8000 / 9200) |
| `RPC_URL`, `CHAIN_ID`, `CHAIN_NAME` | OP Sepolia endpoint + chain identity (verified live by `customize.sh`) |
| `DEVEURAU_ADDRESS` | Payment/fee token |
| `START_BLOCK` | Indexer window start; `start.sh` asks for it at launch (default: current head) and stores it |
| `IPFS_GATEWAY`, `IPFS_UPLOAD_URL`, `IPFS_DELETE_URL`, `IPFS_JWT` | Pinata; **publishing fails without a valid JWT** (see [Getting the Pinata JWT](#getting-the-pinata-jwt)) |
| `ELASTIC_PASSWORD` | Generated; must match what the Elasticsearch volume was created with |
| `NODE_KEYSTORE`, `ADMIN_KEYSTORE` | Paths to the encrypted keystores (`./secrets/`) |
| `NODE_ADDRESS`, `ADMIN_ADDRESS` | Derived addresses, for reference |
| `NODE_FEE_AMOUNT` | Node operator fee per purchase, e.g. `{"amount":1,"unit":"MB"}` |
| `ALLOWED_ADMINS` | JSON array with the admin address |
| `NODE_OWNER_INFO` | JSON imprint / T&C / privacy shown in the marketplace |
| `MARKET_FEE_ADDRESS` | Fee collector — **the node wallet** |
| `MARKET_ORDER_FEE_MAP` / `MARKET_PERCENT_FEE` | Fixed fee (in devEURAU wei) / percentage fee |
| `DATASPACE` | Catalogue tag filter (empty = off) |

`.env` is written with mode `0600` and is git-ignored; `.env.example` documents
the same variables with placeholder values.

## Wallet keys

`customize.sh` manages **two** keys:

| Key | Used for | Address goes to |
|---|---|---|
| **node key** | OE Node `PRIVATE_KEY` (encrypt at publish, decrypt at consume) | `MARKET_FEE_ADDRESS` (fee collector) |
| **admin key** | Administering the node API | `ALLOWED_ADMINS` |

Both are stored only as **Web3 Secret Storage V3 keystore JSON** files:

```
secrets/node.keystore.json    # chmod 600, scrypt-encrypted (aes-128-ctr)
secrets/admin.keystore.json
```

* Nothing in `.env` holds a private key. `start.sh` decrypts the node keystore in
  memory and exports `PRIVATE_KEY` for that `docker compose` run only.
* Password sources for `start.sh`, in order: `$OE_KEYSTORE_PASSWORD`,
  `$OE_KEYSTORE_PASSWORD_FILE`, interactive prompt (hidden input).
* **Bring your own key:** `customize.sh` asks whether you already have one, or
  pass `--private-key 0x…` / `--admin-key 0x…`. Provided keys are still written
  out as password-protected keystores.
* Re-running `customize.sh` **reuses** existing keystores; `--force-keys`
  replaces them (start a fresh index with `docker compose down -v` afterwards).
* The keystores are standard V3 JSON, so the admin key can be imported into
  MetaMask → *Add account → Import account → JSON*.
* **Back up `secrets/` and remember the password.** Without either, the keys are
  unrecoverable — the node key signs asset encryption/decryption.

## Launching

```bash
./start.sh                      # asks for the start block, then docker compose up -d
./start.sh --head               # no backfill: index from the current head (default answer)
./start.sh --week               # backfill the last ~7 days (302,400 blocks, ~2 h)
./start.sh --start-block 51200000
./start.sh --dry-run            # validate config and print the resolved compose file
```

The question is only asked while the node has no indexer state. To be asked
again, wipe the index:

```bash
docker compose down -v && rm -rf oe-node-databases
```

Watch the logs:

```bash
docker compose logs -f oe-node
docker compose logs -f ocean-market
```

First startup is slow when a backfill is chosen: OE Node waits for
Elasticsearch to become healthy, then replays the OP Sepolia events from the
chosen block (~45 blocks/s on a free RPC, so a 1-week window is ~2 h; indexing
from the head is immediate). The marketplace UI is served from :8080 meanwhile.

## Funding the wallets

For a user browser session, connect MetaMask to **OP Sepolia** and fund the
wallet with:

* OP Sepolia **ETH** (gas). Faucets that work for a brand-new wallet (no
  mainnet ETH, no reputation needed):
  1. **Superchain Faucet** — <https://console.optimism.io/faucet>: sign in with
     an email/Google/GitHub account (no onchain identity required), pick
     *OP Sepolia*, claim 0.01 test ETH per address every 24 h. Verifying an
     onchain identity raises the amount.
  2. **ETHGlobal Testnet Faucet** — <https://ethglobal.com/faucet>: free
     ETHGlobal account, 0.05 OP Sepolia ETH.
  3. **No account at all:** mine on the Sepolia PoW faucet
     <https://sepolia-faucet.pk910.de> (runs in the browser), then bridge the
     Sepolia ETH to OP Sepolia at <https://app.optimism.io/bridge/deposit>.
  Avoid Alchemy's faucets (require 0.001 ETH on Ethereum mainnet plus mainnet
  activity) and ethfaucet.com (BringID identity check) for new wallets.
* **devEURAU** tokens on OP Sepolia (the price currency)

### Getting that ETH without MetaMask: `./fund.sh`

The PoW faucet is the only open faucet, but it pays on **Sepolia L1**, so the ETH
has to be bridged. `fund.sh` does the whole loop with the launcher's own keys —
no browser wallet, no extension:

```bash
./fund.sh                    # admin wallet (default)
./fund.sh --target node      # the node wallet instead (it pays for publishing/decrypting)
./fund.sh --target all
./fund.sh --dry-run          # show addresses + deposit plan, send nothing
./fund.sh --bridge-only      # L1 already funded (or the claim landed late)
# bridge the admin wallet, then forward gas to the node wallet on OP Sepolia
./fund.sh --target admin --send-to <node-address> --send-amount 0.02
```

Only the faucet step needs a human (press *Start Mining* and pass one Cloudflare
check); the claim is picked up from the chain, so nothing has to be copied back
from the browser.

### Signing in to the marketplace with the admin wallet

The keystore is an ordinary V3 wallet file, so the marketplace can open it
directly — no MetaMask, no extension:

1. Open the market at `http://localhost:8080`.
2. **Account menu → Connect web3 wallet → Wallet file**.
3. Pick `secrets/admin.keystore.json` (or the file you brought yourself if you
   supplied `--admin-key`/`ADMIN_KEYSTORE`) and type the keystore password.

`fund.sh` prints this reminder — with the actual path — at the end of a run. The
wallet needs OP Sepolia ETH to publish or consume, and devEURAU tokens for the
asset operations the market exercises.

What it does: prints the wallet address, opens
`https://sepolia-faucet.pk910.de/?address=0x…` (address pre-filled — you only
press **Start Mining** and pass the one Cloudflare check), then polls the
Sepolia L1 balance. When the claim lands it signs
`L1StandardBridge.depositETHTo()` for OP Sepolia
(`0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1`) with that wallet's key, keeps
`--keep-eth` (0.002) on L1 for gas, and waits until the credit shows up on OP
Sepolia (usually 1–3 min). The keystore password is asked once, only for the
deposit.

`customize.sh` prints the node wallet balance at the end and warns when it has no
ETH: the node needs gas to publish/decrypt, and it also collects the node fees.
The admin wallet needs gas only for admin transactions.

The publisher sets a price in devEURAU; the consumer pays it plus the node fee
(`NODE_FEE_AMOUNT`) and the market fees. The node encrypts at publish / decrypts
at consume (`NEXT_PUBLIC_ENCRYPT_ASSET=true`, default for a marketplace backed by
an OE Node).

> For a trial on a single machine, the defaults (`OE_NODE_URL=http://localhost:8000`)
> work when the browser runs on the same host. For network/TLS access, set
> `OE_NODE_URL` to the node's public URL and put both services behind a
> TLS-terminating reverse proxy (docs "post installation steps").

## Compute-to-Data (C2D)

Enabled in `docker-compose.yml` with two Docker-engine environments on the local
daemon, sized for a laptop:

| Environment | Cost | vCPU / RAM / disk | Max job | Concurrent |
|---|---|---|---|---|
| `free` | free | 1 / 1 GB / 1 GB | 10 min | 1 |
| `paid` | devEURAU, price/minute | 2 / 3 GB / 5 GB (2 GB per job) | 30 min | 1 |

Job cost = `price × amount × ceil(minutes)`. The paid environment costs
`2×0.0001 + 3×0.0001 + 5×0.00001 = 0.00055` devEURAU per minute, so a 30-minute
job is ≈ `0.0165`. The paid token must be accepted by the chain's
`EnterpriseFeeCollector` (devEURAU is; the node validates at boot).

The node needs Docker control, hence `/var/run/docker.sock` is mounted — that is
equivalent to root on the host. To disable C2D, delete `DOCKER_COMPUTE_ENVIRONMENTS`
and the socket mount, then `docker compose up -d --force-recreate oe-node`.

Verify what the node advertises:

```bash
curl -s http://localhost:8000/api/services/computeEnvironments | jq -r '.[].description'
curl -s -X POST http://localhost:8000/directCommand \
  -H 'Content-Type: application/json' -d '{"command":"status","detailed":true}' | jq '.c2dClusters'
```

Then publish (or use) an asset whose DDO carries a **compute** service — the
asset's *Compute* tab lists both environments and the price is quoted from the
node's fee table before the job is queued.

## What is NOT included

* **SSI stack** (wallet, verifier), **Policy Server / Policy Server Proxy**,
  **Signer Server**, **User Management Package** — `NEXT_PUBLIC_SSI_ENABLED=false`
  and `POLICY_SERVER_URL` left empty, per the no-SSI deployment mode.
* **GPU / Kubernetes C2D clusters** — only the local Docker-engine environments
  above; `OPERATOR_SERVICE_URL` (OPF K8s) is not configured.
* **Reverse proxy / TLS** — add nginx/Caddy in front of 8080/8000 for anything
  beyond local testing.

## Files

```
customize.sh         # interactive/non-interactive configurator → .env + keystores
start.sh             # launcher: unlock node key, ask start block, compose up
fund.sh              # fund a wallet with OP Sepolia ETH (PoW faucet + bridge, no MetaMask)
scripts/lib.sh       # shared shell helpers
scripts/oe-keys.cjs  # keystore + chain tooling (node/ethers)
.env.example         # documented template (never holds real secrets)
.env                 # generated configuration (git-ignored, mode 0600)
secrets/             # encrypted keystores (git-ignored, mode 0700/0600)
.tools/              # ethers installed on first run (git-ignored)
docker-compose.yml   # the stack
oe-node-logs/        # node logs          (created at runtime)
oe-node-databases/   # node local state   (created at runtime)
oe-node-c2d-storage/ # C2D storage        (created at runtime)
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `cannot decrypt secrets/node.keystore.json — wrong password?` | Wrong keystore password; use the original one (or `--force-keys` to start over with new keys) |
| `docker compose` complains about the daemon | Start Docker Desktop / `dockerd` |
| `IPFS upload has failed [uploadToIPFS]` | `IPFS_JWT` empty, expired, or not a JWT (an API key pasted instead). Create a key at <https://app.pinata.cloud> → **API Keys → New Key** and copy the **JWT** field — see [Getting the Pinata JWT](#getting-the-pinata-jwt). Then `docker compose up -d --force-recreate ocean-market` |
| OE Node restarts after changing `ELASTIC_PASSWORD` | Elasticsearch keeps the old password: `docker compose down -v` to re-index |
| Node indexes for hours on a re-run | You chose a backfill window: `START_BLOCK` sits far behind head. Stop, wipe (`docker compose down -v && rm -rf oe-node-databases`) and relaunch answering Enter (current head) |
| Asset publishes ("success") but never appears in the catalogue; its own `/asset/did:ope:…` page works | (1) the DDO's `serviceEndpoint` must be **slash-free** — assets published while `NEXT_PUBLIC_PROVIDER_URL` ended in `/` need republishing; (2) the index was created by a node build that mapped `credentialSubject.services` as a **`nested`** field, so the market's plain `terms` filter on `…serviceEndpoint.keyword` can never match. Elasticsearch cannot change a mapping in place: rebuild the index with `docker compose down -v && ./start.sh` (reindexes from `START_BLOCK`) |
| Unsure what compose will run | `./start.sh --dry-run` |


## Teardown

```bash
docker compose down            # keep data
docker compose down -v         # also wipe Elasticsearch index (forces full re-index)
./customize.sh --force-keys    # rotate the keys afterwards, if you exposed them
```
