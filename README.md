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
./scripts/validate.sh --base http://jetson.local:8080   # validate another host

./scripts/benchmark.sh                        # throughput sweep
./scripts/benchmark.sh -r 5 -n 256            # 5 reps, 256 generated tokens
./scripts/benchmark.sh --json results.json    # machine-readable output
./scripts/benchmark.sh --base http://jetson.local:8080   # measure another host

./scripts/test-detect-platform.sh             # platform detection self-test
./scripts/test-compose.sh                     # deployment configuration self-test
./scripts/test-env-lib.sh                     # configuration reader self-test
./scripts/test-mem.sh                         # memory sizing self-test
./scripts/test-benchmark.sh                   # benchmark self-test
./scripts/test-setup.sh                       # bootstrap self-test
./scripts/test-download-model.sh              # model acquisition self-test
./scripts/test-gen-certs.sh                   # certificate self-test
./scripts/test-validate.sh                    # the validation suite's own self-test
./scripts/test-detect-platform.sh -v          # ... printing every assertion
```

`validate.sh` covers platform detection, GPU passthrough wiring, the Compose
merge, model sizing, disk hygiene, container health, full GPU layer offload, the
OpenAI endpoints, streaming, tool calling, and the TLS proxy (including that it
rejects clients which do not trust the CA). It is **50 checks, all green** on a
Jetson Orin Nano Super with the stack up.

Every self-test above also runs as a preflight check, so `./scripts/validate.sh`
alone exercises all of them. `VALIDATE_SELFTESTS=0` skips them when you only
want the checks about this machine; they are reported as skipped rather than
silently dropped.

`benchmark.sh` drives the deployed HTTP endpoint rather than `llama-bench`, so
the numbers reflect the stack as a client sees it. It reports prompt-eval
throughput (compute bound), generation throughput (memory-bandwidth bound) and
time to first token, with prompt caching disabled so the prompt-eval figure is
real. It exits non-zero unless every case produced an actual measurement and
every requested repetition succeeded, so it is usable as a gate and not only as
something to read.

### Reading a benchmark on a Jetson

A number from a passively-cooled, power-capped board is only meaningful together
with the conditions it was taken under, so the run reports them:

| Column / line  | What it tells you                                                             |
|----------------|-------------------------------------------------------------------------------|
| `Power mode`   | Read from `nvpmodel`. A 15 W figure is not comparable to a 25 W/MAXN one.      |
| `spread`       | `(max-min)/median` of generation throughput across the repetitions of one case. A single median cannot distinguish a steady 12 tok/s from a run that started at 16 and ended at 8. |
| `Steady state` | The *first* case re-measured once after the sweep. The sweep walks from a short prompt to a long one, so throughput falling down the table says nothing about the board; re-running the same prompt at the end compares like with like, and any drop is the machine. |
| `Thermal`      | Every readable sysfs zone, start of run → end of run, including `tj-thermal` (the junction temperature that governs throttling on an Orin). |

If the run degraded, or the board reached the first passive trip point (70 °C on
an Orin Nano - well below the 99 °C most people watch for), the run says so and
tells you the numbers are not comparable. It still exits 0: throttling is a
property of the board, not a fault in the stack.

A healthy, cool Orin Nano Super at 15 W looks like this - spreads under 1 %, no
drift between the first and last measurement, and a rise that stays clear of the
trip point:

```
prompt         tokens     pp tok/s     tg tok/s   spread    TTFT ms
---------------------------------------------------------------------
16w                62        362.0         13.9     0.1%        171
128w              253        503.8         13.7     0.3%        502
512w              903        498.4         13.5     0.2%       1812

