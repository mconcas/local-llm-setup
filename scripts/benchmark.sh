#!/usr/bin/env bash
# benchmark.sh - Measure throughput of the running llama.cpp server.
#
# Drives the deployed HTTP endpoint rather than llama-bench, so the numbers
# describe the stack as a client actually experiences it (server, batching and
# chat template included) instead of a synthetic kernel loop.
#
# Two figures matter:
#   prompt eval (pp)   tokens/s ingesting the prompt   - compute bound
#   generation (tg)    tokens/s producing new tokens   - memory-bandwidth bound
#
# On Jetson tg is usually the limiting factor: the iGPU shares LPDDR with the
# CPU, so effective bandwidth is far below a discrete card's.
#
# A Jetson is passively cooled and power-capped, so a number is only meaningful
# together with the conditions it was taken under. This script therefore reports
# the spread across repetitions, re-measures the first case after the sweep to
# see whether the board slowed down while it ran, and records the power mode and
# the thermal rise alongside the results.
#
# Exit status is 0 only if every case produced a real measurement and every
# requested repetition succeeded, so this is usable as a gate rather than
# something a human has to eyeball. A run that throttled is reported loudly but
# still exits 0: that is a property of the board, not a fault in the stack.
#
# Usage:
#   ./scripts/benchmark.sh                 # default sweep
#   ./scripts/benchmark.sh -r 5            # 5 repetitions per case
#   ./scripts/benchmark.sh -n 256          # generate 256 tokens per case
#   ./scripts/benchmark.sh --json out.json # also write machine-readable results
#   ./scripts/benchmark.sh --base http://jetson.local:8080   # another host (-b)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

REPS=3
GEN_TOKENS=128
JSON_OUT=""
PROMPT_WORDS=(16 128 512)
# Overridable so the same script can measure a remote Jetson from a workstation,
# and so the self-test can point it at a stub server.
BASE="${BENCH_BASE:-http://127.0.0.1:8080}"

# A missing option value used to surface as a raw "$2: unbound variable" from
# bash; take the argument only when there is one.
need_val() {
  [[ $# -ge 2 && -n "$2" ]] || { echo "Option $1 requires a value." >&2; exit 2; }
}
# seq(1) accepts anything and then produces nothing, which turned a typo'd
# repetition count into a full sweep of silently "failed" cases.
need_pos() {
  [[ "$2" =~ ^[0-9]+$ ]] && (( 10#$2 > 0 )) || {
    echo "Option $1 needs a positive integer (got: $2)." >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--reps)   need_val "$@"; need_pos "$1" "$2"; REPS="$2"; shift 2 ;;
    -n|--tokens) need_val "$@"; need_pos "$1" "$2"; GEN_TOKENS="$2"; shift 2 ;;
    --json)      need_val "$@"; JSON_OUT="$2"; shift 2 ;;
    -b|--base)   need_val "$@"; BASE="${2%/}"; shift 2 ;;
    # Print the header comment up to the first line of code, rather than a
    # hardcoded line range that silently drifts as the header is edited.
    -h|--help)   awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
done

# .env is compose syntax, not shell - see lib/env.sh. The results table prints
# CTX_SIZE and CACHE_TYPE_*, so a value mangled here is reported as the
# configuration a measurement was taken under.
ENV_FILE="$PROJECT_DIR/.env"
. "$SCRIPT_DIR/lib/env.sh"
env_load

eval "$(bash "$SCRIPT_DIR/detect-platform.sh" --env 2>/dev/null)" || true

if ! curl -sf --max-time 10 "$BASE/health" >/dev/null 2>&1; then
  echo "The llama.cpp server is not reachable at $BASE."
  echo "Start it first:  docker compose up -d"
  exit 1
fi

# The destination has to be writable before the sweep, not after it: a failed
# redirect at the end used to print "Wrote <path>" over a shell error and still
# exit 0, throwing away several minutes of measurements.
if [[ -n "$JSON_OUT" ]]; then
  # The subshell keeps bash's own redirect error off the terminal; the message
  # below is the one the user should see.
  if ! ( : >"$JSON_OUT" ) 2>/dev/null; then
    echo "Cannot write results to $JSON_OUT." >&2
    exit 2
  fi
