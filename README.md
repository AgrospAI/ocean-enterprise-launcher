# Ocean Enterprise Launcher — Marketplace + OE Node (no SSI)

Docker Compose stack deploying the [Ocean Enterprise](https://docs.oceanenterprise.io/infrastructure)
core for a working dataspace where assets can be **published and consumed**, with
**SSI-based access control disabled** (address-based verification only).

| Component     | Image                              | URL                          |
|---------------|------------------------------------|------------------------------|
| Marketplace   | `oceanenterprise/market:v1.5.2`    | http://localhost:8008        |
| OE Node       | `oceanenterprise/oe-node:v4.2.1`   | http://localhost:8000        |
| Elasticsearch | `elasticsearch:8.19.3` (internal)  | :9200 (diagnostics only)     |

Versions are fixed per the OE [Compatibility Matrix](https://docs.oceanenterprise.io/infrastructure/compatibility-matrix)
(market v1.5.1/v1.5.2 ↔ OE Node v4.2.1).

## Configuration

* **Network:** OP Sepolia (`chainId 11155420`)
* **Main token:** devEURAU `0xD35141583f374d401fee1BFdDc35910E1D33a588`
  (from the [Supported Currencies](https://docs.oceanenterprise.io/developers/networks/supported-currencies) list)
* **RPC:** free public `https://sepolia.optimism.io` (swap in Alchemy/Infura key if rate-limited)
* **IPFS:** Pinata (`gateway.pinata.cloud` public gateway + pin/unpin endpoints)
* **Indexer start block:** on first launch `start.sh` sets `START_BLOCK` to the
  current OP Sepolia head block minus ~1 week (302,400 blocks @ ~2 s/block)

Everything is configured in a single file: **`.env`**. Items are marked:

* `[CUSTOMIZE]` — review before any real deployment (hostnames, ports, fees, owner info…)
* `[PLACEHOLDER]` — fabricated value with an obvious fake pattern that **must** be
  replaced for the stack to work in production:
  * `NODE_PRIVATE_KEY` — fabricated key `0x0001…3f` (bytes 0x00→0xff). Generate: `openssl rand -hex 32`
  * `ELASTIC_PASSWORD` / `DB_PASSWORD` — fabricated pattern. Generate: `openssl rand -base64 24`
  * `IPFS_JWT` — **request a free token** at <https://app.pinata.cloud> (API Keys → JWT).
    Without it, asset publishing from the marketplace fails at the DDO pin step.
  * `MARKET_FEE_ADDRESS` / `ALLOWED_ADMINS` — fabricated `0x2222…` / `0x1111…` addresses.

## Quick start

```bash
# 1. Fill the [PLACEHOLDER] items in .env (at minimum: IPFS_JWT, NODE_PRIVATE_KEY,
#    ELASTIC_PASSWORD — the stack is not functional without them)
# 2. Launch (computes startBlock = head − 1 week on first run, then docker compose up -d)
./start.sh
```

Watch the logs:

```bash
docker compose logs -f oe-node
docker compose logs -f ocean-market
```

First startup is slow: OE Node waits for Elasticsearch to become healthy, then
indexes one week of OP Sepolia events. The marketplace UI is served from :8008
while the node indexes.

## Publishing & consuming

For a user browser session, connect MetaMask to **OP Sepolia** and fund the
wallet with:

* OP Sepolia **ETH** (gas) — faucet: <https://communityfaucet.superalpha.legal/>
* **devEURAU** tokens on OP Sepolia (the price currency)

The publisher sets a price in devEURAU; the consumer pays it plus the node fee
(`FEE_AMOUNT` in `.env`). The node encrypts at publish / decrypts at consume
(`NEXT_PUBLIC_ENCRYPT_ASSET=true`, default for a marketplace backed by an OE Node).

> For a trial on a single machine, the defaults (`OE_NODE_URL=http://localhost:8000`)
> work when the browser runs on the same host. For network/TLS access, set
> `OE_NODE_URL` to the node's public URL and put both services behind a
> TLS-terminating reverse proxy (docs "post installation steps").

## What is NOT included

* **SSI stack** (wallet, verifier), **Policy Server / Policy Server Proxy**,
  **Signer Server**, **User Management Package** — `NEXT_PUBLIC_SSI_ENABLED=false`
  and `POLICY_SERVER_URL` left empty, per the no-SSI deployment mode.
* **Compute-to-Data** — add a `DOCKER_COMPUTE_ENVIRONMENTS` value and mount
  `/var/run/docker.sock` (commented in `docker-compose.yml`) to enable it.
* **Reverse proxy / TLS** — add nginx/Caddy in front of 8008/8000 for anything
  beyond local testing.

## Files

```
docker-compose.yml   # the stack (marked with [CUSTOMIZE]/[PLACEHOLDER])
.env                 # all tunables (marked with [CUSTOMIZE]/[PLACEHOLDER])
start.sh             # first-launch helper: startBlock = head − 1 week, then compose up
oe-node-logs/        # node logs          (created at runtime)
oe-node-databases/   # node local state   (created at runtime)
oe-node-c2d-storage/ # C2D storage        (created at runtime)
```

## Teardown

```bash
docker compose down            # keep data
docker compose down -v         # also wipe Elasticsearch index (forces full re-index)
```
