#!/usr/bin/env bash
# detect-platform.sh - Identify the host platform and emit tuned defaults.
#
# The same stack runs on a discrete-GPU x86_64 workstation and on an NVIDIA
# Jetson (Tegra SoC, unified CPU/GPU memory). Those two targets need different
# container images, different GPU passthrough mechanisms and very different
# model sizes, so everything that varies is derived here instead of being
# hardcoded in docker-compose.yml.
#
# Usage:
#   ./scripts/detect-platform.sh            # human-readable report
#   ./scripts/detect-platform.sh --env      # KEY=VALUE, suitable for eval/source
#
# Emitted variables:
#   PLATFORM_KIND      jetson | nvidia-discrete | cpu
#   PLATFORM_ARCH      aarch64 | x86_64 | ...
#   PLATFORM_LABEL     human-readable board/GPU name
#   L4T_VERSION        Jetson only, e.g. 36.4.7
#   TOTAL_MEM_MB       total system RAM
#   GPU_MEM_MB         memory usable for model weights + KV cache
#   GPU_ACCESS         cdi | reservations | none
#   COMPOSE_FILES      colon-separated compose file list for COMPOSE_FILE
#   LLAMA_IMAGE        container image to run
#   REC_MODEL_REPO     recommended Hugging Face GGUF repo
#   REC_MODEL_FILE     recommended GGUF filename
#   REC_MODEL_MB       on-disk size of that model, in MiB
#   REC_CTX_SIZE       recommended context window
#   REC_PARALLEL       recommended concurrent request slots
#   REC_CACHE_TYPE     recommended KV cache quantisation
#   POWER_STATE        Jetson only: best | below | unknown-mode | ... (lib/power.sh)
#   POWER_ACTIVE_ID    the nvpmodel power mode the board is running in
#   POWER_ACTIVE_NAME
#   POWER_BEST_ID      the fastest mode the board's nvpmodel.conf offers
#   POWER_BEST_NAME
#   POWER_DEFAULT_ID   the mode nvpmodel.conf declares as the boot default
set -euo pipefail

EMIT_ENV=0
[[ "${1:-}" == "--env" ]] && EMIT_ENV=1

# ── Test hooks ────────────────────────────────────────────────────
# Every hardware probe below goes through these two variables so the detection
# logic can be exercised against boards that are not the one in hand. Empty
# defaults mean the real host is inspected, so normal use is unaffected.
#
#   PLATFORM_SYSROOT     prefix for /proc, /etc and /var/run probes
#   PLATFORM_NVIDIA_SMI  binary used for the discrete-GPU probe
#
# See scripts/test-detect-platform.sh.
SYSROOT="${PLATFORM_SYSROOT:-}"
NVIDIA_SMI="${PLATFORM_NVIDIA_SMI:-nvidia-smi}"

# ── Architecture ──────────────────────────────────────────────────
PLATFORM_ARCH="$(uname -m)"

# ── Jetson detection ──────────────────────────────────────────────
# A Jetson is identified by the L4T release file that JetPack installs, or by
# the Tegra device-tree model name. Checking for `tegra` in `uname -r` alone is
# not enough: some non-Jetson ARM boards also ship Tegra-derived kernels.
L4T_VERSION=""
JETSON_MODEL=""
if [[ -f "$SYSROOT/etc/nv_tegra_release" ]]; then
  # Format: "# R36 (release), REVISION: 4.7, GCID: ..., BOARD: generic, ..."
  _major="$(sed -n 's/^# R\([0-9]\+\).*/\1/p' "$SYSROOT/etc/nv_tegra_release" | head -1)"
  _rev="$(sed -n 's/.*REVISION: \([0-9.]\+\).*/\1/p' "$SYSROOT/etc/nv_tegra_release" | head -1)"
  [[ -n "$_major" ]] && L4T_VERSION="${_major}.${_rev}"
fi
if [[ -r "$SYSROOT/proc/device-tree/model" ]]; then
  JETSON_MODEL="$(tr -d '\0' < "$SYSROOT/proc/device-tree/model" 2>/dev/null || true)"
fi

# ── Memory ────────────────────────────────────────────────────────
TOTAL_MEM_MB="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' "$SYSROOT/proc/meminfo")"

