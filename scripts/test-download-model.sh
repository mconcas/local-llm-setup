#!/usr/bin/env bash
# test-download-model.sh - Hermetic tests for download-model.sh.
#
# This is the one script in the repo that writes multi-gigabyte files, on the
# machine with the least disk to spare. Its failure modes are therefore not
# "it crashed" but "it left something on disk that looks like a model":
# an HTML login page named *.gguf, a transfer truncated after its first 4 KiB,
# or several GB in a directory the container never mounts. setup.sh then wires
# whatever it finds into .env, so the user's first sight of the problem is a
# crash-looping container reporting an unreadable model.
#
# None of those paths can be provoked against the real Hugging Face on a
# healthy machine, so the tests drive the real script against a stub HF
# endpoint (HF_ENDPOINT) that can 404, gate, lie about sizes, serve HTML or cut
# a transfer short on demand. No GPU, no Docker, no network, nothing larger
# than a few hundred KiB written.
#
# Usage:
#   ./scripts/test-download-model.sh          # run all cases
#   ./scripts/test-download-model.sh -v       # also print each assertion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/download-model.sh"

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

# ── Stub Hugging Face endpoint ────────────────────────────────────
# Answers /<repo>/resolve/main/<file> the way huggingface.co does: a HEAD gets
# a 302 carrying x-linked-size (the true LFS object size) and the final hop
# reports content-length. Binds port 0 and writes back the port it got, so
# parallel runs cannot collide, and logs every request so the tests can assert
# on what was *not* requested - the point of the idempotence and preflight
# cases is that no transfer happens at all.
cat >"$TMPROOT/stub.py" <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE, PORTFILE, LOGFILE = sys.argv[1], sys.argv[2], sys.argv[3]
# Optional: a real GGUF to serve as the body, and a size to advertise for it.
# The fit preflight reads the model's own metadata, so the cases that exercise
# it need a body with real geometry rather than the filler below - and a size
# claim of its own, because a model large enough to refuse is one this board
# has no business actually holding.
BODYFILE = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else ""
ADV_OVERRIDE = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else 0

# A small but structurally honest GGUF: the magic the script checks, then
# filler. Real weights are gigabytes; nothing here needs to be.
GGUF = b"GGUF" + b"\x03\x00\x00\x00" + bytes(64 * 1024 - 8)
HTML = b"<!DOCTYPE html><html><body>Sign in to access this repository</body></html>"

# How much the HEAD advertises versus what the GET actually delivers.
#   ok        - agree
#   shortget  - HEAD claims 4 KiB more than the body has (truncated upstream)
#   huge      - HEAD claims 1 PiB, so the free-space preflight must refuse
#   html      - a login page served with a correct content-length
#   cutoff    - content-length is honest, the connection dies halfway through
#   getfails  - the size probe succeeds and the transfer itself is refused
#   norange   - Range is ignored and the whole object is sent, which is what
#               turns a header probe into the download it meant to avoid
if BODYFILE:
    BODY = open(BODYFILE, "rb").read()
else:
    BODY = HTML if MODE == "html" else GGUF