Steady state: 16w re-measured at 13.9 tok/s after the sweep (was 13.9, +0.0%)
Thermal tj-thermal     51°C -> 58°C
```

`--json` records all of it - every repetition's sample, the spread, the power
mode, the start and end temperature of each zone, the trip point and any
warnings - so two runs can be compared on their conditions and not just on their
medians.

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
renders as `0.0`), a typo'd `-r` value producing an empty sweep, a results path
that is not writable, which used to print `Wrote <path>` over a shell error and
discard the run, and a case that lost most of its repetitions to errors yet
printed the one surviving sample under a footer claiming a median over three.

`test-benchmark.sh` drives the real script against a stub OpenAI-compatible
server that produces each of those on demand, with no GPU, model, Docker or
network. It runs the script from a copy of the project with a known `.env`, so
the reported context size and KV cache types are actually checked rather than
inherited from whatever the host is configured for.

The Jetson-specific conditions get the same treatment, since a healthy board
will not reproduce them to order. `BENCH_SYSROOT` points the thermal probe at a
synthetic sysfs tree - a cool board, a board already past its passive trip
point, and zones that exist but cannot be read (an Orin's `cv*-thermal` zones
answer `EAGAIN`, and an empty reading used to reach `$(( ... / 1000 ))`).
`BENCH_NVPMODEL` supplies a stub power-mode probe. A stub server whose
throughput decays request by request stands in for a throttling board, and the
thermal read is checked once against a copy of this host's `PATH` with
`tegrastats` removed - the read never needed it, but it used to be gated on it,
which silently removed the whole thermal report on any host without it.

Besides those it pins the things that make the numbers mean anything: that
prompt caching stays disabled, that `-r` and `-n` are actually honoured, that
reported rates are positive, that prompt token counts grow across the sweep, and
that a bad argument is rejected before any request is issued. `validate.sh` runs
it as part of preflight.

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
  The value is read with compose's own rules (`scripts/lib/env.sh`, shared by
  `setup.sh`, `validate.sh` and `benchmark.sh`), so an inline comment or a
  `.env` saved with CRLF endings does not become part of the path. `.env` is
  never `source`d: it is compose syntax, not shell, so sourcing it both executes
  what it should only read - a `$(...)` in a value is a command - and keeps the
  CR that compose would strip. A CRLF-saved `.env` used to produce three
  failures in `validate.sh` at once, the clearest of which read
  `in .env: <image>; expected: <the same image>`.

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

### Deployment configuration self-test

`docker-compose.yml`, the Jetson overlay and `nginx/nginx.conf` are what a user
actually runs, and until now they were the only files every check talked *about*
and none of them exercised. Their failure modes are invisible in a static
reading:

- the overlay clears the base file's GPU reservation with compose's `!reset`
  tag, because compose merges lists by *appending* - requesting the GPU twice
  reintroduces the JetPack 6 hang the CDI path exists to avoid. A compose
  release too old for the tag does not ignore it, it refuses the whole project
  and the error names a YAML tag rather than the version.
- a bind source is not a shell path. Compose expands a leading `~` and treats a
  bare relative path (`MODELS_DIR=models`) as a *named volume*, so the same
  string can send several GB to a directory the container never mounts - with
  every script reporting the model as present, because bash resolves it
  differently.
- nginx defaults to a 1 MiB request body. A long document or a chat history near
  a large context window came back as a bare `413` that llama.cpp never saw,
  while the identical request succeeded against `127.0.0.1:8080` - so the proxy
  looked like the only broken client.

`test-compose.sh` renders the real merged configuration for both platforms with
`docker compose config` (client-side; it never contacts the daemon) and asserts
what the container actually gets: the CDI request present and the legacy
reservation gone on Jetson, the raw port published on loopback only, both
model mounts read-only, every `.env` knob reaching the environment variable
llama.cpp reads, and the proxy waiting for a healthy server. `MODELS_DIR` is
checked *differentially* - for every legal form (`./models`, absolute, `~/…`,
`${HOME}/…`, an inline comment, CRLF, `..` and a symlink in the path) what
`lib/env.sh` tells the scripts must equal what compose mounts. The nginx half
runs the real `nginx.conf` in a container against a stub upstream and asserts
the TLS handshake, the forwarded headers and a 3 MB prompt going through - plus
that the same prompt is a `413` once the body limit is removed, so the assertion
cannot pass for the wrong reason. It is skipped, with the reason printed, when
the Docker daemon or the nginx image is unavailable.

### Does it fit? - memory sizing on a shared-memory board

On a Jetson there is no separate VRAM: the model, the KV cache, the compute
buffers, the OS and the page cache all come out of one LPDDR pool. So "does this
model fit" is not a property of the file, and until this was written the suite
answered it as if it were - it compared the GGUF's size against the budget and
passed anything under 60% of it. For the recommended 3B that is 33%, reported as
"leaves room for the KV cache" no matter what `CTX_SIZE` said:

| `.env` | Weights | KV cache | Total | Old check | Reality |
|---|---|---|---|---|---|
| `CTX_SIZE=4096`, `q8_0` | 1840 MiB | 77 MiB | 1917 MiB | pass (33%) | fine |
| `CTX_SIZE=16384`, `q8_0` | 1840 MiB | 306 MiB | 2146 MiB | pass (33%) | fine |
| `CTX_SIZE=131072`, `q8_0` | 1840 MiB | 2448 MiB | 4288 MiB | pass (33%) | no room for the compute buffers |
| `CTX_SIZE=131072`, `f16` | 1840 MiB | 4608 MiB | 6448 MiB | pass (33%) | `cudaMalloc` failed at load |

The cache is now computed from the model's own metadata rather than guessed at.
`lib/gguf.py` reads the layer count, the KV head count (per layer, for the
architectures that vary it), the head dimensions and the trained context out of
the GGUF header - only the metadata block, so sizing a 40 GiB model costs a few
hundred KiB of I/O - and `lib/mem.sh` does the arithmetic with ggml's own block
sizes:

```
kv_bytes = pad(n_ctx, 256) x (k_elems_per_token x bytes(cache_type_k)
                            + v_elems_per_token x bytes(cache_type_v))