# ── Classify the platform ─────────────────────────────────────────
GPU_MEM_MB=0
if [[ -n "$L4T_VERSION" || "$JETSON_MODEL" == *Jetson* || "$JETSON_MODEL" == *Orin* ]]; then
  PLATFORM_KIND="jetson"
  PLATFORM_LABEL="${JETSON_MODEL:-NVIDIA Jetson}"
  # Jetson has no dedicated VRAM: CPU and GPU share one LPDDR pool. Everything
  # the model allocates competes with the OS, the desktop session and the page
  # cache, so budget conservatively rather than using the full figure that
  # llama.cpp reports as "VRAM".
  #
  # Reserve 2 GB for the OS on >=8 GB boards, 1.5 GB on smaller ones.
  if (( TOTAL_MEM_MB >= 7000 )); then
    GPU_MEM_MB=$(( TOTAL_MEM_MB - 2048 ))
  else
    GPU_MEM_MB=$(( TOTAL_MEM_MB - 1536 ))
  fi
  (( GPU_MEM_MB < 0 )) && GPU_MEM_MB=0
elif command -v "$NVIDIA_SMI" &>/dev/null &&
     "$NVIDIA_SMI" --query-gpu=memory.total --format=csv,noheader,nounits &>/dev/null; then
  PLATFORM_KIND="nvidia-discrete"
  PLATFORM_LABEL="$("$NVIDIA_SMI" --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  GPU_MEM_MB="$("$NVIDIA_SMI" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
  # Discrete VRAM is exclusive to the GPU, but the driver, the compositor and
  # llama.cpp's own scratch buffers still need headroom.
  GPU_MEM_MB=$(( GPU_MEM_MB * 90 / 100 ))
else
  PLATFORM_KIND="cpu"
  PLATFORM_LABEL="CPU only (no NVIDIA GPU detected)"
  GPU_MEM_MB=0
fi

# ── GPU passthrough mechanism ─────────────────────────────────────
# On Jetson the legacy `--gpus all` path (which is what Compose's
# `deploy.resources.reservations.devices` expands to) goes through
# nvidia-container-cli in CSV mode. That mounts several hundred host files and
# then runs ldconfig inside the container; on JetPack 6 this regularly wedges
# for minutes or hangs outright. The CDI spec in /etc/cdi/nvidia.yaml describes
# the same injection declaratively and is applied by the runtime directly, so
# it is both faster and reliable. Prefer it whenever a spec is present.
GPU_ACCESS="none"
COMPOSE_FILES="docker-compose.yml"
# Test each candidate separately: a single `ls` over several globs reports
# failure when *any* one of them is unmatched, which would hide a spec that is
# actually present.
have_cdi_spec() {
  local f
  for f in "$SYSROOT"/etc/cdi/nvidia*.yaml "$SYSROOT"/etc/cdi/nvidia*.json \
           "$SYSROOT"/var/run/cdi/nvidia*.yaml "$SYSROOT"/var/run/cdi/nvidia*.json; do
    [[ -f "$f" ]] && return 0
  done
  return 1
}
case "$PLATFORM_KIND" in
  jetson)
    if have_cdi_spec; then
      GPU_ACCESS="cdi"
      COMPOSE_FILES="docker-compose.yml:docker-compose.jetson.yml"
    else
      GPU_ACCESS="none"
      COMPOSE_FILES="docker-compose.yml:docker-compose.jetson.yml"
    fi
    ;;
  nvidia-discrete)
    # Keep the well-tested reservations path on discrete GPUs.
    GPU_ACCESS="reservations"
    ;;
esac

# ── Container image ───────────────────────────────────────────────
# The upstream ggml-org tag is multi-arch and its arm64 variant *looks* usable
# on Jetson - it starts, enumerates the iGPU and reports "CUDA0: Orin". It still
# cannot run: the shipped kernels carry no sm_87 cubin, and JIT-compiling the
# embedded PTX fails against JetPack 6's driver with
#
#   CUDA error: the provided PTX was compiled with an unsupported toolchain
#
# because that image is built with a newer CUDA toolkit than the L4T driver
# accepts. The failure only surfaces at the first kernel launch, so device
# enumeration is not evidence that a build works here - inference has to be
# exercised. NVIDIA's AI-IoT image is compiled for sm_87 against the L4T CUDA
# stack and does run, at the cost of being a much larger image.
if [[ "$PLATFORM_KIND" == "jetson" ]]; then
  LLAMA_IMAGE="ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin"
else
  LLAMA_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
fi

