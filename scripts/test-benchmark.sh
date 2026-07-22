#!/usr/bin/env bash
# test-benchmark.sh - Hermetic tests for benchmark.sh.
#
# benchmark.sh is the only thing in this repo that produces a number a user will
# act on, so the failure mode that matters is not "it crashed" but "it printed
# something plausible that was not a measurement". Every one of those paths is
# reachable in the field - a server that 500s under memory pressure, a proxy
# that strips llama.cpp's per-request `timings` block, a typo'd repetition
# count, a results path that is not writable - and none of them can be provoked
# on a healthy Jetson, which is exactly why they went unnoticed.
#
# These tests drive the real script against a stub OpenAI-compatible server
# (BENCH_BASE / --base) that can be told to misbehave on demand, so they need no
# GPU, no model, no Docker and no network.
#
# Usage:
#   ./scripts/test-benchmark.sh          # run all cases
#   ./scripts/test-benchmark.sh -v       # also print each assertion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_TARGET="$SCRIPT_DIR/benchmark.sh"
# Set once the fixture project exists; the real script is run from a copy so the
# reported configuration comes from a known .env rather than the host's.
TARGET="$REAL_TARGET"

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
STUB_PID=""
stop_stub() { [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null; STUB_PID=""; }
trap 'stop_stub; rm -rf "$TMPROOT"' EXIT INT TERM

# ── Stub server ───────────────────────────────────────────────────
# Speaks just enough of the llama.cpp HTTP API for benchmark.sh: /health,
# /v1/models and /v1/chat/completions. It binds port 0 and writes back the port
# it actually got, so parallel runs and a busy machine cannot collide. Every
# request body is appended to a log the tests assert against.
cat >"$TMPROOT/stub.py" <<'PYEOF'
import json, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE, PORTFILE, LOGFILE = sys.argv[1], sys.argv[2], sys.argv[3]
COUNT = threading.Lock()
state = {"n": 0}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        elif self.path == "/v1/models":
            self._send(200, {"models": [{"name": "/models/stub-Q4_K_M.gguf"}]})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n) or b"{}"
        req = json.loads(raw)
        with COUNT:
            state["n"] += 1
            seq = state["n"]
        with open(LOGFILE, "a") as f:
            f.write(json.dumps({"seq": seq, "path": self.path, "body": req}) + "\n")

        gen = int(req.get("max_tokens", 16))
        words = len(req["messages"][-1]["content"].split())

        if MODE == "http500":
            self._send(500, {"error": "stub: out of memory"})
            return
        # Fail the warm-up and the first two repetitions of the first case, so
        # that case still yields a sample but only one of the three asked for.
        if MODE == "flaky" and seq <= 3:
            self._send(503, {"error": "stub: warming up"})
            return
        # Only the largest prompt fails, as a context-overflow would.
        if MODE == "bigfail" and words > 400:
            self._send(400, {"error": "stub: prompt exceeds context"})
            return

        # A board that slows down as it heats up: every request is a little
        # worse than the last. The medians alone cannot tell this apart from a
        # steady machine, which is what the spread and the steady-state
        # re-measurement exist to expose.
        rate = gen / 0.5
        if MODE == "throttle":
            rate = max(2.0, 30.0 - 2.0 * seq)

        timings = {
            "prompt_n": words, "prompt_ms": 100.0,
            "prompt_per_second": words / 0.1,
            "predicted_n": gen, "predicted_ms": 500.0,
            "predicted_per_second": rate,
        }
        if MODE == "notimings":
            timings = None
        elif MODE == "zerorates":
            timings = {"prompt_n": words, "prompt_ms": 0.0, "prompt_per_second": 0.0,
                       "predicted_n": 0, "predicted_ms": 0.0, "predicted_per_second": 0.0}

        body = {"choices": [{"message": {"role": "assistant", "content": "stub"},
                             "finish_reason": "length"}]}
        if timings is not None:
            body["timings"] = timings
        self._send(200, body)


srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

STUB_LOG="$TMPROOT/requests.jsonl"
BASE=""