```

For Qwen2.5 3B (36 layers, 2 KV heads, head dimension 128) at 16384 tokens with
a `q8_0` cache, that is `16384 x 36 x 2 x 128 x 2 x 34/32 = 306 MiB`. llama.cpp
on the Orin Nano Super reports `KV buffer size = 306.03 MiB`.

That agreement is not a coincidence to be admired once and then trusted forever,
so it is a check. On every runtime run `validate.sh` reads back the size
llama.cpp actually allocated and compares it against the prediction, and a
divergence beyond the allocator's own padding goes **red** - because the
preflight check refuses configurations on that number, and a wrong number is
worse than none. It also totals every buffer the server reports and compares
that against the budget `detect-platform.sh` derived, which is the only way to
find out that the *budget* is optimistic rather than the model too large.

What the checks say, in order of how much they know:

- **the deployment fits** - weights + cache, with both numbers and the
  percentage of the budget
- **little room left for the compute buffers** (>75%) - a warning, with the
  largest `CTX_SIZE` that would leave a quarter free
- **does not fit** - red, with `CTX_SIZE=<n> fits`, or `CACHE_TYPE_K=q8_0` if
  the cache is still `f16`, or "no context leaves room on this board" when the
  weights alone are already past the line
- **cannot size the KV cache** - a skip naming the reason. An unreadable model
  is not a model with no cache, and it must not inherit the old file-size
  verdict
- **`CTX_SIZE` is beyond this model's trained context** - a warning; llama.cpp
  serves it, and the output quality is not what the model was trained for

Sliding-window (Gemma 3) and MLA (DeepSeek) models allocate less than this
formula, so they are reported as an upper bound with the reason, rather than
having a number invented for them that would refuse a configuration that fits.

`test-mem.sh` covers all of it against hand-computed values and against GGUF
files it builds itself: a 70B at a 128k context, a sliding-window model, an
architecture whose KV head count varies by layer, `key_length` != `value_length`,
every cache type ggml quantizes to, a cache type it does not, and files
truncated inside their own metadata - each of which would size a cache at zero
under a reader that returned defaults, and zero always fits. The fixtures are
sparse, so a 40 GiB model costs under 4 MiB of disk, which the suite asserts.

### Configuration reader self-test

Every script here decides what to do from a value `lib/env.sh` returned: where
the model lives, which Compose file to merge, which image to run, how large the
KV cache is. A reader that disagrees with Compose therefore does not produce a
wrong *message* - it produces a consistent and wrong *view* of the deployment,
in which every other check passes against a configuration the container never
had.

`.env` is Compose syntax, not shell, and the two disagree in more places than
they look like they do. Each of these was found by asking Compose and comparing,
and each was a real divergence before it was a test case:

| Written in `.env` | Compose resolves | The reader used to resolve |
|---|---|---|
| `MODELS_DIR='${HOME}/models'` | the literal `${HOME}/models` (a named volume - the project is refused) | `/home/u/models`, so the model was downloaded where nothing mounts |
| `export MODELS_DIR=/data/x` | `/data/x` | nothing - the key was dropped, so every script used `./models` |
| `MODELS_DIR=` then spaces then `/data/x` | `/data/x` (leading spaces are trimmed) | the spaces stayed in the value, so a valid path was reported as an unmountable bare relative one |
| `CTX_SIZE="4096" # tuned` | `4096` | `"4096"` |
| `A="$$5"` | `$5` (`$$` is Compose's escape) | `$$5` |
| `A="l1\nl2"` | two lines | `"l1` |
| `A=${UNSET:?why}` | the project is refused, with the message | an empty string, silently |
| `MODELS_DIR=/data/../x` | `/data/../x`, byte for byte | `/x` |

The last two rows are the shape worth naming: a value can make Compose refuse to
read the file *at all* (`${VAR:?}` with nothing set, an unterminated quote or
`${`, a stray sentence whose first word contains a space). Nothing starts, and a
reader that quietly invented a value for it would let the whole suite report on
a configuration that never existed. `env_check` now returns that reason, and
both `setup.sh` and `validate.sh` report it before anything else.

`test-env-lib.sh` is therefore differential rather than expectation-based: for
each way a value can be written it asks `docker compose config` what Compose
resolves, asks the library the same question, and asserts the two strings match
- including "the project cannot be read at all" as an answer. A hand-written
expectation would only have pinned what I believed Compose does, which is how
the divergences above survived four scripts and 500 assertions. `docker compose
config` is client-side, so this needs no daemon, image, GPU, model or network;
without the Compose CLI the differential half is skipped with the reason
printed, and the unit half (the reason strings, `env_load`, and the bind-source
rules) still runs.

### The validation suite's own self-test

"50/50 green" is only worth something if a red condition actually turns a check
red. On healthy hardware every check reports PASS - which is also exactly what a
check that *cannot* fail reports, and two of them could not: the "rejects
clients that do not trust the CA" check passed against an nginx that was down
(an endpoint that is off refuses everyone), and the slot-count check passed with
`PARALLEL` unset. A third crashed the whole run on `set -u` before the summary.

`test-validate.sh` drives the real `validate.sh` in throwaway project
directories where each condition is genuinely broken - no model, a truncated
one, a CRLF-saved `.env`, a stopped container, a CPU-only log, an image without
sm_87, a server still holding the previous model, a proxy that does not enforce
its CA - and asserts both that the matching check goes red and that its
neighbours stay green. `docker` is a stub reading canned `config`/`ps`/`logs`
output, and the llama.cpp API is a small HTTP/HTTPS server with a real
certificate, so nothing needs a GPU, Docker, a model or the network.

Two hooks make this possible and are useful in their own right: `--base URL`
points the runtime checks at a llama.cpp reachable elsewhere, and
`VALIDATE_SELFTESTS=0` stops the nested self-tests (without it, the suite
testing `validate.sh` would recurse into itself).

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
machine-specific symlink in the repository. It is a compose *bind source*, not a
shell path, and the difference is not cosmetic:

| Written as            | What happens                                                          |
|-----------------------|-----------------------------------------------------------------------|
| `./models`, `/data/m` | Mounted as written (relative resolves against the repository)          |
| `~/models`            | Expanded by compose; the scripts expand it the same way                |
| `${HOME}/models`      | Interpolated by compose; the scripts interpolate the same way          |
| `models`              | **A named volume**, not a directory - the project fails to parse       |

`setup.sh`, `download-model.sh` and `validate.sh` all resolve it through the same
reader, so a value compose cannot mount is reported before anything is
downloaded, and one it mounts *elsewhere* is never counted as present.

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

The certificate has to cover the name or address the client uses. That is the
default for this host's own addresses; anything else (a DNS alias, a VPN
address) is added with `./scripts/gen-certs.sh <name-or-ip>` followed by
`docker compose restart nginx`. `./scripts/gen-certs.sh --check` prints the
names currently covered.

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

