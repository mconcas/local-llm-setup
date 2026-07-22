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
TARGET="$SCRIPT_DIR/benchmark.sh"

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
        # Fail every request until the warm-up plus the first two have gone by,
        # so a case still has samples left to take a median over.
        if MODE == "flaky" and seq <= 2:
            self._send(503, {"error": "stub: warming up"})
            return
        # Only the largest prompt fails, as a context-overflow would.
        if MODE == "bigfail" and words > 400:
            self._send(400, {"error": "stub: prompt exceeds context"})
            return

        timings = {
            "prompt_n": words, "prompt_ms": 100.0,
            "prompt_per_second": words / 0.1,
            "predicted_n": gen, "predicted_ms": 500.0,
            "predicted_per_second": gen / 0.5,
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

# 3 cases x 2 reps + 1 warm-up.
n_req="$(req_count)"
if (( n_req == 7 )); then pass "issued 7 requests (3 cases x 2 reps + warm-up)"
else fail "unexpected request count" "expected 7, got $n_req"; fi

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
# warm-up shares the 16-word prompt, so that bucket holds 3
sys.exit(0 if sorted(c.values())==[2,2,3] else 1)
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
for r in d['results']:
    assert r['tg_s']>0 and r['pp_s']>0, r
    assert r['reps']==1, r
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

case_start "intermittent failures still yield a measurement"
start_stub flaky
run_bench --base "$BASE" -r 3 -n 8
expect_rc 0 "surviving samples are enough"
expect_out '^16w '
expect_not_out 'produced no measurement'

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