ADVERTISED = ADV_OVERRIDE or {
    "shortget": len(BODY) + 4096,
    "huge": 1 << 50,
}.get(MODE, len(BODY))


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _log(self):
        with open(LOGFILE, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "range": self.headers.get("Range", "")}) + "\n")

    def _error(self, code, msg):
        b = msg.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _dispatch(self, head):
        self._log()
        if MODE == "notfound":
            self._error(404, "Entry not found")
            return
        if MODE == "gated":
            self._error(401, "Access to model is restricted")
            return
        # Order matters: the CDN path still contains "/resolve/", so testing
        # for that first redirects to itself forever.
        if not self.path.startswith("/cdn/"):
            if "/resolve/" not in self.path:
                self._error(404, "no such path")
                return
            # The redirect hop is where the real size lives.
            self.send_response(302)
            self.send_header("Location", "/cdn" + self.path)
            self.send_header("x-linked-size", str(ADVERTISED))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if MODE == "getfails" and not head:
            # A CDN that answers the probe and then refuses the object. curl
            # must not write this body to the destination.
            self._error(403, "Forbidden: request blocked")
            return
        # A ranged GET is how the fit preflight reads the metadata block
        # without pulling the weights. Serve it the way huggingface.co's CDN
        # does, unless this run is modelling an endpoint that does not.
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes=") and not head and MODE != "norange":
            first, _, last = rng[6:].partition("-")
            lo = int(first)
            hi = min(int(last), len(BODY) - 1) if last else len(BODY) - 1
            chunk = BODY[lo:hi + 1]
            self.send_response(206)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Range",
                             "bytes %d-%d/%d" % (lo, lo + len(chunk) - 1, ADVERTISED))
            self.send_header("Content-Length", str(len(chunk)))
            self.end_headers()
            self.wfile.write(chunk)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(ADVERTISED if head else len(BODY)))
        self.end_headers()
        if head:
            return
        if MODE == "cutoff":
            # Promise the whole body, deliver half, hang up: exactly what a
            # dropped Wi-Fi link looks like to curl.
            self.wfile.write(BODY[: len(BODY) // 2])
            self.close_connection = True
            return
        self.wfile.write(BODY)

    def do_HEAD(self):
        self._dispatch(True)

    def do_GET(self):
        self._dispatch(False)


srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

STUB_LOG="$TMPROOT/requests.jsonl"
ENDPOINT=""

# start_stub <mode> [body-file] [advertised-size]
start_stub() {
  stop_stub
  rm -f "$TMPROOT/port" "$STUB_LOG"
  python3 "$TMPROOT/stub.py" "$1" "$TMPROOT/port" "$STUB_LOG" \
          "${2:-}" "${3:-}" >"$TMPROOT/stub.err" 2>&1 &
  STUB_PID=$!
  local i
  for i in $(seq 1 100); do
    [[ -s "$TMPROOT/port" ]] && break
    sleep 0.1
  done
  if [[ ! -s "$TMPROOT/port" ]]; then
    echo "stub endpoint failed to start: $(cat "$TMPROOT/stub.err" 2>/dev/null)" >&2
    exit 1
  fi
  ENDPOINT="http://127.0.0.1:$(cat "$TMPROOT/port")"
}

# Requests the stub saw, optionally filtered by method.
req_count() {
  [[ -f "$STUB_LOG" ]] || { echo 0; return; }
  if [[ -n "${1:-}" ]]; then grep -c "\"method\": \"$1\"" "$STUB_LOG" || true
  else wc -l <"$STUB_LOG"; fi
}

# ── Project fixtures ──────────────────────────────────────────────
# download-model.sh resolves everything relative to its own parent directory,
# so each case gets a throwaway project holding a symlink to the real scripts.
# A global, not an echoed path: a fixture factory that also advances a counter
# has to assign, or every case silently shares one directory.
PROJ=""
PROJ_N=0
new_project() {
  PROJ_N=$((PROJ_N + 1))
  PROJ="$TMPROOT/proj$PROJ_N"
  mkdir -p "$PROJ/scripts"
  ln -sf "$SCRIPT_DIR/lib" "$PROJ/scripts/lib"
  ln -sf "$SCRIPT_DIR/download-model.sh" "$PROJ/scripts/download-model.sh"
  ln -sf "$SCRIPT_DIR/detect-platform.sh" "$PROJ/scripts/detect-platform.sh"
}

MODELS=""   # the directory the current case expects downloads to land in

# The script hands the transfer to huggingface-cli whenever it can find one,
# so a host with huggingface-hub installed - which is every host that has run
# setup.sh - would silently take a different code path than a host without it.
# Drop those directories from PATH so the curl path is the curl path
# everywhere; the two cases that mean to test the CLI ship their own stub in
# the fixture's .venv, which the script prefers over PATH anyway.
CLEAN_PATH="$PATH"
_clean_path() {
  local d out=""
  while IFS= read -r -d ':' d || [[ -n "$d" ]]; do
    [[ -z "$d" ]] && continue
    [[ -x "$d/hf" || -x "$d/huggingface-cli" ]] && continue
    out="${out:+$out:}$d"
  done <<<"$PATH:"
  printf '%s' "$out"
}
CLEAN_PATH="$(_clean_path)"

# run_dl <args...> - runs the real script in the current project.
#
# DL_SYSROOT pins the board the fit preflight sizes against; left empty the
# check reads the host, which makes every verdict depend on whose machine the
# suite runs on. DL_FIT_HEADER shrinks the ranged read to the fixtures' scale.
DL_SYSROOT=""
DL_FIT_HEADER=""
OUT=""; RC=0
run_dl() {
  # An array through `env`, not an assignment prefix: bash decides what is a
  # variable assignment before expanding, so ${X:+K=V} in that position would
  # be run as the command name rather than set as K.
  local -a e=(PATH="$CLEAN_PATH" HF_ENDPOINT="$ENDPOINT")
  [[ -n "$DL_SYSROOT" ]] && e+=(PLATFORM_SYSROOT="$DL_SYSROOT"
                                PLATFORM_NVIDIA_SMI=/nonexistent-in-fixture)
  [[ -n "$DL_FIT_HEADER" ]] && e+=(FIT_HEADER_BYTES="$DL_FIT_HEADER")
  OUT="$(cd "$PROJ" && env "${e[@]}" bash "$PROJ/scripts/download-model.sh" "$@" 2>&1)"
  RC=$?
  return 0
}

expect_rc() {
  if [[ "$RC" == "$1" ]]; then pass "exit status $1${2:+ ($2)}"
  else fail "exit status${2:+ ($2)}" "expected $1, got $RC; output: $(tr '\n' '|' <<<"$OUT" | cut -c1-220)"; fi
}
expect_out() {
  if grep -qE "$1" <<<"$OUT"; then pass "output matches /$1/"
  else fail "output does not match /$1/" "$(tr '\n' '|' <<<"$OUT" | cut -c1-220)"; fi
}
expect_not_out() {
  if grep -qE "$1" <<<"$OUT"; then fail "output unexpectedly matches /$1/" "$(tr '\n' '|' <<<"$OUT" | cut -c1-220)"
  else pass "output does not match /$1/"; fi
}

# The assertion that matters most: whatever went wrong, nothing that looks like
# a model may be left where setup.sh would find it.
expect_no_gguf() {
  local found
  found="$(find "$MODELS" -name '*.gguf' 2>/dev/null)"
  if [[ -z "$found" ]]; then pass "no *.gguf left on disk${1:+ ($1)}"
  else fail "a *.gguf was left behind${1:+ ($1)}" "$found ($(stat -c %s $found 2>/dev/null) bytes)"; fi
}
expect_file_size() {
  local f="$1" want="$2" got
  got="$(stat -c %s "$f" 2>/dev/null || echo missing)"
  if [[ "$got" == "$want" ]]; then pass "$(basename "$f") is $want bytes"
  else fail "$(basename "$f") size" "expected $want, got $got"; fi
}

GGUF_SIZE=65536

# ══════════════════════════════════════════════════════════════════
printf '%s╔══════════════════════════════════════════════════╗%s\n' "$C_HD" "$C_Z"
printf '%s║   download-model.sh - self-test                  ║%s\n' "$C_HD" "$C_Z"
printf '%s╚══════════════════════════════════════════════════╝%s\n' "$C_HD" "$C_Z"

# ── The happy path ────────────────────────────────────────────────
case_start "a healthy download lands verified"
new_project; MODELS="$PROJ/models"
start_stub ok
run_dl acme/Qwen3-GGUF qwen3-4b-q4_k_m.gguf
expect_rc 0 "fresh download"
expect_out 'Model saved'
expect_out 'GGUF verified'
expect_out 'MODEL_FILE=/models/qwen3-4b-q4_k_m.gguf'
expect_file_size "$MODELS/qwen3-4b-q4_k_m.gguf" "$GGUF_SIZE"
# The preflight must run before the transfer, not alongside it.
if grep -q 'Download size' <<<"$OUT" && grep -q 'Free on disk' <<<"$OUT"; then
  pass "reports the download size and free space before transferring"
else
  fail "no space preflight was reported"
fi
if [[ "$(req_count HEAD)" -ge 1 && "$(req_count GET)" -ge 1 ]]; then
  pass "probed with HEAD before fetching with GET"
else
  fail "unexpected request pattern" "$(tr '\n' ' ' <"$STUB_LOG")"
fi
# The repo and filename must reach the URL verbatim - a mangled path is how a
# "not found" that is really a quoting bug looks.
if grep -q '/acme/Qwen3-GGUF/resolve/main/qwen3-4b-q4_k_m.gguf' "$STUB_LOG"; then
  pass "requested the documented resolve/ URL"
else
  fail "wrong URL requested" "$(tr '\n' ' ' <"$STUB_LOG")"
fi

case_start "a second run is idempotent and re-verifies the size"
gets_before="$(req_count GET)"
run_dl acme/Qwen3-GGUF qwen3-4b-q4_k_m.gguf
expect_rc 0 "already present"
expect_out 'already present and verified'
expect_out 'MODEL_FILE=/models/qwen3-4b-q4_k_m.gguf'
expect_file_size "$MODELS/qwen3-4b-q4_k_m.gguf" "$GGUF_SIZE"
# Cheap re-check, not a re-download: it must confirm the size, never refetch.
if [[ "$(req_count GET)" == "$gets_before" && "$(req_count HEAD)" -gt 2 ]]; then
  pass "confirmed the size with a HEAD and did not re-download"
else
  fail "re-downloaded an intact model" \
       "GET was $gets_before, now $(req_count GET); HEAD $(req_count HEAD)"
fi

# ── Files that exist but are not models ───────────────────────────
case_start "a truncated file that still starts with GGUF is replaced"
new_project; MODELS="$PROJ/models"
start_stub ok
mkdir -p "$MODELS"
# 4 KiB of a 64 KiB model: passes the magic check, loads in nothing.
head -c 4096 /dev/zero | { printf 'GGUF'; cat; } >"$MODELS/partial.gguf"
run_dl acme/Qwen3-GGUF partial.gguf
expect_rc 0 "incomplete file replaced"
expect_out 'incomplete'
expect_not_out 'already present'
expect_file_size "$MODELS/partial.gguf" "$GGUF_SIZE"

case_start "a non-GGUF file left by an earlier run is discarded, not resumed"
new_project; MODELS="$PROJ/models"
start_stub ok
mkdir -p "$MODELS"
printf 'Entry not found' >"$MODELS/bogus.gguf"
run_dl acme/Qwen3-GGUF bogus.gguf
expect_rc 0 "invalid file replaced"
expect_out 'Discarding invalid existing file'
expect_file_size "$MODELS/bogus.gguf" "$GGUF_SIZE"
if [[ "$(head -c 4 "$MODELS/bogus.gguf")" == "GGUF" ]]; then
  pass "replacement is a real GGUF, not bytes spliced onto the error page"
else
  fail "new bytes were appended to the old file"
fi

case_start "an unreachable endpoint keeps an existing file but does not claim it is verified"
new_project; MODELS="$PROJ/models"
start_stub ok
mkdir -p "$MODELS"
head -c "$GGUF_SIZE" /dev/zero | { printf 'GGUF'; cat; } >"$MODELS/offline.gguf"
dead="$ENDPOINT"; stop_stub
ENDPOINT="$dead"
run_dl acme/Qwen3-GGUF offline.gguf
expect_rc 0 "offline with a file in hand"
expect_out 'Could not reach'
expect_out 'unverified'
expect_not_out 'already present and verified'
if [[ -f "$MODELS/offline.gguf" ]]; then pass "the existing file was not deleted"
else fail "an offline run deleted the user's model"; fi

# ── Servers that answer, but not with a model ─────────────────────
case_start "a typo'd filename writes nothing"
new_project; MODELS="$PROJ/models"
start_stub notfound
run_dl acme/Qwen3-GGUF qwen3-4b-q4_k_m.ggu
expect_rc 1 "404"
expect_out 'was not found'
expect_out 'nothing was written to disk'
expect_no_gguf "404"

case_start "a gated repo fails instead of saving the sign-in page"
new_project; MODELS="$PROJ/models"
start_stub gated
run_dl meta/Gated-GGUF gated.gguf
expect_rc 1 "401"
expect_out 'was not found|unreachable'
expect_no_gguf "401"

case_start "an HTML page served with a plausible size is rejected by the magic check"
new_project; MODELS="$PROJ/models"
start_stub html
run_dl acme/Qwen3-GGUF login.gguf
expect_rc 1 "html body"
expect_out 'not a valid GGUF'
expect_out 'deleted'
expect_no_gguf "html body"

case_start "a body shorter than the advertised size is deleted, not served"
new_project; MODELS="$PROJ/models"
start_stub shortget
run_dl acme/Qwen3-GGUF short.gguf
expect_rc 1 "size mismatch"
expect_out 'size mismatch'
expect_out 'truncated'
expect_no_gguf "size mismatch"

case_start "a transfer refused after a successful probe writes no error body"
# The size probe and the transfer are two separate requests to two separate
# hosts, so "the file is there" and "the file arrives" can disagree. The error
# body must never land at the destination named *.gguf.
new_project; MODELS="$PROJ/models"
start_stub getfails
run_dl acme/Qwen3-GGUF refused.gguf
expect_rc 1 "GET refused"
# An HTTP failure must be reported as one. Letting curl write the error body
# and diagnosing it afterwards as a corrupt model names the wrong cause.
expect_out 'download failed'
expect_not_out 'not a valid GGUF'
expect_not_out 'Model saved'
expect_no_gguf "refused transfer"

case_start "a transfer cut off mid-body leaves nothing behind"
new_project; MODELS="$PROJ/models"
start_stub cutoff
run_dl acme/Qwen3-GGUF dropped.gguf
expect_rc 1 "connection dropped"
expect_out 'download failed'
expect_no_gguf "dropped connection"

# ── Disk safety ───────────────────────────────────────────────────
case_start "a download that cannot fit is refused before it starts"
new_project; MODELS="$PROJ/models"
start_stub huge
run_dl acme/Qwen3-GGUF enormous.gguf
expect_rc 1 "will not fit"
expect_out 'not enough free space'
expect_out 'safety margin'
expect_out 'MODELS_DIR'
expect_no_gguf "no space"
# Refusing after the transfer would defeat the entire point.
if [[ "$(req_count GET)" == 0 ]]; then pass "no bytes were transferred"
else fail "the transfer started despite the refusal" "$(req_count GET) GET requests"; fi

case_start "--prune reclaims partial transfers and leaves real models alone"
new_project; MODELS="$PROJ/models"
start_stub ok
mkdir -p "$MODELS/sub"
head -c 200000 /dev/zero >"$MODELS/big.gguf.incomplete"
head -c 100000 /dev/zero >"$MODELS/sub/other.gguf.part"
head -c "$GGUF_SIZE" /dev/zero | { printf 'GGUF'; cat; } >"$MODELS/keep.gguf"
run_dl --prune
expect_rc 0 "prune"
expect_out 'Reclaimed'
expect_out '2 partial download'
expect_out 'Models currently on disk'
expect_out 'keep.gguf'
if [[ ! -e "$MODELS/big.gguf.incomplete" && ! -e "$MODELS/sub/other.gguf.part" ]]; then
  pass "both partial transfers were removed"
else
  fail "a partial transfer survived --prune"
fi
if [[ -f "$MODELS/keep.gguf" ]]; then pass "the real model was left alone"
else fail "--prune deleted a valid model"; fi

case_start "--prune on an empty project says so instead of failing"
new_project; MODELS="$PROJ/models"
run_dl --prune
expect_rc 0 "nothing to prune"
expect_out 'No partial downloads found'

# ── MODELS_DIR resolution ─────────────────────────────────────────
# docker-compose.yml mounts MODELS_DIR at /models. A model written anywhere
# else is invisible to the container, and the error the user sees names a
# missing file rather than the wrong directory.
case_start "MODELS_DIR from .env decides where the model lands"
new_project
start_stub ok
mkdir -p "$TMPROOT/datadisk$PROJ_N"
printf 'MODELS_DIR=%s\n' "$TMPROOT/datadisk$PROJ_N" >"$PROJ/.env"
MODELS="$TMPROOT/datadisk$PROJ_N"
run_dl acme/Qwen3-GGUF onadisk.gguf
expect_rc 0 "absolute MODELS_DIR"
expect_file_size "$MODELS/onadisk.gguf" "$GGUF_SIZE"
if [[ ! -e "$PROJ/models" ]]; then pass "did not also create ./models"
else fail "created ./models while MODELS_DIR points elsewhere"; fi

case_start "a compose-legal .env value is read the way compose reads it"
# Each of these is valid in a .env file and each used to end up inside the
# path: an inline comment, quotes, CRLF from an editor on another machine,
# trailing whitespace. The symptom is a several-GB download into a directory
# with a name nobody would ever type.
i=0
for spec in \
    'MODELS_DIR=@ # weights live off the repo' \
    'MODELS_DIR="@"' \
    "MODELS_DIR='@'" \
    'MODELS_DIR=@   ' \
    ; do
  i=$((i + 1))
  new_project
  start_stub ok
  target="$TMPROOT/dd$PROJ_N"
  mkdir -p "$target"
  MODELS="$target"
  printf '%s\n' "${spec//@/$target}" >"$PROJ/.env"
  run_dl acme/Qwen3-GGUF v$i.gguf
  if [[ "$RC" == 0 && -f "$MODELS/v$i.gguf" ]]; then
    pass "value '$spec' resolves to the intended directory"
  else
    fail "value '$spec' was mis-parsed" "rc=$RC; created: $(find "$TMPROOT" -maxdepth 2 -name "v$i.gguf" -o -maxdepth 1 -name '*#*' | tr '\n' ' ')"
  fi
done

new_project
start_stub ok
target="$TMPROOT/crlf"
mkdir -p "$target"
MODELS="$target"
printf 'MODELS_DIR=%s\r\n' "$target" >"$PROJ/.env"
run_dl acme/Qwen3-GGUF crlf.gguf
if [[ "$RC" == 0 && -f "$MODELS/crlf.gguf" ]]; then
  pass "a .env saved with CRLF endings resolves to the intended directory"
else
  fail "CRLF .env was mis-parsed" "rc=$RC out=$(tr '\n' '|' <<<"$OUT" | cut -c1-200)"
fi

# A bind source is not a shell path: compose reads a bare relative value as a
# named volume, so the project does not even parse - and this script would
# otherwise have spent several GB before anyone found out.
new_project
start_stub ok
printf 'MODELS_DIR=models\n' >"$PROJ/.env"
run_dl acme/Qwen3-GGUF bare.gguf
expect_rc 2 "a bare relative MODELS_DIR"
expect_out 'bind-mounted'
expect_out 'write ./models'
if [[ -e "$PROJ/models/bare.gguf" ]]; then fail "downloaded anyway"; else pass "nothing was downloaded"; fi

# ~ is expanded by compose but not by bash, so the untouched form would write
# several GB into a directory literally named '~'.
new_project
start_stub ok
FAKE_HOME="$TMPROOT/home$PROJ_N"; mkdir -p "$FAKE_HOME"
printf 'MODELS_DIR=~/models\n' >"$PROJ/.env"
OUT="$(cd "$PROJ" && HOME="$FAKE_HOME" PATH="$CLEAN_PATH" HF_ENDPOINT="$ENDPOINT" \
       bash "$PROJ/scripts/download-model.sh" acme/Qwen3-GGUF tilde.gguf 2>&1)"; RC=$?
expect_rc 0 "a ~-relative MODELS_DIR"
if [[ -f "$FAKE_HOME/models/tilde.gguf" ]]; then pass "writes where compose will mount"
else fail "writes where compose will mount" "not at $FAKE_HOME/models/tilde.gguf"; fi
if [[ -e "$PROJ/~" ]]; then fail "does not create a directory literally named ~"
else pass "does not create a directory literally named ~"; fi

new_project
start_stub ok
MODELS="$PROJ/models"
printf '# MODELS_DIR=/data/models\nMODELS_DIR=./models\n' >"$PROJ/.env"
run_dl acme/Qwen3-GGUF commented.gguf
if [[ "$RC" == 0 && -f "$MODELS/commented.gguf" ]]; then
  pass "a commented-out MODELS_DIR does not win over the real one"
else
  fail "commented .env line was honoured" "rc=$RC out=$(tr '\n' '|' <<<"$OUT" | cut -c1-200)"
fi

# ── --recommended ─────────────────────────────────────────────────
# The path the README puts first, and the only one that consults the hardware.
make_jetson_sysroot() {
  local root="$TMPROOT/sysroot-$1"
  rm -rf "$root"; mkdir -p "$root/proc" "$root/etc" "$root/bin"
  printf 'MemTotal:       %s kB\nMemFree:         1000000 kB\n' "$2" >"$root/proc/meminfo"
  printf '# R36 (release), REVISION: 4.3, GCID: 1, BOARD: generic, EABI: aarch64, DATE: x\n' \
    >"$root/etc/nv_tegra_release"
  mkdir -p "$root/proc/device-tree"
  printf '%s\0' "NVIDIA Jetson Orin Nano Super Developer Kit" >"$root/proc/device-tree/model"
  mkdir -p "$root/etc/cdi"; : >"$root/etc/cdi/nvidia.yaml"
  printf '%s' "$root"
}

case_start "--recommended pulls the model this board can actually run"
new_project; MODELS="$PROJ/models"
start_stub ok
SYSROOT="$(make_jetson_sysroot orin 8000000)"
OUT="$(cd "$PROJ" && PATH="$CLEAN_PATH" HF_ENDPOINT="$ENDPOINT" PLATFORM_SYSROOT="$SYSROOT" \
       PLATFORM_NVIDIA_SMI=/nonexistent-in-fixture \
       bash "$PROJ/scripts/download-model.sh" --recommended 2>&1)"; RC=$?
expect_rc 0 "recommended on a Jetson fixture"
expect_out 'Platform: .*Orin'
expect_out 'Recommended model for a [0-9]+ GiB budget'
expect_out 'Model saved'
downloaded="$(find "$MODELS" -name '*.gguf')"
if [[ -n "$downloaded" ]]; then
  pass "downloaded $(basename "$downloaded")"
  expect_file_size "$downloaded" "$GGUF_SIZE"
else
  fail "--recommended downloaded nothing"
fi
# It has to fetch what detect-platform.sh names, not a hardcoded default.
rec_file="$(PLATFORM_SYSROOT="$SYSROOT" PLATFORM_NVIDIA_SMI=/nonexistent-in-fixture \
            bash "$SCRIPT_DIR/detect-platform.sh" --env | sed -n 's/^REC_MODEL_FILE=//p' | tr -d '"')"
if [[ -n "$rec_file" && "$(basename "${downloaded:-none}")" == "$rec_file" ]]; then
  pass "fetched exactly the recommended file ($rec_file)"
else
  fail "fetched a different file than recommended" "recommended=$rec_file got=$(basename "${downloaded:-none}")"
fi

case_start "--recommended on an unrecognised host explains itself"
new_project; MODELS="$PROJ/models"
start_stub ok
mkdir -p "$TMPROOT/emptyroot/proc"
OUT="$(cd "$PROJ" && PATH="$CLEAN_PATH" HF_ENDPOINT="$ENDPOINT" PLATFORM_SYSROOT="$TMPROOT/emptyroot" \
       PLATFORM_NVIDIA_SMI=/nonexistent-in-fixture \
       bash "$PROJ/scripts/download-model.sh" --recommended 2>&1)"; RC=$?
expect_rc 1 "detection failed"
expect_out 'platform detection'
expect_out '<hf-repo> <gguf-filename>'
# A raw bash diagnostic here means the script fell off its own logic.
expect_not_out 'unbound variable'
expect_no_gguf "detection failure"

case_start "--recommended survives a probe that succeeds without recommending anything"
# The two scripts agree on a contract - detect-platform.sh --env emits
# REC_MODEL_REPO and REC_MODEL_FILE - and nothing enforces it. A probe that
# exits 0 having recognised the board but not sized a model is the shape this
# breaks in, and it used to reach a bare "REC_MODEL_REPO: unbound variable".
new_project; MODELS="$PROJ/models"
start_stub ok
rm -f "$PROJ/scripts/detect-platform.sh"
cat >"$PROJ/scripts/detect-platform.sh" <<'EOF'
#!/usr/bin/env bash
echo 'PLATFORM_KIND="jetson"'
echo 'PLATFORM_LABEL="Some Board"'
echo 'GPU_MEM_MB="4096"'
exit 0
EOF
chmod +x "$PROJ/scripts/detect-platform.sh"
run_dl --recommended
expect_rc 1 "no recommendation emitted"
expect_out 'no model recommendation'
expect_out 'detect-platform.sh'
expect_not_out 'unbound variable'
expect_no_gguf "empty recommendation"

# ── Argument handling ─────────────────────────────────────────────
case_start "usage errors are rejected with exit 2 and nothing is fetched"
new_project; MODELS="$PROJ/models"
start_stub ok
run_dl
expect_rc 2 "no arguments"
expect_out 'Usage'

run_dl acme/Qwen3-GGUF
expect_rc 2 "repo without a filename"
expect_out 'missing filename'

run_dl acme/Qwen3-GGUF --include
expect_rc 2 "--include without a pattern"
expect_out 'requires a pattern'
expect_not_out 'Missing pattern after'

run_dl --recomended
expect_rc 2 "misspelled option"
expect_out 'unknown option'

if [[ "$(req_count)" == 0 ]]; then pass "no requests issued while rejecting arguments"
else fail "an argument error reached the network" "$(req_count) requests"; fi
expect_no_gguf "argument errors"

case_start "--help documents every mode"
run_dl --help
expect_rc 0 "help"
expect_out 'Usage'
expect_out '\-\-recommended'
expect_out '\-\-prune'
expect_out '\-\-include'
expect_out 'Models are saved to'

# ── The Hugging Face CLI path ─────────────────────────────────────
# When huggingface-cli is installed the script hands the transfer to it, which
# is a completely separate code path - and the one a Jetson with a venv takes.
# Verification has to apply there too, or the CLI path is an unchecked hole.
case_start "a model fetched through the huggingface CLI is verified the same way"
new_project; MODELS="$PROJ/models"
start_stub ok
mkdir -p "$PROJ/.venv/bin"
cat >"$PROJ/.venv/bin/hf" <<EOF
#!/usr/bin/env bash
# Stands in for huggingface-cli: writes the file the way the real CLI would,
# straight into --local-dir.
repo="\$2"; file="\$3"; dir=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "--local-dir" ]] && dir="\$2"; shift; done
mkdir -p "\$dir"
head -c $((GGUF_SIZE - 4)) /dev/zero | { printf 'GGUF'; cat; } >"\$dir/\$file"
echo "stub-hf: wrote \$dir/\$file"
EOF
chmod +x "$PROJ/.venv/bin/hf"
run_dl acme/Qwen3-GGUF viacli.gguf
expect_rc 0 "cli download"
expect_out 'stub-hf: wrote'
expect_out 'GGUF verified'
expect_file_size "$MODELS/viacli.gguf" "$GGUF_SIZE"