`setup.sh` calls `gen-certs.sh`, which also runs standalone:

```bash
./scripts/gen-certs.sh                      # localhost, the hostname, this host's addresses
./scripts/gen-certs.sh myserver.lan 10.0.0.5 192.168.1.100   # add names
./scripts/gen-certs.sh --check              # verify what is installed; writes nothing
./scripts/gen-certs.sh --force              # replace the CA as well
./scripts/gen-certs.sh --reset-sans         # forget names added by earlier runs
```

Four properties are worth knowing, because each of them was once the opposite:

- **The addresses of this host are covered by default.** A headless Jetson is
  reached at `https://192.168.x.y:8443`, and a certificate for `localhost`
  alone fails there with "no alternative certificate subject name matches
  target host name". Docker's own bridges (`docker0`, `br-*`, `veth*`) are left
  out. `--no-auto-ip` opts out.
- **Names already in service are kept.** Re-running to add an address used to
  reissue from a bare list and silently drop every name an earlier run had
  added, so whichever client used the dropped name started failing for no
  visible reason. `--reset-sans` starts over deliberately.
- **A run that cannot finish changes nothing.** Everything is built in a
  staging directory and installed only after the key, the certificate and the
  CA have been checked against each other. Previously a typo in an argument -
  `192.168.1.400`, a name with a space - overwrote `server.key`, failed to sign
  with openssl's explanation sent to `/dev/null`, and left a pair that made
  nginx refuse to start with "key values mismatch".
