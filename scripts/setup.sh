#!/usr/bin/env bash
# setup.sh — One-shot bootstrap: generate certs, create dirs, validate config.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "╔══════════════════════════════════════════════════╗"
echo "║       llama.cpp Local Server — Setup             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── 1. Create directories ─────────────────────────────────────
echo "==> Creating directories …"
mkdir -p models certs

# ── 2. Detect the platform ────────────────────────────────────
# Jetson and discrete-GPU hosts differ in GPU passthrough mechanism, memory
# budget and viable model size, so read those off the hardware rather than
# shipping one set of defaults that only suits the machine it was written on.
echo ""
echo "==> Detecting platform …"
eval "$(bash "$SCRIPT_DIR/detect-platform.sh" --env)"
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
  if [[ "$PLATFORM_KIND" == "jetson" ]] && ! grep -q 'docker-compose.jetson.yml' .env; then
    echo "⚠  This is a Jetson but .env does not select the Jetson overlay."
    echo "   GPU passthrough will use the legacy --gpus path, which hangs on JetPack 6."
    echo "   Set in .env:  COMPOSE_FILE=$COMPOSE_FILES"
  fi
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
  elif python3 -m venv "$VENV_DIR" 2>/dev/null &&
       "$VENV_DIR/bin/pip" install --quiet --upgrade pip 2>/dev/null &&
       "$VENV_DIR/bin/pip" install --quiet -U huggingface-hub 2>/dev/null; then
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
source .env 2>/dev/null || true
MODEL_DIR_HOST="${MODELS_DIR:-./models}"
if ls "$MODEL_DIR_HOST"/*.gguf &>/dev/null; then
  echo "==> Models found in $MODEL_DIR_HOST:"
  ls -lh "$MODEL_DIR_HOST"/*.gguf

  # MODEL_FILE ships pointing at a placeholder that does not exist. If exactly
  # one model is present, wire it up rather than leaving a fresh checkout in a
  # state where `docker compose up` crash-loops on a missing file.
  MODEL_COUNT="$(ls -1 "$MODEL_DIR_HOST"/*.gguf 2>/dev/null | wc -l)"
  if [[ "${MODEL_FILE:-}" == "/models/model.gguf" ]]; then
    if (( MODEL_COUNT == 1 )); then
      ONLY_MODEL="$(basename "$(ls -1 "$MODEL_DIR_HOST"/*.gguf | head -1)")"
      sed -i "s|^MODEL_FILE=.*|MODEL_FILE=/models/${ONLY_MODEL}|" .env
      echo "    Set MODEL_FILE=/models/${ONLY_MODEL} in .env"
    else
      echo "⚠  Several models present — set MODEL_FILE=/models/<filename> in .env."
    fi
  fi
else
  echo "⚠  No .gguf model found in models/."
  echo "   Download one with:"
  echo "     ./scripts/download-model.sh <hf-repo> <filename>"
  echo "   Then set MODEL_FILE=/models/<filename> in .env"
fi

echo ""
echo "════════════════════════════════════════════════════"
echo " Setup complete. Next steps:"
echo ""
echo "   1. Place a .gguf model in ./models/"
echo "   2. Set MODEL_FILE=/models/<filename> in .env"
echo "   3. Run: docker compose up -d"
echo "   4. Test: curl --cacert certs/ca.crt https://localhost:8443/v1/models"
echo "════════════════════════════════════════════════════"
