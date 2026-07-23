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
# Options:
#   --no-fit-check    download even if the model cannot run on this board
#
# Examples:
#   ./scripts/download-model.sh --recommended
#   ./scripts/download-model.sh TheBloke/Mistral-7B-Instruct-v0.2-GGUF \
#       mistral-7b-instruct-v0.2.Q4_K_M.gguf
#   ./scripts/download-model.sh unsloth/Qwen3.5-397B-A17B-GGUF --include 'Q4_K_M/*'
#
# Files are saved to MODELS_DIR (from .env), defaulting to ./models.
#
# Before transferring the body, the model is sized against this board: GGUF
# keeps its metadata at the head of the file, so one ranged request is enough to
# compute the KV cache the configured CTX_SIZE and CACHE_TYPE_K/V will ask for.
# A model that cannot be served is the "useless model file" this script exists
# to keep off the disk, and refusing it costs a few MiB instead of several GB.
#
# A sharded --include pull gets the same two preflights: the repo's file list
# carries every shard's real size, so the set is totalled against free disk and
# sized against the board from the first shard's metadata before the transfer
# starts.
#
# Exit codes: 0 ok, 1 the download failed, 2 wrong arguments, 3 it will not fit.
#
# HF_ENDPOINT overrides the Hugging Face base URL (a mirror, an internal proxy).
# huggingface_hub honours the same variable, so both download paths agree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
HF_ENDPOINT="${HF_ENDPOINT%/}"
export HF_ENDPOINT

# .env is compose syntax, not shell - see lib/env.sh for why reading it needs
# more care than `source` or a sed. A path is the one setting where getting it
# wrong is invisible until several GB have landed in a directory nothing reads.
ENV_FILE="$PROJECT_DIR/.env"
. "$SCRIPT_DIR/lib/env.sh"
# The same arithmetic validate.sh uses. Sharing it is the point: a model this
# script accepts must be one the suite then agrees fits, or the two disagree
# about the deployment and the user finds out from a crash loop.
. "$SCRIPT_DIR/lib/mem.sh"

# ── Destination ────────────────────────────────────────────────
# docker-compose.yml bind-mounts ${MODELS_DIR:-./models} at /models, and both
# setup.sh and validate.sh resolve the host path the same way. Hardcoding
# ./models here would silently download into the repo on any host that points
# MODELS_DIR at a data disk - the container would never see the file, and the
# several GB would sit on the wrong filesystem unnoticed.
MODEL_DIR_RAW="$(env_get MODELS_DIR)"
MODEL_DIR_RAW="${MODEL_DIR_RAW:-./models}"
# env_bind_path applies compose's rules for a bind source (a leading `~` is
# expanded, a bare relative path is a named volume and not a directory at all),
# so several GB cannot land somewhere the container will not mount.
ENV_PROJECT_DIR="$PROJECT_DIR"   # compose resolves a relative source against this
if ! MODEL_DIR="$(env_bind_path "$MODEL_DIR_RAW" 2>/dev/null)"; then
  echo "MODELS_DIR=$MODEL_DIR_RAW cannot be bind-mounted by compose:" >&2
  echo "  $(env_bind_path "$MODEL_DIR_RAW" 2>&1 >/dev/null)" >&2
  echo "Nothing was downloaded - fix MODELS_DIR in .env first." >&2
  exit 2
fi

