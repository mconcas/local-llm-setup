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
# Exit status is 0 only if every case produced a real measurement, so this is
# usable as a gate rather than something a human has to eyeball.
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

[[ -f .env ]] && set -a && . ./.env && set +a

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
POWER_MODE=""
if command -v nvpmodel &>/dev/null; then
  POWER_MODE="$(nvpmodel -q 2>/dev/null | grep -i 'power mode' | sed 's/.*: *//' | head -1)"
  [[ -n "$POWER_MODE" ]] && echo "Power mode : $POWER_MODE"
fi
echo "Reps       : $REPS per case, $GEN_TOKENS tokens generated"
echo ""

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
LAST_ERR=""
printf '%-12s %8s %12s %12s %10s\n' "prompt" "tokens" "pp tok/s" "tg tok/s" "TTFT ms"
printf '%s\n' "-------------------------------------------------------------"

for w in "${PROMPT_WORDS[@]}"; do
  prompt="$(make_prompt "$w")"
  samples="[]"
  for _ in $(seq 1 "$REPS"); do
    out="$(run_once "$prompt" 2>/dev/null)"
    case_err="$(err_of "$out")"
    if [[ -n "$case_err" ]]; then
      LAST_ERR="$case_err"
      continue
    fi
    samples="$(python3 -c "
import json,sys
s=json.loads(sys.argv[1]); s.append(json.loads(sys.argv[2])); print(json.dumps(s))
" "$samples" "$out")"
  done

  line="$(python3 -c "
import json, sys, statistics as st
s = json.loads(sys.argv[1]); label = sys.argv[2]
if not s:
    print('SKIP'); raise SystemExit
med = lambda k: st.median(x[k] for x in s)
n   = int(med('prompt_n'))
print(json.dumps({'label': label, 'prompt_tokens': n, 'gen_tokens': int(med('gen_n')),
                  'pp_s': med('pp_s'), 'tg_s': med('tg_s'), 'ttft_ms': med('ttft_ms'),
                  'reps': len(s)}))
" "$samples" "${w}w")"

  if [[ "$line" == "SKIP" || -z "$line" ]]; then
    printf '%-12s %8s %12s %12s %10s\n' "${w}w" "-" "failed" "-" "-"
    FAILED_CASES+=("${w}w")
    continue
  fi

  python3 -c "
import json,sys
d = json.loads(sys.argv[1])
print('%-12s %8d %12.1f %12.1f %10.0f' % (d['label'], d['prompt_tokens'],
                                          d['pp_s'], d['tg_s'], d['ttft_ms']))
" "$line"
  RESULTS_JSON="$(python3 -c "
import json,sys
a=json.loads(sys.argv[1]); a.append(json.loads(sys.argv[2])); print(json.dumps(a))
" "$RESULTS_JSON" "$line")"
done

echo ""
echo "pp = prompt eval (compute bound), tg = token generation (bandwidth bound)"
echo "Values are medians over $REPS repetitions."

# Thermals matter on a passively-cooled board: a long run can throttle and the
# same command will then report lower numbers.
if command -v tegrastats &>/dev/null && [[ -r /sys/devices/virtual/thermal/thermal_zone0/temp ]]; then
  for z in /sys/devices/virtual/thermal/thermal_zone*/; do
    [[ -r "$z/type" && -r "$z/temp" ]] || continue
    t="$(cat "$z/type")"
    [[ "$t" == *gpu* || "$t" == *cpu* || "$t" == *soc* ]] || continue
    printf 'Thermal %-10s %s°C\n' "$t" "$(( $(cat "$z/temp") / 1000 ))"
  done
fi

if [[ -n "$JSON_OUT" ]]; then
  python3 -c "
import json, sys
out = {
  'platform':   sys.argv[2],
  'arch':       sys.argv[3],
  'jetpack':    sys.argv[4] or None,
  'model':      sys.argv[5],
  'ctx_size':   sys.argv[6],
  'kv_cache':   sys.argv[7],
  'parallel':   sys.argv[8],
  'power_mode': sys.argv[9] or None,
  'gen_tokens': int(sys.argv[10]),
  'results':    json.loads(sys.argv[1]),
}
print(json.dumps(out, indent=2))
" "$RESULTS_JSON" "${PLATFORM_LABEL:-unknown}" "${PLATFORM_ARCH:-}" "${L4T_VERSION:-}" \
    "${MODEL:-}" "${CTX_SIZE:-}" "${CACHE_TYPE_K:-f16}" "${PARALLEL:-}" \
    "$POWER_MODE" "$GEN_TOKENS" > "$JSON_OUT"
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
exit 0
