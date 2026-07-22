#!/usr/bin/env bash
# test-setup.sh - Hermetic tests for setup.sh.
#
# setup.sh is the first thing a user runs and the only script that writes .env,
# so a mistake here is inherited by everything downstream. Its risky paths are
# also the ones a healthy machine never takes: they involve *the other* platform
# (an .env carried over from the x86_64 workstation to a Jetson), a models
# directory on a data disk, or a MODEL_FILE naming a file that has since been
# pruned. Each of those used to end in "Setup complete" and exit 0.
#
# Every case runs the real script inside a throwaway project directory against
# a synthetic /proc + /etc tree (PLATFORM_SYSROOT, see detect-platform.sh) and
# stub docker/nvidia-smi/python3 binaries on PATH, so no GPU, no Docker, no
# network and no real model are needed - and the real .env is never touched.
#
# Usage:
#   ./scripts/test-setup.sh          # run all cases
#   ./scripts/test-setup.sh -v       # also print each assertion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TARGET="$SCRIPT_DIR/setup.sh"

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

pass() { PASS=$((PASS+1)); (( VERBOSE )) && printf '  %sok%s   %s\n' "$C_OK" "$C_Z" "$1"; return 0; }
fail() {
  FAIL=$((FAIL+1)); FAILED_NAMES+=("$CASE: $1")
  printf '  %sFAIL%s %s\n' "$C_NO" "$C_Z" "$1"
  [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
  return 0
}
case_start() { CASE="$1"; printf '\n%s%s%s\n' "$C_HD" "$1" "$C_Z"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

# ── Assertions ────────────────────────────────────────────────────
assert_contains() {
  local hay="$1" needle="$2" what="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$what"
  else fail "$what" "expected to find: $needle"; fi
}
assert_not_contains() {
  local hay="$1" needle="$2" what="$3"
  if [[ "$hay" != *"$needle"* ]]; then pass "$what"
  else fail "$what" "did not expect: $needle"; fi
}
assert_eq() {
  local got="$1" want="$2" what="$3"
  if [[ "$got" == "$want" ]]; then pass "$what"
  else fail "$what" "got '$got', want '$want'"; fi
}
assert_exit() {
  local got="$1" want="$2" what="$3"
  if [[ "$got" == "$want" ]]; then pass "$what"
  else fail "$what" "exit $got, want $want"; fi
}

# ── Stub binaries ─────────────────────────────────────────────────
# setup.sh probes docker/nvidia-smi/python3 directly through `command -v`, so
# the only way to pin them is PATH. A real venv + pip install would also make
# every case network-bound and slow.
STUBBIN="$TMPROOT/bin"
mkdir -p "$STUBBIN"

cat >"$STUBBIN/docker" <<'EOF'
#!/bin/sh
[ "$1" = "--version" ] && { echo "Docker version 27.0.0, build stub"; exit 0; }
[ "$1" = "compose" ] && { [ "$3" = "--short" ] && echo "2.29.0" || echo "Docker Compose version v2.29.0"; exit 0; }
exit 0
EOF

cat >"$STUBBIN/nvidia-smi" <<'EOF'
#!/bin/sh
echo "Orin (nvgpu), N/A"
EOF

# `python3 -m venv DIR` without ensurepip or a network: lay down the directory
# layout setup.sh checks for, and a pip that produces the `hf` entry point.
cat >"$STUBBIN/python3" <<'EOF'
#!/bin/bash
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  d="$3"; mkdir -p "$d/bin" || exit 1
  cat > "$d/bin/pip" <<'PIP'
#!/bin/sh
for a in "$@"; do
  [ "$a" = "huggingface-hub" ] && { touch "$(dirname "$0")/hf"; chmod +x "$(dirname "$0")/hf"; }
done
exit 0
PIP
  chmod +x "$d/bin/pip"; exit 0
fi
exit 0
EOF

chmod +x "$STUBBIN"/*

# ── Synthetic hosts ───────────────────────────────────────────────
# One sysroot per board class. detect-platform.sh reads every probe through
# PLATFORM_SYSROOT, and setup.sh passes the variable through to it unchanged.
make_jetson_sysroot() {   # $1=dir  $2=MemTotal kB  [$3=no-cdi]
  local d="$1"
  mkdir -p "$d/proc/device-tree" "$d/etc"
  printf '# R36 (release), REVISION: 4.7, GCID: 1, BOARD: generic\n' >"$d/etc/nv_tegra_release"
  printf 'NVIDIA Jetson Orin Nano Developer Kit Super\0' >"$d/proc/device-tree/model"
  printf 'MemTotal:        %s kB\n' "$2" >"$d/proc/meminfo"
  if [[ "${3:-}" != "no-cdi" ]]; then
    mkdir -p "$d/etc/cdi"
    printf 'cdiVersion: "0.5.0"\nkind: "nvidia.com/gpu"\n' >"$d/etc/cdi/nvidia.yaml"
  fi
}

make_x86_sysroot() {      # $1=dir  $2=MemTotal kB
  mkdir -p "$1/proc" "$1/etc"
  printf 'MemTotal:       %s kB\n' "$2" >"$1/proc/meminfo"
}

DISCRETE_SMI="$TMPROOT/nvidia-smi-discrete"
cat >"$DISCRETE_SMI" <<'EOF'
#!/bin/sh
case "$*" in
  *memory.total*) echo "32607" ;;
  *) echo "NVIDIA GeForce RTX 5090" ;;
esac
EOF
chmod +x "$DISCRETE_SMI"

JETSON_SYSROOT="$TMPROOT/sys-jetson"; make_jetson_sysroot "$JETSON_SYSROOT" 7620000
X86_SYSROOT="$TMPROOT/sys-x86";       make_x86_sysroot "$X86_SYSROOT" 131072000

# ── Project fixture ───────────────────────────────────────────────
# A throwaway copy of everything setup.sh reads or writes. The scripts are
# copied rather than symlinked so $0-derived PROJECT_DIR lands in the fixture.
#
# Sets P rather than echoing the path: `P="$(new_project)"` would run the whole
# function in a subshell, so the counter would never advance and every case
# would silently share one directory - and thus one .env.
PROJ_N=0
P=""
new_project() {
  PROJ_N=$((PROJ_N+1))
  P="$TMPROOT/proj$PROJ_N"
  mkdir -p "$P/scripts"
  cp "$PROJECT_DIR/.env.example" "$P/"
  cp "$PROJECT_DIR"/docker-compose*.yml "$P/"
  cp "$SCRIPT_DIR"/*.sh "$P/scripts/"
  cp -r "$SCRIPT_DIR/lib" "$P/scripts/"
  # Pre-seed certs from one real set generated below: setup.sh now verifies
  # them rather than only looking for the files, and generating a 4096-bit CA
  # per fixture would cost more than the rest of this suite put together.
  mkdir -p "$P/certs"
  cp "$SEED_CERTS"/ca.crt "$SEED_CERTS"/ca.key \
     "$SEED_CERTS"/server.crt "$SEED_CERTS"/server.key "$P/certs/"
}

# One real certificate set, shared by every fixture.
SEED_CERTS="$TMPROOT/seed-certs"; mkdir -p "$SEED_CERTS"
CERT_DIR="$SEED_CERTS" bash "$SCRIPT_DIR/gen-certs.sh" --no-auto-ip >/dev/null 2>&1 \
  || { echo "could not generate the seed certificates" >&2; exit 1; }

# Run setup.sh in a project fixture. OUT/RC are set for the assertions.
OUT=""; RC=0
run_setup() {   # $1=project  $2=sysroot  [$3=nvidia-smi override]
  local proj="$1" sysroot="$2" smi="${3:-}"
  OUT="$(cd "$proj" && PATH="$STUBBIN:$PATH" \
      PLATFORM_SYSROOT="$sysroot" PLATFORM_NVIDIA_SMI="${smi:-nvidia-smi}" \
      bash "$proj/scripts/setup.sh" 2>&1)"
  RC=$?
}

envval() { grep -E "^[[:space:]]*$2=" "$1/.env" | tail -1 | cut -d= -f2- ; }

# ══════════════════════════════════════════════════════════════════
case_start "Fresh checkout on a Jetson Orin Nano 8GB"
# ══════════════════════════════════════════════════════════════════
new_project
run_setup "$P" "$JETSON_SYSROOT"
assert_exit "$RC" 0 "exits 0"
assert_contains "$OUT" "Creating .env from .env.example" "creates .env"
assert_eq "$(envval "$P" COMPOSE_FILE)" "docker-compose.yml:docker-compose.jetson.yml" \
  "COMPOSE_FILE selects the Jetson overlay"
assert_eq "$(envval "$P" LLAMA_IMAGE)" "ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin" \
  "LLAMA_IMAGE is the Jetson image"
assert_eq "$(envval "$P" PARALLEL)" "1" "PARALLEL is 1 on a unified-memory board"
assert_eq "$(envval "$P" CACHE_TYPE_K)" "q8_0" "CACHE_TYPE_K is quantised"
assert_eq "$(envval "$P" CACHE_TYPE_V)" "q8_0" "CACHE_TYPE_V is quantised"
# The whole point of writing platform defaults is that they are self-consistent:
# a just-written .env must not then be reported as mismatched.
assert_contains "$OUT" ".env matches the detected jetson platform" "written .env is self-consistent"
assert_not_contains "$OUT" "⚠  COMPOSE_FILE" "no COMPOSE_FILE warning on a fresh Jetson .env"
assert_not_contains "$OUT" "⚠  LLAMA_IMAGE" "no LLAMA_IMAGE warning on a fresh Jetson .env"

# ══════════════════════════════════════════════════════════════════
case_start "Fresh checkout on x86_64 with a discrete GPU"
# ══════════════════════════════════════════════════════════════════
new_project
run_setup "$P" "$X86_SYSROOT" "$DISCRETE_SMI"
assert_exit "$RC" 0 "exits 0"
assert_eq "$(envval "$P" COMPOSE_FILE)" "docker-compose.yml" "COMPOSE_FILE has no Jetson overlay"
assert_eq "$(envval "$P" LLAMA_IMAGE)" "ghcr.io/ggml-org/llama.cpp:server-cuda" \
  "LLAMA_IMAGE is the upstream multi-arch image"
assert_contains "$OUT" ".env matches the detected nvidia-discrete platform" \
  "written .env is self-consistent"
assert_not_contains "$OUT" "hangs on JetPack 6" "no Jetson advice on a discrete-GPU host"

# ══════════════════════════════════════════════════════════════════
case_start ".env carried over from the x86_64 workstation to a Jetson"
# ══════════════════════════════════════════════════════════════════
# The regression that motivated this file: the old check grepped .env for the
# string 'docker-compose.jetson.yml', which .env.example documents in a comment,
# so the warning never fired for any .env derived from it.
new_project
cp "$P/.env.example" "$P/.env"          # x86 defaults, Jetson settings in comments
# A model is present and wired up, so the mismatch count is purely the config.
mkdir -p "$P/models"; printf 'GGUF\x03\x00\x00\x00' >"$P/models/carried-Q4_K_M.gguf"
sed -i 's|^MODEL_FILE=.*|MODEL_FILE=/models/carried-Q4_K_M.gguf|' "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_exit "$RC" 0 "exits 0 (advisory, not a gate)"
assert_contains "$OUT" ".env already exists, leaving it untouched" "does not overwrite .env"
assert_contains "$OUT" "COMPOSE_FILE does not select the Jetson overlay" \
  "flags the missing Jetson overlay despite the matching comment in .env"
assert_contains "$OUT" "hangs on JetPack 6" "explains the consequence"
assert_contains "$OUT" "COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml" "gives the fix"
assert_contains "$OUT" "LLAMA_IMAGE is not the image for this platform" \
  "flags the upstream image, which has no sm_87 kernels"
assert_contains "$OUT" "ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin" "names the Jetson image"
assert_contains "$OUT" "PARALLEL=4 exceeds the 1 slot" "flags oversized slot count"
assert_contains "$OUT" "KV cache is f16/f16" "flags the unquantised KV cache"
assert_contains "$OUT" "4 item(s) to resolve" "summary counts every mismatch"
assert_not_contains "$OUT" "Setup complete" "does not claim success"
# Advisory only: the file itself must be left exactly as the user wrote it.
assert_eq "$(envval "$P" COMPOSE_FILE)" "docker-compose.yml" "COMPOSE_FILE left untouched"
assert_eq "$(envval "$P" LLAMA_IMAGE)" "ghcr.io/ggml-org/llama.cpp:server-cuda" "LLAMA_IMAGE left untouched"

# ══════════════════════════════════════════════════════════════════
case_start ".env carried over from a Jetson to the x86_64 workstation"
# ══════════════════════════════════════════════════════════════════
new_project
cp "$P/.env.example" "$P/.env"
sed -i 's|^COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml|' "$P/.env"
sed -i 's|^LLAMA_IMAGE=.*|LLAMA_IMAGE=ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin|' "$P/.env"
run_setup "$P" "$X86_SYSROOT" "$DISCRETE_SMI"
assert_contains "$OUT" "COMPOSE_FILE selects the Jetson overlay but this is not a Jetson" \
  "flags the overlay in the reverse direction"
assert_contains "$OUT" "LLAMA_IMAGE is not the image for this platform" \
  "flags the arm64-only image on x86_64"
# Memory advice is Jetson-specific: PARALLEL=4/f16 is correct on a 32 GB card.
assert_not_contains "$OUT" "exceeds the" "no slot-count advice on a discrete GPU"
assert_not_contains "$OUT" "KV cache is" "no KV cache advice on a discrete GPU"

# ══════════════════════════════════════════════════════════════════
case_start "Hand-tuned Jetson .env within budget stays quiet"
# ══════════════════════════════════════════════════════════════════
# Advice must be one-sided: only flag settings that are *larger* than the board
# can hold, never nag a user who deliberately went smaller.
new_project
run_setup "$P" "$JETSON_SYSROOT"                       # write platform defaults
sed -i 's|^CTX_SIZE=.*|CTX_SIZE=2048|; s|^PARALLEL=.*|PARALLEL=1|' "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_contains "$OUT" ".env matches the detected jetson platform" "a smaller context is not a mismatch"
sed -i 's|^CTX_SIZE=.*|CTX_SIZE=131072|' "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_contains "$OUT" "CTX_SIZE=131072 exceeds the recommended" "a larger context is a mismatch"

# ══════════════════════════════════════════════════════════════════
case_start "MODEL_FILE names a model that is no longer on disk"
# ══════════════════════════════════════════════════════════════════
# Reproduced end to end: prune a model, and setup.sh used to print "Models
# found", "Setup complete" and exit 0, leaving compose to crash-loop on a path
# that does not exist. Only the shipped placeholder was ever repaired.
new_project
run_setup "$P" "$JETSON_SYSROOT"
printf 'GGUF\x03\x00\x00\x00' >"$P/models/qwen2.5-3b-instruct-q4_k_m.gguf"
sed -i 's|^MODEL_FILE=.*|MODEL_FILE=/models/pruned-model.gguf|' "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_eq "$(envval "$P" MODEL_FILE)" "/models/qwen2.5-3b-instruct-q4_k_m.gguf" \
  "repoints MODEL_FILE at the one model present"
assert_contains "$OUT" "Set MODEL_FILE=/models/qwen2.5-3b-instruct-q4_k_m.gguf" "reports the repair"
assert_exit "$RC" 0 "exits 0 once repaired"

# ══════════════════════════════════════════════════════════════════
case_start "MODEL_FILE is ambiguous with several models present"
# ══════════════════════════════════════════════════════════════════
new_project
run_setup "$P" "$JETSON_SYSROOT"
printf 'GGUF\x03\x00\x00\x00' >"$P/models/a-Q4_K_M.gguf"
printf 'GGUF\x03\x00\x00\x00' >"$P/models/b-Q5_K_M.gguf"
sed -i 's|^MODEL_FILE=.*|MODEL_FILE=/models/pruned-model.gguf|' "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_eq "$(envval "$P" MODEL_FILE)" "/models/pruned-model.gguf" "does not guess between models"
assert_contains "$OUT" "Several models are present" "asks the user to choose"
assert_contains "$OUT" "MODEL_FILE=/models/a-Q4_K_M.gguf" "lists the first candidate"
assert_contains "$OUT" "MODEL_FILE=/models/b-Q5_K_M.gguf" "lists the second candidate"
assert_not_contains "$OUT" "Setup complete" "does not claim success while unresolved"

# ══════════════════════════════════════════════════════════════════
case_start "A valid MODEL_FILE is left alone"
# ══════════════════════════════════════════════════════════════════
new_project
run_setup "$P" "$JETSON_SYSROOT"
printf 'GGUF\x03\x00\x00\x00' >"$P/models/a-Q4_K_M.gguf"
printf 'GGUF\x03\x00\x00\x00' >"$P/models/b-Q5_K_M.gguf"
sed -i 's|^MODEL_FILE=.*|MODEL_FILE=/models/b-Q5_K_M.gguf|' "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_eq "$(envval "$P" MODEL_FILE)" "/models/b-Q5_K_M.gguf" "keeps the user's choice"
assert_contains "$OUT" "MODEL_FILE=/models/b-Q5_K_M.gguf is present" "confirms it resolves"
assert_contains "$OUT" "Setup complete" "reports success"
assert_exit "$RC" 0 "exits 0"

# ══════════════════════════════════════════════════════════════════
case_start "No model yet: recommends the one sized for the board"
# ══════════════════════════════════════════════════════════════════
new_project
run_setup "$P" "$JETSON_SYSROOT"
assert_contains "$OUT" "No .gguf model found in" "reports the empty models directory"
assert_contains "$OUT" "download-model.sh --recommended" "points at the sized download"
assert_contains "$OUT" "Qwen2.5-3B-Instruct-Q4_K_M.gguf" "names the Jetson-sized model"
assert_not_contains "$OUT" "Setup complete" "an unusable stack is not complete"

# ══════════════════════════════════════════════════════════════════
case_start "MODELS_DIR on a data disk"
# ══════════════════════════════════════════════════════════════════
# Keeping models off the repo volume is the documented way to stay within a
# Jetson's disk. setup.sh used to create ./models regardless, never create the
# real directory, and print advice naming ./models - so a model downloaded to
# the data disk was reported as missing.
new_project
DATA="$TMPROOT/datadisk/models"
run_setup "$P" "$JETSON_SYSROOT"
sed -i "s|^MODELS_DIR=.*|MODELS_DIR=$DATA|" "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
if [[ -d "$DATA" ]]; then pass "creates MODELS_DIR, not just ./models"
else fail "creates MODELS_DIR, not just ./models" "$DATA does not exist"; fi
assert_contains "$OUT" "No .gguf model found in $DATA" "reports the configured directory"
assert_not_contains "$OUT" "No .gguf model found in ./models" "does not name the wrong directory"
printf 'GGUF\x03\x00\x00\x00' >"$DATA/data-disk-model.gguf"
run_setup "$P" "$JETSON_SYSROOT"
assert_eq "$(envval "$P" MODEL_FILE)" "/models/data-disk-model.gguf" "finds models on the data disk"
assert_contains "$OUT" "Models found in $DATA" "lists them from the data disk"

# A bind source is not a shell path. Both forms below are things a user writes
# by hand, and both put the model somewhere the container never mounts - the
# bare one stops compose from parsing the project at all, and the tilde one is
# expanded by compose but not by bash, so setup.sh would create a directory
# literally named '~' and report the model in it as present.
new_project
run_setup "$P" "$JETSON_SYSROOT"
sed -i "s|^MODELS_DIR=.*|MODELS_DIR=models|" "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_contains "$OUT" "is not a directory compose can bind-mount" "a bare relative MODELS_DIR is reported"
assert_contains "$OUT" "write ./models" "says what to write instead"
assert_not_contains "$OUT" "Setup complete" "and is counted as outstanding"

new_project
run_setup "$P" "$JETSON_SYSROOT"
sed -i "s|^MODELS_DIR=.*|MODELS_DIR=~/models|" "$P/.env"
# HOME points into the fixture: `~` is expanded by the script under test, so
# letting it reach the real home directory would create one there.
FAKE_HOME="$TMPROOT/home$PROJ_N"; mkdir -p "$FAKE_HOME"
OUT="$(cd "$P" && PATH="$STUBBIN:$PATH" HOME="$FAKE_HOME" \
    PLATFORM_SYSROOT="$JETSON_SYSROOT" PLATFORM_NVIDIA_SMI=nvidia-smi \
    bash "$P/scripts/setup.sh" 2>&1)"
assert_contains "$OUT" "$FAKE_HOME/models" "expands ~ the way compose does"
[[ -d "$FAKE_HOME/models" ]] && pass "creates the directory compose will mount" \
                             || fail "creates the directory compose will mount"
[[ -d "$P/~" ]] && fail "does not create a directory literally named ~" \
                || pass "does not create a directory literally named ~"

# ══════════════════════════════════════════════════════════════════
case_start ".env values that are not shell-safe"
# ══════════════════════════════════════════════════════════════════
# .env is compose syntax, not shell. `source` aborts partway through a value
# containing whitespace or a leading dash, silently losing every later key -
# including MODELS_DIR, which decides where models are looked for.
new_project
run_setup "$P" "$JETSON_SYSROOT"
DATA2="$TMPROOT/datadisk2/models"; mkdir -p "$DATA2"
printf 'GGUF\x03\x00\x00\x00' >"$DATA2/quoted-dir-model.gguf"
# An extra-args style key, as compose accepts it, placed before MODELS_DIR.
printf 'LLAMA_EXTRA_ARGS=--flash-attn --mlock\n' >>"$P/.env"
sed -i "s|^MODELS_DIR=.*|MODELS_DIR=$DATA2|" "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_eq "$(envval "$P" MODEL_FILE)" "/models/quoted-dir-model.gguf" \
  "keys after an unquoted multi-word value are still read"
assert_not_contains "$OUT" "command not found" "does not execute .env as shell"
# An inline comment and CRLF line endings are both legal in a .env and both
# used to end up inside the value. On a path that means setup.sh creates - and
# then reports on - a directory whose name nobody would ever type.
new_project
run_setup "$P" "$JETSON_SYSROOT"
DATA3="$TMPROOT/datadisk3/models"; mkdir -p "$DATA3"
printf 'GGUF\x03\x00\x00\x00' >"$DATA3/inline-comment-model.gguf"
sed -i "s|^MODELS_DIR=.*|MODELS_DIR=$DATA3 # weights live off the repo|" "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_eq "$(envval "$P" MODEL_FILE)" "/models/inline-comment-model.gguf" \
  "an inline comment is not part of the path"
assert_not_contains "$OUT" "weights live off the repo" "does not echo the comment as a directory"

new_project
run_setup "$P" "$JETSON_SYSROOT"
DATA4="$TMPROOT/datadisk4/models"; mkdir -p "$DATA4"
printf 'GGUF\x03\x00\x00\x00' >"$DATA4/crlf-model.gguf"
sed -i "s|^MODELS_DIR=.*|MODELS_DIR=$DATA4\r|" "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_eq "$(envval "$P" MODEL_FILE)" "/models/crlf-model.gguf" \
  "a CRLF line ending is not part of the path"

# A commented-out key must not win over the live one below it.
new_project
cp "$P/.env.example" "$P/.env"
sed -i '1i #COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml' "$P/.env"
run_setup "$P" "$JETSON_SYSROOT"
assert_contains "$OUT" "COMPOSE_FILE does not select the Jetson overlay" \
  "a commented assignment does not satisfy the check"

# ══════════════════════════════════════════════════════════════════
case_start "Platform detection failure is reported, not inherited"
# ══════════════════════════════════════════════════════════════════
# With no readable /proc/meminfo the old script aborted mid-way on an awk error
# or an 'unbound variable', both of which read as a bug in setup.sh.
new_project
BROKEN="$TMPROOT/sys-broken"; mkdir -p "$BROKEN"
run_setup "$P" "$BROKEN"
assert_exit "$RC" 1 "exits non-zero"
assert_contains "$OUT" "Platform detection failed" "says what failed"
assert_not_contains "$OUT" "unbound variable" "no raw bash error"
if [[ ! -f "$P/.env" ]]; then pass "writes no .env from an unknown platform"
else fail "writes no .env from an unknown platform" "$(cat "$P/.env")"; fi

# A probe that exits 0 while emitting nothing usable is the harder case: the
# values get eval'd, so an empty result means every later reference is either
# an 'unbound variable' abort or, worse, a silently wrong default.
new_project
cat >"$P/scripts/detect-platform.sh" <<'EOF'
#!/usr/bin/env bash
echo "detect-platform: nothing to report"
exit 0
EOF
run_setup "$P" "$JETSON_SYSROOT"
assert_exit "$RC" 1 "exits non-zero when detection yields no values"
assert_contains "$OUT" "Platform detection failed" "says what failed"
assert_not_contains "$OUT" "unbound variable" "no raw bash error"

# Warnings on stderr must be reported, never eval'd.
new_project
cat >"$P/scripts/detect-platform.sh" <<'EOF'
#!/usr/bin/env bash
echo "warning: this board is close to its memory limit" >&2
exit 1
EOF
run_setup "$P" "$JETSON_SYSROOT"
assert_contains "$OUT" "this board is close to its memory limit" "surfaces the probe's stderr"
assert_not_contains "$OUT" "command not found" "does not execute stderr as shell"

# ══════════════════════════════════════════════════════════════════
case_start "Idempotence"
# ══════════════════════════════════════════════════════════════════
new_project
run_setup "$P" "$JETSON_SYSROOT"
printf 'GGUF\x03\x00\x00\x00' >"$P/models/only-Q4_K_M.gguf"
run_setup "$P" "$JETSON_SYSROOT"
SNAP="$(cat "$P/.env")"
run_setup "$P" "$JETSON_SYSROOT"
assert_eq "$(cat "$P/.env")" "$SNAP" ".env is byte-identical after a repeat run"
assert_exit "$RC" 0 "still exits 0"
assert_contains "$OUT" ".env already exists" "does not recreate .env"
assert_contains "$OUT" "Hugging Face CLI already in .venv/" "does not rebuild the venv"
assert_contains "$OUT" "TLS certs already exist" "does not reissue certificates"

# ══════════════════════════════════════════════════════════════════
case_start "python3 without ensurepip does not abort the bootstrap"
# ══════════════════════════════════════════════════════════════════
# JetPack's Ubuntu ships python3 with no python3-venv. The venv only buys
# resumable downloads, so this must degrade rather than fail.
new_project
NOVENV="$TMPROOT/bin-novenv"; mkdir -p "$NOVENV"
cp "$STUBBIN/docker" "$STUBBIN/nvidia-smi" "$NOVENV/"
printf '#!/bin/sh\nexit 1\n' >"$NOVENV/python3"; chmod +x "$NOVENV/python3"
OUT="$(cd "$P" && PATH="$NOVENV:$PATH" PLATFORM_SYSROOT="$JETSON_SYSROOT" \
    bash "$P/scripts/setup.sh" 2>&1)"; RC=$?
assert_contains "$OUT" "Could not create the Python venv" "explains the fallback"
assert_contains "$OUT" "falls back to curl" "says downloads still work"
assert_contains "$OUT" "Docker version" "continues past the venv step"
if [[ ! -d "$P/.venv" ]]; then pass "leaves no half-built .venv behind"
else fail "leaves no half-built .venv behind" "$P/.venv exists"; fi
assert_exit "$RC" 0 "exits 0"

# ══════════════════════════════════════════════════════════════════
case_start "Recommended model fits the budget it is recommended for"
# ══════════════════════════════════════════════════════════════════
# setup.sh is where a user first sees a model name; that name must be one the
# detected board can actually load.
for MEM in 2000000 4000000 7620000 16000000 65000000; do
  new_project
  S="$TMPROOT/sys-mem-$MEM"; make_jetson_sysroot "$S" "$MEM"
  run_setup "$P" "$S"
  budget="$(cd "$P" && PLATFORM_SYSROOT="$S" bash scripts/detect-platform.sh --env |
            sed -n 's/^GPU_MEM_MB=//p')"
  recmb="$(cd "$P" && PLATFORM_SYSROOT="$S" bash scripts/detect-platform.sh --env |
            sed -n 's/^REC_MODEL_MB=//p')"
  if (( recmb < budget )); then pass "$((MEM/1024)) MiB board: recommended model fits the budget"
  else fail "$((MEM/1024)) MiB board: recommended model fits the budget" "${recmb} MiB vs ${budget} MiB"; fi
  assert_contains "$OUT" ".env matches the detected jetson platform" \
    "$((MEM/1024)) MiB board: written defaults are self-consistent"
done

# ══════════════════════════════════════════════════════════════════
case_start "A Jetson without a CDI spec still gets the overlay"
# ══════════════════════════════════════════════════════════════════
# nvidia-ctk has not been run yet. The overlay is still the right choice - the
# legacy path hangs regardless - and validate.sh is what tells the user to
# generate the spec.
new_project
NOCDI="$TMPROOT/sys-jetson-nocdi"; make_jetson_sysroot "$NOCDI" 7620000 no-cdi
run_setup "$P" "$NOCDI"
assert_exit "$RC" 0 "exits 0"
assert_contains "$OUT" "jetson" "still detected as a Jetson"
assert_eq "$(envval "$P" LLAMA_IMAGE)" "ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin" \
  "still selects the Jetson image"

# ══════════════════════════════════════════════════════════════════
case_start "Certificates that are present but unusable are reported"
# ══════════════════════════════════════════════════════════════════
# setup.sh used to accept certs/ on the strength of server.crt existing, which
# is true of every broken state as well: nginx is then what discovers that the
# key does not match, by refusing to start after `docker compose up`.
new_project
openssl genrsa -out "$P/certs/server.key" 2048 2>/dev/null
run_setup "$P" "$JETSON_SYSROOT"
assert_contains "$OUT" "not usable as they stand" "reports the broken pair"
assert_contains "$OUT" "does not match server.key" "names what is wrong"
assert_contains "$OUT" "item(s) to resolve" "counts it as outstanding"
assert_not_contains "$OUT" "Setup complete" "does not report success"

new_project
run_setup "$P" "$JETSON_SYSROOT"
assert_contains "$OUT" "exist in certs/ and are consistent" "a good set is confirmed, not just counted"

# ── Summary ───────────────────────────────────────────────────────
printf '\n%s────────────────────────────────────────%s\n' "$C_HD" "$C_Z"
if (( FAIL == 0 )); then
  printf '%sAll %d assertions passed.%s\n' "$C_OK" "$PASS" "$C_Z"
  exit 0
fi
printf '%s%d passed, %d failed.%s\n' "$C_NO" "$PASS" "$FAIL" "$C_Z"
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
exit 1
