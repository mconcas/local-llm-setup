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

`CACHE_TYPE_K` / `CACHE_TYPE_V` set the KV-cache quantisation. Setting both to
`q8_0` is what makes a large `CTX_SIZE` (e.g. `65536`) fit alongside Q4_K_M
weights on a 32 GB GPU.

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
API Key:   (leave empty or use any string — no API key auth is enforced)
```

If the client doesn't support custom CA certs, either:
- Install `certs/ca.crt` system-wide on the client machine, or
- Set `NODE_EXTRA_CA_CERTS=path/to/ca.crt` (Node.js clients), or
- Set `REQUESTS_CA_BUNDLE=path/to/ca.crt` (Python `requests`)

### Using as the backend for an agent framework

This stack is suitable as the LLM backend for agent projects (MCP, LangChain,
LlamaIndex, OpenAI SDK, custom tool-calling loops) — any client that accepts a
custom `base_url` + (dummy) API key can point at the HTTPS endpoint above.

Things to keep in mind when wiring it into an agent system:

- **Pick a model trained for tool/function calling.** Generic chat models often
  fail multi-step agent loops. Good local choices: Qwen2.5-Instruct,
  Llama-3.1-Instruct, Hermes, Mistral-Nemo-Instruct. llama.cpp's
  function-calling fidelity also depends on the model's chat template being
  applied correctly — sanity-check with a tool-calling probe before relying on
  it.
- **A passing tool-call probe does not predict agent accuracy.** Once an agent's
  prompts or skills have been tuned against one model, swapping in another can
  regress it badly even when the newcomer's tool calling is mechanically better.
  Benchmark before changing `MODEL_FILE` on a working agent deployment;
  [MODEL-TRIAL.md](MODEL-TRIAL.md) records a measured case.
- **Respect VRAM limits.** For a 32 GB GPU, Q4_K_M quantisations up to ~32B fit
  with full GPU offload; 70B-class models will spill to CPU and be slow.
- **`PARALLEL` caps agent fan-out.** If your agent dispatches many concurrent
  tool calls or sub-agents, raise `PARALLEL` in `.env` accordingly (each slot
  consumes additional KV-cache memory).
- **Local models trail frontier APIs** on long-horizon planning and complex
  tool use — temper expectations for elaborate agent loops.

## TLS Certificates

The setup script generates a self-signed CA and server certificate in `./certs/`:

| File          | Purpose                                        |
|--------------|------------------------------------------------|
| `ca.crt`     | CA certificate — distribute to clients         |
| `ca.key`     | CA private key — keep secret                   |
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
├── .env                        # Runtime configuration (git-ignored)
├── .env.example                # Template for .env
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
- Run `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi` to test Docker GPU access

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