# ── Fixture project ───────────────────────────────────────────────
# benchmark.sh cd's to its own project directory and reports the .env it finds
# there as the configuration a measurement was taken under, so running it in
# place makes the assertions depend on whatever the host happens to be
# configured for. A copy with a known .env fixes that and lets the KV-cache and
# context values actually be checked.
PROJ="$TMPROOT/project"
mkdir -p "$PROJ/scripts"
cp "$SCRIPT_DIR"/benchmark.sh "$SCRIPT_DIR"/detect-platform.sh "$PROJ/scripts/"
cp -r "$SCRIPT_DIR/lib" "$PROJ/scripts/lib"
cat >"$PROJ/.env" <<'ENVEOF'
MODEL_FILE=fixture-Q4_K_M.gguf
CTX_SIZE=4096
PARALLEL=2
# K and V are separate knobs; the results file used to record only K, so two
# runs with different V cache types compared as if they were configured alike.
CACHE_TYPE_K=q8_0
CACHE_TYPE_V=f16
ENVEOF
TARGET="$PROJ/scripts/benchmark.sh"

# A stub nvpmodel, so the power-mode line is exercised on any host. The real one
# prints the mode name on a "NV Power Mode" line followed by the mode number.
cat >"$TMPROOT/nvpmodel" <<'NVEOF'
#!/usr/bin/env bash
printf 'NV Power Mode: 25W\n1\n'
NVEOF
chmod +x "$TMPROOT/nvpmodel"

# Synthetic thermal trees. BENCH_SYSROOT redirects the sysfs probe, so the
# thermal report and the throttle threshold can be tested on any machine -
# including the hot-board case a healthy Jetson will not reproduce on demand.
# millidegrees are what the kernel exposes.
make_thermal() {  # make_thermal <dir> <cpu_mC> <gpu_mC>
  local d="$1/sys/devices/virtual/thermal"
  mkdir -p "$d"/thermal_zone{0,1,2,3}
  printf 'cpu-thermal' >"$d/thermal_zone0/type"; printf '%s\n' "$2" >"$d/thermal_zone0/temp"
  printf 'gpu-thermal' >"$d/thermal_zone1/type"; printf '%s\n' "$3" >"$d/thermal_zone1/temp"
  # An Orin's cv*-thermal zones are readable by permission but answer EAGAIN.
  # Both shapes that produces are modelled: a zone with no temp file at all, and
  # one whose temp reads as nothing. The second is the dangerous one - it used
  # to reach $(( ... / 1000 )) as an empty string.
  printf 'cv0-thermal' >"$d/thermal_zone2/type"
  printf 'cv1-thermal' >"$d/thermal_zone3/type"; : >"$d/thermal_zone3/temp"
  printf '70000\n' >"$d/thermal_zone0/trip_point_0_temp"
  printf 'passive\n' >"$d/thermal_zone0/trip_point_0_type"
  printf '99000\n' >"$d/thermal_zone0/trip_point_1_temp"
  printf 'critical\n' >"$d/thermal_zone0/trip_point_1_type"
}
make_thermal "$TMPROOT/cool" 48000 47000
make_thermal "$TMPROOT/hot"  84000 81000

# This host's PATH with exactly one binary removed. Anything narrower would
# change more than the one thing under test, and on a Jetson - where tegrastats
# is always installed - there is no other way to reach the code path that a
# machine without it takes.
NOTEGRA_BIN="$TMPROOT/bin-no-tegrastats"
mkdir -p "$NOTEGRA_BIN"
while IFS= read -r -d ':' d || [[ -n "$d" ]]; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    [[ "$n" == "tegrastats" || -e "$NOTEGRA_BIN/$n" ]] && continue
    ln -s "$f" "$NOTEGRA_BIN/$n" 2>/dev/null
  done
done <<<"$PATH"
NOTEGRA_PATH="$NOTEGRA_BIN"

# start_stub <mode>
start_stub() {
  stop_stub
  rm -f "$TMPROOT/port" "$STUB_LOG"
  python3 "$TMPROOT/stub.py" "$1" "$TMPROOT/port" "$STUB_LOG" >"$TMPROOT/stub.err" 2>&1 &
  STUB_PID=$!
  local i
  for i in $(seq 1 100); do
    [[ -s "$TMPROOT/port" ]] && break
    sleep 0.1
  done
  if [[ ! -s "$TMPROOT/port" ]]; then
    echo "stub server failed to start: $(cat "$TMPROOT/stub.err" 2>/dev/null)" >&2
    exit 1
  fi
  BASE="http://127.0.0.1:$(cat "$TMPROOT/port")"
}

