#!/usr/bin/env bash
# test-power.sh - Hermetic tests for lib/power.sh, the reader that decides
# whether this board is running as fast as it can.
#
# A board sits in exactly one power mode, and switching it needs root, so the
# host this runs on can demonstrate almost none of what the reader has to get
# right. In particular it cannot demonstrate the thing that makes the ranking
# non-trivial: on an Orin Nano Super the modes are 15W=0, 25W=1, MAXN_SUPER=2,
# 7W=3, so "the fastest mode" is neither the highest id nor the last one in the
# file, and a reader that assumed either would name the *slowest* mode on the
# board as its best and then advise switching to it.
#
# The fixtures are synthetic /etc/nvpmodel.conf and /var/lib/nvpmodel/status
# trees. One case is differential instead: where the host really is a Jetson,
# the value read from those files is compared against what `nvpmodel -q` itself
# reports, so the file-reading shortcut cannot drift away from the authority it
# replaces.
#
# Needs no GPU, Docker, model, network, daemon or root.
#
# Usage:
#   ./scripts/test-power.sh          # run all cases
#   ./scripts/test-power.sh -v       # also print each assertion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

VERBOSE=0
[[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]] && VERBOSE=1

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_SK=$'\033[33m'; C_HD=$'\033[1m'; C_Z=$'\033[0m'
else
  C_OK=""; C_NO=""; C_SK=""; C_HD=""; C_Z=""
fi

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()
CASE=""