case_start "a short file written by the CLI is caught, not published"
new_project; MODELS="$PROJ/models"
start_stub ok
mkdir -p "$PROJ/.venv/bin"
cat >"$PROJ/.venv/bin/hf" <<'EOF'
#!/usr/bin/env bash
file="$3"; dir=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--local-dir" ]] && dir="$2"; shift; done
mkdir -p "$dir"
head -c 8192 /dev/zero | { printf 'GGUF'; cat; } >"$dir/$file"
EOF
chmod +x "$PROJ/.venv/bin/hf"
run_dl acme/Qwen3-GGUF clishort.gguf
expect_rc 1 "cli produced a short file"
expect_out 'size mismatch'
expect_no_gguf "short cli download"

# ══════════════════════════════════════════════════════════════════
printf '\n%s╔══════════════════════════════════════════════════╗%s\n' "$C_HD" "$C_Z"
printf '%s║  Fit preflight: will it run once it is here?      ║%s\n' "$C_HD" "$C_Z"
printf '%s╚══════════════════════════════════════════════════╝%s\n' "$C_HD" "$C_Z"
# Free space says whether the file can land; none of it says whether the model
# can be *served*. On a Jetson the weights, the KV cache and the compute buffers
# share the pool the OS is using, and the cache is set by CTX_SIZE and
# CACHE_TYPE_K/V - two knobs the file size cannot see. These cases pin that the
# verdict comes from the model's own metadata, that it is reached before the
# body is transferred, and that everything it cannot establish is reported as a
# skip rather than guessed at.