# Hermetic defaults: no thermal tree and no nvpmodel unless a case supplies one
# with a `BENCH_SYSROOT=... run_bench ...` prefix. Without this the assertions
# would depend on how warm the machine running the tests happens to be.
mkdir -p "$TMPROOT/nosysfs"
export BENCH_SYSROOT="$TMPROOT/nosysfs"
export BENCH_NVPMODEL="/nonexistent"

# run_bench <args...> - captures output in $OUT and status in $RC.
OUT=""; RC=0
run_bench() {
  OUT="$(bash "$TARGET" "$@" 2>&1)"
  RC=$?
  return 0
}

# Requests logged so far, warm-up included.
req_count() { [[ -f "$STUB_LOG" ]] && wc -l <"$STUB_LOG" || echo 0; }

expect_rc() {
  if [[ "$RC" == "$1" ]]; then pass "exit status $1${2:+ ($2)}"
  else fail "exit status${2:+ ($2)}" "expected $1, got $RC; output: $(tr '\n' '|' <<<"$OUT" | cut -c1-200)"; fi
}
expect_out() {
  if grep -qE "$1" <<<"$OUT"; then pass "output matches /$1/"
  else fail "output does not match /$1/" "$(tr '\n' '|' <<<"$OUT" | cut -c1-200)"; fi
}
expect_not_out() {
  if grep -qE "$1" <<<"$OUT"; then fail "output unexpectedly matches /$1/" "$(tr '\n' '|' <<<"$OUT" | cut -c1-200)"
  else pass "output does not match /$1/"; fi
}

# ══════════════════════════════════════════════════════════════════
printf '%s╔══════════════════════════════════════════════════╗%s\n' "$C_HD" "$C_Z"
printf '%s║   benchmark.sh - self-test                       ║%s\n' "$C_HD" "$C_Z"
printf '%s╚══════════════════════════════════════════════════╝%s\n' "$C_HD" "$C_Z"

# ── A healthy server ──────────────────────────────────────────────
case_start "healthy server produces a full sweep"
start_stub ok
run_bench --base "$BASE" -r 2 -n 8
expect_rc 0 "all cases measured"
expect_out '^16w '
expect_out '^128w '
expect_out '^512w '
expect_not_out 'failed'
expect_not_out 'produced no measurement'

# Every rate on the table must be a real number, not the 0.0 a missing timings
# block used to render as.
bad_rate=0
while read -r _ _ pp tg _; do
  [[ "$pp" =~ ^[0-9.]+$ && "$tg" =~ ^[0-9.]+$ ]] || { bad_rate=1; continue; }
  awk -v a="$pp" -v b="$tg" 'BEGIN{exit !(a>0 && b>0)}' || bad_rate=1
done < <(grep -E '^[0-9]+w ' <<<"$OUT")
if (( bad_rate == 0 )); then pass "every reported rate is positive"
else fail "a reported rate was zero or non-numeric" "$(grep -E '^[0-9]+w ' <<<"$OUT")"; fi

# Prompt token counts must track prompt size, otherwise the sweep is measuring
# the same request three times.
n16="$(awk '/^16w /{print $2}' <<<"$OUT")"
n512="$(awk '/^512w /{print $2}' <<<"$OUT")"
if [[ -n "$n16" && -n "$n512" ]] && (( n512 > n16 )); then
  pass "prompt token count grows with prompt size ($n16 -> $n512)"
else
  fail "prompt sizes do not increase" "16w=$n16 512w=$n512"
fi

# 3 cases x 2 reps + 1 warm-up + 1 steady-state re-measurement.
n_req="$(req_count)"
if (( n_req == 8 )); then pass "issued 8 requests (3 cases x 2 reps + warm-up + steady-state)"
else fail "unexpected request count" "expected 8, got $n_req"; fi

# Prompt caching must stay off or prompt-eval throughput is measured against a
# cache hit rather than against the model.
if python3 -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if rows and all(r['body'].get('cache_prompt') is False for r in rows) else 1)
" "$STUB_LOG"; then
  pass "every request sets cache_prompt=false"
else
  fail "a request did not disable prompt caching"
fi

# Sampling is what makes the median meaningful; -r must actually repeat.
if python3 -c "
import json,sys,collections
rows=[json.loads(l) for l in open(sys.argv[1])]
c=collections.Counter(len(r['body']['messages'][-1]['content'].split()) for r in rows)
# The warm-up and the steady-state re-measurement both reuse the 16-word
# prompt, so that bucket holds 2 reps + 2.
sys.exit(0 if sorted(c.values())==[2,2,4] else 1)
" "$STUB_LOG"; then
  pass "-r 2 sends two requests per case"
