# llama.cpp Local Server

A reproducible, Docker Compose-based setup for running a local LLM server via
[llama.cpp](https://github.com/ggerganov/llama.cpp) with **NVIDIA GPU
acceleration**, **TLS encryption**, and an **OpenAI-compatible API**.

## Architecture

```
Clients (MCP server, curl, etc.)
        │
        ▼  HTTPS :8443
┌───────────────────┐
│   nginx (TLS)     │  ← terminates TLS, forwards to llama.cpp
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

# 2. Run the setup script (generates TLS certs, checks prerequisites)
#    Pass extra hostnames/IPs for the TLS certificate SANs:
./scripts/setup.sh myserver.lan 10.0.0.5

# 3. Download the reference model (or place another .gguf in ./models/)
./scripts/download-model.sh \
  unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF \
  Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf

# 4. Point .env to your model
sed -i 's|MODEL_FILE=.*|MODEL_FILE=/models/Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf|' .env

# 5. Start the stack
docker compose up -d

# 6. Verify
curl --cacert certs/ca.crt https://localhost:8443/v1/models
```

## Reference model

The documented deployment target is
[Devstral Small 2 24B Instruct (2512)](https://huggingface.co/mistralai/Devstral-Small-2-24B-Instruct-2512),
Mistral AI's open-weight (Apache 2.0) agentic coding model, quantised to
Q4_K_M (14.3 GB, [unsloth GGUF](https://huggingface.co/unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF)).

Sizing on a 32 GB GPU: the model's native context is 262144 tokens, but its KV
cache costs ~80 KB/token at `q8_0` (40 layers, 8 KV heads, head dim 128), so
the full window does not fit next to the weights. `CTX_SIZE=131072` with
`CACHE_TYPE_K/V=q8_0` uses ~10.5 GB of KV cache for a total of ~27 GB and is
the largest power-of-two window that fits. Mistral recommends sampling at
temperature 0.15 (a client-side setting).

Any other GGUF model works; see the note under
[agent frameworks](#using-as-the-backend-for-an-agent-framework) before
swapping the model on a tuned agent deployment.

## Configuration

All settings live in `.env` (created from `.env.example` by the setup script):

| Variable       | Default              | Description                               |
|----------------|----------------------|-------------------------------------------|
| `MODEL_FILE`   | Devstral Small 2 Q4_K_M | Path to model inside the container     |
| `CTX_SIZE`     | `131072`             | Context window size (tokens)              |
| `GPU_LAYERS`   | `-1`                 | Layers offloaded to GPU (`-1` = all)      |
| `PARALLEL`     | `1`                  | Concurrent request slots                  |
| `HTTPS_PORT`   | `8443`               | Port exposed for HTTPS                    |
| `CACHE_TYPE_K` | `q8_0`               | KV-cache key quantisation (`f16`, `q8_0`) |
| `CACHE_TYPE_V` | `q8_0`               | KV-cache value quantisation               |
| `LLAMA_IMAGE`  | `ghcr.io/ggml-org/llama.cpp:server-cuda` | llama.cpp server image |
| `MODELS_DIR`   | `./models`           | Host directory bind-mounted at `/models`  |
| `COMPOSE_FILE` | (unset)              | Extra compose files, e.g. the Jetson override |

Setting both cache types to `q8_0` halves KV-cache memory versus `f16`; this
is what lets `CTX_SIZE=131072` fit alongside the reference model's Q4_K_M
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
curl --cacert certs/ca.crt https://localhost:8443/v1/chat/completions \
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

```bash
# On the client, use the server's IP/hostname and trust the CA cert:
curl --cacert ca.crt https://10.0.0.5:8443/v1/models

# Or add the CA system-wide (Debian/Ubuntu):
sudo cp ca.crt /usr/local/share/ca-certificates/llama-local-ca.crt
sudo update-ca-certificates

# Then no --cacert needed:
curl https://myserver.lan:8443/v1/models
```

### Using with an MCP server / OpenAI-compatible client

Point the client at:

```
Base URL:  https://<server-ip>:8443/v1
API Key:   (leave empty or use any string - no API key auth is enforced)
```

If the client doesn't support custom CA certs, either:
- Install `certs/ca.crt` system-wide on the client machine, or
- Set `NODE_EXTRA_CA_CERTS=path/to/ca.crt` (Node.js clients), or
- Set `REQUESTS_CA_BUNDLE=path/to/ca.crt` (Python `requests`)

### Using as the backend for an agent framework

Any client that accepts a custom `base_url` and a dummy API key (OpenAI SDK,
LangChain, MCP servers, custom tool-calling loops) can use the HTTPS endpoint
above.

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
curl --cacert certs/ca.crt https://localhost:8443/v1/models
```

Sizing for an 8 GB Orin Nano, where CPU and GPU share ~7.4 GiB of unified
memory and the OS takes about 1 GiB:

- 4B-class Q4_K_M models fit with all layers offloaded; 7-8B Q4 fits only
  with a small `CTX_SIZE` and `q8_0` KV cache.
- Keep `PARALLEL` at 1-2; each slot multiplies KV-cache memory.
- Models of 24B class and above, including the reference Devstral Small 2, do
  not fit; do not reuse an `.env` sized for a discrete-GPU host.

## TLS Certificates

The setup script generates a self-signed CA and server certificate in `./certs/`:

| File          | Purpose                                        |
|--------------|------------------------------------------------|
| `ca.crt`     | CA certificate - distribute to clients         |
| `ca.key`     | CA private key - keep secret                   |
| `server.crt` | Server certificate (used by nginx)             |
| `server.key` | Server private key (used by nginx)             |

To regenerate certs (e.g., with new SANs):

```bash
rm -rf certs/
./scripts/gen-certs.sh myserver.lan 10.0.0.5 192.168.1.100
```
