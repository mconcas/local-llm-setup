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

## Supported platforms

| Platform                        | Status    | GPU passthrough | Image                                            |
|---------------------------------|-----------|-----------------|--------------------------------------------------|
| x86_64 + discrete NVIDIA GPU    | supported | `--gpus` (Compose device reservation) | `ghcr.io/ggml-org/llama.cpp:server-cuda` |
| NVIDIA Jetson Orin (JetPack 6)  | supported | CDI             | `ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin` |

`./scripts/setup.sh` detects which of the two it is running on and writes
matching defaults into `.env` — image, GPU mechanism, context size, KV cache
type and a model recommendation sized to the available memory. Run
`./scripts/detect-platform.sh` on its own to see what it would pick.

## Quick Start

```bash
# 1. Clone and enter the repo
git clone <this-repo> && cd local-llm-setup

# 2. Run the setup script: detects the platform, writes .env, generates TLS
#    certs. Pass extra hostnames/IPs for the certificate SANs:
./scripts/setup.sh myserver.lan 10.0.0.5

# 3. Download a model sized for this machine (on an 8 GB Jetson Orin Nano
#    that is Qwen2.5-3B-Instruct-Q4_K_M, ~1.8 GiB):
./scripts/download-model.sh --recommended

#    …or name one explicitly:
./scripts/download-model.sh \
  bartowski/Qwen2.5-3B-Instruct-GGUF \
  Qwen2.5-3B-Instruct-Q4_K_M.gguf

# 4. Point .env to your model
sed -i 's|MODEL_FILE=.*|MODEL_FILE=/models/Qwen2.5-3B-Instruct-Q4_K_M.gguf|' .env

# 5. Start the stack
docker compose up -d

# 6. Validate everything end to end
./scripts/validate.sh
```

## Validation and benchmarking

```bash
./scripts/validate.sh              # preflight + runtime checks, non-zero exit on failure
./scripts/validate.sh --preflight  # config/hardware only, no running stack needed
./scripts/validate.sh --runtime    # assume the stack is already up

./scripts/benchmark.sh                        # throughput sweep
./scripts/benchmark.sh -r 5 -n 256            # 5 reps, 256 generated tokens
./scripts/benchmark.sh --json results.json    # machine-readable output
./scripts/benchmark.sh --base http://jetson.local:8080   # measure another host

./scripts/test-detect-platform.sh             # platform detection self-test
./scripts/test-benchmark.sh                   # benchmark self-test
./scripts/test-setup.sh                       # bootstrap self-test
./scripts/test-download-model.sh              # model acquisition self-test
./scripts/test-detect-platform.sh -v          # ... printing every assertion
```

`validate.sh` covers platform detection, GPU passthrough wiring, the Compose
merge, model sizing, disk hygiene, container health, full GPU layer offload, the
OpenAI endpoints, streaming, tool calling, and the TLS proxy (including that it
rejects clients which do not trust the CA).

`benchmark.sh` drives the deployed HTTP endpoint rather than `llama-bench`, so
the numbers reflect the stack as a client sees it. It reports prompt-eval
throughput (compute bound), generation throughput (memory-bandwidth bound) and
time to first token, with prompt caching disabled so the prompt-eval figure is
real. It exits non-zero unless every case produced an actual measurement, so it
is usable as a gate and not only as something to read.

### Platform detection self-test

`detect-platform.sh` decides the container image, the GPU passthrough
mechanism, the memory budget and the model tier - and on any given host it takes
exactly one branch. An Orin Nano can never exercise the AGX, discrete-GPU or
CPU-only paths, so a regression in them would stay invisible until someone ran
the stack on that board.

`test-detect-platform.sh` closes that gap. It runs the real script against
synthetic `/proc`, `/etc` and `/var/run` trees (`PLATFORM_SYSROOT`) and a stub
`nvidia-smi` (`PLATFORM_NVIDIA_SMI`), so every branch is checked on any host
with no GPU, no Docker and no network. It covers Orin Nano / NX / AGX and Nano
2 GB and 4 GB, CDI present under `/etc/cdi` and `/var/run/cdi` as well as absent
or foreign, Jetson identified by device tree alone, discrete cards on x86_64 and
aarch64, CPU-only hosts, and a host whose `nvidia-smi` exists but fails.

It also sweeps the whole memory range and asserts three invariants that a new or
resized model tier could break: the recommended weights fit the budget, they
leave at least 40% of it for the KV cache and compute buffers, and a larger
board is never given a smaller model than a smaller one.

