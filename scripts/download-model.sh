#!/usr/bin/env bash
# download-model.sh - Download a GGUF model from Hugging Face.
#
# Supports single-file and split/sharded GGUF models, and can pull the model
# that detect-platform.sh recommends for this machine.
#
# Usage:
#   Platform-appropriate model (recommended):
#     ./scripts/download-model.sh --recommended
#
#   Single file:
#     ./scripts/download-model.sh <hf-repo> <filename>
#
#   Split/sharded (e.g. unsloth quants with subdirectories):
#     ./scripts/download-model.sh <hf-repo> --include "<pattern>"
#
#   Reclaim disk from interrupted downloads:
#     ./scripts/download-model.sh --prune
#
# Examples:
#   ./scripts/download-model.sh --recommended
#   ./scripts/download-model.sh TheBloke/Mistral-7B-Instruct-v0.2-GGUF \
#       mistral-7b-instruct-v0.2.Q4_K_M.gguf
#   ./scripts/download-model.sh unsloth/Qwen3.5-397B-A17B-GGUF --include 'Q4_K_M/*'
#
# Files are saved to MODELS_DIR (from .env), defaulting to ./models.
#
# HF_ENDPOINT overrides the Hugging Face base URL (a mirror, an internal proxy).
# huggingface_hub honours the same variable, so both download paths agree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
HF_ENDPOINT="${HF_ENDPOINT%/}"
export HF_ENDPOINT

