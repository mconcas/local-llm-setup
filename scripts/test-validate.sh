#!/usr/bin/env bash
# test-validate.sh - Hermetic tests for validate.sh.
#
# validate.sh is what the rest of this repo's claims rest on: "37/37 green" is
# only worth something if a red condition actually turns a check red. On a
# healthy Orin every check reports PASS - which is also precisely what a check
# that *cannot* fail reports. Two of them could not: the CA-enforcement check
# passed against an nginx that was down, and the slot-count check passed with
# PARALLEL unset. A third crashed the whole run on `set -u` before the summary.
#
# These tests drive the real script in throwaway project directories where each
# condition is genuinely broken - no model, a truncated one, a CRLF .env, a
# stopped container, a CPU-only log, a server holding a different model, a proxy
# that does not enforce its CA - and assert both that the matching check goes
# red and that the ones around it stay green.
#
# Everything is stubbed: `docker` is a script reading canned output, and the
# llama.cpp API is a small HTTP/HTTPS server. No GPU, no model, no Docker, no
# network, and nothing written larger than a sparse file.
#
# Usage:
#   ./scripts/test-validate.sh          # run all cases
#   ./scripts/test-validate.sh -v       # also print each assertion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TARGET="$SCRIPT_DIR/validate.sh"

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

# ── Assertions ────────────────────────────────────────────────────
# validate.sh's product is a per-check verdict, so the assertions are about
# verdicts: this named check reported PASS / FAIL / SKIP. Matching the verdict
# column matters - "model file present" appearing anywhere in the output is not
# the same claim as it having passed.
verdict_of() {  # $1=output  $2=substring -> PASS|FAIL|SKIP|<none>
  grep -E '^  (PASS|FAIL|SKIP)  ' <<<"$1" | grep -F -- "$2" | head -1 |
    sed -E 's/^  (PASS|FAIL|SKIP).*/\1/'
}
assert_verdict() {  # $1=output $2=substring $3=expected $4=description
  local got; got="$(verdict_of "$1" "$2")"
  if [[ "$got" == "$3" ]]; then pass "$4"
  else fail "$4" "expected $3 for a check matching '$2', got '${got:-no such check}'"; fi
}
assert_pass() { assert_verdict "$1" "$2" PASS "$3"; }
assert_fail() { assert_verdict "$1" "$2" FAIL "$3"; }
assert_skip() { assert_verdict "$1" "$2" SKIP "$3"; }

assert_exit() {
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected exit $2, got $1"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "output did not contain: $2"; fi
}
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3" "output unexpectedly contained: $2"; fi
}
assert_eq() {
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected '$2', got '$1'"; fi
}

TMPROOT="$(mktemp -d)"
HTTP_PID=""; HTTPS_PID=""
cleanup() {
  [[ -n "$HTTP_PID"  ]] && kill "$HTTP_PID"  2>/dev/null
  [[ -n "$HTTPS_PID" ]] && kill "$HTTPS_PID" 2>/dev/null
  rm -rf "$TMPROOT"
}
trap cleanup EXIT INT TERM

# ══════════════════════════════════════════════════════════════════
# Stub llama.cpp server
# ══════════════════════════════════════════════════════════════════
# One process serves every case: its behaviour comes from a JSON control file
# re-read on each request, so a case changes what the server does by rewriting
# a file rather than by restarting anything. It binds port 0 and writes back the
# port it got, so a busy machine or a parallel run cannot collide.
cat >"$TMPROOT/stub.py" <<'PYEOF'
import json, os, ssl, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CTL, PORTFILE = sys.argv[1], sys.argv[2]
CERT = sys.argv[3] if len(sys.argv) > 3 else None
KEY = sys.argv[4] if len(sys.argv) > 4 else None


