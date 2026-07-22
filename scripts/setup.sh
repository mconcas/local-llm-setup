#!/usr/bin/env bash
# setup.sh - One-shot bootstrap: generate certs, create dirs, validate config.
#
# Runs on both supported targets (x86_64 + discrete NVIDIA GPU, and NVIDIA
# Jetson/Tegra). Safe to re-run: on every invocation it re-reads the hardware
# and reports where an existing .env disagrees with it, because the settings
# that differ between the two targets are exactly the ones whose failure modes
# are opaque (a wedged Docker daemon, a PTX JIT abort, an out-of-memory kill).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "╔══════════════════════════════════════════════════╗"
echo "║       llama.cpp Local Server — Setup             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Read one key out of .env. Deliberately not `source`: .env is compose syntax,
# not shell, so a value containing spaces or a `--flag` aborts sourcing halfway
# and leaves later keys silently unset. Last uncommented assignment wins, which
# is what compose itself does.
env_get() {
  local key="$1" val
  [[ -f .env ]] || return 0
  val="$(grep -E "^[[:space:]]*${key}=" .env | tail -1)" || return 0
  val="${val#*=}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

MISMATCHES=0
mismatch() {
  MISMATCHES=$(( MISMATCHES + 1 ))
  echo "⚠  $1"
  shift
  local line
  for line in "$@"; do echo "   $line"; done
}

# ── 1. Create directories ─────────────────────────────────────
# models/ is created once MODELS_DIR is known (step 3b) - it may point at a
# data disk, in which case ./models is not the directory that matters.
echo "==> Creating directories …"
mkdir -p certs

# ── 2. Detect the platform ────────────────────────────────────
# Jetson and discrete-GPU hosts differ in GPU passthrough mechanism, memory
# budget and viable model size, so read those off the hardware rather than
# shipping one set of defaults that only suits the machine it was written on.
echo ""
echo "==> Detecting platform …"
# Keep stderr out of PLATFORM_ENV: the value is eval'd, so a warning printed by
# detect-platform.sh would be executed as shell rather than reported.
PLATFORM_ERR="$(mktemp)"
trap 'rm -f "$PLATFORM_ERR"' EXIT
if ! PLATFORM_ENV="$(bash "$SCRIPT_DIR/detect-platform.sh" --env 2>"$PLATFORM_ERR")" ||
   [[ "$PLATFORM_ENV" != *PLATFORM_KIND=* ]]; then
  echo "✘ Platform detection failed - cannot choose defaults for this host." >&2
  echo "  ./scripts/detect-platform.sh reported:" >&2
  cat "$PLATFORM_ERR" >&2
  sed 's/^/    /' <<<"$PLATFORM_ENV" >&2
  exit 1
fi
eval "$PLATFORM_ENV"
bash "$SCRIPT_DIR/detect-platform.sh" | sed 's/^/    /'

# ── 3. .env file ───────────────────────────────────────────────
echo ""
if [[ ! -f .env ]]; then
  echo "==> Creating .env from .env.example …"
  cp .env.example .env

  # Rewrite a key in .env, whether or not it is currently commented out.
  set_env() {
    local key="$1" val="$2"
    if grep -qE "^#?\s*${key}=" .env; then
      sed -i "s|^#\?\s*${key}=.*|${key}=${val}|" .env
    else
      printf '%s=%s\n' "$key" "$val" >> .env
    fi
  }

  set_env COMPOSE_FILE  "$COMPOSE_FILES"
  set_env LLAMA_IMAGE   "$LLAMA_IMAGE"
  set_env CTX_SIZE      "$REC_CTX_SIZE"
  set_env PARALLEL      "$REC_PARALLEL"
  set_env CACHE_TYPE_K  "$REC_CACHE_TYPE"
  set_env CACHE_TYPE_V  "$REC_CACHE_TYPE"
  echo "    Applied ${PLATFORM_KIND} defaults to .env."
else
  echo "==> .env already exists, leaving it untouched."
fi

# ── 3b. Review .env against the detected hardware ─────────────
# An .env is portable in form but not in content: carrying one over from the
# x86_64 workstation to a Jetson (or the reverse) produces a config that starts
# and then fails in a way the error message does not explain. Compare the
# effective values - never the file text, since .env.example documents the
# Jetson settings in comments and a grep over the file matches those.
echo ""
echo "==> Checking .env against this platform …"

# MODELS_DIR may point at a data disk. Create *that* directory, not ./models:
# a missing bind-mount source makes the Docker daemon materialise it as a
# root-owned empty directory, so the model the user downloaded is simply not
# there and the container reports a missing file it can see nothing wrong with.
MODEL_DIR_HOST="$(env_get MODELS_DIR)"
MODEL_DIR_HOST="${MODEL_DIR_HOST:-./models}"
mkdir -p "$MODEL_DIR_HOST"
HTTPS_PORT="$(env_get HTTPS_PORT)"

CUR_COMPOSE="$(env_get COMPOSE_FILE)"
CUR_IMAGE="$(env_get LLAMA_IMAGE)"
CUR_CTX="$(env_get CTX_SIZE)"
CUR_PARALLEL="$(env_get PARALLEL)"
CUR_CACHE_K="$(env_get CACHE_TYPE_K)"
CUR_CACHE_V="$(env_get CACHE_TYPE_V)"

if [[ "$PLATFORM_KIND" == "jetson" && "$CUR_COMPOSE" != *docker-compose.jetson.yml* ]]; then
  mismatch "COMPOSE_FILE does not select the Jetson overlay (is: ${CUR_COMPOSE:-unset})" \
           "GPU passthrough would use the legacy --gpus path, which hangs on JetPack 6." \
           "Set:  COMPOSE_FILE=$COMPOSE_FILES"
elif [[ "$PLATFORM_KIND" != "jetson" && "$CUR_COMPOSE" == *docker-compose.jetson.yml* ]]; then
  mismatch "COMPOSE_FILE selects the Jetson overlay but this is not a Jetson." \
           "CDI passthrough needs a Tegra CDI spec and will not find a GPU here." \
           "Set:  COMPOSE_FILE=$COMPOSE_FILES"
fi

if [[ -n "$CUR_IMAGE" && "$CUR_IMAGE" != "$LLAMA_IMAGE" ]]; then
  # The one setting with no runtime fallback. The upstream CUDA image is built
  # without sm_87, so on an Orin it enumerates the GPU, tries to JIT from PTX
  # and aborts; the Jetson image is arm64-only and will not pull on x86_64.
  mismatch "LLAMA_IMAGE is not the image for this platform." \
           "in .env:   $CUR_IMAGE" \
           "detected:  $LLAMA_IMAGE" \
           "Set:  LLAMA_IMAGE=$LLAMA_IMAGE"
fi

# Memory knobs matter on a Jetson, where weights, KV cache and the OS all come
# out of one LPDDR pool. On a discrete GPU an oversized context is the user's
# call, so only warn where it can OOM the whole board.
if [[ "$PLATFORM_KIND" == "jetson" ]]; then
  if [[ "$CUR_PARALLEL" =~ ^[0-9]+$ ]] && (( CUR_PARALLEL > REC_PARALLEL )); then
    mismatch "PARALLEL=$CUR_PARALLEL exceeds the $REC_PARALLEL slot(s) this board can hold." \
             "Each slot carves its own share out of CTX_SIZE; the KV cache is ${CUR_PARALLEL}× larger." \
             "Set:  PARALLEL=$REC_PARALLEL"
  fi
  if [[ "$CUR_CTX" =~ ^[0-9]+$ ]] && (( CUR_CTX > REC_CTX_SIZE )); then
    mismatch "CTX_SIZE=$CUR_CTX exceeds the recommended $REC_CTX_SIZE for ${GPU_MEM_MB} MiB." \
             "Set:  CTX_SIZE=$REC_CTX_SIZE"
  fi
  if [[ "$CUR_CACHE_K" != "$REC_CACHE_TYPE" || "$CUR_CACHE_V" != "$REC_CACHE_TYPE" ]]; then
    mismatch "KV cache is ${CUR_CACHE_K:-unset}/${CUR_CACHE_V:-unset}, not $REC_CACHE_TYPE." \
             "$REC_CACHE_TYPE roughly halves KV memory for a negligible quality cost." \
             "Set:  CACHE_TYPE_K=$REC_CACHE_TYPE and CACHE_TYPE_V=$REC_CACHE_TYPE"
  fi
fi

if (( MISMATCHES == 0 )); then
  echo "    .env matches the detected ${PLATFORM_KIND} platform."
fi

# ── 4. Generate TLS certificates ──────────────────────────────
if [[ ! -f certs/server.crt ]]; then
  echo ""
  echo "==> Generating TLS certificates …"
  echo "    Pass additional hostnames/IPs as arguments to this script."
  echo "    Example: ./scripts/setup.sh myserver.lan 10.0.0.5"
  echo ""
  bash "$SCRIPT_DIR/gen-certs.sh" "$@"
else
  echo "==> TLS certs already exist in certs/, skipping."
fi

# ── 5. Bootstrap Python venv with huggingface-hub ────────────
echo ""
VENV_DIR="$PROJECT_DIR/.venv"
# huggingface-hub >= 0.34 ships the `hf` binary; older versions ship `huggingface-cli`.
if [[ ! -x "$VENV_DIR/bin/hf" && ! -x "$VENV_DIR/bin/huggingface-cli" ]]; then
  echo "==> Setting up Python venv for the Hugging Face CLI …"
  # The venv only buys resumable/authenticated downloads; download-model.sh
  # falls back to curl without it. Distros that ship python3 without ensurepip
  # (no python3-venv package) must therefore not abort the whole bootstrap —
  # which `set -e` would otherwise do. This is the default on JetPack's Ubuntu.
  if ! command -v python3 &>/dev/null; then
    echo "⚠  python3 not found — skipping venv setup."
    echo "   Install Python 3 and re-run setup.sh to enable model downloads."
  # &> not 2>: `python3 -m venv` prints its ensurepip advice on *stdout*, so
  # JetPack's missing python3-venv otherwise dumps a wall of text that the
  # message below already explains more usefully.
  elif python3 -m venv "$VENV_DIR" &>/dev/null &&
       "$VENV_DIR/bin/pip" install --quiet --upgrade pip &>/dev/null &&
       "$VENV_DIR/bin/pip" install --quiet -U huggingface-hub &>/dev/null; then
    echo "    Hugging Face CLI installed in .venv/"
  else
    rm -rf "$VENV_DIR"
    echo "⚠  Could not create the Python venv (python3-venv / ensurepip missing?)."
    echo "   Not fatal: download-model.sh falls back to curl for single files."
    echo "   For sharded models install it, e.g.:  sudo apt install python3-venv"
  fi
else
  echo "==> Hugging Face CLI already in .venv/, skipping."
fi

# ── 6. Check for NVIDIA Container Toolkit ─────────────────────
echo ""
if command -v nvidia-smi &>/dev/null; then
  echo "==> NVIDIA GPU detected:"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true
else
  echo "⚠  nvidia-smi not found. GPU acceleration may not work."
fi

# ── 7. Check Docker ───────────────────────────────────────────
echo ""
if command -v docker &>/dev/null; then
  echo "==> Docker version: $(docker --version)"
  if docker compose version &>/dev/null; then
    echo "==> Docker Compose: $(docker compose version --short 2>/dev/null || docker compose version)"
  else
    echo "⚠  docker compose not found. Install Docker Compose v2."
  fi
else
  echo "⚠  Docker not found. Install Docker Engine first."
fi

# ── 8. Check for model ────────────────────────────────────────
echo ""
CUR_MODEL_FILE="$(env_get MODEL_FILE)"
mapfile -t MODELS_ON_DISK < <(find "$MODEL_DIR_HOST" -maxdepth 1 -name '*.gguf' -type f -printf '%f\n' 2>/dev/null | sort)

# MODEL_FILE is a container path under /models; MODELS_DIR is where that is
# mounted from on the host.
HOST_MODEL=""
[[ "$CUR_MODEL_FILE" == /models/* ]] && HOST_MODEL="$MODEL_DIR_HOST/${CUR_MODEL_FILE#/models/}"

if (( ${#MODELS_ON_DISK[@]} > 0 )); then
  echo "==> Models found in $MODEL_DIR_HOST:"
  ls -lh "$MODEL_DIR_HOST"/*.gguf
fi

if [[ -n "$HOST_MODEL" && -f "$HOST_MODEL" ]]; then
  echo "    MODEL_FILE=$CUR_MODEL_FILE is present."
elif (( ${#MODELS_ON_DISK[@]} == 1 )); then
  # Either MODEL_FILE is still the shipped placeholder, or it names a file that
  # is no longer there (pruned, renamed, or carried over from another host).
  # Both leave `docker compose up` crash-looping on a missing path, so wire up
  # the one model that does exist rather than reporting success.
  sed -i "s|^MODEL_FILE=.*|MODEL_FILE=/models/${MODELS_ON_DISK[0]}|" .env
  echo "    Set MODEL_FILE=/models/${MODELS_ON_DISK[0]} in .env"
elif (( ${#MODELS_ON_DISK[@]} > 1 )); then
  mismatch "MODEL_FILE=${CUR_MODEL_FILE:-unset} does not name a file in $MODEL_DIR_HOST." \
           "Several models are present, so pick one:" \
           "${MODELS_ON_DISK[@]/#/  MODEL_FILE=/models/}"
else
  mismatch "No .gguf model found in $MODEL_DIR_HOST." \
           "Download the model sized for this platform:" \
           "  ./scripts/download-model.sh --recommended" \
           "(${REC_MODEL_FILE}, ~$(( REC_MODEL_MB / 1024 )).$(( REC_MODEL_MB * 10 / 1024 % 10 )) GiB)"
fi

echo ""
echo "════════════════════════════════════════════════════"
if (( MISMATCHES == 0 )); then
  echo " Setup complete. Next steps:"
  echo ""
  echo "   1. Run:      docker compose up -d"
  echo "   2. Validate: ./scripts/validate.sh"
  echo "   3. Test:     curl --cacert certs/ca.crt https://localhost:${HTTPS_PORT:-8443}/v1/models"
else
  echo " Setup finished with ${MISMATCHES} item(s) to resolve (see ⚠ above)."
  echo ""
  echo "   Re-run ./scripts/setup.sh after editing .env, then"
  echo "   ./scripts/validate.sh before bringing the stack up."
fi
echo "════════════════════════════════════════════════════"