# A body with real geometry. Qwen2.5-3B's shape: 36 layers, 2 KV heads,
# head_dim 128 - 9216 K elements per token, the same again for V. At q8_0 that
# is 19584 bytes per token, so 16384 tokens cost 306 MiB and 131072 cost 2448.
FITGGUF="$TMPROOT/fit-model.gguf"
python3 "$SCRIPT_DIR/test-fixtures/mkgguf.py" "$FITGGUF" \
  --arch qwen2 --layers 36 --embd 2048 --heads 16 --kv-heads 2 \
  --ctx-train 32768 --vocab 512
SWAGGUF="$TMPROOT/fit-swa.gguf"
python3 "$SCRIPT_DIR/test-fixtures/mkgguf.py" "$SWAGGUF" \
  --arch gemma2 --layers 36 --embd 2048 --heads 16 --kv-heads 2 \
  --sliding-window 4096 --ctx-train 32768 --vocab 512

FIT_BODY_BYTES="$(stat -c %s "$FITGGUF")"
# The fixtures' Jetson: 8000000 kB of RAM is 7812 MiB, less the 2048 MiB OS
# reserve, so every verdict below is against a 5764 MiB budget.
FIT_SYSROOT="$(make_jetson_sysroot fit 8000000)"
FIT_BUDGET=5764

