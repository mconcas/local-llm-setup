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
BODY = HTML if MODE == "html" else GGUF
ADVERTISED = {
    "shortget": len(BODY) + 4096,
    "huge": 1 << 50,
}.get(MODE, len(BODY))


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _log(self):
        with open(LOGFILE, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path}) + "\n")

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
OUT=""; RC=0
run_dl() {
  OUT="$(cd "$PROJ" && PATH="$CLEAN_PATH" HF_ENDPOINT="$ENDPOINT" \
         bash "$PROJ/scripts/download-model.sh" "$@" 2>&1)"
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