# ── Recommended model ─────────────────────────────────────────────
# Sized so that weights plus KV cache fit in GPU_MEM_MB with room to spare.
# All candidates are instruction-tuned and handle OpenAI-style tool calls,
# which is what this stack is normally pointed at.
#
# REC_MODEL_MB is the real object size in MiB, not a round number: every other
# memory figure in this repo is MiB (GPU_MEM_MB comes from MemTotal/1024, and
# nvidia-smi reports MiB), so a decimal-MB entry here would be compared against
# a MiB budget by REC_MODEL_PCT, by setup.sh's download prompt and by the
# invariant sweep in the self-test. The values below are the byte counts
# huggingface.co reports for these objects, divided by 1048576.
if   (( GPU_MEM_MB >= 20000 )); then
  REC_MODEL_REPO="bartowski/Qwen2.5-14B-Instruct-GGUF"
  REC_MODEL_FILE="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
  REC_MODEL_MB=8571; REC_CTX_SIZE=16384; REC_PARALLEL=4; REC_CACHE_TYPE="f16"
elif (( GPU_MEM_MB >= 10000 )); then
  REC_MODEL_REPO="bartowski/Qwen2.5-7B-Instruct-GGUF"
  REC_MODEL_FILE="Qwen2.5-7B-Instruct-Q4_K_M.gguf"
  REC_MODEL_MB=4466; REC_CTX_SIZE=16384; REC_PARALLEL=2; REC_CACHE_TYPE="f16"
elif (( GPU_MEM_MB >= 4500 )); then
  # Orin Nano Super 8 GB lands here: ~1.8 GiB of weights leaves plenty of room
  # for a 16k KV cache once it is quantised to q8_0.
  REC_MODEL_REPO="bartowski/Qwen2.5-3B-Instruct-GGUF"
  REC_MODEL_FILE="Qwen2.5-3B-Instruct-Q4_K_M.gguf"
  REC_MODEL_MB=1840; REC_CTX_SIZE=16384; REC_PARALLEL=1; REC_CACHE_TYPE="q8_0"
elif (( GPU_MEM_MB >= 2200 )); then
  REC_MODEL_REPO="bartowski/Qwen2.5-1.5B-Instruct-GGUF"
  REC_MODEL_FILE="Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
  REC_MODEL_MB=940; REC_CTX_SIZE=8192; REC_PARALLEL=1; REC_CACHE_TYPE="q8_0"
else
  REC_MODEL_REPO="bartowski/Qwen2.5-0.5B-Instruct-GGUF"
  REC_MODEL_FILE="Qwen2.5-0.5B-Instruct-Q4_K_M.gguf"
  REC_MODEL_MB=379; REC_CTX_SIZE=4096; REC_PARALLEL=1; REC_CACHE_TYPE="q8_0"
fi

# Weights are only part of the footprint: the KV cache, the compute buffers and
# llama.cpp's own scratch space all come out of the same budget. Express the
# weights as a share of the budget so both the report below and validate.sh can
# tell "comfortable" from "will load and then die on the first long prompt".
# Every tier above is sized to land near 50%; only boards too small for even the
# 0.5B model exceed that.
if (( GPU_MEM_MB > 0 )); then
  REC_MODEL_PCT=$(( REC_MODEL_MB * 100 / GPU_MEM_MB ))
else
  REC_MODEL_PCT=0
fi

# ── Power mode ────────────────────────────────────────────────────
# A Jetson's nvpmodel cap decides most of the throughput the board has, and
# nothing in this stack was reporting whether the active cap is the best one on
# offer. Reads plain files under SYSROOT, so it is testable and needs no root.
# shellcheck source=lib/power.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/power.sh"
power_probe "$SYSROOT"

# ── Output ────────────────────────────────────────────────────────
if (( EMIT_ENV )); then
  cat <<EOF
PLATFORM_KIND=$PLATFORM_KIND
PLATFORM_ARCH=$PLATFORM_ARCH
PLATFORM_LABEL="$PLATFORM_LABEL"
L4T_VERSION=$L4T_VERSION
TOTAL_MEM_MB=$TOTAL_MEM_MB
GPU_MEM_MB=$GPU_MEM_MB
GPU_ACCESS=$GPU_ACCESS
COMPOSE_FILES=$COMPOSE_FILES
LLAMA_IMAGE=$LLAMA_IMAGE
REC_MODEL_REPO=$REC_MODEL_REPO
REC_MODEL_FILE=$REC_MODEL_FILE
REC_MODEL_MB=$REC_MODEL_MB
REC_CTX_SIZE=$REC_CTX_SIZE
REC_PARALLEL=$REC_PARALLEL
REC_CACHE_TYPE=$REC_CACHE_TYPE
REC_MODEL_PCT=$REC_MODEL_PCT
POWER_STATE=$POWER_STATE
POWER_ACTIVE_ID=$POWER_ACTIVE_ID
POWER_ACTIVE_NAME="$POWER_ACTIVE_NAME"
POWER_BEST_ID=$POWER_BEST_ID
POWER_BEST_NAME="$POWER_BEST_NAME"
POWER_DEFAULT_ID=$POWER_DEFAULT_ID
EOF
  exit 0
