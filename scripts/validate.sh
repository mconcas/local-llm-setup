#!/usr/bin/env bash
# validate.sh - End-to-end validation of the llama.cpp stack.
#
# Split into two groups:
#
#   preflight  static checks that need no running containers - platform
#              detection, GPU passthrough wiring, compose merge, model file
#   runtime    the stack as a client actually sees it - health, OpenAI
#              endpoints, streaming, tool calling, TLS, GPU offload
#
# Usage:
#   ./scripts/validate.sh              # preflight + runtime
#   ./scripts/validate.sh --preflight  # static checks only (no stack needed)
#   ./scripts/validate.sh --runtime    # assume the stack is already up
#   ./scripts/validate.sh --base URL   # llama.cpp is reachable elsewhere
#
# Environment:
#   VALIDATE_BASE       same as --base (default http://127.0.0.1:8080)
#   VALIDATE_SELFTESTS  set to 0 to skip the nested script self-tests
#
# Exit status is non-zero if any check fails, so this is usable in CI.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

MODE="all"
BASE_URL="${VALIDATE_BASE:-http://127.0.0.1:8080}"
while (( $# )); do
  case "$1" in
    --preflight) MODE="preflight" ;;
    --runtime)   MODE="runtime" ;;
    --base|-b)
      [[ -n "${2:-}" ]] || { echo "--base requires a URL"; exit 2; }
      BASE_URL="$2"; shift ;;
    *) echo "Unknown option: $1"
       echo "Usage: $0 [--preflight|--runtime] [--base URL]"; exit 2 ;;
  esac
  shift
done

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_SK=$'\033[33m'; C_HD=$'\033[1m'; C_Z=$'\033[0m'
else
  C_OK=""; C_NO=""; C_SK=""; C_HD=""; C_Z=""