# fit_env <ctx> [type-k] [type-v] - the deployment the model will be served under.
fit_env() {
  printf 'MODELS_DIR=./models\nCTX_SIZE=%s\nCACHE_TYPE_K=%s\nCACHE_TYPE_V=%s\n' \
    "$1" "${2:-q8_0}" "${3:-q8_0}" >"$PROJ/.env"
}

# Ranged GETs the stub saw. The whole promise of the preflight is that it reads
# a header, so "it refused before downloading" has to be asserted on the wire,
# not inferred from an empty models directory.
ranged_gets() { grep -c '"range": "bytes=' "$STUB_LOG" 2>/dev/null || true; }
full_gets()   { grep '"method": "GET"' "$STUB_LOG" 2>/dev/null | grep -c '"range": ""' || true; }

case_start "a model too large for the board is refused before the body moves"
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" $((9 * 1024 * 1024 * 1024))
fit_env 16384
run_dl acme/Qwen3-GGUF toobig.gguf
expect_rc 3 "will not fit"
expect_out 'will not fit'
expect_out 'Once loaded.*weights 9216 .*16384-token q8_0/q8_0 KV cache 306 = 9522 MiB'
expect_out "against a $FIT_BUDGET MiB budget"
expect_no_gguf "refused model"
if [[ "$(ranged_gets)" -ge 1 ]]; then pass "the metadata was read with a ranged request"
else fail "no ranged request was issued" "$(cat "$STUB_LOG")"; fi
if [[ "$(full_gets)" == 0 ]]; then pass "no unranged GET - the 9 GiB body never started"
else fail "the body transfer started despite the refusal" "$(full_gets) unranged GETs"; fi

