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

# 3. Download a model (or place a .gguf file in ./models/ manually)
./scripts/download-model.sh \
  TheBloke/Mistral-7B-Instruct-v0.2-GGUF \
  mistral-7b-instruct-v0.2.Q4_K_M.gguf

# 4. Point .env to your model
sed -i 's|MODEL_FILE=.*|MODEL_FILE=/models/mistral-7b-instruct-v0.2.Q4_K_M.gguf|' .env

# 5. Start the stack
docker compose up -d

# 6. Verify
curl --cacert certs/ca.crt https://localhost:8443/v1/models
```

## Configuration

All settings live in `.env` (created from `.env.example` by the setup script):

| Variable       | Default              | Description                               |
|----------------|----------------------|-------------------------------------------|
| `MODEL_FILE`   | `/models/model.gguf` | Path to model inside the container        |
| `CTX_SIZE`     | `4096`               | Context window size (tokens)              |
| `GPU_LAYERS`   | `-1`                 | Layers offloaded to GPU (`-1` = all)      |
| `PARALLEL`     | `4`                  | Concurrent request slots                  |
| `HTTPS_PORT`   | `8443`               | Port exposed for HTTPS                    |
| `CACHE_TYPE_K` | `f16`                | KV-cache key quantisation (e.g. `q8_0`)   |
| `CACHE_TYPE_V` | `f16`                | KV-cache value quantisation (e.g. `q8_0`) |
| `LLAMA_IMAGE`  | `ghcr.io/ggml-org/llama.cpp:server-cuda` | llama.cpp server image |
| `MODELS_DIR`   | `./models`           | Host directory bind-mounted at `/models`  |
| `COMPOSE_FILE` | (unset)              | Extra compose files, e.g. the Jetson override |

Setting both cache types to `q8_0` halves KV-cache memory; this is what lets
`CTX_SIZE=65536` fit alongside Q4_K_M weights on a 32 GB GPU.

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
  even when the new model's tool calling is mechanically better.
  [MODEL-TRIAL.md](MODEL-TRIAL.md) records a measured case.
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
- 30B-class models do not fit; do not reuse an `.env` sized for a
  discrete-GPU host.

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

## File Structure

```
.
├── docker-compose.yml          # Service definitions
├── docker-compose.jetson.yml   # Jetson override (locally built image)
├── .env                        # Runtime configuration (git-ignored)
├── .env.example                # Template for .env
├── jetson/
│   └── Dockerfile              # llama.cpp build for Jetson Orin (sm_87)
├── nginx/
│   └── nginx.conf              # TLS reverse proxy config
├── scripts/
│   ├── setup.sh                # Bootstrap script
│   ├── gen-certs.sh            # TLS certificate generator
│   └── download-model.sh       # Model downloader (Hugging Face)
├── models/                     # GGUF model files (git-ignored)
│   └── *.gguf
└── certs/                      # TLS certificates (git-ignored)
    ├── ca.crt
    ├── ca.key
    ├── server.crt
    └── server.key
```

## Troubleshooting

**Container won't start / GPU not found:**
- Install the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
- Run `nvidia-smi` to confirm GPU visibility
- Run `docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu22.04 nvidia-smi` to test Docker GPU access

**Model loading is slow:**
- Increase `GPU_LAYERS` (default `-1` = all) to offload more to GPU
- Check VRAM usage with `nvidia-smi`

**TLS errors from clients:**
- Ensure the client trusts `certs/ca.crt`
- Check that the server hostname/IP is in the certificate SANs:
  `openssl x509 -in certs/server.crt -noout -ext subjectAltName`

**Logs:**
```bash
docker compose logs -f llama-server   # llama.cpp logs
docker compose logs -f nginx          # proxy logs
```