fi

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$C_OK" "$C_Z" "$1"; }
no()   { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %sFAIL%s  %s\n' "$C_NO" "$C_Z" "$1"
         [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n' "$C_SK" "$C_Z" "$1"
         [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }
head() { printf '\n%s%s%s\n' "$C_HD" "$1" "$C_Z"; }

# ── Configuration ─────────────────────────────────────────────────
# `set -a; . ./.env` was wrong in both directions: it executes a file that is
# compose syntax rather than shell, and it keeps whatever compose would have
# stripped. A CRLF-saved .env produced three failures here, one of which
# reported "in .env: <image>; expected: <same image>" because the difference was
# an invisible CR. See lib/env.sh.
ENV_FILE="$PROJECT_DIR/.env"
. "$SCRIPT_DIR/lib/env.sh"
env_load

HTTPS_PORT="${HTTPS_PORT:-8443}"
CA_CERT="$PROJECT_DIR/certs/ca.crt"
HTTP_BASE="${BASE_URL%/}"
HTTPS_BASE="https://localhost:${HTTPS_PORT}"

# detect-platform.sh emits its recommended image as LLAMA_IMAGE - the same name
# .env uses - so evaluating it here would overwrite the user's value in an
# already-exported variable, and every `docker compose` call below would then
# inspect a different image than `docker compose up` runs. Keep the two apart.
LLAMA_IMAGE_ENV="${LLAMA_IMAGE:-}"
eval "$(bash "$SCRIPT_DIR/detect-platform.sh" --env 2>/dev/null)" || true
LLAMA_IMAGE_REC="${LLAMA_IMAGE:-}"
if [[ -n "$LLAMA_IMAGE_ENV" ]]; then
  LLAMA_IMAGE="$LLAMA_IMAGE_ENV"
else
  unset LLAMA_IMAGE   # let compose fall back to the default in docker-compose.yml
fi

# `docker compose` needs the same file list the user runs with. COMPOSE_FILE is
# exported from .env above, so a bare `docker compose` already picks it up.
dc() { docker compose "$@"; }

# Extract a field from a JSON document on stdin without requiring jq.
jget() { python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for k in sys.argv[1:]:
    if isinstance(d,list):
        try: d=d[int(k)]
        except Exception: sys.exit(1)
    else:
        if not isinstance(d,dict) or k not in d: sys.exit(1)
        d=d[k]
print(d if not isinstance(d,(dict,list)) else json.dumps(d))
" "$@"; }

# Run one script self-test as a check. Each of these drives a real script
# against synthetic fixtures, covering the paths a healthy host cannot reach.
#
# VALIDATE_SELFTESTS=0 turns them off. That exists because test-validate.sh runs
# *this* script, so leaving them on would recurse; it is not a way to make the
# suite quieter, and the summary says so when they are skipped.
selftest() {
  local script="$1" label="$2" out nfail first
  if [[ "${VALIDATE_SELFTESTS:-1}" == "0" ]]; then
    skip "$label self-test (VALIDATE_SELFTESTS=0)"
    return 0
  fi
  if out="$(VALIDATE_SELFTESTS=0 bash "$SCRIPT_DIR/$script" 2>&1)"; then
    ok "$label self-test ($(grep -oE '[0-9]+ (assertions )?passed' <<<"$out" | tail -1))"
  else
    nfail="$(grep -cE '^ +- ' <<<"$out")"
    first="$(grep -E '^ +- ' <<<"$out" | sed -n '1s/^ *- //p')"
    no "$label self-test: ${nfail} assertion(s) failed" \
       "first: ${first:-see output}; run ./scripts/$script for the rest"
  fi
}

# ══════════════════════════════════════════════════════════════════
# Preflight
# ══════════════════════════════════════════════════════════════════
preflight() {
  head "Preflight - platform"

  if [[ -n "${PLATFORM_KIND:-}" ]]; then
    ok "platform detected: $PLATFORM_KIND (${PLATFORM_LABEL:-unknown})"
  else
    no "detect-platform.sh did not report a platform"
  fi

  if [[ -n "${GPU_MEM_MB:-}" ]] && (( GPU_MEM_MB > 0 )); then
    ok "usable GPU memory budget: $((GPU_MEM_MB)) MiB"
  else
    skip "no GPU memory budget (CPU-only host)"
  fi

  # Detection takes exactly one branch on any given host, so this machine can
  # never exercise the other boards' paths. The self-test drives the same script
  # against synthetic /proc and /etc trees and covers all of them.
  selftest test-detect-platform.sh "platform detection"

  head "Preflight - tooling"

  if command -v docker &>/dev/null; then
    ok "docker present ($(docker --version | sed 's/,.*//'))"
  else
    no "docker not found"
  fi

  if docker compose version &>/dev/null; then
    ok "docker compose present (v$(docker compose version --short 2>/dev/null))"
  else
    no "docker compose v2 not found"
  fi

  # Every runtime check below speaks HTTP and parses JSON. Without these two the
  # whole runtime section fails as "the server returned nothing", which points
  # at the stack rather than at the missing tool.
  if command -v curl &>/dev/null; then
    ok "curl present"
  else
    no "curl not found" "the runtime checks cannot reach the server without it"
  fi
  if command -v python3 &>/dev/null; then
    ok "python3 present"
  else
    no "python3 not found" "needed to parse the server's JSON responses"
  fi

  head "Preflight - GPU passthrough"

  case "${PLATFORM_KIND:-}" in
    jetson)
      # The legacy --gpus path hangs on JetPack 6, so the Jetson overlay must be
      # active and must be the *only* GPU request in the merged config.
      if [[ "${GPU_ACCESS:-}" == "cdi" ]]; then
        ok "CDI spec present under /etc/cdi"
      else
        no "no CDI spec found" \
           "run: sudo nvidia-ctk cdi generate --mode=csv --output=/etc/cdi/nvidia.yaml"
      fi

      if [[ "${COMPOSE_FILE:-docker-compose.yml}" == *docker-compose.jetson.yml* ]]; then
        ok "COMPOSE_FILE selects the Jetson overlay"
      else
        no "COMPOSE_FILE does not include docker-compose.jetson.yml" \
           "set COMPOSE_FILE=${COMPOSE_FILES:-docker-compose.yml:docker-compose.jetson.yml} in .env"
      fi

      local cfg
      cfg="$(dc config 2>/dev/null)"
      if grep -q 'nvidia.com/gpu=all' <<<"$cfg"; then
        ok "merged config requests the GPU over CDI"
      else
        no "merged config has no CDI device request"
      fi
      if grep -q 'driver: nvidia' <<<"$cfg"; then
        no "merged config still carries the legacy nvidia device reservation" \
           "this reintroduces the JetPack 6 ldconfig hang"
      else
        ok "legacy nvidia device reservation is cleared"
      fi
      ;;
    nvidia-discrete)
      if dc config 2>/dev/null | grep -q 'driver: nvidia'; then
        ok "merged config reserves an nvidia device"
      else
        no "merged config does not request a GPU"
      fi
      ;;
    *)
      skip "no NVIDIA GPU detected - nothing to check"
      ;;
  esac

  head "Preflight - compose and model"

  if dc config >/dev/null 2>&1; then
    ok "compose config is valid (${COMPOSE_FILE:-docker-compose.yml})"
  else
    no "compose config is invalid" "$(dc config 2>&1 | tail -3)"
  fi

  # The image is the one setting with no runtime fallback. The upstream CUDA
  # build carries no sm_87 kernels, so on an Orin it enumerates the GPU, tries
  # to JIT from PTX and aborts - which reads as a driver problem, not a config
  # one. The Jetson image is arm64-only and will not pull on x86_64 at all.
  if [[ -z "$LLAMA_IMAGE_ENV" ]]; then
    no "LLAMA_IMAGE is not set in .env" "set LLAMA_IMAGE=${LLAMA_IMAGE_REC:-see detect-platform.sh}"
  elif [[ "$LLAMA_IMAGE_ENV" == "${LLAMA_IMAGE_REC:-}" ]]; then
    ok "LLAMA_IMAGE is the image for this platform"
  else
    no "LLAMA_IMAGE is not the image detected for this platform" \
       "in .env: ${LLAMA_IMAGE_ENV}; expected: ${LLAMA_IMAGE_REC:-unknown}"
  fi

  # MODEL_FILE is a container path under /models; map it back to the host.
  # Note the :- default: with MODEL_FILE absent from .env this line used to die
  # on `set -u` with a raw "unbound variable", which skipped every check after
  # it - disk hygiene, TLS and all four self-tests - and printed no summary,
  # while exiting 1 exactly like an ordinary failed check.
  local mfile="${MODEL_FILE:-}"
  local host_model="${MODELS_DIR:-./models}/${mfile#/models/}"
  if [[ -z "${MODEL_FILE:-}" ]]; then
    no "MODEL_FILE is not set in .env" "run ./scripts/setup.sh to write one"
  elif [[ "${MODEL_FILE}" != /models/* ]]; then
    no "MODEL_FILE must be a container path starting with /models/ (got: $MODEL_FILE)"
  elif [[ -f "$host_model" ]]; then
    ok "model file present ($(du -h "$host_model" | cut -f1): $(basename "$host_model"))"
  else
    no "model file not found at $host_model" \
       "download one: ./scripts/download-model.sh ${REC_MODEL_REPO:-<repo>} ${REC_MODEL_FILE:-<file>}"
  fi

  # A model that does not fit leaves the container in a crash loop with an
  # opaque cudaMalloc failure, so flag it here where the message can be useful.
  if [[ -f "$host_model" && -n "${GPU_MEM_MB:-}" ]] && (( GPU_MEM_MB > 0 )); then
    local model_mb model_pct
    model_mb=$(( $(stat -c %s "$host_model") / 1048576 ))
    model_pct=$(( model_mb * 100 / GPU_MEM_MB ))
    if (( model_mb >= GPU_MEM_MB )); then
      no "model weights (${model_mb} MiB) exceed the ${GPU_MEM_MB} MiB budget" \
         "expect an out-of-memory failure at load; try ${REC_MODEL_FILE:-a smaller quant}"
    elif (( model_pct > 60 )); then
      # Weights fitting is not enough: the KV cache, the compute buffers and
      # llama.cpp's scratch space come out of the same budget. A model at this
      # ratio loads and then dies once a long prompt grows the cache, which is
      # far harder to diagnose than a failure at load.
      skip "model weights take ${model_pct}% of the ${GPU_MEM_MB} MiB budget" \
           "little room left for a ${CTX_SIZE:-?}-token KV cache; lower CTX_SIZE or use ${REC_MODEL_FILE:-a smaller quant}"
    else
      ok "model weights (${model_mb} MiB, ${model_pct}% of budget) leave room for the KV cache"
    fi
  fi

  head "Preflight - disk hygiene"

  local model_dir_host="${MODELS_DIR:-./models}"

  # A GGUF starts with the ASCII magic "GGUF". Anything else here is a failed
  # download wearing a .gguf name - an HTTP error body, an HTML login page or a
  # truncated transfer - and it fails at load time with an opaque llama.cpp
  # error rather than an obvious one. Note `head` is a section-header function
  # in this script, so the binary has to be called explicitly.
  if [[ -f "$host_model" ]]; then
    if [[ "$(command head -c 4 "$host_model" 2>/dev/null)" == "GGUF" ]]; then
      ok "model file has a valid GGUF header"
    else
      no "model file is not a valid GGUF (bad magic bytes): $host_model" \
         "a failed download left this behind; re-fetch it with ./scripts/download-model.sh --recommended"
    fi
  fi

  # llama.cpp memory-maps the weights and the OS still needs room for logs and
  # the page cache, so a models filesystem run to 100% breaks more than loading.
  local avail_mb
  avail_mb="$(df -Pk "$model_dir_host" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}')"
  if [[ -z "$avail_mb" ]]; then
    skip "could not determine free space on $model_dir_host"
  elif (( avail_mb >= 512 )); then
    ok "models filesystem has $((avail_mb / 1024)) GiB free"
  else
    no "only ${avail_mb} MiB free on the models filesystem" \
       "reclaim space: ./scripts/download-model.sh --prune"
  fi

  # Interrupted transfers are the main way this stack quietly eats a disk: a
  # multi-GB partial blob that nothing will ever resume or serve.
  local partial_mb=0 partial_n=0 f
  while IFS= read -r -d '' f; do
    partial_mb=$(( partial_mb + $(stat -c %s "$f" 2>/dev/null || echo 0) / 1048576 ))
    partial_n=$((partial_n + 1))
  done < <(find "$model_dir_host" \( -name '*.incomplete' -o -name '*.gguf.part' \) \
             -type f -print0 2>/dev/null)
  if (( partial_n == 0 )); then
    ok "no interrupted downloads left in $model_dir_host"
  else
    no "$partial_n interrupted download(s) holding ${partial_mb} MiB" \
       "reclaim it: ./scripts/download-model.sh --prune"
  fi

  # Only the GGUF named by MODEL_FILE is ever served. Extra copies are a common
  # way to lose tens of GB after trying a few quants, so surface them - but as
  # information, since keeping a spare on purpose is legitimate.
  local unused_mb=0 unused_n=0 g
  while IFS= read -r -d '' g; do
    [[ "$(realpath -m "$g")" == "$(realpath -m "$host_model")" ]] && continue
    unused_mb=$(( unused_mb + $(stat -c %s "$g" 2>/dev/null || echo 0) / 1048576 ))
    unused_n=$((unused_n + 1))
  done < <(find "$model_dir_host" -maxdepth 2 -name '*.gguf' -type f -print0 2>/dev/null)
  if (( unused_n == 0 )); then
    ok "no unused model files in $model_dir_host"
  else
    skip "$unused_n model file(s) not referenced by MODEL_FILE (${unused_mb} MiB)" \
         "delete any you no longer need; only $(basename "$host_model") is served"
  fi

  head "Preflight - TLS"

  # Presence is a proxy for validity, and the states that matter here have all
  # four files on disk: a server key that does not match its certificate (nginx
  # refuses to start), a certificate signed by a CA that has since been
  # replaced (every client rejects it), an expired CA. gen-certs.sh --check
  # resolves those; it writes nothing.
  if [[ -f "$CA_CERT" && -f "$PROJECT_DIR/certs/server.crt" ]]; then
    local certchk
    if certchk="$(CERT_DIR="$PROJECT_DIR/certs" bash "$SCRIPT_DIR/gen-certs.sh" --check 2>&1)"; then
      ok "TLS certificates present and consistent"
    else
      no "TLS certificates are inconsistent: $(grep -m1 '^  [a-z]' <<<"$certchk" | sed 's/^ *//')" \
         "run: ./scripts/gen-certs.sh --check   for the full report"
    fi
  else
    no "TLS certificates missing" "run: ./scripts/setup.sh <hostname-or-ip>"
  fi

  # gen-certs.sh writes the only files in this repo that another process holds
  # open: nginx bind-mounts them. Its failure modes therefore land on a running
  # proxy rather than in this script's output, and none of them are reachable
  # from a host whose certificates are already fine. The self-test drives the
  # real script through each of them and finishes with a TLS handshake.
  selftest test-gen-certs.sh "certificate generation"

  head "Preflight - benchmark"

  # A healthy stack only ever exercises the benchmark's happy path, so the ways
  # it can report a non-measurement as a measurement - a 500 under memory
  # pressure, a stripped timings block, a typo'd repetition count, an unwritable
  # results path - are invisible here. The self-test drives the real script
  # against a stub server that produces each of them on demand.
  selftest test-benchmark.sh "benchmark"

  head "Preflight - bootstrap"

  # setup.sh writes .env, so anything it gets wrong is inherited by every check
  # below. Its risky paths all involve the platform this host is not, or an .env
  # carried over from one. The self-test runs the real script in throwaway
  # project directories against synthetic /proc trees.
  selftest test-setup.sh "setup"

  head "Preflight - model acquisition"

  # download-model.sh is the only script here that writes gigabytes, on the
  # board with the least room for a mistake. Everything it can get wrong leaves
  # something on disk that looks like a model - a truncated transfer, a login
  # page, several GB outside the mounted directory - and the checks below then
  # pass on a file the container cannot load. The self-test drives it against a
  # stub Hugging Face endpoint that 404s, gates, lies about sizes and drops
  # connections on demand.
  selftest test-download-model.sh "download"

  head "Preflight - the suite itself"

  # Every check above reports PASS on this machine, which is exactly what a
  # check that cannot fail also does. The suite's own self-test drives this
  # script against fixtures where each condition is genuinely broken - a missing
  # model, a CRLF .env, a container that is down, a server answering with the
  # wrong model, an nginx accepting untrusted clients - and asserts that the
  # matching check goes red and the exit status follows.
  selftest test-validate.sh "validation suite"
}

# ══════════════════════════════════════════════════════════════════
# Runtime
# ══════════════════════════════════════════════════════════════════
runtime() {
  head "Runtime - containers"

  local ps_out; ps_out="$(dc ps --format '{{.Service}} {{.Status}}' 2>/dev/null)"
  if grep -q '^llama-server .*Up' <<<"$ps_out"; then
    ok "llama-server is up"
  else
    no "llama-server is not running" "start it: docker compose up -d"
    echo ""
    echo "Skipping the remaining runtime checks - the server is required."
    return
  fi
  if grep -qi 'healthy' <<<"$ps_out"; then
    ok "llama-server reports healthy"
  else
    skip "llama-server has no healthy status yet (still starting?)"
  fi

  head "Runtime - GPU offload"

  # The CUDA banner, the ARCHS line and the layer-offload summary are each
  # printed once, at model load. Searching only the tail of the log made these
  # checks pass on a freshly started stack and then fail on the same healthy
  # stack after any real traffic - a single benchmark run is enough to push the
  # startup banner out of a 400-line window, which then reads as "the model is
  # running on CPU". Search the whole log, and keep it in a file so a
  # long-running server's output is never held in a shell variable.
  local logfile; logfile="$(mktemp)"
  dc logs llama-server >"$logfile" 2>/dev/null

  if grep -q 'found [0-9]* CUDA devices' "$logfile"; then
    ok "llama.cpp initialised a CUDA device"
  else
    no "llama.cpp did not report a CUDA device" "the model is running on CPU"
  fi

  # On Jetson the build must contain real sm_87 cubins. Images built for generic
  # arm64/sbsa enumerate the Orin fine and then die at the first kernel launch
  # with "the provided PTX was compiled with an unsupported toolchain", so check
  # the compiled architecture list rather than trusting enumeration.
  if [[ "${PLATFORM_KIND:-}" == "jetson" ]]; then
    if grep -qE 'ARCHS = .*870' "$logfile"; then
      ok "image contains sm_87 kernels (Orin)"
    else
      no "image does not advertise sm_87 in its CUDA ARCHS" \
         "use ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin"
    fi
    if grep -q 'unsupported toolchain' "$logfile"; then
      no "CUDA PTX JIT failed against the L4T driver" \
         "the image was built with a CUDA toolkit newer than JetPack supports"
    else
      ok "no CUDA PTX toolchain errors in the log"
    fi
  fi

  local offl; offl="$(grep -oE 'offloaded [0-9]+/[0-9]+ layers to GPU' "$logfile" | tail -1)"
  rm -f "$logfile"
  if [[ -n "$offl" ]]; then
    local n d; n="${offl#offloaded }"; n="${n%%/*}"; d="${offl#*/}"; d="${d%% *}"
    if [[ "$n" == "$d" ]]; then
      ok "all layers offloaded to GPU ($n/$d)"
    else
      no "only $n of $d layers are on the GPU" "raise GPU_LAYERS or use a smaller model"
    fi
  else
    skip "no layer-offload line found in the log"
  fi

  head "Runtime - HTTP API"

  if curl -sf --max-time 10 "$HTTP_BASE/health" | grep -q '"status"'; then
    ok "GET /health"
  else
    no "GET /health did not return a status"
  fi

  local loaded
  loaded="$(curl -sf --max-time 15 "$HTTP_BASE/v1/models" 2>/dev/null | jget models 0 name 2>/dev/null)"
  if [[ -n "$loaded" ]]; then
    ok "GET /v1/models lists '$loaded'"
    # The running server holds whatever was configured when it started. Editing
    # MODEL_FILE and forgetting to recreate the container leaves every check
    # here green against the *old* model - which on a Jetson is how a "the new
    # quant is no faster" report happens. Compare by basename, since the server
    # reports the path it was given and .env names it inside the container.
    if [[ -n "${MODEL_FILE:-}" ]]; then
      if [[ "$(basename "$loaded")" == "$(basename "$MODEL_FILE")" ]]; then
        ok "the server is serving the model named by MODEL_FILE"
      else
        no "the server is serving $(basename "$loaded"), but MODEL_FILE says $(basename "$MODEL_FILE")" \
           "recreate the container to pick up the change: docker compose up -d --force-recreate"
      fi
    fi
  else
    no "GET /v1/models returned no model"
  fi

  local slots ctx props
  props="$(curl -sf --max-time 15 "$HTTP_BASE/props" 2>/dev/null)"
  slots="$(jget total_slots <<<"$props" 2>/dev/null)"
  ctx="$(jget default_generation_settings n_ctx <<<"$props" 2>/dev/null)"
  if [[ -n "$slots" && -n "$ctx" ]]; then
    ok "GET /props reports $slots slot(s), n_ctx=$ctx"
    # PARALLEL used to be passed as LLAMA_ARG_PARALLEL, which llama.cpp ignores.
    # Catch a regression back to that by comparing against the configured value.
    # With PARALLEL unset there is nothing to compare against, and reporting a
    # PASS there is the same vacuous-pass shape this suite exists to catch.
    if [[ -z "${PARALLEL:-}" ]]; then
      skip "PARALLEL is not set in .env - cannot verify the slot count"
    elif [[ "$slots" != "${PARALLEL}" ]]; then
      no "PARALLEL=${PARALLEL} in .env but the server has $slots slots" \
         "the server is not receiving LLAMA_ARG_N_PARALLEL"
    else
      ok "slot count matches PARALLEL=${PARALLEL}"
    fi
  else
    no "GET /props did not return slot/context information"
  fi

  head "Runtime - inference"

  local reply
  reply="$(curl -sf --max-time 120 "$HTTP_BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"any","temperature":0,"max_tokens":16,
         "messages":[{"role":"user","content":"Reply with exactly: JETSON OK"}]}' 2>/dev/null \
    | jget choices 0 message content 2>/dev/null)"
  if [[ "$reply" == *"JETSON OK"* ]]; then
    ok "chat completion returns the requested text"
  elif [[ -n "$reply" ]]; then
    # A small quantised model may paraphrase; that is still a working pipeline.
    ok "chat completion produced output (got: $(tr -d '\n' <<<"$reply" | cut -c1-40))"
  else
    no "chat completion returned nothing"
  fi

  local stream
  stream="$(curl -sf --max-time 120 "$HTTP_BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"any","temperature":0,"max_tokens":32,"stream":true,
         "messages":[{"role":"user","content":"Count from 1 to 5."}]}' 2>/dev/null)"
  if grep -q 'data: \[DONE\]' <<<"$stream" && \
     [[ "$(grep -c '^data: ' <<<"$stream")" -gt 2 ]]; then
    ok "streaming completion emits SSE chunks and terminates with [DONE]"
  else
    no "streaming completion did not produce a well-formed SSE stream"
  fi

  # Tool calling is the main reason this stack sets LLAMA_ARG_JINJA=1: without
  # the GGUF chat template the model emits tool calls as prose and agent clients
  # never see a structured tool_calls block.
  local tool_json
  tool_json="$(curl -sf --max-time 120 "$HTTP_BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"any","temperature":0,"max_tokens":128,
         "messages":[{"role":"user","content":"What is the weather in Turin? Use the tool."}],
         "tools":[{"type":"function","function":{
            "name":"get_weather",
            "description":"Get the current weather for a city",
            "parameters":{"type":"object",
              "properties":{"city":{"type":"string","description":"City name"}},
              "required":["city"]}}}],
         "tool_choice":"auto"}' 2>/dev/null)"
  local fn
  fn="$(jget choices 0 message tool_calls 0 function name <<<"$tool_json" 2>/dev/null)"
  if [[ "$fn" == "get_weather" ]]; then
    ok "tool calling returns a structured tool_calls block"
  else
    no "tool calling did not produce a structured tool_calls block" \
       "check that LLAMA_ARG_JINJA=1 and the model ships a tool-aware chat template"
  fi

  head "Runtime - TLS proxy"

  if [[ ! -f "$CA_CERT" ]]; then
    skip "no CA certificate at certs/ca.crt"
  elif ! grep -q '^nginx .*Up' <<<"$ps_out"; then
    skip "nginx is not running"
  else
    local tls_up=0
    if curl -sf --max-time 15 --cacert "$CA_CERT" "$HTTPS_BASE/v1/models" >/dev/null 2>&1; then
      ok "HTTPS GET /v1/models through nginx"; tls_up=1
    else
      no "HTTPS request through nginx failed"
    fi

    # The proxy must not buffer SSE, otherwise streaming clients stall until the
    # whole completion is done.
    local https_stream
    https_stream="$(curl -sf --max-time 120 --cacert "$CA_CERT" "$HTTPS_BASE/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"model":"any","temperature":0,"max_tokens":24,"stream":true,
           "messages":[{"role":"user","content":"Say hello."}]}' 2>/dev/null)"
    if grep -q 'data: \[DONE\]' <<<"$https_stream"; then
      ok "HTTPS streaming completion works end to end"
    else
      no "HTTPS streaming completion failed"
    fi

    # An endpoint that is simply down also refuses a request without the CA, so
    # this only means anything once the same request has been shown to succeed
    # *with* it. Reporting a PASS otherwise would make a dead proxy look secure.
    if (( ! tls_up )); then
      skip "cannot check CA enforcement - HTTPS is not answering with the CA either"
    elif curl -sf --max-time 10 "$HTTPS_BASE/v1/models" >/dev/null 2>&1; then
      no "HTTPS endpoint accepted a request without the CA - certificate is not being verified" \
         "either the cert is signed by a CA in the system trust store, or nginx is serving plain HTTP"
    else
      ok "HTTPS endpoint rejects clients that do not trust the CA"
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════
printf '%s╔══════════════════════════════════════════════════╗%s\n' "$C_HD" "$C_Z"
printf '%s║   llama.cpp Local Server - Validation Suite      ║%s\n' "$C_HD" "$C_Z"
printf '%s╚══════════════════════════════════════════════════╝%s\n' "$C_HD" "$C_Z"

[[ "$MODE" == "all" || "$MODE" == "preflight" ]] && preflight
[[ "$MODE" == "all" || "$MODE" == "runtime"   ]] && runtime

head "Summary"
printf '  %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
  "$C_OK" "$PASS" "$C_Z" "$C_NO" "$FAIL" "$C_Z" "$C_SK" "$SKIP" "$C_Z"
if (( FAIL > 0 )); then
  printf '\n  Failed checks:\n'
  printf '    - %s\n' "${FAILED_NAMES[@]}"
  echo ""
  exit 1
fi
echo ""
exit 0