fi

MODEL="$(curl -sf "$BASE/v1/models" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['models'][0]['name'])" 2>/dev/null)"

echo "╔══════════════════════════════════════════════════╗"
echo "║   llama.cpp Local Server - Benchmark             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Platform   : ${PLATFORM_LABEL:-unknown} (${PLATFORM_ARCH:-?})"
[[ -n "${L4T_VERSION:-}" ]] && echo "JetPack    : R$L4T_VERSION"
echo "Model      : ${MODEL:-unknown}"
echo "Context    : ${CTX_SIZE:-?} tokens, KV cache ${CACHE_TYPE_K:-f16}/${CACHE_TYPE_V:-f16}"
echo "Slots      : ${PARALLEL:-?}"

# The Jetson's power mode caps clocks and is the single biggest lever on these
# numbers, so record it alongside the results - a 15W figure is not comparable
# to a 25W/MAXN one.
#
# Reporting the mode alone was still half the story, and it is the same shape as
# every other defect this script has had: a run at 15W on a board that offers
# MAXN_SUPER is a measurement of less than the hardware can do, and the old
# header could not distinguish it from the board's best. lib/power.sh reads the
# catalogue too, so the run states which mode it took and whether that was the
# fastest one available.
POWER_NVPMODEL="${BENCH_NVPMODEL:-nvpmodel}"
# shellcheck source=lib/power.sh
. "$SCRIPT_DIR/lib/power.sh"
power_probe "${BENCH_SYSROOT:-}"
POWER_MODE="$POWER_ACTIVE_NAME"
if [[ -n "$POWER_MODE" ]]; then
  case "$POWER_STATE" in
    best)  echo "Power mode : $POWER_MODE (the fastest this board offers)" ;;
    below) echo "Power mode : $POWER_MODE (not the fastest - $POWER_BEST_NAME is available)" ;;
    *)     echo "Power mode : $POWER_MODE" ;;
  esac
fi
echo "Reps       : $REPS per case, $GEN_TOKENS tokens generated"
echo ""

# ── Thermals ──────────────────────────────────────────────────────
# Read straight from sysfs. The previous version required tegrastats on PATH,
# which contributes nothing here and silently removed the whole thermal report
# from any host that does not ship it. BENCH_SYSROOT redirects the tree so the
# self-test can present synthetic zones on any machine.
SYSROOT="${BENCH_SYSROOT:-}"
THERMAL_DIR="$SYSROOT/sys/devices/virtual/thermal"

# Prints "<zone type> <millidegrees>" per zone that actually reads. An Orin's
# cv*-thermal zones exist and are readable by permission but answer EAGAIN, so a
# zone has to be probed rather than assumed - `cat` of one used to feed an empty
# string into $(( ... / 1000 )).
read_thermals() {
  local z t v
  for z in "$THERMAL_DIR"/thermal_zone*/; do
    [[ -r "$z/type" && -r "$z/temp" ]] || continue
    t="$(cat "$z/type" 2>/dev/null)" || continue
    v="$(cat "$z/temp" 2>/dev/null)" || continue
    [[ "$t" =~ ^[A-Za-z0-9._-]+$ && "$v" =~ ^-?[0-9]+$ ]] || continue
    printf '%s %s\n' "$t" "$v"
  done
}

# The lowest "passive" trip point across all zones: the temperature at which the
# kernel starts pulling clocks back. On an Orin Nano that is 70°C, well below
# the 99°C most people watch for, which is why a run can throttle while every
# reading still looks healthy.
passive_trip() {
  local best="" z tp ty v
  for z in "$THERMAL_DIR"/thermal_zone*/; do
    for tp in "$z"trip_point_*_temp; do
      [[ -r "$tp" ]] || continue
      ty="$(cat "${tp%_temp}_type" 2>/dev/null)" || continue
      [[ "$ty" == "passive" ]] || continue
      v="$(cat "$tp" 2>/dev/null)" || continue
      [[ "$v" =~ ^[0-9]+$ ]] || continue
      if [[ -z "$best" ]] || (( v < best )); then best="$v"; fi
    done
  done
  printf '%s' "$best"
}