else
  fail "repetition count not honoured" "$(python3 -c "
import json,sys,collections
rows=[json.loads(l) for l in open(sys.argv[1])]
print(collections.Counter(len(r['body']['messages'][-1]['content'].split()) for r in rows))
" "$STUB_LOG")"
fi

# max_tokens must follow -n, otherwise the generation figure describes a
# different amount of work than the one reported.
if python3 -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if rows and all(r['body'].get('max_tokens')==8 for r in rows) else 1)
" "$STUB_LOG"; then
  pass "-n 8 is passed through as max_tokens"
else
  fail "generation length not honoured"
fi

# ── Run conditions ────────────────────────────────────────────────
# A throughput figure from a Jetson means nothing without the conditions it was
# taken under: the power mode caps clocks, the KV cache type changes both memory
# and bandwidth, and the context size changes what the numbers describe.
case_start "the conditions the run was taken under are reported"
start_stub ok
BENCH_NVPMODEL="$TMPROOT/nvpmodel" run_bench --base "$BASE" -r 2 -n 8
expect_rc 0 "conditions run"
expect_out 'Power mode : 25W'
expect_out 'Context    : 4096 tokens, KV cache q8_0/f16'
expect_out 'Slots      : 2'
expect_out 'Reps       : 2 per case, 8 tokens generated'

case_start "no nvpmodel means no power-mode line, not a failure"
start_stub ok
run_bench --base "$BASE" -r 1 -n 8
expect_rc 0 "run without nvpmodel"
expect_not_out 'Power mode'

# ── Steadiness ────────────────────────────────────────────────────
# The defect this replaces: the table showed one median per case, so a board
# that fell from 28 to 4 tok/s while the sweep ran produced a plausible-looking
# set of numbers that no one could tell apart from a healthy run.
case_start "a run that steadily degrades is reported, not averaged away"
start_stub throttle
run_bench --base "$BASE" -r 3 -n 8 --json "$TMPROOT/throttle.json"
expect_rc 0 "degradation is the board's property, not a stack failure"
expect_out 'These numbers are not comparable'
expect_out 'throughput fell [0-9.]+% between the start and the end of the run'
expect_out 'repetitions of .* varied by more than 20%'
expect_out 'Steady state: 16w re-measured at .* \(was .*, -[0-9.]+%\)'
if python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
ss=d['steady_state']
assert ss['label']=='16w', ss
assert ss['drop_pct'] > 15, ss
assert any('throughput fell' in w for w in d['warnings']), d['warnings']
first=d['results'][0]
assert first['tg_spread_pct'] > 0, first
assert first['tg_min'] < first['tg_max'], first
assert len(first['tg_samples'])==3, first
" "$TMPROOT/throttle.json" 2>"$TMPROOT/terr"; then
  pass "the results file records the spread, the samples and the degradation"
else
  fail "degradation not recorded" "$(cat "$TMPROOT/terr")"
fi

case_start "a steady run reports a zero spread and no warning"
start_stub ok
run_bench --base "$BASE" -r 3 -n 8
expect_rc 0 "steady run"
expect_out '^16w +[0-9]+ +[0-9.]+ +[0-9.]+ +0\.0% '
expect_not_out 'These numbers are not comparable'
expect_out 'Steady state: 16w re-measured at .* \(was .*, \+0\.0%\)'

case_start "a single repetition reports no spread rather than a fake one"
start_stub ok
run_bench --base "$BASE" -r 1 -n 8
expect_rc 0 "single-rep run"
expect_out '^16w +[0-9]+ +[0-9.]+ +[0-9.]+ +- '
expect_out 'Values are single measurements'
expect_not_out 'These numbers are not comparable'

# ── Thermals ──────────────────────────────────────────────────────
# Reading these used to be gated on tegrastats being on PATH, which contributes
# nothing to a sysfs read and removed the entire thermal report from any host
# that does not ship it.
case_start "thermal zones are read from sysfs, start and end"
start_stub ok
BENCH_SYSROOT="$TMPROOT/cool" run_bench --base "$BASE" -r 1 -n 8
expect_rc 0 "cool board"
expect_out 'Thermal cpu-thermal +48°C -> 48°C'
expect_out 'Thermal gpu-thermal +47°C -> 47°C'
# Zones with no readable temperature must be dropped, not rendered as 0°C or
# fed as an empty string into $(( ... / 1000 )).
expect_not_out 'cv0-thermal'
expect_not_out 'cv1-thermal'
expect_not_out 'division by 0|syntax error|unbound variable'
expect_not_out 'These numbers are not comparable'