- **The CA is reused unless you ask otherwise**, so clients that already trust
  `ca.crt` keep working when you add a name. `--force` replaces it and says so;
  every client then has to install the new `ca.crt`. A CA that is expired, does
  not match its key, or is not a CA at all is reported by name rather than used
  to sign something no client will accept.

`ca.key` is only needed to issue certificates. Keeping it off the serving host
is better practice, and `--check` treats it as optional rather than missing.

**nginx reads the certificates once, at startup.** After regenerating, reload
the proxy or the old certificate stays in service:

```bash
docker compose restart nginx
```

### Certificate self-test

`certs/` is the only directory in this repo another process holds open, so the
interesting failures land on a running proxy rather than in the script's
output - and none of them are reachable from a host whose certificates are
already fine. `test-gen-certs.sh` drives the real script through each of them
against a private `CERT_DIR` with stubbed `hostname` and `ip`: a typo'd
address, a name with a space, half a CA left by an interrupted run, a CA that
does not match its key, an expired CA, a `ca.crt` that is not a CA, an openssl
that fails at the signing step, a host with no address probe, a system hostname
that is not a valid DNS name.

The assertions end in a real TLS handshake against the generated pair - a
server that loads exactly what nginx mounts, a client that verifies with
`ca.crt` - because a certificate that inspects correctly can still be one no
TLS stack will accept. It needs no GPU, Docker, model or network, and
`validate.sh` runs it as a preflight check.

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
│   ├── lib/
│   │   ├── env.sh              # Reading .env with compose's semantics
│   │   ├── mem.sh              # KV cache and footprint arithmetic
│   │   └── gguf.py             # GGUF metadata reader (layers, heads, vocab)
│   ├── test-fixtures/
│   │   └── mkgguf.py           # Builds sparse GGUF files for the tests
│   ├── setup.sh                # Bootstrap + .env/platform consistency check
│   ├── test-setup.sh           # Hermetic tests for the bootstrap
│   ├── detect-platform.sh      # Hardware detection + tuned defaults
│   ├── gen-certs.sh            # TLS certificate generator (staged + verified)
│   ├── test-gen-certs.sh       # Hermetic tests for certificate generation
│   ├── download-model.sh       # Model downloader (size-checked, GGUF-verified)
│   ├── test-download-model.sh  # Hermetic tests for the downloader
│   ├── validate.sh             # End-to-end validation suite
│   ├── test-validate.sh        # Hermetic tests for the validation suite
│   ├── test-detect-platform.sh # Hermetic tests for platform detection
│   ├── test-compose.sh         # Hermetic tests for the compose files + nginx.conf
│   ├── test-env-lib.sh         # Hermetic tests for the .env reader (vs compose)
│   ├── test-mem.sh             # Hermetic tests for the memory sizing
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

**`413 Request Entity Too Large`, but only over HTTPS:**
- The proxy is enforcing a body limit the raw port does not have. `nginx.conf`
  sets `client_max_body_size 64m`; an older copy left nginx's 1 MiB default.
- nginx reads its configuration only at startup: `docker compose restart nginx`.

**`refers to undefined volume` / `invalid compose project`:**
- `MODELS_DIR` is a bare relative path, which compose reads as the name of a
  volume. Write `./models`, not `models` (see [Configuration](#configuration)).

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
