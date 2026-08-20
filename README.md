# llama.cpp Local Server

A reproducible, Docker Compose-based setup for running a local LLM server via
[llama.cpp](https://github.com/ggerganov/llama.cpp) with **NVIDIA GPU
acceleration**, **mutual TLS** (clients authenticate with certificates), and an
**OpenAI-compatible API**.

## Architecture

```
Clients (curl, SDKs, agent frameworks)
        │
        ▼  HTTPS :8443 (mTLS: client cert required)
┌───────────────────┐
│   nginx (mTLS)    │  ← terminates TLS, verifies client certs, forwards to llama.cpp
└───────┬───────────┘
        │  HTTP :8080 (internal)
┌───────▼───────────┐
│  llama.cpp server │  ← CUDA GPU inference
│  (OpenAI API)     │
└───────────────────┘
        │
    ./models/        ← local GGUF model files (bind-mounted)
```

## Quick Start

```bash
# 1. Clone and enter the repo
git clone <this-repo> && cd local-llm-setup

# 2. Run the setup script (generates CA, server and client certs, checks
#    prerequisites). Pass extra hostnames/IPs for the TLS certificate SANs:
./scripts/setup.sh myserver.lan 10.0.0.5

# 3. Download the reference model (or place another .gguf in ./models/)
./scripts/download-model.sh \
  bartowski/Qwen3.8-27B-GGUF \
  Qwen3.8-27B-Q6_K.gguf

# 4. The default .env already points at the reference model; for any other
#    model set MODEL_FILE and a matching CHAT_TEMPLATE_FILE in .env

# 5. Start the stack
docker compose up -d

# 6. Verify (mTLS: the client cert is mandatory)
curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
  https://localhost:8443/v1/models
```

## Reference model

The documented deployment target is
[Qwen3.8 27B](https://huggingface.co/bartowski/Qwen3.8-27B-GGUF), a dense 27B
reasoning model, quantised to Q6_K (22 GiB, bartowski GGUF). The GGUF is
served text-only in this stack (no vision projector is wired in).

Sizing on a 32 GB GPU (measured on an RTX 5090): the model's native context
is 262144 tokens, but the full window does not fit next to the Q6_K weights.
`CTX_SIZE=131072` with `CACHE_TYPE_K/V=q8_0` totals ~27.2 GiB of VRAM and is
the largest power-of-two window that fits; decode runs at ~60 tok/s. The
model emits thinking output, so give clients a generous `max_tokens`.
Sampling defaults ship in the GGUF (temperature 1.0, top_k 20, top_p 0.95).

Requires a llama.cpp build of b10499 or newer: older `server-cuda` images
(e.g. May 2026) produce garbage output for this model via a DeltaNet CUDA
bug. The chat template must be the matching relaxed Qwen3.8 file (see
`CHAT_TEMPLATE_FILE` in `.env.example`);
`templates/devstral-small-2-relaxed.jinja` remains available for the previous
Devstral Small 2 reference model.

Any other GGUF model works; see the note under
[agent frameworks](#using-as-the-backend-for-an-agent-framework) before
swapping the model on a tuned agent deployment.

## Configuration

All settings live in `.env` (created from `.env.example` by the setup script):

| Variable       | Default              | Description                               |
|----------------|----------------------|-------------------------------------------|
| `MODEL_FILE`   | Qwen3.8 27B Q6_K     | Path to model inside the container        |
| `CTX_SIZE`     | `131072`             | Context window size (tokens)              |
| `GPU_LAYERS`   | `-1`                 | Layers offloaded to GPU (`-1` = all)      |
| `PARALLEL`     | `1`                  | Concurrent request slots                  |
| `HTTPS_PORT`   | `8443`               | Port exposed for HTTPS                    |
| `CACHE_TYPE_K` | `q8_0`               | KV-cache key quantisation (`f16`, `q8_0`) |
| `CACHE_TYPE_V` | `q8_0`               | KV-cache value quantisation               |
| `LLAMA_IMAGE`  | `ghcr.io/ggml-org/llama.cpp:server-cuda` | llama.cpp server image |
| `MODELS_DIR`   | `./models`           | Host directory bind-mounted at `/models`  |
| `COMPOSE_FILE` | (unset)              | Extra compose files: Jetson override, observability add-on |
| `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` | `admin` / (required) | Grafana login (observability add-on) |
| `GRAFANA_ROOT_URL` | `https://localhost:8443/grafana/` | Public Grafana URL through nginx |
| `METRICS_RETENTION` / `LOGS_RETENTION` | `30d` / `720h` | Prometheus / Loki retention |

Setting both cache types to `q8_0` halves KV-cache memory versus `f16`; this
is what lets `CTX_SIZE=131072` fit alongside the reference model's Q6_K
weights on a 32 GB GPU. With `PARALLEL>1` llama.cpp divides `CTX_SIZE` across
slots, shrinking the real per-request window.

## OpenAI-Compatible API

llama.cpp exposes these OpenAI-compatible endpoints:

| Endpoint                   | Method | Description              |
|---------------------------|--------|--------------------------|
| `/v1/models`              | GET    | List loaded models       |
| `/v1/chat/completions`    | POST   | Chat completions         |
| `/v1/completions`         | POST   | Text completions         |
| `/v1/embeddings`          | POST   | Text embeddings          |

### Example: Chat Completion

```bash
curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
  https://localhost:8443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "any",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello!"}
    ],
    "stream": true
  }'
```

### Connecting from another machine on the network

Issue a dedicated certificate per client machine and copy it over together
with the CA certificate:

```bash
# On the server:
./scripts/gen-certs.sh --client laptop
scp certs/ca.crt certs/laptop.crt certs/laptop.key user@laptop:

# On the client:
curl --cacert ca.crt --cert laptop.crt --key laptop.key \
  https://10.0.0.5:8443/v1/models

# Optionally trust the CA system-wide (Debian/Ubuntu) to drop --cacert:
sudo cp ca.crt /usr/local/share/ca-certificates/llama-local-ca.crt
sudo update-ca-certificates
```

### Using with an OpenAI-compatible client

Point the client at:

```
Base URL:  https://<server-ip>:8443/v1
API Key:   (any string - authentication is the client certificate, not a key)
```

The client must support both a custom CA and a client certificate:
- Python `requests`: `verify="ca.crt"`, `cert=("client.crt", "client.key")`
- Python OpenAI SDK: pass an `httpx.Client(verify="ca.crt", cert=(...))`
- Node.js: `https.Agent({ca, cert, key})` on the HTTP client; the
  `NODE_EXTRA_CA_CERTS` env var covers only the CA half
- Clients that cannot present a client certificate cannot connect

### Using as the backend for an agent framework

Any client that accepts a custom `base_url`, a dummy API key, and TLS client
credentials (OpenAI SDK, LangChain, custom tool-calling loops) can use the
HTTPS endpoint above.

- Use a model trained for tool/function calling, and verify with a
  tool-calling probe before relying on it; correct parsing also depends on the
  model's chat template being applied (see `LLAMA_ARG_JINJA` in
  `docker-compose.yml`).
- Do not change `MODEL_FILE` on a working agent deployment without re-running
  its benchmark: prompts tuned against one model can regress badly on another
  even when the new model's tool calling is mechanically better. A measured
  case is recorded in git history (`git show de9bed3:MODEL-TRIAL.md`).
- `PARALLEL` caps concurrent requests; each slot consumes additional KV-cache
  memory.

## Observability (metrics, logs, dashboards)

`docker-compose.observability.yml` adds a Prometheus + Loki + Grafana stack that
joins the same Docker network. Nothing in it publishes a host port: Grafana is
served by nginx under `/grafana/` on the existing mTLS vhost, so the same client
certificates gate it.

```bash
# .env
COMPOSE_FILE=docker-compose.yml:docker-compose.observability.yml
GRAFANA_ADMIN_PASSWORD=<choose one>
GRAFANA_ROOT_URL=https://<public host>:8443/grafana/

docker compose up -d
```

Then open `https://<host>:8443/grafana/` with the client certificate loaded in
the browser (import `client.crt` + `client.key` as a PKCS#12 bundle:
`openssl pkcs12 -export -in certs/client.crt -inkey certs/client.key -out client.p12`).

| Signal | Source | Collector |
|--------|--------|-----------|
| Inference metrics (tokens/s, prompt vs decode time, queue, cache hits) | llama.cpp `/metrics` | Prometheus |
| Proxy metrics (connections, request rate) | nginx `stub_status` on an internal port | nginx-prometheus-exporter |
| GPU (utilisation, VRAM, power, temperature, clocks, PCIe) | NVIDIA DCGM | dcgm-exporter |
| Host CPU / memory / disk / network | node-exporter | Prometheus |
| Per-container CPU / memory / network | cAdvisor | Prometheus |
| Logs of every container in this project | Docker log driver | Grafana Alloy -> Loki |

The nginx access log is JSON (status, timings, bytes, client certificate CN,
user agent), so Loki can derive per-client request rates, latency percentiles
and error counts without extra exporters. Provisioned dashboards live in
`observability/grafana/dashboards/` and are read-only in the UI; they are
produced by `observability/grafana/gen-dashboards.py`, so edit that script and
rerun it, Grafana reloads the files automatically.

Retention is `METRICS_RETENTION` (Prometheus) and `LOGS_RETENTION` (Loki); data
lives in the `prometheus-data`, `loki-data` and `grafana-data` volumes.

## NVIDIA Jetson (Orin / JetPack 6)

The stack also runs on Jetson Orin devices (tested on an Orin Nano Super
Developer Kit, L4T r36.4.7 / CUDA 12.6). The upstream `server-cuda` image does
not work there: its arm64 variant is built with CUDA 12.8 for server-class
GPUs and ships no `sm_87` cubin, so model load aborts with *"the provided PTX
was compiled with an unsupported toolchain"*. `jetson/Dockerfile` instead
builds the same pinned llama.cpp release on the device, against the L4T CUDA
toolchain and with a native `sm_87` kernel image.

```bash
# On the Jetson (requires JetPack 6 and Docker with the nvidia runtime):
./scripts/setup.sh myjetson.lan
echo 'COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml' >> .env

docker compose build     # one-time on-device build of llama-server
docker compose up -d
curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
  https://localhost:8443/v1/models
```

Sizing for an 8 GB Orin Nano, where CPU and GPU share ~7.4 GiB of unified
memory and the OS takes about 1 GiB:

- 4B-class Q4_K_M models fit with all layers offloaded; 7-8B Q4 fits only
  with a small `CTX_SIZE` and `q8_0` KV cache.
- Keep `PARALLEL` at 1-2; each slot multiplies KV-cache memory.
- Models of 24B class and above, including the reference Qwen3.8 27B, do not
  fit; do not reuse an `.env` sized for a discrete-GPU host.

## TLS Certificates (mutual TLS)

nginx requires every client to present a certificate signed by the local CA
(`ssl_verify_client on`); connections without one are rejected with HTTP 400
before reaching llama.cpp. The setup script generates all of this in `./certs/`:

| File          | Purpose                                             |
|--------------|-----------------------------------------------------|
| `ca.crt`     | CA certificate - distribute to clients              |
| `ca.key`     | CA private key - keep secret, signs all certs       |
| `server.crt` | Server certificate (used by nginx)                  |
| `server.key` | Server private key (used by nginx)                  |
| `client.crt` | Default client certificate                          |
| `client.key` | Default client private key                          |

Issue one certificate per client so they can be distributed and replaced
independently:

```bash
./scripts/gen-certs.sh --client laptop   # writes certs/laptop.{crt,key}
```

To regenerate the server certificate (e.g., with new SANs), delete only the
server pair - the CA is reused, so existing client certs stay valid:

```bash
rm certs/server.crt certs/server.key
./scripts/gen-certs.sh myserver.lan 10.0.0.5 192.168.1.100
docker compose up -d --force-recreate nginx
```

Deleting the whole `certs/` directory discards the CA and invalidates every
distributed client certificate and CA trust store - only do that to evict a
client, since there is no certificate revocation list: re-key the CA, reissue
the remaining client certs, and redistribute.

Certificates expire: the CA after 10 years, server and client certs after
~825 days. Reissue and redistribute before expiry; the failure mode is sudden
TLS errors on all clients. Config changes to `nginx/nginx.conf` or `certs/`
need `docker compose up -d --force-recreate nginx` (a plain reload keeps the
old bind-mounted file).