case_start "the same model and board flip verdict on CTX_SIZE alone"
# The check this replaces sized on the file, so these two configurations were
# indistinguishable: identical weights, identical board, one that runs and one
# that cannot. A model at 88% of the budget is exactly where that matters.
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" $((5 * 1024 * 1024 * 1024))
fit_env 131072
run_dl acme/Qwen3-GGUF ctxdecides.gguf
expect_rc 3 "5 GiB of weights plus a 131072-token cache does not fit"
expect_out 'KV cache 2448'
expect_no_gguf "refused at 131072"
# Same everything, a context the board can hold: the transfer goes ahead.
new_project; MODELS="$PROJ/models"
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 4096
run_dl acme/Qwen3-GGUF ctxdecides.gguf
expect_rc 0 "the same model at 4096 tokens is fetched"
expect_out 'Once loaded'
if [[ -f "$MODELS/ctxdecides.gguf" ]]; then pass "the model landed"
else fail "the fitting configuration was not downloaded" "$(tr '\n' '|' <<<"$OUT" | cut -c1-200)"; fi

case_start "the cache type is part of the verdict, not just the context"
# f16 is exactly twice q8_0, which is the whole reason the Jetson defaults are
# quantised. A refusal that ignored CACHE_TYPE_K/V would pass both of these.
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 16384 f16 f16
run_dl acme/Qwen3-GGUF cachetype.gguf
expect_out 'KV cache 576'
new_project; MODELS="$PROJ/models"
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 16384 q8_0 q8_0
run_dl acme/Qwen3-GGUF cachetype.gguf
expect_out 'KV cache 306'