`validate.sh` runs it as part of preflight, so a normal validation run reports
the cross-platform result alongside the checks for the machine in hand.

### Benchmark self-test

The benchmark is the only thing here that produces a number someone will act on,
so the failure that matters is not a crash but a plausible-looking table that was
never a measurement. A healthy Jetson only ever exercises the happy path, which
is why several of these went unnoticed: a server answering `500` under memory
pressure, a proxy stripping llama.cpp's per-request `timings` block (every rate
renders as `0.0`), a typo'd `-r` value producing an empty sweep, and a results
path that is not writable, which used to print `Wrote <path>` over a shell error
and discard the run.

`test-benchmark.sh` drives the real script against a stub OpenAI-compatible
server that produces each of those on demand, with no GPU, model, Docker or
network. Besides the failure paths it pins the things that make the numbers
mean anything: that prompt caching stays disabled, that `-r` and `-n` are
actually honoured, that reported rates are positive, that prompt token counts
grow across the sweep, and that a bad argument is rejected before any request is
issued. `validate.sh` runs it as part of preflight.

### Moving an `.env` between the two platforms

`.env` is portable in form but not in content. The settings that differ between
an x86_64 workstation and a Jetson are precisely the ones whose failure modes do
not name themselves:

| Setting | Wrong value on a Jetson | What you see |
|---|---|---|
| `COMPOSE_FILE` | without the Jetson overlay | GPU passthrough takes the legacy `--gpus` path, which wedges the Docker daemon on JetPack 6 |
| `LLAMA_IMAGE` | the upstream CUDA image | the GPU is enumerated, then the server aborts trying to JIT from PTX - it carries no `sm_87` kernels |
| `PARALLEL` | more slots than the board holds | the KV cache is N× larger and the container is OOM-killed mid-request |
| `CACHE_TYPE_K` / `_V` | `f16` | the KV cache is twice the size it needs to be, on the machine with the least memory |

So `setup.sh` re-reads the hardware on every run and reports where the existing
`.env` disagrees with it, with the value to set. It never edits an existing
`.env` - the one exception is `MODEL_FILE`, which is repointed when it names a
file that is not there and exactly one model is, since that value is otherwise
guaranteed to crash-loop the container. It exits 0 either way; `validate.sh` is
the gate, and now also checks `LLAMA_IMAGE`.

### Bootstrap self-test

`setup.sh` is the first thing a user runs and the only script that writes
`.env`, so what it gets wrong is inherited by everything downstream - including
the rest of the validation suite. Its risky paths are again the ones a healthy
machine never takes: they involve the *other* platform, a `MODELS_DIR` on a data
disk, or a `MODEL_FILE` naming a model that has since been pruned. Each of those
used to end in `Setup complete` and exit 0.

`test-setup.sh` runs the real script in throwaway project directories against
synthetic `/proc` trees and stub `docker`/`nvidia-smi`/`python3` binaries, so no
GPU, Docker, network or model is needed and the real `.env` is never touched. It
covers a fresh checkout on either platform, an `.env` carried in each direction,
a pruned or ambiguous `MODEL_FILE`, models on a data disk, `.env` values that are
not shell-safe, a failing platform probe, idempotence, and JetPack's missing
`python3-venv`. `validate.sh` runs it as part of preflight.

## Disk usage

Model files are the only large artifact this stack keeps, and a Jetson is
usually the machine with the least room to spare, so `download-model.sh` is
built not to waste it:

- **It refuses downloads that would not fit.** The size is probed over HTTP
  first and compared against real free space on `MODELS_DIR`, keeping a 512 MiB
  margin. Nothing is transferred when it would not fit.
- **It never leaves junk named `*.gguf`.** Every download is verified against
  the GGUF magic bytes and the expected byte count; anything else is deleted.
  Without this a typo'd filename silently produces a 15-byte file containing
  `Entry not found`, which `setup.sh` then wires into `.env` and which
  crash-loops the container with an opaque load error.
- **It is idempotent, and re-checks rather than assumes.** An already-present
  model is left alone once its size has been confirmed against the remote. The
  magic bytes alone are not enough: a transfer killed after its first few KiB
  still starts with `GGUF`, and that used to be accepted forever - every re-run
  printed `already present and valid` and exited 0. When the endpoint is
  unreachable the file is kept but reported as unverified rather than as good.