THERMAL_START="$(read_thermals)"
PASSIVE_TRIP="$(passive_trip)"

# Build a prompt of roughly N words. Varied words keep the tokenizer from
# collapsing the text into a handful of repeated tokens.
make_prompt() {
  python3 -c "
import sys
n = int(sys.argv[1])
words = ('alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo '
         'lima mike november oscar papa quebec romeo sierra tango uniform '
         'victor whiskey xray yankee zulu').split()
print('Summarise the following word list. ' + ' '.join(words[i % len(words)] for i in range(n)))
" "$1"
}

# One timed request. Prompt caching is disabled: with it on, a repeated prompt
# is served from the KV cache and prompt-eval throughput is reported against a
# handful of uncached tokens, which is not a measurement of anything.
#
# Always prints one JSON object. A failed request reports {"error": ...} rather
# than dying, so the caller can tell the user *why* a case produced no numbers
# instead of printing a bare "failed".
run_once() {
  local prompt="$1"
  python3 - "$BASE" "$GEN_TOKENS" <<'PY' "$prompt"
import json, sys, time, urllib.error, urllib.request
base, gen = sys.argv[1], int(sys.argv[2])
prompt = sys.argv[3]
body = json.dumps({
    "model": "any", "temperature": 0, "max_tokens": gen,
    "cache_prompt": False,
    "messages": [{"role": "user", "content": prompt}],
}).encode()
req = urllib.request.Request(base + "/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json"})
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
except urllib.error.HTTPError as e:
    detail = (e.read(200) or b"").decode("utf-8", "replace").replace("\n", " ").strip()
    print(json.dumps({"error": "HTTP %d %s" % (e.code, detail)})); raise SystemExit
except Exception as e:
    print(json.dumps({"error": "%s: %s" % (type(e).__name__, e)})); raise SystemExit
wall = time.time() - t0

# llama.cpp reports per-request timings; a proxy or a build that strips them
# leaves every rate at 0.0, which must not read as a measurement of zero.
t = d.get("timings") or {}
if not t.get("predicted_per_second"):
    print(json.dumps({"error": "response carried no timings block "
                               "(is something proxying /v1/chat/completions?)"}))
    raise SystemExit
print(json.dumps({
    "prompt_n":  t.get("prompt_n", 0),
    "pp_s":      t.get("prompt_per_second", 0.0),
    "gen_n":     t.get("predicted_n", 0),
    "tg_s":      t.get("predicted_per_second", 0.0),
    "ttft_ms":   t.get("prompt_ms", 0.0),
    "wall_s":    wall,
}))
PY
}

