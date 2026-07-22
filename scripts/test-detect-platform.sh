#!/usr/bin/env bash
# test-detect-platform.sh - Hermetic tests for the platform detection logic.
#
# detect-platform.sh decides everything that differs between targets: which
# container image is pulled, how the GPU is handed to the container, how much
# memory the model may use and which model is recommended. All of that is read
# off the hardware, so on any given machine exactly one branch is ever taken -
# an Orin Nano can never exercise the AGX, the discrete-GPU or the CPU-only
# paths, and a regression in them stays invisible until someone runs the stack
# on that board.
#
# These tests drive the script against synthetic /proc, /etc and /var/run trees
# (PLATFORM_SYSROOT) and a stub nvidia-smi (PLATFORM_NVIDIA_SMI), so every
# branch is checked on any host, with no GPU, no Docker and no network.
#
# Usage:
#   ./scripts/test-detect-platform.sh          # run all cases
#   ./scripts/test-detect-platform.sh -v       # also print each assertion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/detect-platform.sh"

VERBOSE=0
[[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]] && VERBOSE=1

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_HD=$'\033[1m'; C_Z=$'\033[0m'
else
  C_OK=""; C_NO=""; C_HD=""; C_Z=""
fi

PASS=0; FAIL=0
FAILED_NAMES=()
CASE=""

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

# ── Fixture construction ──────────────────────────────────────────
# Each fixture is a directory that looks like the root of the board under test.
# Only the files detect-platform.sh actually probes are created.

# fake_root <name> <mem_kb>
fake_root() {
  local name="$1" mem_kb="$2" root="$TMPROOT/$1"
  rm -rf "$root"
  mkdir -p "$root/proc" "$root/etc" "$root/bin"
  cat >"$root/proc/meminfo" <<EOF
MemTotal:       ${mem_kb} kB
MemFree:         1000000 kB
EOF
  printf '%s' "$root"
}

# with_tegra_release <root> <major> <revision>
with_tegra_release() {
  cat >"$1/etc/nv_tegra_release" <<EOF
# R$2 (release), REVISION: $3, GCID: 12345678, BOARD: generic, EABI: aarch64, DATE: Mon Jan  1 00:00:00 UTC 2024
EOF
}

# with_device_tree_model <root> <model string>
# The kernel exposes this as a NUL-terminated string, which is why the script
# strips NULs; reproduce that faithfully or the test would not cover it.
with_device_tree_model() {
  mkdir -p "$1/proc/device-tree"
  printf '%s\0' "$2" >"$1/proc/device-tree/model"
}

# with_cdi_spec <root> <etc|run>
with_cdi_spec() {
  case "$2" in
    etc) mkdir -p "$1/etc/cdi";     : >"$1/etc/cdi/nvidia.yaml" ;;
    run) mkdir -p "$1/var/run/cdi"; : >"$1/var/run/cdi/nvidia.json" ;;
  esac
}

# with_unrelated_cdi_spec <root> - a CDI directory holding only non-NVIDIA
# specs. Must not be mistaken for GPU support.
with_unrelated_cdi_spec() {
  mkdir -p "$1/etc/cdi"; : >"$1/etc/cdi/vendor.com-device.yaml"
}

# with_nvidia_smi <root> <gpu name> <vram_mib>
with_nvidia_smi() {
  local root="$1" name="$2" vram="$3"
  cat >"$root/bin/nvidia-smi" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *memory.total*) echo "$vram" ;;
  *--query-gpu=name*) echo "$name" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$root/bin/nvidia-smi"
}

# with_broken_nvidia_smi <root> - the binary exists but every query fails, as
# on a host where the driver is not loaded. Must fall through to CPU-only
# rather than reporting a GPU with an empty memory figure.
with_broken_nvidia_smi() {
  printf '#!/usr/bin/env bash\nexit 1\n' >"$1/bin/nvidia-smi"
  chmod +x "$1/bin/nvidia-smi"
}

# with_uname <root> <arch>
with_uname() {
  cat >"$1/bin/uname" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "-m" ]] && { echo "$2"; exit 0; }
exec /usr/bin/uname "\$@"
EOF
  chmod +x "$1/bin/uname"
}

