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

Requires a llama.cpp build of b10818 or newer: older `server-cuda` images
(e.g. May 2026) produce garbage output for this model via a DeltaNet CUDA
bug, and builds before b10818 reject Claude Code's tool schemas with
`Failed to initialize samplers: failed to parse grammar`. The chat template must be the matching relaxed Qwen3.8 file (see
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
| `REASONING`    | `auto`               | Thinking: `auto` follows the template, `off` disables it, `on` forces it |
| `CHAT_TEMPLATE_KWARGS` | `{}`         | Extra chat-template variables as a JSON object |
| `CACHE_TYPE_K` | `q8_0`               | KV-cache key quantisation (`f16`, `q8_0`) |
| `CACHE_TYPE_V` | `q8_0`               | KV-cache value quantisation               |
| `LLAMA_IMAGE`  | `ghcr.io/ggml-org/llama.cpp:server-cuda-b10818` | llama.cpp server image, pinned per build; the Jetson override pins the matching `llama-server-jetson` build |
| `MODELS_DIR`   | `./models`           | Host directory bind-mounted at `/models`  |
| `COMPOSE_FILE` | (unset)              | Extra compose files: Jetson override, observability add-on |
| `SIDECAR_MODEL_NAMES` / `SIDECAR_UPSTREAM` / `SIDECAR_CERTS_DIR` | (unset) | Forward selected model names to a second instance of this stack, see [sidecar](#sidecar-small-model-on-another-host) |
| `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` | `admin` / (required) | Grafana login (observability add-on) |
| `GRAFANA_ROOT_URL` | `https://localhost:8443/grafana/` | Public Grafana URL through nginx |
| `METRICS_RETENTION` / `LOGS_RETENTION` / `TRACES_RETENTION` | `30d` / `720h` / `720h` | Prometheus / Loki / Tempo retention |

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

## Small-model endpoint for Claude Code

Claude Code talks to one `ANTHROPIC_BASE_URL` for every model it uses, with
no per-model endpoint. To serve its Haiku-class model (background jobs such
as conversation summaries, plus anything run with `--model haiku`) from a
smaller, cheaper machine while the main model runs on the reference GPU,
nginx routes each inference request by the `model` field of its body
(`nginx/router.js`):

- `model` listed in `SIDECAR_MODEL_NAMES` -> `SIDECAR_UPSTREAM`, a second
  instance of this stack (see [sidecar](#sidecar-small-model-on-another-host))
- any other model -> local llama.cpp

Requests never leave the deployment: there is deliberately no pass-through
to a hosted API, so pointing a client here can never spend hosted-API
credit. To use a hosted model, point the client at that provider instead.

Routed paths are `/v1/messages`, `/v1/messages/count_tokens`,
`/v1/chat/completions`, `/v1/completions` and `/v1/embeddings`; everything
else (`/v1/models`, `/health`, `/grafana/`) stays local.

### Server side (Jetson Orin Nano 8 GB reference profile)

The small model is [Qwen3.5 4B](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF)
at UD-Q4_K_XL (2.7 GiB): it is trained for tool calling, its hybrid
Gated-DeltaNet/attention layout keeps the KV cache small at the long
contexts summarisation prompts carry, and it shares the llama.cpp build pin
and template lineage of the reference Qwen3.8 model.
`templates/qwen3.5-4b-relaxed.jinja` is its embedded template with the same
relaxations as the Qwen3.8 one. Measured on the Orin Nano with the full
stack idle, CUDA can allocate about 5.2 GiB; this quant at `CTX_SIZE=65536`
uses 2.9 GiB weights + 1.1 GiB KV + 0.2 GiB recurrent state + 0.4 GiB
compute and leaves ~1 GiB. Q6_K (3.8 GiB loaded) does not fit at any context
size worth having. Thinking is disabled with
`REASONING=off` (`--reasoning-budget 0` has no effect on this model):
background jobs are latency-bound and the model otherwise spends its whole
output budget reasoning.

```bash
# On the Jetson, after the Jetson section above:
./scripts/download-model.sh unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-UD-Q4_K_XL.gguf
```

```bash
# .env
MODEL_FILE=/models/Qwen3.5-4B-UD-Q4_K_XL.gguf
CHAT_TEMPLATE_FILE=/templates/qwen3.5-4b-relaxed.jinja
CTX_SIZE=65536
REASONING=off
```

`docker compose up -d` (nginx needs `--force-recreate` when only the routing
variables changed). The server certificate must carry the hostname clients
will use (`./scripts/setup.sh myjetson.lan` or regenerate it, see
[TLS certificates](#tls-certificates-mutual-tls)). The same profile works on
any host running this stack; only the model sizing is Jetson-specific.

### Sidecar: small model on another host

The small model can run on a different machine than the front door, e.g. the
main stack on a workstation serving the reference model and a Jetson serving
the small-model profile above. Clients then keep a single endpoint and a
single client certificate. In the front door's `.env`:

```bash
SIDECAR_MODEL_NAMES=qwen3.5-4b
SIDECAR_UPSTREAM=https://myjetson.lan:8443
SIDECAR_CERTS_DIR=/home/me/.config/local-llm/jetson
```

nginx resolves the upstream through Docker DNS, which does not apply the
host's search domains, so use a resolvable FQDN in `SIDECAR_UPSTREAM`. If the
sidecar's server certificate lists a different name in its SANs (e.g. the
bare hostname), set `SIDECAR_TLS_NAME` to a SAN name; it defaults to the
`SIDECAR_UPSTREAM` host.

`SIDECAR_CERTS_DIR` holds `ca.crt`, `client.crt` and `client.key` issued by
the sidecar's own CA (`./scripts/gen-certs.sh --client NAME` on the sidecar,
renamed to `client.crt`/`client.key`); keep it outside this repository. nginx
presents that certificate to the sidecar and verifies the sidecar's server
certificate against `ca.crt`. The sidecar serves any model name locally, so
no configuration is needed there; an empty `SIDECAR_UPSTREAM` disables the
leg here.
Apply with `docker compose up -d --force-recreate nginx`; `llama-server` is
not touched. Requests on this leg appear with `"route":"sidecar"` in the
access log.

Use a name of your own for the small model (`qwen3.5-4b` above) rather than
an Anthropic model ID: Claude Code is told the name through
`ANTHROPIC_DEFAULT_HAIKU_MODEL`, so the routing stays valid when Anthropic
renames its models.

### Client side

On the server, issue a certificate for the client machine and print its
configuration:

```bash
./scripts/claude-code-client.sh laptop myjetson.lan
```

It copies `ca.crt`, `laptop.crt` and `laptop.key` to the client's
`~/.config/local-llm/` and prints the `env` block for the client's
`~/.claude/settings.json`:

```json
"env": {
  "ANTHROPIC_BASE_URL": "https://myjetson.lan:8443",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": "qwen3.5-4b",
  "ENABLE_TOOL_SEARCH": "true",
  "CLAUDE_CODE_CLIENT_CERT": "/home/me/.config/local-llm/laptop.crt",
  "CLAUDE_CODE_CLIENT_KEY": "/home/me/.config/local-llm/laptop.key",
  "NODE_EXTRA_CA_CERTS": "/home/me/.config/local-llm/ca.crt"
}
```

Set `ANTHROPIC_AUTH_TOKEN` to any placeholder (e.g. `not-needed`): mTLS is
the real access control and no request is ever forwarded to a hosted API, so
no hosted credential belongs in this configuration. Verify with
`claude --model haiku -p 'reply with pong'`; the nginx access log shows
`upstream_status` from llama.cpp. `claude --debug` prints
`mTLS: Loaded client certificate` on startup.

`ENABLE_TOOL_SEARCH=true` is not optional: a non-first-party
`ANTHROPIC_BASE_URL` turns MCP tool search off, so Claude Code sends every
MCP tool schema upfront, and llama.cpp b10499 turns some of them (e.g. a
`format: date` string) into a grammar it then fails to parse, answering
`400 Failed to initialize samplers`. With tool search on, MCP tools arrive as
`tool_reference` blocks, which this proxy forwards untouched. Other
consequences of a non-first-party base URL (Claude Code docs): Remote
Control is disabled, fast-mode and WebFetch safety checks still call
`api.anthropic.com` directly, `--model haiku` warns that the model ID is
unrecognised and assumes a 200k window, and all Claude Code traffic now
depends on this server being up. The access log records `model` and `route`
(`local`/`sidecar`) per request.

Measured on the Orin Nano in its default 15 W mode (`nvpmodel` mode 0, GPU
capped at 612 MHz): 280 prompt tok/s and 7 tok/s decode; a `--model haiku`
turn carrying Claude Code's built-in tool set (~16k tokens) takes ~55 s
before the first token, and background jobs are shorter. Switch to
`MAXN_SUPER` (`sudo nvpmodel -m 2 && sudo jetson_clocks`) and boot headless
(`sudo systemctl set-default multi-user.target`, the desktop holds ~0.5 GiB)
before judging latency; both need root and were not applied on the test
device.

## Observability (metrics, logs, traces, dashboards)

`docker-compose.observability.yml` adds a Prometheus + Loki + Tempo + Grafana
stack that joins the same Docker network. Nothing in it publishes a host port:
Grafana is served by nginx under `/grafana/` on the existing mTLS vhost, so the
same client certificates gate it, and the OTLP ingest path below sits behind
the same vhost.

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
| Claude Code sessions (metrics, events, traces) | OTLP over HTTPS at `/otlp/` | Grafana Alloy -> Prometheus, Loki, Tempo |

The nginx access log is JSON (status, timings, bytes, client certificate CN,
user agent, routing leg and model, upstream status and connect/header times,
and the W3C `traceparent` header when the client sends one),
so Loki can derive per-client request rates, latency percentiles and error
counts without extra exporters. On the inference legs `nginx/router.js` also
observes the response body without altering it and logs the usage block the
backend reports (`usage_input`, `usage_output`, `usage_cache_read`,
`usage_cache_creation`, in the backend's own convention: Anthropic
`input_tokens` exclude cached tokens, OpenAI-format `prompt_tokens` include
them) and llama.cpp's `timings` (`usage_prompt_ms`, `usage_predicted_ms`).
This gives per-client, per-model and per-route token accounting across the
local, sidecar and hosted legs; compressed responses (`Content-Encoding`) are
not parsed and leave the fields empty. The "Routing" row of the nginx
dashboard is built on these fields. Provisioned dashboards live in
`observability/grafana/dashboards/` and are read-only in the UI; they are
produced by `observability/grafana/gen-dashboards.py`, so edit that script and
rerun it, Grafana reloads the files automatically.

Retention is `METRICS_RETENTION` (Prometheus), `LOGS_RETENTION` (Loki) and
`TRACES_RETENTION` (Tempo); data lives in the `prometheus-data`, `loki-data`,
`tempo-data` and `grafana-data` volumes.

### Claude Code telemetry

Claude Code can export its own OpenTelemetry metrics, events and traces. nginx
accepts them at `/otlp/` on the mTLS vhost (not access-logged, the exports are
periodic) and hands them to Alloy, which fans them out: metrics to Prometheus's
native OTLP receiver, events to Loki's OTLP endpoint, spans to Tempo. Client
settings, in `~/.claude/settings.json` on each machine that has a client
certificate:

```json
"env": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_TRACES_EXPORTER": "otlp",
  "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "https://<host>:8443/otlp",
  "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "cumulative",
  "OTEL_RESOURCE_ATTRIBUTES": "gen_ai.provider.name=llama_cpp",
  "NODE_EXTRA_CA_CERTS": "/home/me/.config/local-llm/ca.crt",
  "CLAUDE_CODE_CLIENT_CERT": "/home/me/.config/local-llm/laptop.crt",
  "CLAUDE_CODE_CLIENT_KEY": "/home/me/.config/local-llm/laptop.key"
}
```

The exporter uses the same client certificate variables as the inference
connection, so a session that talks to `api.anthropic.com` can still export
here as long as those three variables are set. `cumulative` temporality is what
Prometheus's receiver ingests without its experimental delta conversion. Every
session is its own set of series (`session_id` label), and a counter that
appears with a non-zero first value is invisible to `increase()`, so Prometheus
runs with `created-timestamp-zero-ingestion`: the OTLP start timestamp becomes
a zero sample just before the first export, and rates and increases count the
whole session. Range totals in the dashboard use
`last_over_time - min_over_time` per series rather than `increase`, which
extrapolates.
Traces are a Claude Code beta behind `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA`;
`CLAUDE_CODE_PROPAGATE_TRACEPARENT=1` additionally makes the client send its
`traceparent` header to this proxy, which the access log records.

Two attributes tell sessions apart in every dashboard:

- `gen_ai.provider.name`, set by the client in `OTEL_RESOURCE_ATTRIBUTES`
  (`anthropic` for the hosted API, `llama_cpp` for this stack). Claude Code
  emits nothing that says which backend served a session, and the per-request
  `model` name does not reach the session-level metrics, so the client has to
  say it.
- `host.name`, which Claude Code's resource does not carry either. Alloy takes
  it from an `X-Host-Name` request header, so a client sets it with an
  `otelHeadersHelper` script in `settings.json` that prints
  `{"X-Host-Name": "<hostname>"}`.

Both become Prometheus labels (`gen_ai_provider_name`, `host_name`), Loki
stream labels and Tempo resource attributes. Events land in Loki as the stream
`{service_name="claude-code"}` with every event attribute in structured
metadata (`| event_name="api_request"`), and carry `trace_id`, which the Loki
datasource links to Tempo. What the events contain is decided on the client:
`OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_TOOL_DETAILS`, `OTEL_LOG_ASSISTANT_RESPONSES`,
`OTEL_LOG_TOOL_CONTENT` and `OTEL_LOG_RAW_API_BODIES` each default to off and
are honoured as `0`/`1`. Note that `claude_code.cost.usage` and the
`cost_usd` event attribute are Claude Code's estimate at Anthropic list prices
for whatever model name it saw, so for `llama_cpp` sessions they are not a
cost; the "Claude Code" dashboard only sums them for `anthropic`.

### Sidecar metrics

A [sidecar host](#sidecar-small-model-on-another-host) is monitored by the
same stack without running Prometheus there. On the sidecar, append
`:docker-compose.metrics.yml` to `COMPOSE_FILE`: it adds node-exporter,
nginx-exporter and, on Jetson hardware, a small Tegra exporter
(`jetson/tegra-exporter/`, iGPU load and frequency plus INA3221 rail power;
temperatures and the rest come from node-exporter). nginx exposes them under
the mTLS vhost as `/metrics/llama`, `/metrics/node`, `/metrics/nginx` and
`/metrics/tegra` (resolved at request time, not access-logged), so the only
open port stays 8443 and the client-certificate CA is the only access
control.

On the host running Prometheus, drop a scrape file into
`observability/prometheus/scrape.d/` (gitignored; start from
`sidecar.yml.example`): it scrapes those paths over HTTPS with the client
credentials from `SIDECAR_CERTS_DIR`, which the observability compose file
mounts read-only into the Prometheus container. Then
`docker compose up -d --force-recreate prometheus`. The provisioned
"Jetson sidecar" dashboard reads the `jetson-*` job names used in the
example.

## NVIDIA Jetson (Orin / JetPack 6)

The stack also runs on Jetson Orin devices (tested on an Orin Nano Super
Developer Kit, L4T r36.4.7 / CUDA 12.6). The upstream `server-cuda` image does
not work there: its arm64 variant is built with CUDA 12.8 for server-class
GPUs and ships no `sm_87` cubin, so model load aborts with *"the provided PTX
was compiled with an unsupported toolchain"*. `jetson/Dockerfile` instead
builds the same pinned llama.cpp build against the L4T CUDA toolchain with a
native `sm_87` kernel image and the Orin's CPU target. The
`jetson-image` workflow builds it on a GitHub arm64 runner and publishes
`ghcr.io/mconcas/local-llm-setup/llama-server-jetson:bNNNN`, which
`docker-compose.jetson.yml` pins; nothing is compiled on the device.

```bash
# On the Jetson (requires JetPack 6 and Docker with the nvidia runtime):
./scripts/setup.sh myjetson.lan
echo 'COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml' >> .env

docker compose up -d
curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
  https://localhost:8443/v1/models
```

Upgrading llama.cpp: the workflow runs weekly, resolves the newest upstream
release to the nearest published `server-cuda-bNNNN` image, builds the Jetson
image for that same build and opens a pull request pinning both compose
defaults. Run it manually with `gh workflow run jetson-image -f
llama_cpp_ref=bNNNN` for a specific build. To build on the device instead
(offline, or a fork without the workflow):

```bash
docker build --build-arg LLAMA_CPP_REF=bNNNN -t local/llama-server-jetson:bNNNN jetson
echo 'LLAMA_IMAGE=local/llama-server-jetson:bNNNN' >> .env
```

Sizing for an 8 GB Orin Nano, where CPU and GPU share ~7.4 GiB of unified
memory and the OS takes about 1 GiB:

- 4B-class Q4 models fit with all layers offloaded and a 64k context; 7-8B
  Q4 fits only with a small `CTX_SIZE` and `q8_0` KV cache.
- The override sets `LLAMA_ARG_LOAD_MODE=dio`: an mmap-loaded GGUF keeps a
  second copy of the weights in page cache that the Tegra allocator never
  reclaims, so the KV-cache allocation fails with `cudaMalloc out of memory`
  while `free` still reports gigabytes available.
- Keep `PARALLEL` at 1-2; each slot multiplies KV-cache memory.
- Models of 24B class and above, including the reference Qwen3.8 27B, do not
  fit; do not reuse an `.env` sized for a discrete-GPU host.

The sized, tested profile for this board is the
[Claude Code small-model endpoint](#small-model-endpoint-for-claude-code).

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