def ctl():
    with open(CTL) as f:
        return json.load(f)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _raw(self, code, body, ctype="application/json"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._raw(code, json.dumps(obj))

    def do_GET(self):
        c = ctl()
        if self.path == "/health":
            if c.get("health", True):
                self._json(200, {"status": "ok"})
            else:
                self._json(503, {"error": "loading model"})
        elif self.path == "/v1/models":
            if c.get("models_empty"):
                self._json(200, {"models": []})
            else:
                self._json(200, {"models": [{"name": c.get("model_name",
                                                            "/models/stub-Q4_K_M.gguf")}]})
        elif self.path == "/props":
            if c.get("props_broken"):
                self._json(200, {"error": "no props"})
            else:
                self._json(200, {
                    "total_slots": c.get("slots", 1),
                    "default_generation_settings": {"n_ctx": c.get("n_ctx", 4096)},
                })
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        c = ctl()
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")

        if req.get("stream"):
            # Sent with a Content-Length rather than incrementally: validate.sh
            # greps the whole body, so real chunking would add nothing but a
            # source of flakiness.
            if not c.get("stream_ok", True):
                self._raw(200, 'data: {"choices":[]}\n\n', "text/event-stream")
                return
            body = "".join(
                'data: {"choices":[{"delta":{"content":"%d "}}]}\n\n' % i for i in range(5)
            ) + "data: [DONE]\n\n"
            self._raw(200, body, "text/event-stream")
            return

        if req.get("tools"):
            if not c.get("tool_calls", True):
                # A model without a tool-aware template answers in prose, which
                # is what LLAMA_ARG_JINJA=0 produces.
                self._json(200, {"choices": [{"message": {
                    "content": 'I would call get_weather({"city": "Turin"}).'}}]})
            else:
                self._json(200, {"choices": [{"message": {"content": None, "tool_calls": [
                    {"type": "function", "function": {
                        "name": "get_weather",
                        "arguments": '{"city":"Turin"}'}}]}}]})
            return

        if c.get("chat_broken"):
            self._json(500, {"error": "stub: out of memory"})
            return
        self._json(200, {"choices": [{"message": {"content": "JETSON OK"}}]})


srv = HTTPServer(("127.0.0.1", 0), H)
if CERT:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

CTL="$TMPROOT/control.json"
set_ctl() { printf '%s' "$1" >"$CTL"; }
set_ctl '{}'

# ── TLS material ──────────────────────────────────────────────────
# A real CA and a real server certificate, so the "rejects clients that do not
# trust the CA" check is exercised by actual verification rather than by a
# connection that happens to fail.
CERTS="$TMPROOT/certs"; mkdir -p "$CERTS"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$CERTS/ca.key" -out "$CERTS/ca.crt" -subj "/CN=test-ca" 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$CERTS/server.key" -out "$CERTS/server.csr" -subj "/CN=localhost" 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' >"$CERTS/ext.cnf"
openssl x509 -req -in "$CERTS/server.csr" -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" \
  -CAcreateserial -days 2 -extfile "$CERTS/ext.cnf" -out "$CERTS/server.crt" 2>/dev/null

start_stub() {  # $1=portfile  [cert key]
  local pf="$1"; shift
  rm -f "$pf"
  python3 "$TMPROOT/stub.py" "$CTL" "$pf" "$@" >/dev/null 2>&1 &
  local pid=$! i
  for i in $(seq 1 100); do [[ -s "$pf" ]] && break; sleep 0.05; done
  [[ -s "$pf" ]] || { echo "stub server did not start" >&2; exit 1; }
  echo "$pid"
}

HTTP_PORTFILE="$TMPROOT/http.port"
HTTPS_PORTFILE="$TMPROOT/https.port"
HTTP_PID="$(start_stub "$HTTP_PORTFILE")"
HTTPS_PID="$(start_stub "$HTTPS_PORTFILE" "$CERTS/server.crt" "$CERTS/server.key")"
HTTP_PORT="$(cat "$HTTP_PORTFILE")"
HTTPS_PORT_N="$(cat "$HTTPS_PORTFILE")"
HTTP_BASE="http://127.0.0.1:$HTTP_PORT"

# ══════════════════════════════════════════════════════════════════
# Stub docker
# ══════════════════════════════════════════════════════════════════
# `docker compose config|ps|logs` answer from files in the project fixture, so a
# case describes the state of the stack by writing three text files.
STUBBIN="$TMPROOT/bin"; mkdir -p "$STUBBIN"
cat >"$STUBBIN/docker" <<'EOF'
#!/usr/bin/env bash
D="${DOCKER_STUB_DIR:?}"
if [[ "${1:-}" == "--version" ]]; then echo "Docker version 99.9.9, build stub"; exit 0; fi
if [[ "${1:-}" == "compose" ]]; then
  shift
  case "${1:-}" in
    version) [[ "${2:-}" == "--short" ]] && echo "2.99.0" || echo "Docker Compose version v2.99.0"; exit 0 ;;
    config)  cat "$D/config.out" 2>/dev/null; exit "$(cat "$D/config.rc" 2>/dev/null || echo 0)" ;;
    ps)      cat "$D/ps.out" 2>/dev/null; exit 0 ;;
    logs)    cat "$D/logs.out" 2>/dev/null; exit 0 ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$STUBBIN/docker"

# A PATH holding only what validate.sh actually needs, used by the cases that
# remove one tool from it. Building it explicitly is also a standing check that
# the dependency set stays this small.
MINBIN="$TMPROOT/minbin"; mkdir -p "$MINBIN"
for t in bash sed grep awk find stat df du realpath basename dirname mktemp tr cut \
         sort head tail cat wc rm chmod ln uname openssl curl python3; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$MINBIN/$t"
done

# ══════════════════════════════════════════════════════════════════
# Synthetic hosts and project fixtures
# ══════════════════════════════════════════════════════════════════
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
make_x86_sysroot() { mkdir -p "$1/proc" "$1/etc"; printf 'MemTotal:       %s kB\n' "$2" >"$1/proc/meminfo"; }

JETSON_SYSROOT="$TMPROOT/sys-jetson";        make_jetson_sysroot "$JETSON_SYSROOT" 7620000
JETSON_NOCDI="$TMPROOT/sys-jetson-nocdi";    make_jetson_sysroot "$JETSON_NOCDI" 7620000 no-cdi
X86_SYSROOT="$TMPROOT/sys-x86";              make_x86_sysroot "$X86_SYSROOT" 131072000