# Extract .error from a run_once result, empty if it succeeded.
err_of() { python3 -c "
import json,sys
try: print(json.loads(sys.argv[1]).get('error') or '')
except Exception: print('no response from the server')
" "$1"; }

echo "Warming up …"
run_once "$(make_prompt 16)" >/dev/null 2>&1

RESULTS_JSON="[]"
FAILED_CASES=()
PARTIAL_CASES=()
LOST_REPS=0
LAST_ERR=""
# The first case that produced a measurement, kept so the same prompt can be
# re-run after the sweep as a steady-state check.
FIRST_PROMPT=""; FIRST_LABEL=""; FIRST_TG=""
printf '%-12s %8s %12s %12s %8s %10s\n' \
  "prompt" "tokens" "pp tok/s" "tg tok/s" "spread" "TTFT ms"
printf '%s\n' "---------------------------------------------------------------------"

for w in "${PROMPT_WORDS[@]}"; do
  prompt="$(make_prompt "$w")"
  samples="[]"
  case_failed=0
  for _ in $(seq 1 "$REPS"); do
    out="$(run_once "$prompt" 2>/dev/null)"
    case_err="$(err_of "$out")"
    if [[ -n "$case_err" ]]; then
      LAST_ERR="$case_err"
      case_failed=$((case_failed + 1))
      continue
    fi
    samples="$(python3 -c "
import json,sys
s=json.loads(sys.argv[1]); s.append(json.loads(sys.argv[2])); print(json.dumps(s))
" "$samples" "$out")"
  done
  LOST_REPS=$((LOST_REPS + case_failed))

  # Spread is the point of repeating a case at all: on a passively-cooled board
  # a median alone cannot distinguish a steady 12 tok/s from a run that started
  # at 16 and ended at 8.
  line="$(python3 -c "
import json, sys, statistics as st
s = json.loads(sys.argv[1]); label = sys.argv[2]
want, failed = int(sys.argv[3]), int(sys.argv[4])
if not s:
    print('SKIP'); raise SystemExit
med = lambda k: st.median(x[k] for x in s)
tg  = sorted(x['tg_s'] for x in s)
m   = med('tg_s')
print(json.dumps({'label': label, 'prompt_tokens': int(med('prompt_n')),
                  'gen_tokens': int(med('gen_n')),
                  'pp_s': med('pp_s'), 'tg_s': m, 'ttft_ms': med('ttft_ms'),
                  'tg_min': tg[0], 'tg_max': tg[-1],
                  'tg_spread_pct': ((tg[-1] - tg[0]) / m * 100.0) if m else 0.0,
                  'tg_samples': tg,
                  'reps': len(s), 'reps_requested': want, 'failed_reps': failed}))
" "$samples" "${w}w" "$REPS" "$case_failed")"

  if [[ "$line" == "SKIP" || -z "$line" ]]; then
    printf '%-12s %8s %12s %12s %8s %10s\n' "${w}w" "-" "failed" "-" "-" "-"
    FAILED_CASES+=("${w}w")
    continue
  fi

  (( case_failed > 0 )) && PARTIAL_CASES+=("${w}w $((REPS - case_failed))/$REPS")

  python3 -c "
import json,sys
d = json.loads(sys.argv[1])
sp = ('%.1f%%' % d['tg_spread_pct']) if d['reps'] > 1 else '-'
print('%-12s %8d %12.1f %12.1f %8s %10.0f' % (d['label'], d['prompt_tokens'],
                                              d['pp_s'], d['tg_s'], sp, d['ttft_ms']))
" "$line"
  RESULTS_JSON="$(python3 -c "
import json,sys
a=json.loads(sys.argv[1]); a.append(json.loads(sys.argv[2])); print(json.dumps(a))
" "$RESULTS_JSON" "$line")"

  if [[ -z "$FIRST_LABEL" ]]; then
    FIRST_LABEL="${w}w"
    FIRST_PROMPT="$prompt"
    FIRST_TG="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['tg_s'])" "$line")"
  fi
done

echo ""
echo "pp = prompt eval (compute bound), tg = token generation (bandwidth bound)"
echo "spread = (max-min)/median of tg across the repetitions of one case"
if (( REPS == 1 )); then
  echo "Values are single measurements (-r 3 or more for a median and a spread)."
else
  echo "Values are medians over up to $REPS repetitions."
fi

# ── Steady state ──────────────────────────────────────────────────
# The sweep walks from a short prompt to a long one, so tg falling across the
# table is expected and says nothing about the board. Re-running the *first*
# case at the end compares like with like: any drop is the machine, not the
# workload. One extra request buys the difference between "this Jetson does 13
# tok/s" and "this Jetson did 13 tok/s until it got hot".
STEADY_TG=""; STEADY_DROP=""
if [[ -n "$FIRST_LABEL" ]]; then
  steady_out="$(run_once "$FIRST_PROMPT" 2>/dev/null)"
  if [[ -z "$(err_of "$steady_out")" ]]; then
    STEADY_TG="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['tg_s'])" "$steady_out")"
    # Positive means the board got slower while the sweep ran.
    STEADY_DROP="$(python3 -c "
import sys
a, b = float(sys.argv[1]), float(sys.argv[2])
print('%.1f' % (((a - b) / a * 100.0) if a else 0.0))
" "$FIRST_TG" "$STEADY_TG")"
    python3 -c "