usage() {
  cat <<EOF
Usage:
  $0 --recommended                  # model sized for this machine
  $0 <hf-repo> <gguf-filename>
  $0 <hf-repo> --include <pattern>
  $0 --prune                        # delete interrupted partial downloads

Options:
  --no-fit-check                    download even if it cannot run here

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

# hf_tree REPO PATTERN - the repo's files matching PATTERN, one "<bytes>\t<path>"
# line each. rc=1 with a reason on stderr when the listing cannot be read; rc=0
# with no output when it was read and nothing matched.
#
# Shard sizes used to be knowable only to huggingface-cli, which is why the
# sharded path had neither of the guarantees the single-file path has: the
# script could not total a download it had not started, so `--include` on a
# repo far larger than the disk transferred until the filesystem filled. The
# tree API answers exactly that question - every file with its real LFS size -
# before a byte of any body moves.
#
# The pattern is matched with Python's fnmatch because that is what
# huggingface_hub's filter_repo_objects uses for allow_patterns, including its
# rule that a trailing "/" means the directory's contents. Whatever this totals
# has to be the same set the CLI then transfers, or the preflight is sizing a
# different download than the one that happens.
hf_tree() {
  local repo="$1" pat="$2"
  command -v python3 >/dev/null 2>&1 || {
    printf 'python3 is needed to read the repository listing' >&2; return 1; }
  local url="$HF_ENDPOINT/api/models/$repo/tree/main?recursive=true"
  local page=0 body hdrs matched out=""
  while [[ -n "$url" ]] && (( page < 50 )); do
    page=$((page + 1))
    hdrs="$(mktemp)"
    if ! body="$(curl -sfL --max-time 60 -D "$hdrs" "$url" 2>/dev/null)"; then
      rm -f "$hdrs"
      printf 'the file list for %s could not be fetched' "$repo" >&2
      return 1
    fi
    if ! matched="$(printf '%s' "$body" | python3 -c '
import json, sys, fnmatch
pat = sys.argv[1]
if pat.endswith("/"):
    pat += "*"
for e in json.load(sys.stdin):
    if e.get("type") != "file":
        continue
    p = e.get("path", "")
    if not fnmatch.fnmatch(p, pat):
        continue
    lfs = e.get("lfs") or {}
    # An LFS pointer is a few hundred bytes; lfs.size is the object behind it.
    print("%d\t%s" % (int(lfs.get("size") or e.get("size") or 0), p))
' "$pat" 2>/dev/null)"; then
      rm -f "$hdrs"
      printf 'the file list for %s was not readable JSON' "$repo" >&2
      return 1
    fi
    [[ -n "$matched" ]] && out="${out:+$out$'\n'}$matched"
    # The API pages with a Link header; a repo with hundreds of quants needs it.
    url="$(grep -i '^link:' "$hdrs" |
           sed -n 's/.*<\([^>]*\)>[[:space:]]*;[[:space:]]*rel="next".*/\1/p' | tail -1)"
    rm -f "$hdrs"
  done
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
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

# ── Will it actually run once it is here? ──────────────────────
# Free space is only half the question. On a Jetson the weights, the KV cache
# and the compute buffers all come out of the one pool the OS is already using,
# and none of that is visible in the file size: the same 1.8 GiB model needs
# 306 MiB of cache at CTX_SIZE=16384/q8_0 and 6 GiB at 131072/f16. A model the
# board cannot serve is exactly the file the objective says not to leave lying
# around, so decide before the body is transferred rather than after.
FIT_CHECK=1
# How much of the head to read. GGUF stores its metadata block first, so the
# geometry is always in the prefix; 16 MiB clears the largest tokenizer array in
# the recommended set (the 14B needs just under 8). Configurable because the
# self-test serves models whose metadata ends far sooner.
FIT_HEADER_BYTES="${FIT_HEADER_BYTES:-16777216}"

# platform_probe - run detect-platform.sh once and eval its output here.
# rc=1 with the reason in PLATFORM_PROBE_ERR when it cannot be read. Keeps the
# probe's stderr out of the string that gets eval'd: any warning it learns to
# print would otherwise be executed as shell.
PLATFORM_PROBED=0
PLATFORM_PROBE_RC=0
PLATFORM_PROBE_ERR=""
platform_probe() {
  (( PLATFORM_PROBED )) && return "$PLATFORM_PROBE_RC"
  PLATFORM_PROBED=1
  local err penv
  err="$(mktemp)"
  if penv="$(bash "$SCRIPT_DIR/detect-platform.sh" --env 2>"$err")"; then
    eval "$penv"
  else
    PLATFORM_PROBE_RC=1
  fi
  PLATFORM_PROBE_ERR="$(cat "$err")"
  rm -f "$err"
  return "$PLATFORM_PROBE_RC"
}

# fit_fetch_header URL DEST - the first FIT_HEADER_BYTES of URL.
#
# --max-filesize is not belt-and-braces: a server that ignores Range answers 200
# with the whole object, and without it this "preflight" would download the very
# model it was meant to avoid downloading. curl checks the advertised length
# before transferring, so an endpoint with no range support costs nothing.
fit_fetch_header() {
  local url="$1" dest="$2"
  curl -sfL --max-time 120 \
       -r "0-$((FIT_HEADER_BYTES - 1))" \
       --max-filesize "$FIT_HEADER_BYTES" \
       -o "$dest" "$url" 2>/dev/null
}

# check_fit URL WEIGHT_BYTES - refuse a model this board cannot serve (exit 3).
# Anything that cannot be established - no budget, no metadata, an endpoint with
# no range support - is reported as a skip with its reason and lets the download
# proceed. A preflight that guesses is worse than one that says it did not run.
check_fit() {
  local url="$1" bytes="$2"
  (( FIT_CHECK )) || { echo "    Fit check     : skipped (--no-fit-check)"; return 0; }

  if ! platform_probe; then
    echo "    Fit check     : skipped (platform detection failed)"
    return 0
  fi
  if [[ -z "${GPU_MEM_MB:-}" ]] || (( GPU_MEM_MB <= 0 )); then
    echo "    Fit check     : skipped (${PLATFORM_LABEL:-this host} has no GPU memory budget)"
    return 0
  fi

  # The configuration the model will be served under, which is what decides the
  # cache. .env wins over the recommendation: a user who lowered CTX_SIZE has
  # already made this decision, and sizing against the default would refuse a
  # model their own configuration can hold.
  local ctx tk tv
  ctx="$(env_get CTX_SIZE)";    ctx="${ctx:-${REC_CTX_SIZE:-4096}}"
  tk="$(env_get CACHE_TYPE_K)"; tk="${tk:-${REC_CACHE_TYPE:-f16}}"
  tv="$(env_get CACHE_TYPE_V)"; tv="${tv:-${REC_CACHE_TYPE:-f16}}"
  [[ "$ctx" =~ ^[0-9]+$ ]] && (( ctx > 0 )) || ctx=4096

  local hdr; hdr="$(mktemp)"
  if ! fit_fetch_header "$url" "$hdr"; then
    rm -f "$hdr"
    echo "    Fit check     : skipped (the model header could not be fetched)"
    return 0
  fi
  local meta why
  why="$(mktemp)"
  if ! meta="$(mem_model_read "$hdr" 2>"$why")"; then
    echo "    Fit check     : skipped ($(cat "$why"))"
    rm -f "$hdr" "$why"
    return 0
  fi
  rm -f "$hdr" "$why"
  # Eval-safe by contract - see lib/gguf.py, which quotes every string field and
  # emits nothing at all rather than a partial record.
  eval "$meta"

  local kv
  if ! kv="$(mem_kv_bytes "$ctx" "$GGUF_K_ELEMS_PER_TOKEN" "$GGUF_V_ELEMS_PER_TOKEN" \
                          "$tk" "$tv" 2>&1)"; then
    echo "    Fit check     : skipped ($kv)"
    echo "                    CACHE_TYPE_K/V in .env is not a type llama.cpp quantizes to."
    return 0
  fi

  local w_mib kv_mib total pct
  w_mib=$(( bytes / 1048576 ))
  kv_mib="$(mem_mib "$kv")"
  total=$(( w_mib + kv_mib ))
  pct=$(( total * 100 / GPU_MEM_MB ))
  echo "    Memory budget : ${GPU_MEM_MB} MiB (${PLATFORM_LABEL:-this host})"
  echo "    Once loaded   : weights ${w_mib} + ${ctx}-token ${tk}/${tv} KV cache ${kv_mib}" \
       "= ${total} MiB (${pct}%)"

  # The largest context that leaves the compute buffers somewhere to live. Same
  # quarter-of-the-budget reservation validate.sh makes, and for the same
  # reason: their size is a property of the llama.cpp build, so it is held back
  # rather than guessed at.
  local room=$(( (GPU_MEM_MB * 75 / 100 - w_mib) * 1048576 ))
  local fit_ctx=0 fit_ctx_q8=0
  if (( room > 0 )); then
    fit_ctx="$(mem_max_ctx "$room" "$GGUF_K_ELEMS_PER_TOKEN" \
                           "$GGUF_V_ELEMS_PER_TOKEN" "$tk" "$tv" || echo 0)"
    # Quantising the cache halves it, so it can open room that the configured
    # type does not - but only while there is room at all. Compute it rather
    # than offering it as generic advice: on a board whose weights are already
    # past the line, "use q8_0" is a suggestion that cannot be taken.
    fit_ctx_q8="$(mem_max_ctx "$room" "$GGUF_K_ELEMS_PER_TOKEN" \
                              "$GGUF_V_ELEMS_PER_TOKEN" q8_0 q8_0 || echo 0)"
  fi

  # An architecture this arithmetic overestimates gives an upper bound, and an
  # upper bound cannot prove a model does *not* fit. Report it and let the
  # transfer go ahead rather than refusing on a number known to be too large.
  if (( total >= GPU_MEM_MB )) && [[ -n "${GGUF_ESTIMATE_CAVEAT:-}" ]]; then
    echo "⚠  That is an upper bound: ${GGUF_ESTIMATE_CAVEAT}"
    echo "   The real footprint is smaller, so the download continues."
    return 0
  fi

  if (( total >= GPU_MEM_MB )); then
    echo "" >&2
    echo "Error: this model will not fit on ${PLATFORM_LABEL:-this board}." >&2
    echo "  weights $(human "$bytes") + a ${ctx}-token ${tk}/${tv} KV cache" \
         "= ${total} MiB, against a ${GPU_MEM_MB} MiB budget." >&2
    if (( fit_ctx > 0 )); then
      echo "  Set CTX_SIZE=$fit_ctx in .env and re-run - that context does fit." >&2
      (( fit_ctx_q8 > fit_ctx )) &&
        echo "  With CACHE_TYPE_K=q8_0 and CACHE_TYPE_V=q8_0, CTX_SIZE=$fit_ctx_q8 fits." >&2
    elif (( fit_ctx_q8 > 0 )); then
      echo "  No context fits with a ${tk}/${tv} cache. Set CACHE_TYPE_K=q8_0 and" \
           "CACHE_TYPE_V=q8_0 with CTX_SIZE=$fit_ctx_q8, which does." >&2
    else
      echo "  Weights of ${w_mib} MiB against a ${GPU_MEM_MB} MiB budget leave" \
           "no room for any context, whatever the cache type." >&2
      [[ -n "${REC_MODEL_FILE:-}" ]] &&
        echo "  This board is sized for ${REC_MODEL_REPO}/${REC_MODEL_FILE}." >&2
    fi
    echo "  Nothing was downloaded. Re-run with --no-fit-check to fetch it anyway." >&2
    exit 3
  fi

  if (( pct > 75 )); then
    echo "⚠  That leaves ${GPU_MEM_MB} - ${total} = $(( GPU_MEM_MB - total )) MiB for the"
    echo "   compute buffers, which are not in that total and are usually a few"
    echo "   hundred MiB. Expect it to be tight."
    # Same reason the refusal derives its advice: past the line the weights put
    # it, there is no context to name, and "CTX_SIZE=0 has room" is what the
    # arithmetic literally returns.
    if (( fit_ctx > 0 )); then
      echo "   CTX_SIZE=${fit_ctx} would leave the buffers room."
    else
      echo "   The weights alone are ${w_mib} MiB of the budget, so no context does."
    fi
  fi
  return 0
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

# --no-fit-check is a modifier, not a mode, so pull it out before the positional
# parse below rather than adding it to every branch. ${a[@]+"${a[@]}"} because
# an empty array under `set -u` is an unbound variable, not an empty list.
_argv=()
for _a in "$@"; do
  case "$_a" in
    --no-fit-check) FIT_CHECK=0 ;;
    *) _argv+=("$_a") ;;
  esac