DISCRETE_SMI="$TMPROOT/nvidia-smi-discrete"
cat >"$DISCRETE_SMI" <<'EOF'
#!/bin/sh
case "$*" in
  *memory.total*) echo "32607" ;;
  *) echo "NVIDIA GeForce RTX 5090" ;;
esac
EOF
chmod +x "$DISCRETE_SMI"
NO_SMI="$TMPROOT/nvidia-smi-absent"   # a path that does not exist

JETSON_IMAGE="ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin"
X86_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"

# The merged-config text the GPU checks grep. Only the two markers matter.
CFG_CDI=$'services:\n  llama-server:\n    devices:\n      - nvidia.com/gpu=all\n'
CFG_LEGACY=$'services:\n  llama-server:\n    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n'
CFG_BOTH="${CFG_CDI}${CFG_LEGACY}"
CFG_NONE=$'services:\n  llama-server:\n    image: stub\n'

LOG_HEALTHY=$'ggml_cuda_init: found 1 CUDA devices:\nggml_cuda_init:   Device 0: Orin\nggml_cuda_init: GGML_CUDA_FORCE_MMQ: no\nload_backend: ARCHS = 870\nload_tensors: offloaded 29/29 layers to GPU\n'
LOG_CPU=$'llama_model_loader: loaded meta data\nload_tensors: CPU model buffer size = 1918.35 MiB\n'
LOG_NO_ARCHS=$'ggml_cuda_init: found 1 CUDA devices:\nload_backend: ARCHS = 750;800\nload_tensors: offloaded 29/29 layers to GPU\n'
LOG_PTX=$'ggml_cuda_init: found 1 CUDA devices:\nload_backend: ARCHS = 870\nload_tensors: offloaded 29/29 layers to GPU\nggml-cuda.cu: the provided PTX was compiled with an unsupported toolchain.\n'
LOG_PARTIAL=$'ggml_cuda_init: found 1 CUDA devices:\nload_backend: ARCHS = 870\nload_tensors: offloaded 12/29 layers to GPU\n'

PS_UP=$'llama-server Up 3 minutes (healthy)\nnginx Up 3 minutes\n'
PS_NO_NGINX=$'llama-server Up 3 minutes (healthy)\n'
PS_DOWN=$'nginx Exited (1) 2 minutes ago\n'