import sys
label, now, before, drop = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
change = -drop or 0.0   # keeps a no-change run from printing '-0.0%'
print('Steady state: %s re-measured at %.1f tok/s after the sweep '
      '(was %.1f, %+.1f%%)' % (label, now, before, change))
" "$FIRST_LABEL" "$STEADY_TG" "$FIRST_TG" "$STEADY_DROP"
  else
    echo "Steady state: could not re-measure $FIRST_LABEL after the sweep."
  fi
fi

# ── Thermals ──────────────────────────────────────────────────────
# A long run on a passively-cooled board heats up, the kernel pulls clocks back
# at the first passive trip point, and the same command then reports lower
# numbers. Start and end readings make that visible instead of leaving a single
# end-of-run temperature to be interpreted.
THERMAL_END="$(read_thermals)"
THERMAL_PEAK=0
if [[ -n "$THERMAL_END" ]]; then
  echo ""
  while read -r zone end_mc; do
    [[ -n "$zone" ]] || continue
    start_mc="$(awk -v z="$zone" '$1 == z {print $2; exit}' <<<"$THERMAL_START")"
    (( end_mc > THERMAL_PEAK )) && THERMAL_PEAK="$end_mc"
    if [[ -n "$start_mc" ]]; then
      printf 'Thermal %-14s %s°C -> %s°C\n' "$zone" "$((start_mc / 1000))" "$((end_mc / 1000))"
    else
      printf 'Thermal %-14s %s°C\n' "$zone" "$((end_mc / 1000))"
    fi
  done <<<"$THERMAL_END"
fi

# ── Was this a run worth comparing? ───────────────────────────────
# Throttling is a property of the board, not a fault in the stack, so it is
# reported rather than failed - but it has to be reported, because a throttled
# run and a badly configured one produce the same disappointing number.
WARNINGS=()
if [[ -n "$STEADY_DROP" ]] && (( $(python3 -c "print(1 if float('$STEADY_DROP') >= 15 else 0)") )); then
  msg="throughput fell ${STEADY_DROP}% between the start and the end of the run"
  if [[ -n "$PASSIVE_TRIP" ]] && (( THERMAL_PEAK >= PASSIVE_TRIP )); then
    msg="$msg; the board reached $((THERMAL_PEAK / 1000))°C and clocks are pulled back from $((PASSIVE_TRIP / 1000))°C, so it is throttling"
  fi
  WARNINGS+=("$msg")