fi

echo "Platform"
echo "  Kind          : $PLATFORM_KIND"
echo "  Device        : $PLATFORM_LABEL"
echo "  Architecture  : $PLATFORM_ARCH"
[[ -n "$L4T_VERSION" ]] && echo "  L4T / JetPack : R$L4T_VERSION"
echo "  System RAM    : $((TOTAL_MEM_MB / 1024)) GiB"
if [[ "$PLATFORM_KIND" == "jetson" ]]; then
  echo "  Model budget  : $((GPU_MEM_MB / 1024)) GiB (unified memory, minus OS reserve)"
else
  echo "  Model budget  : $((GPU_MEM_MB / 1024)) GiB"
fi
if [[ "$POWER_STATE" != "unavailable" ]]; then
  echo "  Power mode    : ${POWER_ACTIVE_NAME:-unknown}$([[ -n "$POWER_ACTIVE_ID" ]] && echo " (id $POWER_ACTIVE_ID)")"
  case "$POWER_STATE" in
    best)  echo "                  this is the fastest mode this board offers" ;;
    below) echo "                  fastest available: $POWER_BEST_NAME (id $POWER_BEST_ID)" ;;
  esac
fi
echo ""
echo "Container"
echo "  Image         : $LLAMA_IMAGE"
echo "  GPU access    : $GPU_ACCESS"
echo "  Compose files : $COMPOSE_FILES"
echo ""
echo "Recommended model"
echo "  Repo          : $REC_MODEL_REPO"
echo "  File          : $REC_MODEL_FILE (~$((REC_MODEL_MB / 1024)).$(( (REC_MODEL_MB % 1024) * 10 / 1024 )) GiB)"
echo "  Context       : $REC_CTX_SIZE tokens"
echo "  Parallel      : $REC_PARALLEL slot(s)"
echo "  KV cache      : $REC_CACHE_TYPE"
(( GPU_MEM_MB > 0 )) && echo "  Weights use   : ${REC_MODEL_PCT}% of the budget"

if (( GPU_MEM_MB > 0 && REC_MODEL_MB >= GPU_MEM_MB )); then
  # No context is small enough to rescue this: the weights do not fit before
  # the cache is allocated at all. Advice that cannot be taken is worse than
  # none, so do not offer CTX_SIZE here.
  echo ""
  echo "WARNING: the smallest supported model is ${REC_MODEL_MB} MiB of weights against a"
  echo "         ${GPU_MEM_MB} MiB budget, so it will not load on this board whatever"
  echo "         CTX_SIZE is set to. Run this stack on a larger board."
elif (( GPU_MEM_MB > 0 && REC_MODEL_PCT > 60 )); then
  echo ""
  echo "WARNING: even the smallest supported model takes ${REC_MODEL_PCT}% of this board's"
  echo "         ${GPU_MEM_MB} MiB budget, leaving little for the KV cache. Expect to"
  echo "         lower CTX_SIZE below $REC_CTX_SIZE, or run this stack on a larger board."
fi

if [[ "$POWER_STATE" == "below" ]]; then
  # Not a warning about a broken configuration - the stack runs fine here. It
  # is a warning that the numbers this board produces are not the ones it can
  # produce, which on a bandwidth-bound workload is most of the difference.
  echo ""
  echo "NOTE: this board is in its $POWER_ACTIVE_NAME power mode, which is not its fastest."
  while IFS= read -r _line; do echo "      $_line"; done < <(power_advice_lines)
fi

if [[ "$PLATFORM_KIND" == "jetson" && "$GPU_ACCESS" == "none" ]]; then
  echo ""
  echo "WARNING: no CDI spec found under /etc/cdi or /var/run/cdi."
  echo "         Generate one so the container can reach the GPU:"
  echo "           sudo nvidia-ctk cdi generate --mode=csv --output=/etc/cdi/nvidia.yaml"
fi