# ── Running a fixture ─────────────────────────────────────────────
# Results land in the RES associative array, so assertions read like the
# variables detect-platform.sh documents.
declare -A RES

# run_detect <root>  - nvidia-smi resolves to the fixture's stub if it has one,
# otherwise to a name that cannot exist, so the real host GPU never leaks in.
run_detect() {
  local root="$1" smi="nvidia-smi-absent-in-fixture" out
  [[ -x "$root/bin/nvidia-smi" ]] && smi="$root/bin/nvidia-smi"
  out="$(PATH="$root/bin:$PATH" PLATFORM_SYSROOT="$root" PLATFORM_NVIDIA_SMI="$smi" \
         bash "$TARGET" --env 2>&1)" || {
    echo "    detect-platform.sh --env failed:"; sed 's/^/      /' <<<"$out"; return 1; }
  RES=()
  local k v
  while IFS='=' read -r k v; do
    [[ -z "$k" ]] && continue
    v="${v%\"}"; v="${v#\"}"
    RES["$k"]="$v"
  done <<<"$out"
  return 0
}

# run_detect_human <root> - the report humans read, for warning assertions.
run_detect_human() {
  local root="$1" smi="nvidia-smi-absent-in-fixture"
  [[ -x "$root/bin/nvidia-smi" ]] && smi="$root/bin/nvidia-smi"
  PATH="$root/bin:$PATH" PLATFORM_SYSROOT="$root" PLATFORM_NVIDIA_SMI="$smi" \
    bash "$TARGET" 2>&1
}

# ── Assertions ────────────────────────────────────────────────────
begin() { CASE="$1"; printf '\n%s%s%s\n' "$C_HD" "$1" "$C_Z"; }

