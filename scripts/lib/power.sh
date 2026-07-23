# lib/power.sh - which power mode the board is in, and whether it is the fastest.
#
# A Jetson ships with a power cap, and the cap is the single biggest lever on
# LLM throughput on these boards. An Orin Nano Super in its default 15W mode
# runs the memory controller at 2133 MHz; MAXN_SUPER removes the cap entirely.
# Token *generation* is memory-bandwidth bound (see benchmark.sh), so that is
# not a marginal difference - it is most of the performance the board has.
#
# Nothing in this stack was reporting it. benchmark.sh printed whatever string
# `nvpmodel -q` produced, which says what the board is set to and nothing about
# what else it offers, so a number measured at 15W was indistinguishable from
# the best the hardware can do.
#
# Everything here reads two plain files, so it needs no root and no nvpmodel
# binary (`nvpmodel -q` is only a fallback for the active mode):
#
#   /var/lib/nvpmodel/status   the active mode, as "pmode:0000"
#   /etc/nvpmodel.conf         the catalogue: every mode's clock ceilings
#
# Ranking. The fastest mode is NOT the highest ID - on an Orin Nano Super the
# IDs are 15W=0, 25W=1, MAXN_SUPER=2, 7W=3, so "highest ID" would name the
# slowest mode on the board. Modes are ranked by what they actually uncap, in
# the order that decides inference throughput: EMC (memory bandwidth, which
# sets generation speed), then GPU clock (prompt processing), then online CPU
# cores and CPU clock. A value of -1 in nvpmodel.conf means "no cap", which
# ranks above any number.

# nvpmodel.conf writes an absent cap as -1. Kept as a name because the
# comparison treats it as larger than every real frequency, which reads as a
# bug otherwise.
POWER_UNCAPPED=-1