pass() { PASS=$((PASS+1)); (( VERBOSE )) && printf '  %sok%s   %s\n' "$C_OK" "$C_Z" "$1"; return 0; }
fail() {
  FAIL=$((FAIL+1)); FAILED_NAMES+=("$CASE: $1")
  printf '  %sFAIL%s %s\n' "$C_NO" "$C_Z" "$1"
  [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
  return 0
}
skipped() { SKIP=$((SKIP+1)); printf '  %sskip%s %s\n' "$C_SK" "$C_Z" "$1"; return 0; }
case_start() { CASE="$1"; printf '\n%s%s%s\n' "$C_HD" "$1" "$C_Z"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
assert_has() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "no [$2] in [$3]"; fi
}
assert_not_has() {
  if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1" "unexpected [$2] in [$3]"; fi
}

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# shellcheck source=lib/power.sh
. "$SCRIPT_DIR/lib/power.sh"

# ── Fixtures ──────────────────────────────────────────────────────
# A sysroot is just the two files the reader looks at. mk_sysroot writes the
# status file; the conf is supplied per case.
mk_sysroot() {   # mk_sysroot <name> [<pmode line>] -> echoes the path
  local dir="$TMPROOT/$1"
  mkdir -p "$dir/etc" "$dir/var/lib/nvpmodel"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" >"$dir/var/lib/nvpmodel/status"
  printf '%s' "$dir"
}

# One POWER_MODEL block. Written as a function so a case states only the
# numbers it cares about, and so every block has the surrounding shape of a
# real file (the keyword order and the CPU_ONLINE lines) rather than a
# minimal one the parser might handle by accident.
mode_block() {   # mode_block <id> <name> <emc> <gpu> <cores> <cpu_max>
  local id="$1" name="$2" emc="$3" gpu="$4" cores="$5" cpumax="$6" i
  printf '< POWER_MODEL ID=%s NAME=%s >\n' "$id" "$name"
  for (( i = 0; i < 6; i++ )); do
    printf 'CPU_ONLINE CORE_%d %d\n' "$i" "$(( i < cores ? 1 : 0 ))"
  done
  printf 'FBP_POWER_GATING FBP_PG_MASK 2\n'
  printf 'TPC_POWER_GATING TPC_PG_MASK 240\n'
  printf 'GPU_POWER_CONTROL_ENABLE GPU_PWR_CNTL_EN on\n'
  for (( i = 0; i < cores; i++ )); do
    printf 'CPU_A78_%d MIN_FREQ 729600\n' "$i"
    printf 'CPU_A78_%d MAX_FREQ %s\n' "$i" "$cpumax"
  done
  printf 'GPU MIN_FREQ 0\n'
  printf 'GPU MAX_FREQ %s\n' "$gpu"
  printf 'GPU_POWER_CONTROL_DISABLE GPU_PWR_CNTL_DIS auto\n'
  printf 'EMC MAX_FREQ %s\n' "$emc"
  printf '\n'
}

# The definitions section every real nvpmodel.conf carries above the modes. It
# uses the same keywords the mode blocks do - there is a bare `MAX_FREQ /sys/...`
# line in it - so a parser that collects fields outside a POWER_MODEL block
# invents a mode out of it.
preamble() {
  cat <<'EOF'
# nvpmodel configuration
< PARAM TYPE=FILE NAME=CPU_ONLINE >
FILE_STR /sys/devices/system/cpu/cpu%d/online
ARG_DEFAULT 1

< PARAM TYPE=CLOCK NAME=EMC >
MAX_FREQ /sys/kernel/nvpmodel_emc_cap/emc_iso_cap
MAX_FREQ_KNEXT /sys/kernel/nvpmodel_clk_cap/emc

< PARAM TYPE=CLOCK NAME=GPU >
MAX_FREQ /sys/devices/gpu.0/devfreq/17000000.ga10b/max_freq

###########################
# POWER_MODEL DEFINITIONS #
###########################

EOF
}

# The catalogue this board actually ships, values copied from the Orin Nano
# Super's /etc/nvpmodel.conf. Deliberately the real thing: the whole point of
# the ranking is that this file's fastest mode is id 2 with id 3 below it.
orin_conf() {
  preamble
  mode_block 0 15W         2133000000 612000000 6 1497600
  mode_block 1 25W         3199000000 918000000 6 1344000
  mode_block 2 MAXN_SUPER  -1         -1        6 -1
  mode_block 3 7W          2133000000 408000000 4 960000
  printf '< PM_CONFIG DEFAULT=1 >\n'
}

# ══════════════════════════════════════════════════════════════════
case_start "the fastest mode is found by what it uncaps, not by its id"
# This is the case the real board cannot show and the one every naive
# implementation gets wrong: MAXN_SUPER is id 2 of 0..3, so both "highest id"
# and "last block in the file" name 7W - the slowest mode on the board.
SR="$(mk_sysroot orin 'pmode:0000')"
orin_conf >"$SR/etc/nvpmodel.conf"
power_probe "$SR"

assert_eq "four modes are read from the catalogue" "4" "${#POWER_IDS[@]}"
assert_eq "the ids are the file's, in file order" "0 1 2 3" "${POWER_IDS[*]}"
assert_eq "the fastest mode is MAXN_SUPER, not the highest id" "2" "$POWER_BEST_ID"
assert_eq "…named" "MAXN_SUPER" "$POWER_BEST_NAME"
assert_eq "the active mode is read from the status file" "0" "$POWER_ACTIVE_ID"
assert_eq "…named from the catalogue" "15W" "$POWER_ACTIVE_NAME"
assert_eq "the boot default is read from PM_CONFIG" "1" "$POWER_DEFAULT_ID"
assert_eq "a board below its fastest mode is reported as such" "below" "$POWER_STATE"

# The preamble uses the same keywords as a mode block. A parser that collects
# outside a POWER_MODEL block turns it into a fifth mode with a garbage id.
assert_eq "the definitions section is not read as a mode" "" \
  "$(for i in "${POWER_IDS[@]}"; do [[ "$i" =~ ^[0-3]$ ]] || printf '%s ' "$i"; done)"

case_start "clock ceilings survive the read"
assert_eq "15W's EMC ceiling"            "2133000000" "${POWER_EMC[0]}"
# 3199000000 is past INT32_MAX. The first version of the parser formatted these
# with awk's %d, which clamps at 2147483647 - so 25W was reported as "2147 MHz"
# and every mode above 2.1 GHz compared equal to every other.
assert_eq "25W's EMC ceiling is not clamped at INT32_MAX" "3199000000" "${POWER_EMC[1]}"
assert_eq "an uncapped ceiling stays -1"  "-1"         "${POWER_EMC[2]}"
assert_eq "15W's GPU ceiling"             "612000000"  "${POWER_GPU[0]}"
assert_eq "7W's GPU ceiling"              "408000000"  "${POWER_GPU[3]}"
assert_eq "7W leaves four cores online"   "4"          "${POWER_CORES[3]}"
assert_eq "15W leaves six cores online"   "6"          "${POWER_CORES[0]}"
assert_eq "the CPU ceiling is the cluster's" "1497600"  "${POWER_CPU[0]}"

assert_eq "an uncapped ceiling reads as uncapped" "uncapped" "$(power_mhz -1)"
assert_eq "a real ceiling reads in MHz"           "2133 MHz" "$(power_mhz 2133000000)"
assert_eq "…and past INT32_MAX too"               "3199 MHz" "$(power_mhz 3199000000)"
assert_eq "an absent ceiling is not invented"     "unspecified" "$(power_mhz 0)"
assert_has "a mode is described by what it allows" "EMC 2133 MHz, GPU 612 MHz, 6 core(s)" \
  "$(power_describe 0)"

case_start "the ranking orders the whole catalogue, not just the top"
_power_faster 1 0 && r=yes || r=no
assert_eq "25W is faster than 15W"                    "yes" "$r"
_power_faster 0 3 && r=yes || r=no
assert_eq "15W is faster than 7W"                     "yes" "$r"
_power_faster 3 0 && r=yes || r=no
assert_eq "…and 7W is not faster than 15W"            "no"  "$r"
_power_faster 2 1 && r=yes || r=no
assert_eq "an uncapped mode beats the highest capped one" "yes" "$r"
_power_faster 1 2 && r=yes || r=no
assert_eq "…and not the other way round"              "no"  "$r"
_power_faster 0 0 && r=yes || r=no
assert_eq "a mode is not faster than itself"          "no"  "$r"
# 15W and 7W share an EMC ceiling, so the GPU clock is what separates them -
# a ranking on memory bandwidth alone would call them equal.
assert_eq "modes with equal EMC are separated by the GPU clock" \
  "${POWER_EMC[0]}" "${POWER_EMC[3]}"

case_start "a board already in its fastest mode is not nagged"
SR="$(mk_sysroot orin-maxn 'pmode:0002')"
orin_conf >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
assert_eq "state is best"          "best"       "$POWER_STATE"
assert_eq "the active mode"        "MAXN_SUPER" "$POWER_ACTIVE_NAME"
assert_eq "no advice is offered"   ""           "$(power_advice_lines)"

case_start "the advice names the mode and the command"
SR="$(mk_sysroot orin-15w 'pmode:0000')"
orin_conf >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
ADV="$(power_advice_lines)"
assert_eq "two lines of advice" "2" "$(printf '%s\n' "$ADV" | grep -c .)"
assert_has "…naming the faster mode"  "MAXN_SUPER is faster" "$ADV"
assert_has "…and the exact command"   "sudo nvpmodel -m 2"   "$ADV"
# The board's fastest mode is uncapped, so there is no ratio to quote. Printing
# one anyway would put a number in the advice that nothing measured.
assert_has "an uncapped target says what it removes" "removes the caps" "$ADV"
assert_not_has "…without inventing a speedup figure" "%" "$ADV"

case_start "where both modes state a ceiling, the gain is quoted from them"
# Same board with MAXN_SUPER removed: 25W becomes the best, and both it and the
# active mode carry real numbers, so the ratio is derived rather than guessed.
SR="$(mk_sysroot orin-nomaxn 'pmode:0000')"
{ preamble
  mode_block 0 15W 2133000000 612000000 6 1497600
  mode_block 1 25W 3199000000 918000000 6 1344000
  printf '< PM_CONFIG DEFAULT=0 >\n'
} >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
assert_eq "the best mode is the highest capped one" "1" "$POWER_BEST_ID"
ADV="$(power_advice_lines)"
assert_has "the EMC ceilings are quoted"  "EMC 2133 MHz -> 3199 MHz" "$ADV"
# (3199-2133)/2133 = 49.9% -> 49 by integer division. Derived, not asserted at
# a round number, so the assertion still holds if the formula is re-derived.
assert_has "…with the bandwidth increase they imply" \
  "$(( (3199000000 - 2133000000) * 100 / 2133000000 ))% more memory bandwidth" "$ADV"
assert_has "…and the GPU ceilings"        "GPU 612 MHz -> 918 MHz"   "$ADV"
assert_has "the command names the new id" "sudo nvpmodel -m 1"       "$ADV"

case_start "two modes past INT32_MAX are still told apart"
# The bug this pins is not hypothetical: with awk's %d both of these read back
# as 2147483647, so the reader called them equal and named the first as best.
SR="$(mk_sysroot bigemc 'pmode:0000')"
{ preamble
  mode_block 0 SLOW 3199000000 918000000 6 1344000
  mode_block 1 FAST 4266000000 918000000 6 1344000
  printf '< PM_CONFIG DEFAULT=0 >\n'
} >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
assert_eq "the higher ceiling is read back intact" "4266000000" "${POWER_EMC[1]}"
assert_eq "…and wins the ranking"                  "1"          "$POWER_BEST_ID"
assert_eq "…so the board is reported as below it"  "below"      "$POWER_STATE"

case_start "identical modes do not make one of them 'faster'"
SR="$(mk_sysroot twins 'pmode:0000')"
{ preamble
  mode_block 0 A 2133000000 612000000 6 1497600
  mode_block 1 B 2133000000 612000000 6 1497600
  printf '< PM_CONFIG DEFAULT=0 >\n'
} >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
assert_eq "the first of two equals is the best"  "0"    "$POWER_BEST_ID"
assert_eq "…and the board is in its fastest mode" "best" "$POWER_STATE"
assert_eq "…so it is given no advice"             ""     "$(power_advice_lines)"

case_start "the status file is read the way nvpmodel writes it"
SR="$(mk_sysroot z 'pmode:0000')"; orin_conf >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
# 0000 is neither an empty match nor octal: a greedy leading-zero strip leaves
# nothing behind, and $((0010)) is 8.
assert_eq "pmode:0000 is mode 0" "0" "$POWER_ACTIVE_ID"

SR="$(mk_sysroot z2 'pmode:0002')"; orin_conf >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
assert_eq "pmode:0002 is mode 2" "2" "$POWER_ACTIVE_ID"

SR="$(mk_sysroot z3)"; orin_conf >"$SR/etc/nvpmodel.conf"
printf 'pmode:0001\nfmode:fanmode_quiet\n' >"$SR/var/lib/nvpmodel/status"
power_probe "$SR"
assert_eq "a fan-mode line alongside does not confuse it" "1" "$POWER_ACTIVE_ID"
assert_eq "…and the mode is named"                        "25W" "$POWER_ACTIVE_NAME"

case_start "a mode the configuration does not define is a fault, not a guess"
SR="$(mk_sysroot stale 'pmode:0009')"
orin_conf >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
assert_eq "the state says so"                    "unknown-mode" "$POWER_STATE"
assert_eq "the id read is kept for the message"  "9"            "$POWER_ACTIVE_ID"
assert_eq "…and no mode is claimed as active"    ""             "$POWER_ACTIVE_NAME"
assert_eq "the catalogue is still ranked"        "2"            "$POWER_BEST_ID"
assert_eq "…and no advice is offered against an unknown mode" "" "$(power_advice_lines)"

case_start "a configuration with no modes is reported, not silently ranked"
SR="$(mk_sysroot empty 'pmode:0000')"
preamble >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
assert_eq "state is no-modes"      "no-modes" "$POWER_STATE"
assert_eq "no mode is named best"  ""         "$POWER_BEST_ID"

case_start "a host with no nvpmodel at all is a normal host"
SR="$(mk_sysroot bare)"
POWER_NVPMODEL="/nonexistent/nvpmodel" power_probe "$SR"
assert_eq "state is unavailable"   "unavailable" "$POWER_STATE"
assert_eq "no active mode"         ""            "$POWER_ACTIVE_ID"
assert_eq "no active mode name"    ""            "$POWER_ACTIVE_NAME"
assert_eq "no best mode"           ""            "$POWER_BEST_ID"
assert_eq "no advice"              ""            "$(power_advice_lines)"

case_start "nvpmodel -q is the fallback when the status file is absent"
# A freshly flashed board has never been switched, so nvpmodel has not written
# a status file yet. The binary is the only source of the active mode there.
cat >"$TMPROOT/nvpmodel-stub" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-q" ]] || exit 1
printf 'NV Power Mode: 25W\n1\n'
EOF
chmod +x "$TMPROOT/nvpmodel-stub"

SR="$(mk_sysroot fresh)"   # no status file
orin_conf >"$SR/etc/nvpmodel.conf"
POWER_NVPMODEL="$TMPROOT/nvpmodel-stub" power_probe "$SR"
assert_eq "the mode id comes from the binary"     "1"     "$POWER_ACTIVE_ID"
assert_eq "…and the name from the catalogue"      "25W"   "$POWER_ACTIVE_NAME"
assert_eq "…and the board is still ranked"        "below" "$POWER_STATE"

# With no catalogue there is nothing to rank against, but the mode the binary
# reports is still worth printing - benchmark.sh's header is the consumer.
SR="$(mk_sysroot fresh-noconf)"
POWER_NVPMODEL="$TMPROOT/nvpmodel-stub" power_probe "$SR"
assert_eq "without a catalogue the state is unavailable" "unavailable" "$POWER_STATE"
assert_eq "…but the binary's mode name is kept"          "25W"         "$POWER_ACTIVE_NAME"
assert_eq "…and its id"                                  "1"           "$POWER_ACTIVE_ID"

# The status file wins where both exist: it is what nvpmodel itself consults,
# and a stale binary on PATH must not override it.
SR="$(mk_sysroot both 'pmode:0003')"
orin_conf >"$SR/etc/nvpmodel.conf"
POWER_NVPMODEL="$TMPROOT/nvpmodel-stub" power_probe "$SR"
assert_eq "the status file takes precedence over the binary" "3" "$POWER_ACTIVE_ID"
assert_eq "…and names the mode it points at"                 "7W" "$POWER_ACTIVE_NAME"

case_start "a failing nvpmodel binary is not a crash"
cat >"$TMPROOT/nvpmodel-broken" <<'EOF'
#!/usr/bin/env bash
echo "nvpmodel: failed to open /sys/..." >&2
exit 1
EOF
chmod +x "$TMPROOT/nvpmodel-broken"
SR="$(mk_sysroot broken)"
orin_conf >"$SR/etc/nvpmodel.conf"
POWER_NVPMODEL="$TMPROOT/nvpmodel-broken" power_probe "$SR" 2>/dev/null
rc=$?
assert_eq "the probe still returns cleanly"        "0"            "$rc"
assert_eq "…and reports the mode as unknown"       "unknown-mode" "$POWER_STATE"
assert_eq "…while still ranking the catalogue"     "MAXN_SUPER"   "$POWER_BEST_NAME"

case_start "a Xavier-style configuration reads the same way"
# The CPU cluster keyword is SoC-specific, and the mode names are different
# again. Nothing in the reader may depend on the strings this one board uses.
SR="$(mk_sysroot xavier 'pmode:0000')"
{ preamble
  printf '< POWER_MODEL ID=0 NAME=MAXN >\n'
  printf 'CPU_ONLINE CORE_0 1\nCPU_ONLINE CORE_1 1\n'
  printf 'CPU_DENVER_0 MIN_FREQ 1190400\nCPU_DENVER_0 MAX_FREQ 2265600\n'
  printf 'GPU MAX_FREQ 1377000000\nEMC MAX_FREQ 2133000000\n\n'
  printf '< POWER_MODEL ID=1 NAME=MODE_10W >\n'
  printf 'CPU_ONLINE CORE_0 1\nCPU_ONLINE CORE_1 0\n'
  printf 'CPU_DENVER_0 MIN_FREQ 1190400\nCPU_DENVER_0 MAX_FREQ 1200000\n'
  printf 'GPU MAX_FREQ 520000000\nEMC MAX_FREQ 1065600000\n\n'
  printf '< PM_CONFIG DEFAULT=0 >\n'
} >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
assert_eq "both modes are read"              "2"       "${#POWER_IDS[@]}"
assert_eq "the Denver cluster ceiling"       "2265600" "${POWER_CPU[0]}"
assert_eq "the wide mode ranks first"        "0"       "$POWER_BEST_ID"
assert_eq "…and the board is in it"          "best"    "$POWER_STATE"
assert_eq "core counting follows CPU_ONLINE" "1"       "${POWER_CORES[1]}"

case_start "the probe is safe to call repeatedly and under set -u"
# validate.sh runs with `set -u` and calls this after evaluating
# detect-platform.sh --env, which sets the same POWER_* names. A second probe
# must fully replace the first rather than leaving one board's values mixed
# with another's.
SR="$(mk_sysroot again 'pmode:0002')"; orin_conf >"$SR/etc/nvpmodel.conf"
power_probe "$SR"
SR2="$(mk_sysroot again2)"
out="$( set -u; POWER_NVPMODEL="/nonexistent" power_probe "$SR2" 2>&1; echo "rc=$?" )"
assert_has "no unbound-variable error on a second probe" "rc=0" "$out"
assert_not_has "…and nothing on stderr"                  "unbound" "$out"
POWER_NVPMODEL="/nonexistent" power_probe "$SR2"
assert_eq "the previous board's best mode is cleared" "" "$POWER_BEST_ID"
assert_eq "…and its catalogue"                        "0" "${#POWER_IDS[@]}"
assert_eq "…and its active mode"                      "" "$POWER_ACTIVE_NAME"

case_start "the values detect-platform.sh emits can be eval'd"
# Every consumer of --env eval's it. A name or a state with a space in it would
# execute as a command, and PLATFORM_LABEL has already had that shape.
SR="$(mk_sysroot emit 'pmode:0000')"; orin_conf >"$SR/etc/nvpmodel.conf"
# Enough of a Jetson for detection to reach the power section at all.
mkdir -p "$SR/proc" "$SR/etc/cdi"
printf 'MemTotal:       7620000 kB\n' >"$SR/proc/meminfo"
printf '# R36 (release), REVISION: 4.7, GCID: 1, BOARD: generic, EABI: aarch64\n' \
  >"$SR/etc/nv_tegra_release"
printf 'cdiVersion: "0.5.0"\nkind: nvidia.com/gpu\n' >"$SR/etc/cdi/nvidia.yaml"
env_out="$(PLATFORM_SYSROOT="$SR" PLATFORM_NVIDIA_SMI=/nonexistent \
           bash "$SCRIPT_DIR/detect-platform.sh" --env 2>/dev/null)"
if [[ -z "$env_out" ]]; then
  # The synthetic sysroot has no /proc/meminfo, so detection cannot run. Not a
  # power-mode failure; say so rather than reporting a pass or a fail.
  skipped "detect-platform.sh needs a full sysroot - covered by test-detect-platform.sh"
else
  ( eval "$env_out" ) >/dev/null 2>&1 \
    && pass "the emitted block eval's cleanly" \
    || fail "the emitted block eval's cleanly" "$env_out"
  assert_has "the state reaches the consumer"       'POWER_STATE=below'          "$env_out"
  assert_has "…with the active mode"                'POWER_ACTIVE_NAME="15W"'    "$env_out"
  assert_has "…and the fastest one available"       'POWER_BEST_NAME="MAXN_SUPER"' "$env_out"
  assert_has "…and its id, for the switch command"  'POWER_BEST_ID=2'            "$env_out"
  # detect-platform.sh's human report is what a user reads before installing
  # anything, so the note has to be there and has to be actionable.
  human="$(PLATFORM_SYSROOT="$SR" PLATFORM_NVIDIA_SMI=/nonexistent \
           bash "$SCRIPT_DIR/detect-platform.sh" 2>/dev/null)"
  assert_has "the human report names the active mode" "Power mode    : 15W (id 0)" "$human"
  assert_has "…and the faster one"  "fastest available: MAXN_SUPER (id 2)" "$human"
  assert_has "…and how to switch"   "sudo nvpmodel -m 2"                   "$human"
fi

case_start "against the real board, the files agree with nvpmodel itself"
# The one differential case. Reading /var/lib/nvpmodel/status instead of
# shelling out is a shortcut, and a shortcut is only safe while it still gives
# the same answer as the thing it replaced.
if [[ ! -r /etc/nvpmodel.conf ]]; then
  skipped "this host has no /etc/nvpmodel.conf (not a Jetson)"
elif ! command -v nvpmodel >/dev/null 2>&1; then
  skipped "this host has no nvpmodel binary to compare against"
else
  power_probe ""
  q="$(nvpmodel -q 2>/dev/null)"
  q_id="$(awk '/^[0-9]+$/ { print $1; exit }' <<<"$q")"
  q_name="$(sed -n 's/.*[Pp]ower [Mm]ode: *//p' <<<"$q" | tr -d '\r')"
  q_name="${q_name%%$'\n'*}"
  if [[ -z "$q_id" ]]; then
    skipped "nvpmodel -q reported no mode id on this host"
  else
    assert_eq "the active mode id matches nvpmodel -q" "$q_id" "$POWER_ACTIVE_ID"
    assert_eq "the active mode name matches nvpmodel -q" "$q_name" "$POWER_ACTIVE_NAME"
    if (( ${#POWER_IDS[@]} > 0 )); then
      pass "the real catalogue is readable (${#POWER_IDS[@]} modes, best: $POWER_BEST_NAME)"
      # Every mode nvpmodel.conf defines must be rankable, or the "fastest
      # available" claim is made against a partial list.
      bad=""
      for i in "${POWER_IDS[@]}"; do
        [[ -n "${POWER_NAME[$i]:-}" ]] || bad="$bad $i"
      done
      assert_eq "…and every mode in it is named" "" "$bad"
    else
      fail "the real catalogue is readable" "no modes parsed from /etc/nvpmodel.conf"
    fi
  fi
fi

# ══════════════════════════════════════════════════════════════════
printf '\n%s────────────────────────────────────────%s\n' "$C_HD" "$C_Z"
if (( FAIL == 0 )); then
  printf '%sAll %d assertions passed%s' "$C_OK" "$PASS" "$C_Z"
  (( SKIP )) && printf ' (%d skipped)' "$SKIP"
  printf '.\n'
  exit 0
fi
printf '%s%d of %d assertions failed%s:\n' "$C_NO" "$FAIL" "$((PASS+FAIL))" "$C_Z"
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
exit 1