fi
if [[ -n "$PASSIVE_TRIP" ]] && (( THERMAL_PEAK >= PASSIVE_TRIP )) && [[ ${#WARNINGS[@]} -eq 0 ]]; then
  WARNINGS+=("the board reached $((THERMAL_PEAK / 1000))°C, at or above the $((PASSIVE_TRIP / 1000))°C passive trip point - a longer run may throttle")
fi
WIDE_SPREAD="$(python3 -c "
import json,sys
r = json.loads(sys.argv[1])
w = [x['label'] for x in r if x['reps'] > 1 and x['tg_spread_pct'] >= 20]
print(' '.join(w))
" "$RESULTS_JSON")"
if [[ -n "$WIDE_SPREAD" ]]; then
  WARNINGS+=("repetitions of $WIDE_SPREAD varied by more than 20%, so the medians are not a stable figure")
fi

if (( ${#WARNINGS[@]} > 0 )); then
  echo ""
  for msg in "${WARNINGS[@]}"; do
    echo "! These numbers are not comparable: $msg."
  done
  echo "  Let the board settle before comparing runs."
fi

# Separate from the warnings above, and deliberately so: those say the run is
# not a stable measurement, this says the run is a stable measurement of a board
# that was not allowed to go as fast as it can. Both can be true, and treating
# them as one message is how "check the power mode" stayed advice nobody could
# act on - it never said which mode, or what the alternative was.
if [[ "$POWER_STATE" == "below" ]]; then
  echo ""
  echo "! This is not the fastest this board can go: it ran in $POWER_ACTIVE_NAME."
  while IFS= read -r _line; do echo "  $_line"; done < <(power_advice_lines)
fi

if [[ -n "$JSON_OUT" ]]; then
  python3 -c "
import json, sys
def zones(text):
    out = {}
    for line in text.splitlines():
        p = line.split()
        if len(p) == 2:
            out[p[0]] = int(p[1]) / 1000.0
    return out
out = {
  'platform':     sys.argv[2],
  'arch':         sys.argv[3],
  'jetpack':      sys.argv[4] or None,
  'model':        sys.argv[5],
  'ctx_size':     sys.argv[6],
  'kv_cache':     {'k': sys.argv[7], 'v': sys.argv[8]},
  'parallel':     sys.argv[9],
  # The mode alone does not say whether it was the board's best, and comparing
  # two results files is exactly where that matters: 13.6 tok/s at 15W and
  # 13.6 tok/s at MAXN_SUPER are the same number about very different boards.
  'power_mode':   sys.argv[10] or None,
  'power_mode_id':   sys.argv[21] or None,
  'power_best_mode': sys.argv[22] or None,
  'power_is_best':   {'best': True, 'below': False}.get(sys.argv[23]),
  'gen_tokens':   int(sys.argv[11]),
  'reps':         int(sys.argv[12]),
  'failed_reps':  int(sys.argv[13]),
  'steady_state': {'label': sys.argv[14] or None,
                   'tg_s': float(sys.argv[15]) if sys.argv[15] else None,
                   'drop_pct': float(sys.argv[16]) if sys.argv[16] else None},
  'thermal_c':    {'start': zones(sys.argv[17]), 'end': zones(sys.argv[18]),
                   'passive_trip': (int(sys.argv[19]) / 1000.0) if sys.argv[19] else None},
  'warnings':     [w for w in sys.argv[20].split('\n') if w],
  'results':      json.loads(sys.argv[1]),
}
print(json.dumps(out, indent=2))
" "$RESULTS_JSON" "${PLATFORM_LABEL:-unknown}" "${PLATFORM_ARCH:-}" "${L4T_VERSION:-}" \
    "${MODEL:-}" "${CTX_SIZE:-}" "${CACHE_TYPE_K:-f16}" "${CACHE_TYPE_V:-f16}" \
    "${PARALLEL:-}" "$POWER_MODE" "$GEN_TOKENS" "$REPS" "$LOST_REPS" \
    "$FIRST_LABEL" "$STEADY_TG" "$STEADY_DROP" \
    "$THERMAL_START" "$THERMAL_END" "$PASSIVE_TRIP" \
    "$(printf '%s\n' "${WARNINGS[@]+"${WARNINGS[@]}"}")" \
    "$POWER_ACTIVE_ID" "$POWER_BEST_NAME" "$POWER_STATE" > "$JSON_OUT"
  echo ""
  if [[ -s "$JSON_OUT" ]]; then
    echo "Wrote $JSON_OUT"
  else
    echo "Failed to write $JSON_OUT" >&2
    exit 1
  fi
fi

# A benchmark that measured nothing must not look like a benchmark that measured
# well. Anything short of every case succeeding is a non-zero exit.
if (( ${#FAILED_CASES[@]} > 0 )); then
  echo ""
  echo "${#FAILED_CASES[@]} of ${#PROMPT_WORDS[@]} case(s) produced no measurement: ${FAILED_CASES[*]}"
  [[ -n "$LAST_ERR" ]] && echo "Last error: $LAST_ERR"
  exit 1
fi

# Nor must a run that quietly lost most of its repetitions: a median over one
# surviving sample was printed under a footer claiming a median over three, and
# the errors that ate the other two were never shown.
if (( LOST_REPS > 0 )); then
  echo ""
  echo "$LOST_REPS of $((REPS * ${#PROMPT_WORDS[@]})) requests failed, so some cases were measured fewer times than asked: ${PARTIAL_CASES[*]}"
  [[ -n "$LAST_ERR" ]] && echo "Last error: $LAST_ERR"
  exit 1
fi
exit 0