# power_probe [SYSROOT] - read the active mode and the catalogue.
#
# Sets, always:
#   POWER_STATE        unavailable | no-modes | unknown-mode | best | below
#   POWER_ACTIVE_ID    numeric mode id, or empty if it could not be read
#   POWER_ACTIVE_NAME  e.g. 15W (from the catalogue, or from nvpmodel -q)
#   POWER_BEST_ID      the fastest mode in the catalogue, or empty
#   POWER_BEST_NAME
#   POWER_DEFAULT_ID   the mode PM_CONFIG declares as the boot default
#   POWER_IDS          every catalogue id, in file order
#   POWER_NAME/POWER_EMC/POWER_GPU/POWER_CORES/POWER_CPU  per-id detail
#
# SYSROOT prefixes both files so the whole thing is testable on any host; it is
# the same hook detect-platform.sh calls PLATFORM_SYSROOT and benchmark.sh
# calls BENCH_SYSROOT. POWER_NVPMODEL overrides the fallback binary.
#
# Never fails: a host with no nvpmodel.conf is a normal, supported host, and
# "unavailable" is a state a caller reports rather than an error it handles.
power_probe() {
  local sysroot="${1:-}"
  local conf="$sysroot/etc/nvpmodel.conf"
  local statusf="$sysroot/var/lib/nvpmodel/status"

  POWER_STATE="unavailable"
  POWER_ACTIVE_ID=""
  POWER_ACTIVE_NAME=""
  POWER_BEST_ID=""
  POWER_BEST_NAME=""
  POWER_DEFAULT_ID=""
  POWER_IDS=()
  declare -gA POWER_NAME=()
  declare -gA POWER_EMC=()
  declare -gA POWER_GPU=()
  declare -gA POWER_CORES=()
  declare -gA POWER_CPU=()

  # ── The active mode ─────────────────────────────────────────────
  # The status file is what nvpmodel itself writes, so it is authoritative and
  # readable without root. The binary is a fallback for a board that has not
  # been switched since flashing and therefore has no status file yet.
  local raw=""
  if [[ -r "$statusf" ]]; then
    raw="$(awk 'match($0, /pmode:[0-9]+/) {
                  print substr($0, RSTART + 6, RLENGTH - 6); exit }' "$statusf" 2>/dev/null)"
  fi
  local binname=""
  if [[ -z "$raw" ]]; then
    local bin="${POWER_NVPMODEL:-nvpmodel}"
    if command -v "$bin" >/dev/null 2>&1; then
      local q
      q="$("$bin" -q 2>/dev/null)"
      # Real output is a "NV Power Mode: 15W" line followed by the bare id.
      raw="$(awk '/^[0-9]+$/ { print $1; exit }' <<<"$q")"
      binname="$(sed -n 's/.*[Pp]ower [Mm]ode: *//p' <<<"$q" | tr -d '\r')"
      binname="${binname%%$'\n'*}"
    fi
  fi
  # 10# so "0000" is 0 rather than an octal-looking string, and so a comparison
  # against a catalogue id written as "0" matches.
  [[ "$raw" =~ ^[0-9]+$ ]] && POWER_ACTIVE_ID=$((10#$raw))
  POWER_ACTIVE_NAME="$binname"

  # ── The catalogue ───────────────────────────────────────────────
  [[ -r "$conf" ]] || return 0

  local id name emc gpu cores cpu
  while IFS='|' read -r id name emc gpu cores cpu; do
    if [[ "$id" == "DEFAULT" ]]; then
      [[ "$name" =~ ^[0-9]+$ ]] && POWER_DEFAULT_ID=$((10#$name))
      continue
    fi
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    id=$((10#$id))
    POWER_IDS+=("$id")
    POWER_NAME[$id]="$name"
    POWER_EMC[$id]="$emc"
    POWER_GPU[$id]="$gpu"
    POWER_CORES[$id]="$cores"
    POWER_CPU[$id]="$cpu"
  done < <(_power_parse_conf "$conf")

  if (( ${#POWER_IDS[@]} == 0 )); then
    POWER_STATE="no-modes"
    return 0
  fi

  # ── Rank ────────────────────────────────────────────────────────
  local best="${POWER_IDS[0]}" cand
  for cand in "${POWER_IDS[@]}"; do
    _power_faster "$cand" "$best" && best="$cand"
  done
  POWER_BEST_ID="$best"
  POWER_BEST_NAME="${POWER_NAME[$best]}"

  if [[ -z "$POWER_ACTIVE_ID" || -z "${POWER_NAME[$POWER_ACTIVE_ID]+x}" ]]; then
    POWER_STATE="unknown-mode"
    return 0
  fi
  POWER_ACTIVE_NAME="${POWER_NAME[$POWER_ACTIVE_ID]}"
  if [[ "$POWER_ACTIVE_ID" == "$POWER_BEST_ID" ]]; then
    POWER_STATE="best"
  else
    POWER_STATE="below"
  fi
  return 0
}

# _power_parse_conf FILE - one "id|name|emc|gpu|cores|cpu" line per mode, plus a
# "DEFAULT|<id>|||| " line for PM_CONFIG.
#
# The definitions section at the top of nvpmodel.conf uses the same keywords
# (a bare `MAX_FREQ /sys/...` line, for instance), so fields are only collected
# while inside a POWER_MODEL block and any other `< ... >` header closes it.
_power_parse_conf() {
  awk '
    /^[[:space:]]*</ {
      cur = ""
      if ($0 ~ /POWER_MODEL/) {
        id = ""; name = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^ID=/)   id   = substr($i, 4)
          if ($i ~ /^NAME=/) name = substr($i, 6)
        }
        if (id != "") {
          cur = id
          order[++n] = id; nm[id] = name
          emc[id] = 0; gpu[id] = 0; cores[id] = 0; cpu[id] = 0
        }
      } else if ($0 ~ /PM_CONFIG/) {
        for (i = 1; i <= NF; i++)
          if ($i ~ /^DEFAULT=/) def = substr($i, 9)
      }
      next
    }
    cur == "" { next }
    $1 == "EMC" && $2 == "MAX_FREQ" { emc[cur] = $3 + 0; next }
    $1 == "GPU" && $2 == "MAX_FREQ" { gpu[cur] = $3 + 0; next }
    # CPU_ONLINE CORE_n 1 - a core the mode leaves enabled.
    $1 == "CPU_ONLINE" && $3 + 0 > 0 { cores[cur]++; next }
    # The cluster keyword is SoC-specific (CPU_A78_0 on Orin, CPU_DENVER_0 on
    # Xavier), so match the family and keep the highest ceiling any cluster has.
    $1 ~ /^CPU_/ && $2 == "MAX_FREQ" {
      v = $3 + 0
      if (v == -1) cpu[cur] = -1
      else if (cpu[cur] != -1 && v > cpu[cur]) cpu[cur] = v
      next
    }
    END {
      # %.0f, not %d: awk clamps %d at INT32_MAX, and an EMC ceiling of
      # 3199000000 is past it - it came out as 2147483647, which made two
      # genuinely different modes compare equal and reported 25W as "2147 MHz".
      for (i = 1; i <= n; i++) {
        k = order[i]
        printf "%s|%s|%.0f|%.0f|%d|%.0f\n", k, nm[k], emc[k], gpu[k], cores[k], cpu[k]
      }
      if (def != "") printf "DEFAULT|%s||||\n", def
    }
  ' "$1" 2>/dev/null
}

# _power_gt A B - rc=0 when frequency A is higher than B, with -1 meaning
# "uncapped" and therefore higher than any number.
_power_gt() {
  local a="$1" b="$2"
  (( a == b )) && return 1
  (( a == -1 )) && return 0
  (( b == -1 )) && return 1
  (( a > b ))
}

# _power_faster A B - rc=0 when mode A is faster than mode B for inference.
# Compared field by field in the order that decides throughput; equal on all
# four means neither is faster, and the earlier id wins by the caller's fold.
_power_faster() {
  local a="$1" b="$2"
  local av bv
  local f
  for f in EMC GPU CORES CPU; do
    case "$f" in
      EMC)   av="${POWER_EMC[$a]:-0}";   bv="${POWER_EMC[$b]:-0}" ;;
      GPU)   av="${POWER_GPU[$a]:-0}";   bv="${POWER_GPU[$b]:-0}" ;;
      CORES) av="${POWER_CORES[$a]:-0}"; bv="${POWER_CORES[$b]:-0}" ;;
      CPU)   av="${POWER_CPU[$a]:-0}";   bv="${POWER_CPU[$b]:-0}" ;;
    esac
    if _power_gt "$av" "$bv"; then return 0; fi
    if _power_gt "$bv" "$av"; then return 1; fi
  done
  return 1
}

# power_mhz VALUE - a clock ceiling as text. An uncapped value is reported as
# "uncapped" rather than converted, because inventing a number for it would put
# a figure in a report that nothing measured.
power_mhz() {
  local v="${1:-0}"
  if (( v == -1 )); then printf 'uncapped'
  elif (( v == 0 )); then printf 'unspecified'
  else printf '%d MHz' $(( v / 1000000 ))
  fi
}

# power_describe ID - "MAXN_SUPER (id 2): EMC uncapped, GPU uncapped, 6 cores"
power_describe() {
  local id="$1"
  [[ -n "${POWER_NAME[$id]+x}" ]] || { printf 'mode %s' "$id"; return; }
  printf '%s (id %s): EMC %s, GPU %s, %s core(s)' \
    "${POWER_NAME[$id]}" "$id" \
    "$(power_mhz "${POWER_EMC[$id]}")" "$(power_mhz "${POWER_GPU[$id]}")" \
    "${POWER_CORES[$id]}"
}

# power_gain_line - one line naming what the fastest mode changes, only ever
# from values that were read. Where both modes state a real EMC ceiling the
# ratio is printed, because on a Jetson that ratio is roughly what generation
# throughput does; where the faster mode is uncapped there is no honest number
# to give, so it says so instead of guessing.
power_gain_line() {
  local a="$POWER_ACTIVE_ID" b="$POWER_BEST_ID"
  local ae="${POWER_EMC[$a]:-0}" be="${POWER_EMC[$b]:-0}"
  local ag="${POWER_GPU[$a]:-0}" bg="${POWER_GPU[$b]:-0}"
  if (( be == -1 )); then
    printf 'it removes the caps this mode applies (EMC %s, GPU %s)' \
      "$(power_mhz "$ae")" "$(power_mhz "$ag")"
  elif (( ae > 0 && be > ae )); then
    printf 'EMC %s -> %s (%d%% more memory bandwidth, which is what generation speed follows), GPU %s -> %s' \
      "$(power_mhz "$ae")" "$(power_mhz "$be")" $(( (be - ae) * 100 / ae )) \
      "$(power_mhz "$ag")" "$(power_mhz "$bg")"
  else
    printf 'EMC %s, GPU %s against this mode'\''s %s / %s' \
      "$(power_mhz "$be")" "$(power_mhz "$bg")" \
      "$(power_mhz "$ae")" "$(power_mhz "$ag")"
  fi
}

# power_advice_lines - what to tell a user whose board is not in its fastest
# mode, one line per call, shared so validate.sh and benchmark.sh say the same
# thing. Prints nothing in any other state.
power_advice_lines() {
  [[ "$POWER_STATE" == "below" ]] || return 0
  printf '%s is faster: %s\n' "$POWER_BEST_NAME" "$(power_gain_line)"
  printf 'switch with: sudo nvpmodel -m %s   (persists across reboots)\n' "$POWER_BEST_ID"
}