case_start "a refusal names a context that would fit"
# "Lower CTX_SIZE" is advice; "CTX_SIZE=N fits" is an instruction. It has to be
# derived from the room actually left, not picked from a table.
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" $((4 * 1024 * 1024 * 1024))
fit_env 131072
run_dl acme/Qwen3-GGUF advises.gguf
expect_rc 3 "refused"
expect_out 'Set CTX_SIZE=[0-9]+ in .env'
suggested="$(sed -n 's/.*Set CTX_SIZE=\([0-9]*\) .*/\1/p' <<<"$OUT" | head -1)"
# Derive the expectation rather than hardcoding it: the suggestion must fit the
# room it was computed from, and one step larger must not.
room=$(( (FIT_BUDGET * 75 / 100 - 4096) * 1048576 ))
per_token=$(( 9216 * 34 / 32 * 2 ))
if [[ -n "$suggested" ]] && (( suggested > 0 )) \
   && (( suggested * per_token <= room )) && (( (suggested + 256) * per_token > room )); then
  pass "the suggested CTX_SIZE=$suggested is the largest that fits"
else
  fail "the suggested context is not the largest that fits" \
       "suggested=$suggested room=$room per_token=$per_token"
fi

case_start "a model with no room for any context says so instead of suggesting zero"
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" $((7 * 1024 * 1024 * 1024))
fit_env 16384
run_dl acme/Qwen3-GGUF noroom.gguf
expect_rc 3 "refused"
expect_out 'no room for any context'
expect_not_out 'CTX_SIZE=0'
# The weights are 7168 MiB against a 5764 MiB budget, so quantising the cache
# cannot rescue it either. Advice that cannot be taken is worse than none.
expect_not_out 'Set CACHE_TYPE_K=q8_0'

case_start "quantising the cache is offered only when it opens room"
# Weights at 4316 MiB leave 4323 - 4316 = 7 MiB under the three-quarter line.
# One 256-token step costs 9 MiB at f16 and 4.8 MiB at q8_0, so this is the
# narrow band where quantising the cache is the difference between no context
# at all and some. A generic "use q8_0" would be right by accident here and
# wrong in the case above; both have to come from the arithmetic.
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" $((4316 * 1048576))
fit_env 131072 f16 f16
run_dl acme/Qwen3-GGUF q8helps.gguf
expect_rc 3 "refused at f16"
expect_out 'CACHE_TYPE_K=q8_0 and CACHE_TYPE_V=q8_0 with CTX_SIZE=[0-9]+'
q8ctx="$(sed -n 's/.*CACHE_TYPE_V=q8_0 with CTX_SIZE=\([0-9]*\).*/\1/p' <<<"$OUT" | head -1)"
room=$(( (FIT_BUDGET * 75 / 100 - 4316) * 1048576 ))
q8_per_token=$(( 9216 * 34 / 32 * 2 ))
f16_per_token=$(( 9216 * 2 * 2 ))
if [[ -n "$q8ctx" ]] && (( q8ctx > 0 )) && (( q8ctx * q8_per_token <= room )) \
   && (( 256 * f16_per_token > room )); then
  pass "q8_0 is offered exactly where it opens room f16 does not ($q8ctx tokens)"
else
  fail "the q8_0 suggestion is not derived from the room left" \
       "q8ctx=$q8ctx room=$room q8/tok=$q8_per_token f16/tok=$f16_per_token"
fi

case_start "a tight fit whose weights are past the line names no context either"
# The warning branch has the same trap as the refusal: room is negative, so the
# arithmetic returns 0 and the advice reads "CTX_SIZE=0 would leave room".
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" $((5000 * 1048576))
fit_env 4096
run_dl acme/Qwen3-GGUF tightweights.gguf
expect_out 'compute buffers'
expect_out 'The weights alone are 5000 MiB'
expect_not_out 'CTX_SIZE=0'