# The thermal read used to be gated on tegrastats being on PATH, which
# contributes nothing to a sysfs read. The gate is invisible on a Jetson, where
# tegrastats is always present - so the case has to be run on a copy of this
# host's PATH with exactly that one binary missing.
case_start "thermals do not depend on tegrastats being installed"
start_stub ok
BENCH_SYSROOT="$TMPROOT/cool" PATH="$NOTEGRA_PATH" run_bench --base "$BASE" -r 1 -n 8
expect_rc 0 "host without tegrastats"
expect_out 'Thermal cpu-thermal +48°C'
expect_out 'Thermal gpu-thermal +47°C'

case_start "a board already at the passive trip point is called out"
start_stub ok
BENCH_SYSROOT="$TMPROOT/hot" run_bench --base "$BASE" -r 1 -n 8 --json "$TMPROOT/hot.json"
expect_rc 0 "hot board still measures"
expect_out 'the board reached 84°C, at or above the 70°C passive trip point'
if python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
t=d['thermal_c']
assert t['passive_trip']==70.0, t
assert t['start']['cpu-thermal']==84.0, t
assert 'cv0-thermal' not in t['end'], t
assert any('passive trip' in w for w in d['warnings']), d['warnings']
" "$TMPROOT/hot.json" 2>"$TMPROOT/herr"; then
  pass "the results file records the thermal readings and the trip point"
else
  fail "thermal state not recorded" "$(cat "$TMPROOT/herr")"
fi

case_start "a host with no thermal tree reports no thermals and no warning"
start_stub ok
run_bench --base "$BASE" -r 1 -n 8 --json "$TMPROOT/nothermal.json"
expect_rc 0 "host without sysfs thermal zones"
expect_not_out '^Thermal '
expect_not_out 'These numbers are not comparable'
if python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d['thermal_c']['start']=={} and d['thermal_c']['end']=={}, d['thermal_c']
assert d['thermal_c']['passive_trip'] is None, d['thermal_c']
assert d['warnings']==[], d['warnings']
assert d['power_mode'] is None, d['power_mode']
" "$TMPROOT/nothermal.json" 2>"$TMPROOT/nerr"; then
  pass "absent hardware is recorded as absent, not as zero"
else
  fail "absent thermal state mis-recorded" "$(cat "$TMPROOT/nerr")"
fi

# ── Machine-readable output ───────────────────────────────────────
case_start "--json writes a usable results file"
start_stub ok
run_bench --base "$BASE" -r 1 -n 8 --json "$TMPROOT/out.json"
expect_rc 0 "json run"
expect_out "Wrote $TMPROOT/out.json"
if [[ -s "$TMPROOT/out.json" ]]; then
  pass "results file is non-empty"
  if python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d['results'])==3, d['results']
assert d['model']=='/models/stub-Q4_K_M.gguf', d['model']
assert d['gen_tokens']==8, d['gen_tokens']
assert d['ctx_size']=='4096', d['ctx_size']
assert d['parallel']=='2', d['parallel']
# Recorded as a pair: only K used to be written, so a run with a q8_0 K cache
# and an f16 V cache compared as identical to one with both quantised.
assert d['kv_cache']=={'k': 'q8_0', 'v': 'f16'}, d['kv_cache']
assert d['reps']==1 and d['failed_reps']==0, d
for r in d['results']:
    assert r['tg_s']>0 and r['pp_s']>0, r
    assert r['reps']==1 and r['reps_requested']==1 and r['failed_reps']==0, r
    assert r['tg_samples']==[r['tg_s']], r
" "$TMPROOT/out.json" 2>"$TMPROOT/jsonerr"; then
    pass "results file has 3 measured cases with the run's parameters"
  else
    fail "results file contents are wrong" "$(cat "$TMPROOT/jsonerr")"
  fi
else
  fail "results file was not written"
fi