- **It downloads to `MODELS_DIR`**, so pointing that at a data disk works.
  The value is read with compose's own rules, so an inline comment or a `.env`
  saved with CRLF endings does not become part of the path.

```bash
./scripts/download-model.sh --recommended   # model sized for this machine
./scripts/download-model.sh --prune         # reclaim interrupted downloads
```

`--prune` deletes partial transfers (`*.incomplete`, `*.gguf.part`) and lists
the models on disk. Only the one named by `MODEL_FILE` is ever served, so any
others are safe to delete; `validate.sh` reports how much they hold.

`HF_ENDPOINT` points both download paths at a Hugging Face mirror or an internal
proxy; `huggingface_hub` honours the same variable.

### Model acquisition self-test

Everything `download-model.sh` can get wrong leaves *something* on disk that
looks like a model, and the checks downstream then pass on a file the container
cannot load. None of it is reachable against the real Hugging Face on a healthy
machine: it takes a 404, a gated repo, a CDN that answers the size probe and
refuses the transfer, a body shorter than advertised, or a connection dropped
mid-transfer.

`test-download-model.sh` drives the real script against a stub Hugging Face
endpoint (`HF_ENDPOINT`) that produces each of those on demand, in throwaway
project directories, writing nothing larger than 64 KiB. It also covers the
free-space refusal, `--prune`, `--recommended` against a synthetic Jetson,
`MODELS_DIR` in every form a `.env` may legally carry it, the argument errors,
and the `huggingface-cli` path - which is a separate transfer path that must be
verified the same way. `validate.sh` runs it as part of preflight.

## Running on NVIDIA Jetson

Validated on a **Jetson Orin Nano Super (8 GB), JetPack 6 / L4T R36.4.7**.
`setup.sh` handles all of the below automatically; this section explains what it
does and why, since the differences from a discrete-GPU host are not cosmetic.

**GPU passthrough uses CDI, not `--gpus`.** Compose's
`deploy.resources.reservations.devices` maps onto Docker's legacy `--gpus` path,
which on Tegra resolves to `nvidia-container-cli` in CSV mode. That bind-mounts
several hundred driver files into the container and then runs `ldconfig` over
the merged overlay. On JetPack 6 that step routinely stalls for minutes in
uninterruptible I/O — the container sits in `Created`, and the Docker daemon
becomes unresponsive with it. `docker-compose.jetson.yml` clears that
reservation and requests the GPU through CDI (`nvidia.com/gpu=all`) instead,
which applies a pre-generated spec with no hook and starts in about a second.

If `/etc/cdi/nvidia.yaml` does not exist, generate it once:

```bash
sudo nvidia-ctk cdi generate --mode=csv --output=/etc/cdi/nvidia.yaml
```

**The upstream image does not work on Jetson.**
`ghcr.io/ggml-org/llama.cpp:server-cuda` publishes an arm64 manifest and it is
misleading: it starts, enumerates the iGPU and prints `CUDA0: Orin`. It then
dies at the first kernel launch with

```
CUDA error: the provided PTX was compiled with an unsupported toolchain
```

because it carries no `sm_87` cubin and its embedded PTX was produced by a newer
CUDA toolkit than the L4T driver accepts. Device enumeration is therefore *not*
evidence that a build works — inference has to be exercised, which is what
`validate.sh` does. Use `ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin`,
which is compiled for `sm_87` against the L4T CUDA stack (verify with
`CUDA : ARCHS = 870` in the server log).

**Memory is unified, so "VRAM" is system RAM.** llama.cpp reports the full
7619 MiB on an 8 GB board, but the OS, the desktop session and the page cache
are drawing on the same pool. `detect-platform.sh` budgets total RAM minus a
2 GB OS reserve. Exceeding it does not degrade gracefully — the container
crash-loops on a `cudaMalloc failed: out of memory` while allocating the KV
cache. Keep `PARALLEL=1` and quantise the KV cache with `CACHE_TYPE_K/V=q8_0`,
which roughly halves KV memory against `f16` for negligible quality cost.

**Model sizing.** On an 8 GB Orin Nano, a 3B model at Q4_K_M (~1.9 GB) leaves
comfortable room for a 16k context. Measured with `benchmark.sh`:

| Model                        | Power mode | prompt eval | generation |
|------------------------------|-----------|-------------|------------|
| Qwen2.5-3B-Instruct Q4_K_M   | 15 W      | ~500 tok/s  | ~14 tok/s  |