case_start "--no-fit-check fetches it anyway"
# The check is a guard, not a policy. A user who knows something it does not -
# a board about to be reflashed, a model they mean to requantize - must be able
# to say so, and the refusal has to tell them how.
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
# Drive the refusal from the cache rather than the weights, so the same stub can
# serve the override run honestly: at 19584 bytes a token, 524288 tokens is
# 9792 MiB of cache on its own, well past the 5764 MiB budget.
fit_env 524288
run_dl acme/Qwen3-GGUF override.gguf
expect_rc 3 "refused without the flag"
expect_out 'Re-run with --no-fit-check'
run_dl --no-fit-check acme/Qwen3-GGUF override.gguf
expect_rc 0 "the flag overrides the refusal"
expect_out 'skipped \(--no-fit-check\)'
if [[ -f "$MODELS/override.gguf" ]]; then pass "the model landed with --no-fit-check"
else fail "--no-fit-check did not download" "$(tr '\n' '|' <<<"$OUT" | cut -c1-200)"; fi
# The flag is a modifier, not a mode: it must work in any position and must not
# be mistaken for the repo argument.
new_project; MODELS="$PROJ/models"
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 524288
run_dl acme/Qwen3-GGUF trailing.gguf --no-fit-check
expect_rc 0 "accepted after the positional arguments"
if [[ -f "$MODELS/trailing.gguf" ]]; then pass "trailing --no-fit-check names the same file"
else fail "the flag consumed a positional argument" "$(tr '\n' '|' <<<"$OUT" | cut -c1-200)"; fi

case_start "an endpoint that ignores Range does not turn the probe into a download"
# The failure this guards against is the preflight downloading the very object
# it exists to avoid downloading: a server that answers a ranged request with
# the whole body. curl checks the advertised length first, so the probe costs
# nothing and the check reports that it did not run.
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=4096
start_stub norange "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 16384
run_dl acme/Qwen3-GGUF norange.gguf
expect_rc 0 "the download still proceeds"
expect_out 'Fit check.*skipped'
if [[ "$(ranged_gets)" -ge 1 ]]; then pass "a ranged request was attempted"
else fail "no ranged request was attempted" "$(cat "$STUB_LOG")"; fi

case_start "a body whose metadata is not readable is skipped, not guessed at"
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok            # the filler GGUF: right magic, no metadata
fit_env 16384
run_dl acme/Qwen3-GGUF nometa.gguf
expect_rc 0 "an unreadable header does not block the download"
expect_out 'Fit check.*skipped'
expect_not_out 'will not fit'

case_start "a KV cache type llama.cpp cannot quantize to is named, not sized"
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 16384 q3_k q3_k
run_dl acme/Qwen3-GGUF badtype.gguf
expect_rc 0 "an unusable cache type is a configuration problem, not a refusal"
expect_out 'unknown KV cache type: q3_k'
expect_out 'CACHE_TYPE_K/V'

case_start "an architecture this arithmetic overestimates is not refused on an upper bound"
# A sliding-window model needs less cache than the formula computes, and an
# upper bound cannot prove a model does *not* fit. Refusing on it would block a
# model the board can actually hold.
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$SWAGGUF" "$(stat -c %s "$SWAGGUF")"
fit_env 524288
run_dl acme/Gemma-GGUF swa.gguf
expect_rc 0 "an upper bound past the budget still downloads"
expect_out 'upper bound'
if [[ -f "$MODELS/swa.gguf" ]]; then pass "the sliding-window model landed"
else fail "an upper bound blocked a model that may well fit" "$(tr '\n' '|' <<<"$OUT" | cut -c1-200)"; fi

case_start "a host with no memory budget reports that instead of a verdict"
new_project; MODELS="$PROJ/models"
mkdir -p "$TMPROOT/cpuroot/proc"
printf 'MemTotal:       32000000 kB\n' >"$TMPROOT/cpuroot/proc/meminfo"
DL_SYSROOT="$TMPROOT/cpuroot"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 16384
run_dl acme/Qwen3-GGUF cpuhost.gguf
expect_rc 0 "a CPU-only host downloads what it is asked for"
expect_out 'no GPU memory budget'
expect_not_out 'will not fit'

case_start "a warning is not a refusal when the model is merely tight"
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
# A 262144-token q8_0 cache is 4896 MiB, 84% of the 5764 MiB budget: past the
# point where the compute buffers comfortably fit, not past the budget itself.
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 262144
run_dl acme/Qwen3-GGUF tight.gguf
expect_rc 0 "a tight fit is still fetched"
expect_out 'compute buffers'
expect_not_out 'will not fit'

case_start "--recommended is sized against the board it was recommended for"
# The end-to-end shape of the whole feature: detection picks the model, the
# preflight confirms the board can serve it, and the two agree.
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"; DL_FIT_HEADER=65536
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 16384
run_dl --recommended
expect_rc 0 "recommended model passes its own fit check"
expect_out "Memory budget : $FIT_BUDGET MiB"
expect_out 'Once loaded'

case_start "the sharded path says the fit check did not run"
new_project; MODELS="$PROJ/models"
DL_SYSROOT="$FIT_SYSROOT"
mkdir -p "$PROJ/.venv/bin"
cat >"$PROJ/.venv/bin/hf" <<EOF
#!/usr/bin/env bash
dir=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "--local-dir" ]] && dir="\$2"; shift; done
mkdir -p "\$dir/Q4_K_M"
cp "$FITGGUF" "\$dir/Q4_K_M/shard-00001-of-00002.gguf"
EOF
chmod +x "$PROJ/.venv/bin/hf"
start_stub ok "$FITGGUF" "$FIT_BODY_BYTES"
fit_env 16384
run_dl acme/Qwen3-GGUF --include 'Q4_K_M/*'
expect_rc 0 "sharded download succeeds"
expect_out 'Fit check.*not available for sharded models'
expect_out 'validate.sh'

DL_SYSROOT=""; DL_FIT_HEADER=""

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