pass() { PASS=$((PASS+1)); (( VERBOSE )) && printf '  %sok%s   %s\n' "$C_OK" "$C_Z" "$1"; return 0; }
fail() {
  FAIL=$((FAIL+1)); FAILED_NAMES+=("$CASE: $1")
  printf '  %sFAIL%s %s\n' "$C_NO" "$C_Z" "$1"
  [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
  return 0
}

# eq <key> <expected>
# `-` rather than `:-`: an empty value is a legitimate result (L4T_VERSION on a
# board detected only through the device tree) and must not read as unset.
eq() {
  local got="${RES[$1]-<unset>}"
  if [[ "$got" == "$2" ]]; then pass "$1 = $2"
  else fail "$1" "expected '$2', got '$got'"; fi
}

# num_between <key> <min> <max>  (inclusive)
num_between() {
  local got="${RES[$1]:-}"
  if [[ "$got" =~ ^-?[0-9]+$ ]] && (( got >= $2 && got <= $3 )); then
    pass "$1 = $got (in [$2,$3])"
  else
    fail "$1" "expected a number in [$2,$3], got '$got'"
  fi
}

# contains <haystack> <needle> <label>
contains() {
  if [[ "$1" == *"$2"* ]]; then pass "$3"
  else fail "$3" "output does not contain '$2'"; fi
}

# not_contains <haystack> <needle> <label>
not_contains() {
  if [[ "$1" != *"$2"* ]]; then pass "$3"
  else fail "$3" "output unexpectedly contains '$2'"; fi
}

printf '%s╔══════════════════════════════════════════════════╗%s\n' "$C_HD" "$C_Z"
printf '%s║   detect-platform.sh - self-test                 ║%s\n' "$C_HD" "$C_Z"
printf '%s╚══════════════════════════════════════════════════╝%s\n' "$C_HD" "$C_Z"

# ══════════════════════════════════════════════════════════════════
# Jetson boards
# ══════════════════════════════════════════════════════════════════

begin "Jetson Orin Nano Super 8 GB, CDI present (the reference board)"
root="$(fake_root orin-nano 8218000)"          # ~7.84 GiB, as reported by JetPack 6
with_tegra_release "$root" 36 4.7
with_device_tree_model "$root" "NVIDIA Jetson Orin Nano Engineering Reference Developer Kit Super"
with_cdi_spec "$root" etc
with_nvidia_smi "$root" "Orin (nvgpu)" 0        # Jetson nvidia-smi reports no VRAM
with_uname "$root" aarch64
if run_detect "$root"; then
  eq PLATFORM_KIND   jetson
  eq PLATFORM_ARCH   aarch64
  eq L4T_VERSION     36.4.7
  eq GPU_ACCESS      cdi
  eq COMPOSE_FILES   docker-compose.yml:docker-compose.jetson.yml
  eq LLAMA_IMAGE     ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin
  eq REC_MODEL_FILE  Qwen2.5-3B-Instruct-Q4_K_M.gguf
  eq REC_CACHE_TYPE  q8_0
  eq REC_PARALLEL    1
  # 8026 MiB total minus the 2048 MiB OS reserve.
  num_between GPU_MEM_MB 5900 6100
fi

begin "Jetson without a CDI spec - overlay stays, GPU access is flagged"
root="$(fake_root orin-nano-nocdi 8218000)"
with_tegra_release "$root" 36 4.7
with_device_tree_model "$root" "NVIDIA Jetson Orin Nano Developer Kit"
with_uname "$root" aarch64
if run_detect "$root"; then
  eq PLATFORM_KIND jetson
  eq GPU_ACCESS    none
  # The overlay must still be selected: it also clears the legacy device
  # reservation that hangs JetPack 6, which matters even before CDI exists.
  eq COMPOSE_FILES docker-compose.yml:docker-compose.jetson.yml
fi
out="$(run_detect_human "$root")"
contains "$out" "nvidia-ctk cdi generate" "human report tells the user how to create the CDI spec"

begin "Jetson with a CDI spec only under /var/run/cdi"
root="$(fake_root orin-runtime-cdi 8218000)"
with_tegra_release "$root" 36 4.7
with_cdi_spec "$root" run
with_uname "$root" aarch64
run_detect "$root" && eq GPU_ACCESS cdi

begin "Jetson with a CDI directory holding no NVIDIA spec"
root="$(fake_root orin-foreign-cdi 8218000)"
with_tegra_release "$root" 36 4.7
with_unrelated_cdi_spec "$root"
with_uname "$root" aarch64
run_detect "$root" && eq GPU_ACCESS none

begin "Jetson identified by device tree alone (no /etc/nv_tegra_release)"
root="$(fake_root orin-dt-only 8218000)"
with_device_tree_model "$root" "NVIDIA Orin NX Developer Kit"
with_cdi_spec "$root" etc
with_uname "$root" aarch64
if run_detect "$root"; then
  eq PLATFORM_KIND jetson
  eq L4T_VERSION   ""
  eq LLAMA_IMAGE   ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin
fi

begin "Jetson Orin NX 16 GB - one model tier up"
root="$(fake_root orin-nx-16 16384000)"
with_tegra_release "$root" 36 3.0
with_device_tree_model "$root" "NVIDIA Jetson Orin NX Developer Kit"
with_cdi_spec "$root" etc
with_uname "$root" aarch64
if run_detect "$root"; then
  eq PLATFORM_KIND  jetson
  eq L4T_VERSION    36.3.0
  eq REC_MODEL_FILE Qwen2.5-7B-Instruct-Q4_K_M.gguf
  eq REC_PARALLEL   2
  num_between GPU_MEM_MB 13800 14000
fi

begin "Jetson AGX Orin 64 GB - largest tier, still the Jetson image and CDI"
root="$(fake_root agx-orin-64 66584000)"
with_tegra_release "$root" 36 4.0
with_device_tree_model "$root" "NVIDIA Jetson AGX Orin Developer Kit"
with_cdi_spec "$root" etc
with_uname "$root" aarch64
if run_detect "$root"; then
  eq PLATFORM_KIND  jetson
  eq REC_MODEL_FILE Qwen2.5-14B-Instruct-Q4_K_M.gguf
  eq REC_CACHE_TYPE f16
  eq REC_CTX_SIZE   16384
  eq LLAMA_IMAGE    ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin
  eq GPU_ACCESS     cdi
fi

begin "Jetson Nano 4 GB - small board takes the smaller OS reserve"
root="$(fake_root nano-4g 4194304)"
with_tegra_release "$root" 32 7.4
with_device_tree_model "$root" "NVIDIA Jetson Nano Developer Kit"
with_uname "$root" aarch64
if run_detect "$root"; then
  eq PLATFORM_KIND  jetson
  eq L4T_VERSION    32.7.4
  # 4096 total - 1536 reserve = 2560, which lands in the 1.5B tier.
  num_between GPU_MEM_MB 2500 2620
  eq REC_MODEL_FILE Qwen2.5-1.5B-Instruct-Q4_K_M.gguf
  eq REC_CTX_SIZE   8192
fi

begin "Jetson Nano 2 GB - too small to be comfortable, and says so"
root="$(fake_root nano-2g 2097152)"
with_tegra_release "$root" 32 7.4
with_device_tree_model "$root" "NVIDIA Jetson Nano 2GB Developer Kit"
with_uname "$root" aarch64
if run_detect "$root"; then
  eq PLATFORM_KIND  jetson
  eq REC_MODEL_FILE Qwen2.5-0.5B-Instruct-Q4_K_M.gguf
  eq REC_CTX_SIZE   4096
fi
out="$(run_detect_human "$root")"
contains "$out" "leaving little for the KV cache" "human report warns that the board is undersized"

# ══════════════════════════════════════════════════════════════════
# Discrete NVIDIA GPUs
# ══════════════════════════════════════════════════════════════════

begin "x86_64 with an RTX 5090 - the originally supported configuration"
root="$(fake_root x86-5090 134217728)"          # 128 GiB RAM
with_nvidia_smi "$root" "NVIDIA GeForce RTX 5090" 32607
with_uname "$root" x86_64
if run_detect "$root"; then
  eq PLATFORM_KIND  nvidia-discrete
  eq PLATFORM_ARCH  x86_64
  eq GPU_ACCESS     reservations
  eq COMPOSE_FILES  docker-compose.yml
  eq LLAMA_IMAGE    ghcr.io/ggml-org/llama.cpp:server-cuda
  eq REC_MODEL_FILE Qwen2.5-14B-Instruct-Q4_K_M.gguf
  eq REC_CACHE_TYPE f16
  eq REC_PARALLEL   4
  # VRAM is budgeted at 90%, and system RAM must not inflate it.
  num_between GPU_MEM_MB 29000 29500
fi

begin "Discrete 8 GB card - budget follows VRAM, not the 128 GiB of host RAM"
root="$(fake_root x86-3070 134217728)"
with_nvidia_smi "$root" "NVIDIA GeForce RTX 3070" 8192
with_uname "$root" x86_64
if run_detect "$root"; then
  eq PLATFORM_KIND  nvidia-discrete
  eq REC_MODEL_FILE Qwen2.5-3B-Instruct-Q4_K_M.gguf
  num_between GPU_MEM_MB 7300 7400
fi

begin "aarch64 host with a discrete card - not a Jetson, so not the Jetson image"
root="$(fake_root arm-discrete 33554432)"
with_nvidia_smi "$root" "NVIDIA RTX A4000" 16376
with_uname "$root" aarch64
if run_detect "$root"; then
  eq PLATFORM_KIND nvidia-discrete
  eq PLATFORM_ARCH aarch64
  eq LLAMA_IMAGE   ghcr.io/ggml-org/llama.cpp:server-cuda
  eq GPU_ACCESS    reservations
fi

# ══════════════════════════════════════════════════════════════════
# No GPU
# ══════════════════════════════════════════════════════════════════

begin "CPU-only host - no GPU request, smallest model"
root="$(fake_root cpu-only 33554432)"
with_uname "$root" x86_64
if run_detect "$root"; then
  eq PLATFORM_KIND  cpu
  eq GPU_ACCESS     none
  eq GPU_MEM_MB     0
  eq COMPOSE_FILES  docker-compose.yml
  eq REC_MODEL_FILE Qwen2.5-0.5B-Instruct-Q4_K_M.gguf
  eq REC_MODEL_PCT  0
fi
out="$(run_detect_human "$root")"
not_contains "$out" "WARNING" "no spurious warning on a CPU-only host"

begin "nvidia-smi present but the driver is dead - falls back to CPU"
root="$(fake_root broken-driver 33554432)"
with_broken_nvidia_smi "$root"
with_uname "$root" x86_64
if run_detect "$root"; then
  eq PLATFORM_KIND cpu
  eq GPU_MEM_MB    0
fi

# ══════════════════════════════════════════════════════════════════
# Invariants across the whole memory range
# ══════════════════════════════════════════════════════════════════
# The per-board cases above pin down known hardware. This sweep covers the
# tier boundaries themselves, so adding or resizing a model tier cannot
# silently recommend something that does not fit.

begin "Invariant sweep - every recommendation fits its budget"
sweep_fail=0; sweep_n=0
for mem_mib in 2048 3072 4096 6144 7856 8192 12288 16384 24576 32768 65536 131072; do
  root="$(fake_root "sweep-$mem_mib" $((mem_mib * 1024)))"
  with_tegra_release "$root" 36 4.7
  with_cdi_spec "$root" etc
  with_uname "$root" aarch64
  run_detect "$root" || { sweep_fail=1; continue; }
  sweep_n=$((sweep_n + 1))

  budget="${RES[GPU_MEM_MB]}"; weights="${RES[REC_MODEL_MB]}"; pct="${RES[REC_MODEL_PCT]}"

  # 1. Weights must fit at all - otherwise the container dies at load with an
  #    opaque cudaMalloc failure.
  if (( weights >= budget )); then
    fail "${mem_mib} MiB board" "weights ${weights} MiB do not fit the ${budget} MiB budget"
    sweep_fail=1; continue
  fi

  # 2. Above the 1.5B tier there must be real room left for the KV cache and
  #    the compute buffers, not just for the weights. Boards below that are
  #    already flagged by the undersized-board warning.
  if (( budget >= 2200 && pct > 60 )); then
    fail "${mem_mib} MiB board" "weights take ${pct}% of the budget; leaves too little for the KV cache"
    sweep_fail=1; continue
  fi

  # 3. A larger board must never be given a smaller model than a smaller one.
  if [[ -n "${prev_weights:-}" ]] && (( weights < prev_weights )); then
    fail "${mem_mib} MiB board" "recommends ${weights} MiB after a smaller board got ${prev_weights} MiB"
    sweep_fail=1; continue
  fi
  prev_weights="$weights"
done
(( sweep_fail == 0 )) && pass "$sweep_n memory sizes: weights fit, KV headroom kept, tiers monotonic"

begin "Invariant - --env output is safe to eval"
root="$(fake_root eval-safety 8218000)"
with_tegra_release "$root" 36 4.7
with_device_tree_model "$root" "NVIDIA Jetson Orin Nano Developer Kit Super"
with_cdi_spec "$root" etc
with_uname "$root" aarch64
# PLATFORM_LABEL carries spaces from the device tree, so it has to survive a
# round trip through eval - setup.sh and validate.sh both consume it that way.
env_out="$(PATH="$root/bin:$PATH" PLATFORM_SYSROOT="$root" \
           PLATFORM_NVIDIA_SMI=nvidia-smi-absent-in-fixture bash "$TARGET" --env)"
if ( eval "$env_out" ) 2>/dev/null; then
  label="$(eval "$env_out"; printf '%s' "$PLATFORM_LABEL")"
  if [[ "$label" == "NVIDIA Jetson Orin Nano Developer Kit Super" ]]; then
    pass "PLATFORM_LABEL survives eval with spaces intact"
  else
    fail "PLATFORM_LABEL round trip" "got '$label'"
  fi
else
  fail "--env output is not eval-safe"
fi

# ══════════════════════════════════════════════════════════════════
printf '\n%sSummary%s\n' "$C_HD" "$C_Z"
printf '  %s%d passed%s, %s%d failed%s\n' "$C_OK" "$PASS" "$C_Z" "$C_NO" "$FAIL" "$C_Z"
if (( FAIL > 0 )); then
  printf '\n  Failed assertions:\n'
  printf '    - %s\n' "${FAILED_NAMES[@]}"
  echo ""
  exit 1
fi
echo ""
exit 0