Generation is bandwidth bound, so it barely moves with prompt length. The Orin
Nano *Super* also has a 25 W mode, which is not the default and is worth
enabling before benchmarking:

```bash
sudo nvpmodel -m 2 && sudo jetson_clocks   # check `sudo nvpmodel -q` for the mode list
```

## Configuration

All settings live in `.env` (created from `.env.example` by the setup script,
with platform-appropriate values filled in):

| Variable       | Default                      | Description                                              |
|----------------|------------------------------|----------------------------------------------------------|
| `COMPOSE_FILE` | `docker-compose.yml`         | Compose files to merge; Jetson appends the overlay        |
| `LLAMA_IMAGE`  | `ghcr.io/ggml-org/llama.cpp:server-cuda` | Server image (platform specific)              |
| `MODELS_DIR`   | `./models`                   | Host directory holding the `.gguf` files                  |
| `MODEL_FILE`   | `/models/model.gguf`         | Path to model inside the container                        |
| `CTX_SIZE`     | `4096`                       | Context window size (tokens)                              |
| `GPU_LAYERS`   | `-1`                         | Layers offloaded to GPU (`-1` = all)                      |
| `PARALLEL`     | `4`                          | Concurrent request slots                                  |
| `CACHE_TYPE_K` / `CACHE_TYPE_V` | `f16`       | KV cache quantisation (`q8_0` halves KV memory)           |
| `HTTPS_PORT`   | `8443`                       | Port exposed for HTTPS                                    |

`MODELS_DIR` exists so models can live on a separate data disk without a
machine-specific symlink in the repository.

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
- **Respect VRAM limits.** For a 32 GB GPU, Q4_K_M quantisations up to ~32B fit
  with full GPU offload; 70B-class models will spill to CPU and be slow. On an
  8 GB Jetson the ceiling is a 3B-class Q4_K_M, and the budget is shared with
  the OS rather than being dedicated VRAM — see the Jetson section above.
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
├── docker-compose.jetson.yml   # Jetson overlay (CDI GPU passthrough)
├── scripts/
│   ├── setup.sh                # Bootstrap + .env/platform consistency check
│   ├── test-setup.sh           # Hermetic tests for the bootstrap
│   ├── detect-platform.sh      # Hardware detection + tuned defaults
│   ├── gen-certs.sh            # TLS certificate generator
│   ├── download-model.sh       # Model downloader (size-checked, GGUF-verified)
│   ├── test-download-model.sh  # Hermetic tests for the downloader
│   ├── validate.sh             # End-to-end validation suite
│   ├── test-detect-platform.sh # Hermetic tests for platform detection
│   ├── benchmark.sh            # Throughput benchmark
│   └── test-benchmark.sh       # Hermetic tests for the benchmark
├── models/                     # GGUF model files (git-ignored)
│   └── *.gguf
└── certs/                      # TLS certificates (git-ignored)
    ├── ca.crt
    ├── ca.key
    ├── server.crt
    └── server.key
```

## Troubleshooting

Start with `./scripts/validate.sh` — most of the failure modes below are
detected by name, with the fix in the message.

**Container won't start / GPU not found:**
- Install the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
- Run `nvidia-smi` to confirm GPU visibility
- Run `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi` to test Docker GPU access
- On Jetson, do **not** use `--gpus all` for this test — it hangs (see below).
  Use `docker run --rm --device nvidia.com/gpu=all ubuntu:24.04 ls /dev/nvhost-gpu`

**Jetson: container stuck in `Created`, `docker` commands hang:**
- The legacy `--gpus` path is being used. Confirm `.env` has
  `COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml`, and that
  `docker compose config` shows `nvidia.com/gpu=all` and no `driver: nvidia`.
- A stuck `ldconfig.real` in `D` state (`ps -eo stat,comm | grep D`) is the
  signature. It clears on its own, but takes minutes.

**Jetson: `CUDA error: the provided PTX was compiled with an unsupported toolchain`:**
- The image has no `sm_87` kernels. Set
  `LLAMA_IMAGE=ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin` in `.env`.

**Jetson: `cudaMalloc failed: out of memory` while loading:**
- Unified memory is exhausted. Lower `CTX_SIZE`, set `PARALLEL=1`, set
  `CACHE_TYPE_K=q8_0` and `CACHE_TYPE_V=q8_0`, or use a smaller quantisation.
- Free the page cache first if a large file was just written:
  `sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'`

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
