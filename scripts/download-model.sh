#!/usr/bin/env bash
# download-model.sh - Download a GGUF model from Hugging Face.
#
# Supports both single-file and split/sharded GGUF models.
#
# Usage:
#   Single file:
#     ./scripts/download-model.sh <hf-repo> <filename>
#
#   Split/sharded (e.g. unsloth quants with subdirectories):
#     ./scripts/download-model.sh <hf-repo> --include "<pattern>"
#
# Examples:
#   # Single file download
#   ./scripts/download-model.sh TheBloke/Mistral-7B-Instruct-v0.2-GGUF \
#       mistral-7b-instruct-v0.2.Q4_K_M.gguf
#
#   # Split/sharded model (downloads entire subdirectory)
#   ./scripts/download-model.sh unsloth/Qwen3.5-397B-A17B-GGUF \
#       --include "Q4_K_M/*"
#
# Files are saved to ./models/.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage:"
  echo "  $0 <hf-repo> <gguf-filename>"
  echo "  $0 <hf-repo> --include <pattern>"
  echo ""
  echo "Examples:"
  echo "  # Single file"
  echo "  $0 TheBloke/Mistral-7B-Instruct-v0.2-GGUF mistral-7b-instruct-v0.2.Q4_K_M.gguf"
  echo ""
  echo "  # Split/sharded model (subdirectory)"
  echo "  $0 unsloth/Qwen3.5-397B-A17B-GGUF --include 'Q4_K_M/*'"
  exit 1
fi

REPO="$1"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MODEL_DIR="$PROJECT_DIR/models"

mkdir -p "$MODEL_DIR"

# ── Resolve Hugging Face CLI (prefer project venv) ─────────────
# huggingface-hub >= 0.34 renamed `huggingface-cli` to `hf`. Try the new name
# first, fall back to the legacy one for older installs.
HF_CLI=""
for candidate in \
    "$PROJECT_DIR/.venv/bin/hf" \
    "$PROJECT_DIR/.venv/bin/huggingface-cli" \
    "$(command -v hf 2>/dev/null || true)" \
    "$(command -v huggingface-cli 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    HF_CLI="$candidate"
    break
  fi
done

has_hf_cli() { [[ -n "$HF_CLI" ]]; }

# ── Split/sharded download via --include ───────────────────────
if [[ "$1" == "--include" ]]; then
  PATTERN="${2:?Missing pattern after --include}"

  if ! has_hf_cli; then
    echo "Error: huggingface-cli is required for split/sharded downloads."
    echo "Install it with: pip install -U huggingface-hub"
    exit 1
  fi

  echo "==> Downloading from $REPO (pattern: $PATTERN) …"
  echo "    Destination: $MODEL_DIR/"
  echo ""

  "$HF_CLI" download "$REPO" \
    --include "$PATTERN" \
    --local-dir "$MODEL_DIR"

  # Find the first shard for MODEL_FILE
  SUBDIR="${PATTERN%%/*}"
  FIRST_SHARD=$(find "$MODEL_DIR/$SUBDIR" -name '*00001-of-*.gguf' 2>/dev/null | head -1)
  SINGLE_FILE=$(find "$MODEL_DIR/$SUBDIR" -name '*.gguf' ! -name '*-of-*' 2>/dev/null | head -1)

  echo ""
  echo "✔ Model downloaded to $MODEL_DIR/$SUBDIR/"
  echo ""
  if [[ -n "$FIRST_SHARD" ]]; then
    REL_PATH="/models/${FIRST_SHARD#"$MODEL_DIR/"}"
    echo "Update .env to point to the first shard:"
    echo "  MODEL_FILE=$REL_PATH"
  elif [[ -n "$SINGLE_FILE" ]]; then
    REL_PATH="/models/${SINGLE_FILE#"$MODEL_DIR/"}"
    echo "Update .env to point to it:"
    echo "  MODEL_FILE=$REL_PATH"
  fi
  exit 0
fi

# ── Single file download ──────────────────────────────────────
FILE="$1"

if has_hf_cli; then
  # Prefer huggingface-cli for resume support and authentication
  echo "==> Downloading $FILE from $REPO via huggingface-cli …"
  "$HF_CLI" download "$REPO" "$FILE" --local-dir "$MODEL_DIR"
else
  # Fallback to curl
  URL="https://huggingface.co/${REPO}/resolve/main/${FILE}"
  DEST="$MODEL_DIR/$FILE"

  if [[ -f "$DEST" ]]; then
    echo "Model already exists: $DEST"
    echo "Delete it first if you want to re-download."
    exit 0
  fi

  echo "==> Downloading $FILE from $REPO …"
  echo "    URL:  $URL"
  echo "    Dest: $DEST"
  echo ""

  curl -L -C - --progress-bar -o "$DEST" "$URL"
fi

echo ""
echo "✔ Model saved to $MODEL_DIR/$FILE"
echo ""
echo "Update .env to point to it:"
echo "  MODEL_FILE=/models/$FILE"