case_start "--json refuses an unwritable path before measuring"
start_stub ok
run_bench --base "$BASE" -r 1 -n 8 --json "$TMPROOT/no/such/dir/out.json"
expect_rc 2 "unwritable results path"
expect_out 'Cannot write results'
expect_not_out 'No such file or directory'
# Failing fast matters: the old behaviour ran the whole sweep and then lost it.
if (( $(req_count) == 0 )); then pass "no measurement was taken before failing"
else fail "sweep ran before the write check" "$(req_count) requests issued"; fi

# ── Servers that answer but do not measure ────────────────────────
case_start "server returning HTTP 500 fails the run"
start_stub http500
run_bench --base "$BASE" -r 1 -n 8
expect_rc 1 "all cases failed"
expect_out '3 of 3 case\(s\) produced no measurement'
expect_out 'HTTP 500'
expect_out 'out of memory'

case_start "response without a timings block fails the run"
start_stub notimings
run_bench --base "$BASE" -r 1 -n 8
expect_rc 1 "no timings"
expect_out '3 of 3 case\(s\) produced no measurement'
expect_out 'no timings block'
expect_not_out '  0\.0 '

case_start "response with zeroed rates fails the run"
start_stub zerorates
run_bench --base "$BASE" -r 1 -n 8
expect_rc 1 "zero rates"
expect_out 'produced no measurement'

case_start "a single failing case fails the run and is named"
start_stub bigfail
run_bench --base "$BASE" -r 1 -n 8
expect_rc 1 "one case failed"
expect_out '1 of 3 case\(s\) produced no measurement: 512w'
expect_out '^16w +[0-9]+ '
expect_out 'exceeds context'

# A case that loses some of its repetitions used to print the surviving median
# under a footer claiming "medians over 3 repetitions" and exit 0. Six of nine
# requests could 500 with "out of memory" and the run still looked perfect.
case_start "intermittent failures are measured but reported as incomplete"
start_stub flaky
run_bench --base "$BASE" -r 3 -n 8
expect_rc 1 "the sweep was not completed as asked"
expect_out '^16w '
expect_not_out 'produced no measurement'
expect_out '2 of 9 requests failed'
expect_out '16w 1/3'
expect_out 'Last error: HTTP 503'

# ── Unreachable server ────────────────────────────────────────────
case_start "unreachable server is reported, not measured"
start_stub ok
dead="$BASE"
stop_stub
run_bench --base "$dead" -r 1 -n 8
expect_rc 1 "server down"
expect_out 'not reachable'
expect_out 'docker compose up -d'
expect_not_out 'tok/s'

# ── Argument handling ─────────────────────────────────────────────
case_start "invalid arguments are rejected before any work"
start_stub ok
for bad_args in "-r abc" "-r 0" "-r -1" "-n abc" "-n 0"; do
  # shellcheck disable=SC2086  # deliberate word splitting of the test case
  run_bench --base "$BASE" $bad_args
  if [[ "$RC" == 2 ]] && grep -q 'positive integer' <<<"$OUT"; then
    pass "'$bad_args' rejected with exit 2"
  else
    fail "'$bad_args' not rejected" "rc=$RC out=$(tr '\n' '|' <<<"$OUT" | cut -c1-120)"
  fi
done

for opt in -r -n --json --base; do
  run_bench "$opt"
  if [[ "$RC" == 2 ]] && grep -q 'requires a value' <<<"$OUT"; then
    pass "'$opt' with no value rejected with exit 2"
  else
    fail "'$opt' with no value not rejected" "rc=$RC out=$(tr '\n' '|' <<<"$OUT" | cut -c1-120)"
  fi
done

run_bench --nonsense
expect_rc 2 "unknown option"
expect_out 'Unknown option'

if (( $(req_count) == 0 )); then pass "no requests issued while rejecting arguments"
else fail "argument errors reached the server" "$(req_count) requests"; fi

case_start "--help works without a server"
stop_stub
run_bench --help
expect_rc 0 "help"
expect_out 'Usage:'
expect_out '\-\-json'
expect_out '\-\-base'

# ── Base URL handling ─────────────────────────────────────────────
case_start "base URL comes from --base or BENCH_BASE"
start_stub ok
run_bench --base "$BASE/" -r 1 -n 8
expect_rc 0 "trailing slash is tolerated"
expect_not_out '//v1'

start_stub ok
OUT="$(BENCH_BASE="$BASE" bash "$TARGET" -r 1 -n 8 2>&1)"; RC=$?
expect_rc 0 "BENCH_BASE environment override"
expect_out '^16w '

# ══════════════════════════════════════════════════════════════════
stop_stub
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