PROJ_N=0
P=""
# Sets P rather than echoing it: a fixture factory that also advances a counter
# cannot run in a subshell, or every case silently shares one directory.
new_project() {
  PROJ_N=$((PROJ_N+1))
  P="$TMPROOT/proj$PROJ_N"
  mkdir -p "$P/scripts" "$P/models" "$P/certs" "$P/.dockerstub"
  cp "$PROJECT_DIR"/docker-compose*.yml "$P/"
  # Copied, not symlinked: validate.sh derives PROJECT_DIR from $0, and it must
  # land in the fixture rather than in the real repo.
  cp "$SCRIPT_DIR"/*.sh "$P/scripts/"
  cp -r "$SCRIPT_DIR/lib" "$P/scripts/"
  cp "$CERTS/ca.crt" "$CERTS/server.crt" "$CERTS/server.key" "$P/certs/"
  printf '%s' "$CFG_CDI" >"$P/.dockerstub/config.out"
  echo 0 >"$P/.dockerstub/config.rc"
  printf '%s' "$PS_UP" >"$P/.dockerstub/ps.out"
  printf '%s' "$LOG_HEALTHY" >"$P/.dockerstub/logs.out"
  make_model "$P" tiny.gguf 512
}

# A GGUF-shaped file of an arbitrary apparent size. Sparse, so a "model" larger
# than the board's whole memory budget costs 4 KiB of disk.
make_model() {  # $1=project $2=name $3=size MiB
  printf 'GGUF\x03\x00\x00\x00' >"$1/models/$2"
  truncate -s "$3M" "$1/models/$2"
}

write_env() {  # $1=project, remaining args are KEY=VALUE lines
  local p="$1"; shift
  : >"$p/.env"
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >>"$p/.env"; done
}

# The .env every healthy case starts from. HTTPS_PORT points at the stub TLS
# server; the plain-HTTP endpoint is passed with --base.
healthy_env() {  # $1=project [extra KEY=VALUE ...]
  local p="$1"; shift
  write_env "$p" \
    "COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml" \
    "LLAMA_IMAGE=$JETSON_IMAGE" \
    "MODELS_DIR=./models" \
    "MODEL_FILE=/models/tiny.gguf" \
    "CTX_SIZE=4096" \
    "GPU_LAYERS=-1" \
    "PARALLEL=1" \
    "HTTPS_PORT=$HTTPS_PORT_N" \
    "$@"
}

# Every key a fixture .env might set has to be cleared from the environment
# first. validate.sh exports what it reads - as compose does, where a real
# environment variable outranks .env - so when this suite runs as a check
# *inside* validate.sh, the host's own MODEL_FILE and MODELS_DIR are already
# exported and every fixture inherits them. The "MODEL_FILE missing" case then
# quietly tests nothing, and passes.
ENV_KEYS=(COMPOSE_FILE LLAMA_IMAGE MODELS_DIR MODEL_FILE CTX_SIZE GPU_LAYERS
          PARALLEL CACHE_TYPE_K CACHE_TYPE_V HTTPS_PORT DEBUG_PORT VALIDATE_BASE)
SCRUB=(env)
for k in "${ENV_KEYS[@]}"; do SCRUB+=(-u "$k"); done

OUT=""; RC=0
run_validate() {  # $1=project $2=sysroot $3=smi ... rest are validate.sh args
  local proj="$1" sysroot="$2" smi="$3"; shift 3
  OUT="$(cd "$proj" && "${SCRUB[@]}" PATH="$STUBBIN:$PATH" \
      DOCKER_STUB_DIR="$proj/.dockerstub" \
      PLATFORM_SYSROOT="$sysroot" PLATFORM_NVIDIA_SMI="$smi" \
      VALIDATE_SELFTESTS=0 \
      bash "$proj/scripts/validate.sh" --base "$HTTP_BASE" "$@" 2>&1)"
  RC=$?
}
# The common shape: a Jetson with no discrete GPU present.
run_jetson() { local proj="$1"; shift; run_validate "$proj" "$JETSON_SYSROOT" "$NO_SMI" "$@"; }

# ══════════════════════════════════════════════════════════════════
case_start "A correctly configured Jetson passes every check"
# ══════════════════════════════════════════════════════════════════
# The baseline the other cases are read against. If this one is not clean, a
# FAIL somewhere below proves nothing about the condition it was meant to test.
set_ctl '{"model_name":"/models/tiny.gguf","slots":1,"n_ctx":4096}'
new_project; healthy_env "$P"
run_jetson "$P"
assert_exit "$RC" 0 "exits 0"
assert_not_contains "$OUT" "  FAIL  " "no check fails on a healthy stack"
assert_pass "$OUT" "platform detected: jetson" "detects the Jetson"
assert_pass "$OUT" "CDI spec present" "finds the CDI spec"
assert_pass "$OUT" "COMPOSE_FILE selects the Jetson overlay" "accepts the overlay"
assert_pass "$OUT" "merged config requests the GPU over CDI" "sees the CDI device request"
assert_pass "$OUT" "legacy nvidia device reservation is cleared" "sees no legacy reservation"
assert_pass "$OUT" "LLAMA_IMAGE is the image for this platform" "accepts the Jetson image"
assert_pass "$OUT" "model file present" "finds the model"
assert_pass "$OUT" "valid GGUF header" "accepts the GGUF header"
assert_pass "$OUT" "TLS certificates present" "finds the certificates"
assert_pass "$OUT" "llama-server is up" "sees the container up"
assert_pass "$OUT" "initialised a CUDA device" "sees CUDA in the log"
assert_pass "$OUT" "sm_87 kernels" "sees sm_87 in the ARCHS line"
assert_pass "$OUT" "all layers offloaded to GPU (29/29)" "sees a full offload"
assert_pass "$OUT" "GET /health" "health endpoint answers"
assert_pass "$OUT" "serving the model named by MODEL_FILE" "served model matches .env"
assert_pass "$OUT" "slot count matches PARALLEL=1" "slot count matches"
assert_pass "$OUT" "chat completion" "chat completion works"
assert_pass "$OUT" "streaming completion emits SSE chunks" "streaming works"
assert_pass "$OUT" "structured tool_calls block" "tool calling works"
assert_pass "$OUT" "HTTPS GET /v1/models through nginx" "HTTPS works"
assert_pass "$OUT" "rejects clients that do not trust the CA" "CA is enforced"

# ══════════════════════════════════════════════════════════════════
case_start "MODEL_FILE missing from .env does not abort the run"
# ══════════════════════════════════════════════════════════════════
# This used to die on `set -u` with a bare "MODEL_FILE: unbound variable" at the
# first use, which skipped disk hygiene, TLS and all four self-tests, printed no
# summary, and exited 1 exactly like an ordinary failed check.
new_project
write_env "$P" "COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml" \
               "LLAMA_IMAGE=$JETSON_IMAGE" "MODELS_DIR=./models"
run_jetson "$P" --preflight
assert_exit "$RC" 1 "exits 1"
assert_fail "$OUT" "MODEL_FILE is not set in .env" "reports the missing key as a check"
assert_not_contains "$OUT" "unbound variable" "does not die on set -u"
assert_contains "$OUT" "Preflight - disk hygiene" "reaches the section after it"
assert_contains "$OUT" "Summary" "still prints the summary"
assert_contains "$OUT" "Failed checks:" "lists the failure"

# ══════════════════════════════════════════════════════════════════
case_start "An .env saved with CRLF endings is read as compose reads it"
# ══════════════════════════════════════════════════════════════════
# `set -a; . ./.env` kept the CR, which produced three failures at once, the
# clearest of which read "in .env: <image>; expected: <the same image>".
new_project
printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml\r\nLLAMA_IMAGE=%s\r\nMODELS_DIR=./models\r\nMODEL_FILE=/models/tiny.gguf\r\nPARALLEL=1\r\n' \
  "$JETSON_IMAGE" >"$P/.env"
run_jetson "$P" --preflight
assert_exit "$RC" 0 "exits 0"
assert_pass "$OUT" "COMPOSE_FILE selects the Jetson overlay" "COMPOSE_FILE survives the CR"
assert_pass "$OUT" "LLAMA_IMAGE is the image for this platform" "LLAMA_IMAGE survives the CR"
assert_pass "$OUT" "model file present" "MODEL_FILE survives the CR"

# ══════════════════════════════════════════════════════════════════
case_start "Compose-legal .env values that are not shell-legal"
# ══════════════════════════════════════════════════════════════════
# Sourcing this file printed "for: command not found" and executed the command
# substitution. Quotes, an inline comment and an unquoted value with spaces are
# all things compose accepts and .env.example itself documents.
new_project
mkdir -p "$P/models sub"; printf 'GGUF\x03\x00\x00\x00' >"$P/models sub/tiny.gguf"
cat >"$P/.env" <<EOF
COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml
LLAMA_IMAGE="$JETSON_IMAGE"
NOTE=tuned for the Orin Nano Super
STAMP=\$(touch $TMPROOT/pwned)
MODELS_DIR=./models sub   # a directory with a space in it
MODEL_FILE='/models/tiny.gguf'
PARALLEL=1
HTTPS_PORT=$HTTPS_PORT_N
EOF
run_jetson "$P"
assert_exit "$RC" 0 "exits 0"
assert_not_contains "$OUT" "command not found" "does not execute the file"
[[ -e "$TMPROOT/pwned" ]] && fail "does not run command substitutions in .env" "\$( ) in .env was executed" \
                          || pass "does not run command substitutions in .env"
assert_pass "$OUT" "LLAMA_IMAGE is the image for this platform" "strips surrounding quotes"
assert_pass "$OUT" "model file present" "resolves a MODELS_DIR containing a space and a comment"
assert_pass "$OUT" "slot count matches PARALLEL=1" "keys after the odd ones are still read"

# ══════════════════════════════════════════════════════════════════
case_start "Model file problems"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P" "MODEL_FILE=/models/gone.gguf"
run_jetson "$P" --preflight
assert_fail "$OUT" "model file not found" "missing model is reported"
assert_contains "$OUT" "download-model.sh" "points at the downloader"

new_project; healthy_env "$P"
printf 'Entry not found' >"$P/models/tiny.gguf"
run_jetson "$P" --preflight
assert_fail "$OUT" "not a valid GGUF" "an HTTP error body wearing a .gguf name is caught"

new_project; healthy_env "$P" "MODEL_FILE=models/tiny.gguf"
run_jetson "$P" --preflight
assert_fail "$OUT" "must be a container path" "a host path in MODEL_FILE is rejected"

# ══════════════════════════════════════════════════════════════════
case_start "Model sizing against the board's memory budget"
# ══════════════════════════════════════════════════════════════════
# The Orin Nano Super sysroot gives a 5571 MiB budget. Weights larger than that
# fail at load; weights over 60% of it load and then die once the KV cache grows.
new_project; healthy_env "$P" "MODEL_FILE=/models/huge.gguf"
make_model "$P" huge.gguf 8000
run_jetson "$P" --preflight
assert_fail "$OUT" "exceed the" "oversized weights are reported"
assert_contains "$OUT" "out-of-memory failure at load" "explains what will happen"

new_project; healthy_env "$P" "MODEL_FILE=/models/tight.gguf"
make_model "$P" tight.gguf 4200
run_jetson "$P" --preflight
assert_skip "$OUT" "% of the" "weights that fit but crowd the KV cache are flagged"

new_project; healthy_env "$P" "MODEL_FILE=/models/right.gguf"
make_model "$P" right.gguf 2000
run_jetson "$P" --preflight
assert_pass "$OUT" "leave room for the KV cache" "a correctly sized model passes"

# ══════════════════════════════════════════════════════════════════
case_start "Disk hygiene"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P"
printf 'GGUF' >"$P/models/half.gguf.part"; truncate -s 700M "$P/models/half.gguf.part"
run_jetson "$P" --preflight
assert_fail "$OUT" "interrupted download(s) holding" "an interrupted transfer is reported"
assert_contains "$OUT" "download-model.sh --prune" "points at the prune mode"

new_project; healthy_env "$P"
make_model "$P" spare.gguf 900
run_jetson "$P" --preflight
assert_skip "$OUT" "not referenced by MODEL_FILE" "an unused model is surfaced, not failed"

# ══════════════════════════════════════════════════════════════════
case_start "Jetson GPU passthrough wiring"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P"
run_validate "$P" "$JETSON_NOCDI" "$NO_SMI" --preflight
assert_fail "$OUT" "no CDI spec found" "a host with no CDI spec is caught"
assert_contains "$OUT" "nvidia-ctk cdi generate" "gives the command that fixes it"

new_project; healthy_env "$P" "COMPOSE_FILE=docker-compose.yml"
run_jetson "$P" --preflight
assert_fail "$OUT" "does not include docker-compose.jetson.yml" "a missing overlay is caught"

new_project; healthy_env "$P"
printf '%s' "$CFG_BOTH" >"$P/.dockerstub/config.out"
run_jetson "$P" --preflight
assert_fail "$OUT" "legacy nvidia device reservation" "a surviving legacy reservation is caught"
assert_contains "$OUT" "ldconfig hang" "names the consequence"

new_project; healthy_env "$P"
printf '%s' "$CFG_NONE" >"$P/.dockerstub/config.out"
run_jetson "$P" --preflight
assert_fail "$OUT" "no CDI device request" "a merged config with no GPU request is caught"

# ══════════════════════════════════════════════════════════════════
case_start "The image is the one setting with no runtime fallback"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P" "LLAMA_IMAGE=$X86_IMAGE"
run_jetson "$P" --preflight
assert_fail "$OUT" "not the image detected for this platform" "the x86 image on a Jetson is caught"
assert_contains "$OUT" "$JETSON_IMAGE" "names the image to use"

new_project
write_env "$P" "COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml" \
               "MODELS_DIR=./models" "MODEL_FILE=/models/tiny.gguf" "PARALLEL=1"
run_jetson "$P" --preflight
assert_fail "$OUT" "LLAMA_IMAGE is not set" "an absent image is caught"

# ══════════════════════════════════════════════════════════════════
case_start "Other platforms"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P" "COMPOSE_FILE=docker-compose.yml" "LLAMA_IMAGE=$X86_IMAGE"
printf '%s' "$CFG_LEGACY" >"$P/.dockerstub/config.out"
run_validate "$P" "$X86_SYSROOT" "$DISCRETE_SMI" --preflight
assert_pass "$OUT" "platform detected: nvidia-discrete" "detects a discrete GPU host"
assert_pass "$OUT" "merged config reserves an nvidia device" "accepts the legacy reservation there"
assert_not_contains "$OUT" "CDI spec" "does not ask an x86 host for a CDI spec"

new_project; healthy_env "$P" "COMPOSE_FILE=docker-compose.yml" "LLAMA_IMAGE=$X86_IMAGE"
printf '%s' "$CFG_NONE" >"$P/.dockerstub/config.out"
run_validate "$P" "$X86_SYSROOT" "$DISCRETE_SMI" --preflight
assert_fail "$OUT" "does not request a GPU" "a discrete host with no GPU request is caught"

new_project; healthy_env "$P" "COMPOSE_FILE=docker-compose.yml" "LLAMA_IMAGE=$X86_IMAGE"
run_validate "$P" "$X86_SYSROOT" "$NO_SMI" --preflight
# Matched on "nothing to check", not on "no NVIDIA GPU detected": the latter is
# also the tail of PLATFORM_LABEL on a CPU-only host, so it matches the platform
# line above and the assertion reads a PASS that belongs to a different check.
assert_skip "$OUT" "nothing to check" "a CPU-only host skips the GPU checks"
assert_skip "$OUT" "no GPU memory budget" "and reports no memory budget"

# ══════════════════════════════════════════════════════════════════
case_start "Tooling and compose"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P"
echo 1 >"$P/.dockerstub/config.rc"
printf 'services.llama-server.image: invalid interpolation\n' >"$P/.dockerstub/config.out"
run_jetson "$P" --preflight
assert_fail "$OUT" "compose config is invalid" "an unmergeable compose set is caught"

new_project; healthy_env "$P"
rm -f "$P/certs/ca.crt" "$P/certs/server.crt"
run_jetson "$P" --preflight
assert_fail "$OUT" "TLS certificates missing" "missing certificates are caught"

# A PATH without docker/curl/python3. Only the check under test is asserted on -
# removing a tool legitimately disturbs others.
new_project; healthy_env "$P"
for missing in docker curl python3; do
  MB="$TMPROOT/minbin-no-$missing"; rm -rf "$MB"; cp -r "$MINBIN" "$MB"; rm -f "$MB/$missing"
  [[ "$missing" == docker ]] || cp "$STUBBIN/docker" "$MB/docker"
  OUT="$(cd "$P" && "${SCRUB[@]}" PATH="$MB" DOCKER_STUB_DIR="$P/.dockerstub" \
      PLATFORM_SYSROOT="$JETSON_SYSROOT" PLATFORM_NVIDIA_SMI="$NO_SMI" \
      VALIDATE_SELFTESTS=0 bash "$P/scripts/validate.sh" --preflight 2>&1)"
  assert_fail "$OUT" "$missing not found" "a missing $missing is reported by name"
done

# ══════════════════════════════════════════════════════════════════
case_start "Runtime: the stack is not up"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P"
printf '%s' "$PS_DOWN" >"$P/.dockerstub/ps.out"
run_jetson "$P" --runtime
assert_exit "$RC" 1 "exits 1"
assert_fail "$OUT" "llama-server is not running" "reports the container as down"
assert_contains "$OUT" "Skipping the remaining runtime checks" "says why it stopped"
assert_not_contains "$OUT" "GET /health" "does not run endpoint checks against a dead stack"

new_project; healthy_env "$P"
printf '%s' "$PS_NO_NGINX" >"$P/.dockerstub/ps.out"
run_jetson "$P" --runtime
assert_skip "$OUT" "nginx is not running" "skips TLS when the proxy is absent"

# ══════════════════════════════════════════════════════════════════
case_start "Runtime: GPU offload as seen in the log"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P"
printf '%s' "$LOG_CPU" >"$P/.dockerstub/logs.out"
run_jetson "$P" --runtime
assert_fail "$OUT" "did not report a CUDA device" "CPU-only operation is caught"
assert_contains "$OUT" "running on CPU" "says what it means"

new_project; healthy_env "$P"
printf '%s' "$LOG_NO_ARCHS" >"$P/.dockerstub/logs.out"
run_jetson "$P" --runtime
assert_fail "$OUT" "does not advertise sm_87" "an image without Orin kernels is caught"
assert_contains "$OUT" "nvidia-ai-iot" "names the image that works"

new_project; healthy_env "$P"
printf '%s' "$LOG_PTX" >"$P/.dockerstub/logs.out"
run_jetson "$P" --runtime
assert_fail "$OUT" "PTX JIT failed" "a PTX toolchain mismatch is caught"

new_project; healthy_env "$P"
printf '%s' "$LOG_PARTIAL" >"$P/.dockerstub/logs.out"
run_jetson "$P" --runtime
assert_fail "$OUT" "only 12 of 29 layers" "a partial offload is caught"

# The whole log is searched, not a bounded tail: llama.cpp prints the CUDA
# banner once at load, and a server that has served real traffic pushes it out
# of any fixed window - which used to read as "the model is running on CPU".
new_project; healthy_env "$P"
{ printf '%s' "$LOG_HEALTHY"; for i in $(seq 1 2000); do
    printf 'srv  update_slots: id  0 | task %d | processing\n' "$i"; done
} >"$P/.dockerstub/logs.out"
run_jetson "$P" --runtime
assert_pass "$OUT" "initialised a CUDA device" "finds the CUDA banner behind 2000 log lines"
assert_pass "$OUT" "sm_87 kernels" "finds the ARCHS line behind 2000 log lines"
assert_pass "$OUT" "all layers offloaded" "finds the offload line behind 2000 log lines"

# ══════════════════════════════════════════════════════════════════
case_start "Runtime: the HTTP API"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P"
set_ctl '{"model_name":"/models/tiny.gguf","slots":1,"health":false}'
run_jetson "$P" --runtime
assert_fail "$OUT" "GET /health did not return a status" "a server that is not ready is caught"

set_ctl '{"models_empty":true,"slots":1}'
new_project; healthy_env "$P"
run_jetson "$P" --runtime
assert_fail "$OUT" "returned no model" "an empty model list is caught"

# Editing MODEL_FILE without recreating the container leaves every other check
# green against the model that is actually loaded.
set_ctl '{"model_name":"/models/old-Q4_K_M.gguf","slots":1}'
new_project; healthy_env "$P"
run_jetson "$P" --runtime
assert_fail "$OUT" "but MODEL_FILE says" "a stale container is caught"
assert_contains "$OUT" "force-recreate" "gives the command that fixes it"

set_ctl '{"model_name":"/models/tiny.gguf","props_broken":true}'
new_project; healthy_env "$P"
run_jetson "$P" --runtime
assert_fail "$OUT" "did not return slot/context" "a server without /props is caught"

# PARALLEL reaching the server is the reason this check exists: it was passed as
# LLAMA_ARG_PARALLEL, which llama.cpp ignores, leaving the slot count at auto.
set_ctl '{"model_name":"/models/tiny.gguf","slots":4}'
new_project; healthy_env "$P" "PARALLEL=1"
run_jetson "$P" --runtime
assert_fail "$OUT" "but the server has 4 slots" "a slot count that ignores PARALLEL is caught"

# With nothing to compare against, this check has no content - and reporting a
# PASS there is the vacuous-pass shape the whole suite exists to catch.
new_project
write_env "$P" "COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml" \
               "LLAMA_IMAGE=$JETSON_IMAGE" "MODELS_DIR=./models" \
               "MODEL_FILE=/models/tiny.gguf" "HTTPS_PORT=$HTTPS_PORT_N"
run_jetson "$P" --runtime
assert_skip "$OUT" "PARALLEL is not set" "an unset PARALLEL is a skip, not a pass"
assert_not_contains "$OUT" "slot count matches" "and does not claim the count matched"

set_ctl '{"model_name":"/models/tiny.gguf","slots":1,"chat_broken":true}'
new_project; healthy_env "$P"
run_jetson "$P" --runtime
assert_fail "$OUT" "chat completion returned nothing" "a 500 from the model is caught"

set_ctl '{"model_name":"/models/tiny.gguf","slots":1,"stream_ok":false}'
new_project; healthy_env "$P"
run_jetson "$P" --runtime
assert_fail "$OUT" "well-formed SSE stream" "a stream with no [DONE] is caught"

# Without LLAMA_ARG_JINJA=1 the model describes the call in prose and agent
# clients never see a tool_calls block - the reason the flag is set at all.
set_ctl '{"model_name":"/models/tiny.gguf","slots":1,"tool_calls":false}'
new_project; healthy_env "$P"
run_jetson "$P" --runtime
assert_fail "$OUT" "structured tool_calls block" "a prose tool call is caught"
assert_contains "$OUT" "LLAMA_ARG_JINJA=1" "names the setting"

# ══════════════════════════════════════════════════════════════════
case_start "Runtime: TLS enforcement"
# ══════════════════════════════════════════════════════════════════
set_ctl '{"model_name":"/models/tiny.gguf","slots":1}'

# An endpoint that is simply down also refuses a request without the CA. This
# check used to report PASS in that state, which made a dead proxy look secure.
new_project; healthy_env "$P" "HTTPS_PORT=$HTTP_PORT"
run_jetson "$P" --runtime
assert_fail "$OUT" "HTTPS request through nginx failed" "a proxy not speaking TLS is caught"
assert_skip "$OUT" "cannot check CA enforcement" "CA enforcement is skipped, not passed"

# CURL_CA_BUNDLE stands in for the certificate being trusted machine-wide, which
# is the realistic way an unverified endpoint looks verified.
new_project; healthy_env "$P"
OUT="$(cd "$P" && "${SCRUB[@]}" PATH="$STUBBIN:$PATH" DOCKER_STUB_DIR="$P/.dockerstub" \
    PLATFORM_SYSROOT="$JETSON_SYSROOT" PLATFORM_NVIDIA_SMI="$NO_SMI" \
    VALIDATE_SELFTESTS=0 CURL_CA_BUNDLE="$P/certs/ca.crt" \
    bash "$P/scripts/validate.sh" --runtime --base "$HTTP_BASE" 2>&1)"
assert_fail "$OUT" "accepted a request without the CA" "an unenforced CA is caught"

new_project; healthy_env "$P"
rm -f "$P/certs/ca.crt"
run_jetson "$P" --runtime
assert_skip "$OUT" "no CA certificate" "a missing CA skips the TLS section"

# ══════════════════════════════════════════════════════════════════
case_start "Arguments and modes"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P"
run_jetson "$P" --bogus
assert_exit "$RC" 2 "an unknown option exits 2"
assert_contains "$OUT" "Unknown option" "names the problem"

OUT="$(cd "$P" && bash "$P/scripts/validate.sh" --base 2>&1)"; RC=$?
assert_exit "$RC" 2 "--base with no URL exits 2"

run_jetson "$P" --preflight
assert_not_contains "$OUT" "Runtime - " "--preflight runs no runtime checks"
assert_contains "$OUT" "Preflight - platform" "--preflight runs the static checks"

run_jetson "$P" --runtime
assert_not_contains "$OUT" "Preflight - " "--runtime runs no preflight checks"
assert_contains "$OUT" "Runtime - containers" "--runtime runs the live checks"

# A trailing slash on --base must not produce //health.
run_validate "$P" "$JETSON_SYSROOT" "$NO_SMI" --runtime --base "$HTTP_BASE/"
assert_pass "$OUT" "GET /health" "a trailing slash on --base is tolerated"

# The self-tests are the one thing that can be switched off, so it has to be
# visible in the output rather than silently reducing the count.
new_project; healthy_env "$P"
run_jetson "$P" --preflight
assert_skip "$OUT" "validation suite self-test" "a disabled self-test is reported as skipped"
assert_contains "$OUT" "VALIDATE_SELFTESTS=0" "and says why it was skipped"
assert_skip "$OUT" "benchmark self-test" "the other self-tests are skipped the same way"

# ══════════════════════════════════════════════════════════════════
case_start "The summary reflects the checks"
# ══════════════════════════════════════════════════════════════════
new_project; healthy_env "$P" "COMPOSE_FILE=docker-compose.yml" "MODEL_FILE=/models/gone.gguf"
run_jetson "$P" --preflight
assert_exit "$RC" 1 "exits 1 when checks fail"
NFAIL="$(grep -cE '^  FAIL  ' <<<"$OUT")"
NLISTED="$(sed -n '/Failed checks:/,$p' <<<"$OUT" | grep -cE '^    - ')"
assert_eq "$NLISTED" "$NFAIL" "every failed check is listed in the summary"
SUMMARY="$(grep -E '[0-9]+ passed, [0-9]+ failed' <<<"$OUT")"
assert_eq "$(sed -E 's/.* ([0-9]+) failed.*/\1/' <<<"$SUMMARY")" "$NFAIL" \
  "the summary count matches the failed checks"
assert_eq "$(sed -E 's/^ *([0-9]+) passed.*/\1/' <<<"$SUMMARY")" \
          "$(grep -cE '^  PASS  ' <<<"$OUT")" "the summary count matches the passed checks"

# ══════════════════════════════════════════════════════════════════
printf '\n────────────────────────────────────────\n'
if (( FAIL == 0 )); then
  printf '%sAll %d assertions passed.%s\n' "$C_OK" "$PASS" "$C_Z"
  exit 0
fi
printf '%s%d passed, %d failed%s\n' "$C_NO" "$PASS" "$FAIL" "$C_Z"
printf '  - %s\n' "${FAILED_NAMES[@]}"
exit 1
