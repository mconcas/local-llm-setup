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

# ── 2. .env file ───────────────────────────────────────────────
if [[ ! -f .env ]]; then
  echo "==> Creating .env from .env.example …"
  cp .env.example .env
  echo "    Edit .env to set MODEL_FILE and other options."
else
  echo "==> .env already exists, skipping."
fi

# ── 3. Generate TLS certificates ──────────────────────────────
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

# ── 4. Check for NVIDIA Container Toolkit ─────────────────────
echo ""
if command -v nvidia-smi &>/dev/null; then
  echo "==> NVIDIA GPU detected:"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true
else
  echo "⚠  nvidia-smi not found. GPU acceleration may not work."
  echo "   Install the NVIDIA Container Toolkit:"
  echo "   https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
fi

# ── 5. Check Docker ───────────────────────────────────────────
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

# ── 6. Check for model ────────────────────────────────────────
echo ""
source .env 2>/dev/null || true
MODEL_BASENAME="$(basename "${MODEL_FILE:-model.gguf}")"
if ls models/*.gguf &>/dev/null; then
  echo "==> Models found in models/:"
  ls -lh models/*.gguf
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