done
set -- ${_argv[@]+"${_argv[@]}"}

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
    # Check what came back - a probe that fails on an unfamiliar host used to
    # leave every REC_* variable unset, so the next line died with a raw bash
    # "REC_MODEL_REPO: unbound variable" instead of saying what went wrong.
    if ! platform_probe; then
      echo "Error: platform detection failed - cannot pick a model for this machine." >&2
      [[ -n "$PLATFORM_PROBE_ERR" ]] && sed 's/^/  /' <<<"$PLATFORM_PROBE_ERR" >&2
      echo "  Name the repo and file explicitly instead: $0 <hf-repo> <gguf-filename>" >&2
      exit 1
    fi
    if [[ -z "${REC_MODEL_REPO:-}" || -z "${REC_MODEL_FILE:-}" ]]; then
      echo "Error: platform detection returned no model recommendation." >&2
      [[ -n "$PLATFORM_PROBE_ERR" ]] && sed 's/^/  /' <<<"$PLATFORM_PROBE_ERR" >&2
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

  # Size the set before the CLI starts transferring it. A sharded pull is the
  # largest thing this script can be asked to do and was, until now, the only
  # one that started without knowing how big it was.
  TREE_ERR="$(mktemp)"
  TREE=""; TREE_RC=0
  TREE="$(hf_tree "$REPO" "$PATTERN" 2>"$TREE_ERR")" || TREE_RC=$?

  if (( TREE_RC == 0 )) && [[ -z "$TREE" ]]; then
    # The CLI treats this as a successful transfer of nothing, and the script
    # used to agree with it: "✔ Model downloaded", exit 0, empty directory.
    echo "" >&2
    echo "Error: no file in $REPO matches the pattern '$PATTERN'." >&2
    echo "  Patterns match the full path, so a quant in a subdirectory needs it:" >&2
    echo "    --include 'Q4_K_M/*'   not   --include '*.gguf'" >&2
    echo "  Browse the files at $HF_ENDPOINT/$REPO/tree/main" >&2
    echo "  Nothing was downloaded." >&2
    rm -f "$TREE_ERR"
    exit 2
  fi

  if (( TREE_RC == 0 )); then
    SHARD_TOTAL=0; SHARD_COUNT=0; WEIGHT_TOTAL=0; FIRST_REMOTE=""
    while IFS=$'\t' read -r _sz _path; do
      [[ -z "$_path" ]] && continue
      SHARD_TOTAL=$((SHARD_TOTAL + _sz)); SHARD_COUNT=$((SHARD_COUNT + 1))
      echo "      $(human "$_sz")  $_path"
      # The fit check sizes the weights, which are the GGUFs; a README or a
      # tokenizer caught by the pattern costs disk but not memory.
      [[ "$_path" == *.gguf ]] && WEIGHT_TOTAL=$((WEIGHT_TOTAL + _sz))
      if [[ -z "$FIRST_REMOTE" && "$_path" == *.gguf ]]; then FIRST_REMOTE="$_path"; fi
      [[ "$_path" == *00001-of-*.gguf ]] && FIRST_REMOTE="$_path"
    done <<<"$TREE"
    echo "    $SHARD_COUNT file(s) matched"
    check_space "$SHARD_TOTAL" "$MODEL_DIR"
    if [[ -n "$FIRST_REMOTE" ]]; then
      # A split GGUF keeps the whole model's metadata in its first shard, so
      # the same ranged read that sizes a single file sizes the set - against
      # the set's total weight, not the one shard the header came from.
      check_fit "$HF_ENDPOINT/${REPO}/resolve/main/${FIRST_REMOTE}" "$WEIGHT_TOTAL"
    else
      echo "    Fit check     : skipped (no .gguf among the matched files)"
    fi
  else
    # Say which guarantee is missing and why, rather than letting silence read
    # as a pass.
    echo "    Free on disk  : $(human "$(free_bytes "$MODEL_DIR")")"
    echo "    Download size : unknown - $(cat "$TREE_ERR")"
    echo "    Fit check     : skipped (the file list could not be read) - run"
    echo "                    ./scripts/validate.sh once MODEL_FILE points at the first shard."
  fi
  rm -f "$TREE_ERR"
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
check_fit "$URL" "$SIZE"
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