# Read one key out of .env with compose's semantics: the last uncommented
# assignment wins, surrounding quotes come off, and an unquoted value ends at
# the first whitespace-preceded '#'. Deliberately not `source` and deliberately
# not a bare `sed 's/^KEY=//'`: .env is compose syntax, so both a documented
# inline comment and a file saved with CRLF line endings otherwise end up
# *inside* the value, and a path is the one setting where that is invisible
# until several GB have landed in a directory nothing reads.
env_get() {
  local key="$1" val
  [[ -f "$PROJECT_DIR/.env" ]] || return 0
  val="$(grep -E "^[[:space:]]*${key}=" "$PROJECT_DIR/.env" | tail -1)" || return 0
  val="${val#*=}"
  val="${val%$'\r'}"
  if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  else
    val="${val%%[[:space:]]#*}"
    val="${val%"${val##*[![:space:]]}"}"
  fi
  printf '%s' "$val"
}

# ── Destination ────────────────────────────────────────────────
# docker-compose.yml bind-mounts ${MODELS_DIR:-./models} at /models, and both
# setup.sh and validate.sh resolve the host path the same way. Hardcoding
# ./models here would silently download into the repo on any host that points
# MODELS_DIR at a data disk - the container would never see the file, and the
# several GB would sit on the wrong filesystem unnoticed.
MODEL_DIR="$(env_get MODELS_DIR)"
MODEL_DIR="${MODEL_DIR:-./models}"
# Resolve relative paths against the project, not the caller's cwd.
[[ "$MODEL_DIR" != /* ]] && MODEL_DIR="$PROJECT_DIR/${MODEL_DIR#./}"

usage() {
  cat <<EOF
Usage:
  $0 --recommended                  # model sized for this machine
  $0 <hf-repo> <gguf-filename>
  $0 <hf-repo> --include <pattern>
  $0 --prune                        # delete interrupted partial downloads

Examples:
  $0 --recommended
  $0 TheBloke/Mistral-7B-Instruct-v0.2-GGUF mistral-7b-instruct-v0.2.Q4_K_M.gguf
  $0 unsloth/Qwen3.5-397B-A17B-GGUF --include 'Q4_K_M/*'

Models are saved to: $MODEL_DIR
EOF
}

# ── Helpers ────────────────────────────────────────────────────

# Human-readable MiB/GiB from a byte count.
human() {
  local b="${1:-0}"
  if (( b >= 1073741824 )); then
    awk -v b="$b" 'BEGIN{printf "%.1f GiB", b/1073741824}'
  else
    awk -v b="$b" 'BEGIN{printf "%.0f MiB", b/1048576}'
  fi
}

# Free bytes on the filesystem backing a directory. Walks up to the nearest
# existing ancestor so this works before the directory has been created.
free_bytes() {
  local d="$1"
  while [[ ! -d "$d" && "$d" != "/" ]]; do d="$(dirname "$d")"; done
  df -Pk "$d" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4*1024}'
}

# Remote size of a Hugging Face file, in bytes, without downloading it.
# The resolve/ endpoint answers a HEAD with a 302 carrying x-linked-size (the
# real LFS object size); the final hop's content-length agrees. Take the last
# value seen so both shapes work, and emit nothing if the probe fails.
remote_size() {
  local url="$1" hdrs
  hdrs="$(curl -sIL --max-time 30 "$url" 2>/dev/null)" || return 1
  # A 4xx/5xx anywhere in the chain means the file is not fetchable.
  if ! grep -qiE '^HTTP/[0-9.]+ 2' <<<"$hdrs"; then return 1; fi
  local sz
  sz="$(grep -i '^x-linked-size:' <<<"$hdrs" | tail -1 | tr -dc '0-9')"
  [[ -z "$sz" ]] && sz="$(grep -i '^content-length:' <<<"$hdrs" | tail -1 | tr -dc '0-9')"
  [[ -n "$sz" ]] && printf '%s' "$sz"
}

# Refuse a download that would not fit, instead of filling the disk and leaving
# a truncated GGUF behind. Keep a margin free: llama.cpp memory-maps the model,
# and a filesystem at 100% breaks far more than this download.
MARGIN_BYTES=$((512 * 1024 * 1024))
check_space() {
  local need="$1" dir="$2" avail
  avail="$(free_bytes "$dir")"
  if [[ -z "$avail" || -z "$need" || "$need" -le 0 ]]; then
    echo "    Free space: unable to determine - proceeding without a check."
    return 0
  fi
  echo "    Download size : $(human "$need")"
  echo "    Free on disk  : $(human "$avail")"
  if (( avail < need + MARGIN_BYTES )); then
    echo "" >&2
    echo "Error: not enough free space in $dir" >&2
    echo "  need $(human "$need") plus a $(human "$MARGIN_BYTES") safety margin," \
         "have $(human "$avail")." >&2
    echo "  Free some space, or point MODELS_DIR in .env at a larger filesystem." >&2
    echo "  Existing models can be listed with: $0 --prune" >&2
    exit 1
  fi
}

# A GGUF file starts with the magic bytes "GGUF". An HTTP error body ("Entry
# not found"), an HTML login page or a half-finished transfer does not - and
# each of those otherwise lands on disk named *.gguf, gets auto-wired into
# .env by setup.sh, and crash-loops the container with an opaque load error.
verify_gguf() {
  local f="$1" magic
  magic="$(head -c 4 "$f" 2>/dev/null || true)"
  [[ "$magic" == "GGUF" ]]
}

# Report and remove partial transfers. These are the real disk hogs: an
# interrupted multi-GB download leaves a blob that nothing will ever use.
prune_partials() {
  local quiet="${1:-}" found=0 total=0
  if [[ ! -d "$MODEL_DIR" ]]; then
    [[ "$quiet" != "quiet" ]] && echo "    No partial downloads found."
    return 0
  fi
  local f
  while IFS= read -r -d '' f; do
    local sz; sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    total=$((total + sz)); found=$((found + 1))
    echo "    removing $(human "$sz")  ${f#"$MODEL_DIR"/}"
    rm -f "$f"
  done < <(find "$MODEL_DIR" \( -name '*.incomplete' -o -name '*.gguf.part' \) -type f -print0 2>/dev/null)
  if (( found > 0 )); then
    echo "    Reclaimed $(human "$total") from $found partial download(s)."
  elif [[ "$quiet" != "quiet" ]]; then
    echo "    No partial downloads found."
  fi
}

# ── Argument handling ──────────────────────────────────────────
# Usage errors exit 2, so a caller can tell "you asked for the wrong thing"
# apart from "the download failed" (exit 1).
die_usage() {
  echo "Error: $1" >&2
  echo "" >&2
  usage >&2
  exit 2
}

if [[ $# -lt 1 ]]; then usage >&2; exit 2; fi

case "$1" in
  -h|--help) usage; exit 0 ;;
  --prune)
    echo "==> Reclaiming space in $MODEL_DIR …"
    prune_partials
    echo ""
    if compgen -G "$MODEL_DIR"/*.gguf >/dev/null 2>&1; then
      echo "    Models currently on disk:"
      du -h "$MODEL_DIR"/*.gguf 2>/dev/null | sed 's/^/      /'
      echo ""
      echo "    Delete any you no longer use - only the one named by MODEL_FILE"
      echo "    in .env is actually served."
    fi
    exit 0
    ;;
  --recommended)
    # Keep stderr out of the string that gets eval'd: any warning the probe
    # learns to print would otherwise be executed as shell. And check what came
    # back - a probe that fails on an unfamiliar host used to leave every
    # REC_* variable unset, so the next line died with a raw bash
    # "REC_MODEL_REPO: unbound variable" instead of saying what went wrong.
    _perr="$(mktemp)"
    trap 'rm -f "$_perr"' EXIT
    if ! _penv="$(bash "$SCRIPT_DIR/detect-platform.sh" --env 2>"$_perr")"; then
      echo "Error: platform detection failed - cannot pick a model for this machine." >&2
      [[ -s "$_perr" ]] && sed 's/^/  /' "$_perr" >&2
      echo "  Name the repo and file explicitly instead: $0 <hf-repo> <gguf-filename>" >&2
      exit 1
    fi
    eval "$_penv"
    if [[ -z "${REC_MODEL_REPO:-}" || -z "${REC_MODEL_FILE:-}" ]]; then
      echo "Error: platform detection returned no model recommendation." >&2
      [[ -s "$_perr" ]] && sed 's/^/  /' "$_perr" >&2
      echo "  Run ./scripts/detect-platform.sh to see what it found." >&2
      echo "  Name the repo and file explicitly instead: $0 <hf-repo> <gguf-filename>" >&2
      exit 1
    fi
    REPO="$REC_MODEL_REPO"
    set -- "$REC_MODEL_FILE"
    echo "==> Platform: ${PLATFORM_LABEL:-unknown} (${PLATFORM_KIND:-?})"
    echo "    Recommended model for a $(( ${GPU_MEM_MB:-0} / 1024 )) GiB budget:"
    echo "      $REPO / $1"
    echo ""
    ;;
  -*)
    die_usage "unknown option: $1"
    ;;
  *)
    if [[ $# -lt 2 ]]; then
      die_usage "missing filename - a repo alone does not say which file to fetch."
    fi
    REPO="$1"
    shift
    ;;
esac

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
  if [[ $# -lt 2 || -z "$2" ]]; then
    die_usage "--include requires a pattern, e.g. --include 'Q4_K_M/*'"
  fi
  PATTERN="$2"

  if ! has_hf_cli; then
    echo "Error: huggingface-cli is required for split/sharded downloads."
    echo "Install it with: pip install -U huggingface-hub"
    exit 1
  fi

  echo "==> Downloading from $REPO (pattern: $PATTERN) …"
  echo "    Destination: $MODEL_DIR/"
  # Shard sizes are only known to the CLI, so report headroom rather than
  # gating on a total this script cannot compute.
  echo "    Free on disk: $(human "$(free_bytes "$MODEL_DIR")")"
  echo ""

  "$HF_CLI" download "$REPO" \
    --include "$PATTERN" \
    --local-dir "$MODEL_DIR"

  # Find the first shard for MODEL_FILE
  SUBDIR="${PATTERN%%/*}"
  FIRST_SHARD=$(find "$MODEL_DIR/$SUBDIR" -name '*00001-of-*.gguf' 2>/dev/null | head -1)
  SINGLE_FILE=$(find "$MODEL_DIR/$SUBDIR" -name '*.gguf' ! -name '*-of-*' 2>/dev/null | head -1)

  TARGET="${FIRST_SHARD:-$SINGLE_FILE}"
  if [[ -n "$TARGET" ]] && ! verify_gguf "$TARGET"; then
    echo ""
    echo "Error: $TARGET is not a valid GGUF file (bad magic bytes)." >&2
    exit 1
  fi

  echo ""
  echo "==> Cleaning up transfer leftovers …"
  prune_partials quiet

  echo ""
  echo "✔ Model downloaded to $MODEL_DIR/$SUBDIR/"
  echo ""
  if [[ -n "$TARGET" ]]; then
    REL_PATH="/models/${TARGET#"$MODEL_DIR/"}"
    echo "Update .env to point to it:"
    echo "  MODEL_FILE=$REL_PATH"
  fi
  exit 0
fi

# ── Single file download ──────────────────────────────────────
FILE="$1"
DEST="$MODEL_DIR/$FILE"
URL="$HF_ENDPOINT/${REPO}/resolve/main/${FILE}"

SIZE=""
if [[ -f "$DEST" ]]; then
  EXISTING="$(stat -c %s "$DEST")"
  if ! verify_gguf "$DEST"; then
    # A file that fails the magic check is a leftover from a previous failed
    # run. Resuming it with `curl -C -` would splice new bytes onto an error
    # page, so start clean instead.
    echo "==> Discarding invalid existing file ($(human "$EXISTING")): $DEST"
    rm -f "$DEST"
  else
    # Magic bytes alone do not mean the file is complete. A transfer killed
    # after its first 4 KiB leaves something that starts with "GGUF" and is
    # still unusable, and this fast path used to accept it forever: every
    # re-run printed "already present and valid" and exited 0, so the only
    # way out was to notice the byte count by hand. Confirm the size against
    # the remote before trusting it.
    echo "==> Verifying existing $FILE …"
    SIZE="$(remote_size "$URL" || true)"
    if [[ -z "$SIZE" ]]; then
      # Offline, or a repo that has since gone private. The file may well be
      # fine, so keep it - but do not claim it was verified.
      echo "⚠  Could not reach $HF_ENDPOINT to confirm the expected size."
      echo "   Keeping $DEST ($(human "$EXISTING")) unverified."
      echo ""
      echo "Update .env to point to it:"
      echo "  MODEL_FILE=/models/$FILE"
      exit 0
    fi
    if (( EXISTING == SIZE )); then
      echo "✔ Model already present and verified: $DEST ($(human "$EXISTING"), GGUF, full size)"
      echo ""
      echo "Update .env to point to it:"
      echo "  MODEL_FILE=/models/$FILE"
      exit 0
    fi
    echo "==> Existing file is incomplete: have $(human "$EXISTING"), expected $(human "$SIZE")."
    echo "    Discarding it and downloading again."
    rm -f "$DEST"
  fi
fi

if [[ -z "$SIZE" ]]; then
  echo "==> Checking $FILE in $REPO …"
  SIZE="$(remote_size "$URL" || true)"
fi
if [[ -z "$SIZE" ]]; then
  echo "" >&2
  echo "Error: $FILE was not found in $REPO (or Hugging Face is unreachable)." >&2
  echo "  URL: $URL" >&2
  echo "  Check the repo and filename - nothing was written to disk." >&2
  exit 1
fi
check_space "$SIZE" "$MODEL_DIR"
echo ""

echo "==> Downloading $FILE from $REPO …"
echo "    Dest: $DEST"
echo ""

# Remove a partial transfer on interrupt or error so a failed run never leaves
# a truncated GGUF sitting in models/ for setup.sh to pick up. Unconditionally:
# this only runs while a transfer is in flight, and the magic bytes are the
# first thing to arrive, so a file interrupted at 5% passes verify_gguf and
# looks exactly like a complete model to everything downstream.
cleanup_partial() { rm -f "$DEST"; return 0; }
trap cleanup_partial INT TERM

if has_hf_cli; then
  # Prefer the CLI when available: it authenticates and resumes.
  "$HF_CLI" download "$REPO" "$FILE" --local-dir "$MODEL_DIR"
else
  # -f makes curl fail on an HTTP error instead of writing the error body to
  # the destination. Without it a typo'd filename produces a 15-byte "Entry
  # not found" file named *.gguf, which setup.sh then wires into .env.
  if ! curl -fL --progress-bar -o "$DEST" "$URL"; then
    cleanup_partial
    echo "" >&2
    echo "Error: download failed - no partial file was left behind." >&2
    exit 1
  fi
fi

trap - INT TERM

# ── Verify what actually landed ────────────────────────────────
if [[ ! -f "$DEST" ]]; then
  echo "Error: expected $DEST after download, but it is missing." >&2
  exit 1
fi

ACTUAL="$(stat -c %s "$DEST")"
if ! verify_gguf "$DEST"; then
  rm -f "$DEST"
  echo "Error: downloaded file is not a valid GGUF (bad magic bytes) - deleted." >&2
  exit 1
fi
if (( ACTUAL != SIZE )); then
  rm -f "$DEST"
  echo "Error: size mismatch - expected $(human "$SIZE"), got $(human "$ACTUAL") - deleted." >&2
  echo "  The transfer was truncated. Re-run to try again." >&2
  exit 1
fi

prune_partials quiet

echo ""
echo "✔ Model saved to $DEST ($(human "$ACTUAL"), GGUF verified)"
echo ""
echo "Update .env to point to it:"
echo "  MODEL_FILE=/models/$FILE"
