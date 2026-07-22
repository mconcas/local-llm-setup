#!/usr/bin/env bash
# test-compose.sh - Hermetic tests for the deployment configuration.
#
# Every other self-test in this repo drives a shell script. This one drives the
# two files the shell scripts only ever talk *about*: docker-compose.yml plus
# its Jetson overlay, and nginx/nginx.conf. They are the part of the stack a
# user actually runs, they have no test of their own, and both fail in ways that
# name something other than themselves:
#
#   - the overlay's `!reset` tag is a compose *feature*; an older compose does
#     not ignore it, it refuses to parse the project and names a YAML tag
#   - a bind source is not a shell path: compose expands a leading `~` and
#     treats a bare relative path as a named volume, so MODELS_DIR can point the
#     scripts and the container at two different directories with no error
#   - nginx defaults to a 1 MiB request body, so a long prompt is rejected by
#     the proxy with a 413 that llama.cpp never sees - and the same request
#     succeeds against the raw 127.0.0.1:8080 port
#
# The compose half needs only the compose CLI (`docker compose config` is
# client-side and never contacts the daemon). The nginx half runs the real
# nginx.conf in a container against a stub upstream; it is skipped, with the
# reason printed, when the daemon or the nginx image is unavailable. No GPU, no
# model and no network are needed either way.
#
# Usage:
#   ./scripts/test-compose.sh          # run all cases
#   ./scripts/test-compose.sh -v       # also print each assertion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
# assert_has LABEL NEEDLE HAYSTACK
assert_has() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "no [$2] in output"; fi
}
# assert_lacks LABEL NEEDLE HAYSTACK
assert_lacks() {
  if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1" "unexpected [$2] in output"; fi
}

TMPROOT="$(mktemp -d)"
CONTAINERS=()
NETWORK=""
cleanup() {
  local c
  for c in "${CONTAINERS[@]:-}"; do [[ -n "$c" ]] && docker rm -f "$c" >/dev/null 2>&1; done
  [[ -n "$NETWORK" ]] && docker network rm "$NETWORK" >/dev/null 2>&1
  rm -rf "$TMPROOT"
}
trap cleanup EXIT INT TERM

# ── Fixtures ──────────────────────────────────────────────────────
# A project directory holding the real compose files and the directories they
# bind-mount, plus whatever .env the case needs. The compose files are copied
# rather than symlinked: compose resolves `./templates` and `./nginx/nginx.conf`
# against the project directory, so a fixture that symlinked them would silently
# mount the repo's own directories.
PROJ_N=0
new_project() {
  PROJ_N=$((PROJ_N+1))
  PROJ="$TMPROOT/proj$PROJ_N"
  mkdir -p "$PROJ/models" "$PROJ/templates" "$PROJ/nginx" "$PROJ/certs"
  cp "$PROJECT_DIR/docker-compose.yml" "$PROJECT_DIR/docker-compose.jetson.yml" "$PROJ/"
  cp "$PROJECT_DIR/nginx/nginx.conf" "$PROJ/nginx/"
  : >"$PROJ/.env"
}

# compose_config [VAR=VAL ...] - render the merged config for $PROJ.
#
# The environment is scrubbed to PATH/HOME. This matters more than it looks:
# the caller's shell may already export MODELS_DIR, COMPOSE_FILE or LLAMA_IMAGE
# (validate.sh does exactly that before running this test), and an environment
# variable overrides the .env entry under test - so an unscrubbed run would
# quietly render the *host's* configuration and pass.
compose_config() {
  (cd "$PROJ" && env -i PATH="$PATH" HOME="$HOME" "$@" docker compose config 2>&1)
}

# mount_source YAML TARGET - the host path compose resolved for a bind mount.
mount_source() {
  awk -v want="$2" '
    $1 == "source:" { src = $2 }
    $1 == "target:" && $2 == want { print src; exit }
  ' <<<"$1"
}

# mount_ro YAML TARGET - the read_only flag of one mount ("" if absent).
#
# Per mount, deliberately: asserting that "read_only: true" appears somewhere in
# the service passes while the models mount is writable, because the templates
# mount is read-only too.
mount_ro() {
  awk -v want="$2" '
    $1 == "-" && $2 == "type:" { inmount = 0 }
    $1 == "target:" && $2 == want { inmount = 1; next }
    inmount && $1 == "read_only:" { print $2; exit }
  ' <<<"$1"
}

# service_block YAML NAME - one service'"'"'s section of the rendered config.
service_block() {
  awk -v svc="  $2:" '
    $0 == svc { inblk = 1; next }
    inblk && /^  [a-z]/ { exit }
    inblk { print }
  ' <<<"$1"
}

# ── Case 1: base file on a discrete-GPU host ──────────────────────
case_start "base compose file (x86_64 / discrete GPU)"
new_project
CFG="$(compose_config)"

assert_has "config renders" "llama-server:" "$CFG"
assert_has "reserves an nvidia device the legacy way" "driver: nvidia" "$CFG"
assert_has "requests every GPU (count: all renders as -1)" "count: -1" "$CFG"
assert_lacks "no CDI device request" "nvidia.com/gpu=all" "$CFG"
assert_has "default image is the upstream multi-arch build" \
  "image: ghcr.io/ggml-org/llama.cpp:server-cuda" "$CFG"

LL="$(service_block "$CFG" llama-server)"
assert_has "raw port is published on loopback only" "host_ip: 127.0.0.1" "$LL"
assert_lacks "raw port is not published on all interfaces" "host_ip: 0.0.0.0" "$LL"
assert_has "raw port is 8080" 'published: "8080"' "$LL"
assert_eq "models bind source" "$PROJ/models" "$(mount_source "$LL" /models)"
assert_eq "templates bind source" "$PROJ/templates" "$(mount_source "$LL" /templates)"
assert_eq "model mount is read-only" "true" "$(mount_ro "$LL" /models)"
assert_eq "template mount is read-only" "true" "$(mount_ro "$LL" /templates)"
assert_has "cold start gets 120s of grace" "start_period: 2m0s" "$LL"
assert_has "health check hits /health" "curl -sf http://localhost:8080/health" "$LL"

NG="$(service_block "$CFG" nginx)"
assert_eq "nginx.conf bind source" "$PROJ/nginx/nginx.conf" "$(mount_source "$NG" /etc/nginx/nginx.conf)"
assert_eq "certs bind source" "$PROJ/certs" "$(mount_source "$NG" /etc/nginx/certs)"
assert_eq "nginx.conf is mounted read-only" "true" "$(mount_ro "$NG" /etc/nginx/nginx.conf)"
assert_eq "the private key is mounted read-only" "true" "$(mount_ro "$NG" /etc/nginx/certs)"
assert_has "proxy waits for a healthy server" "condition: service_healthy" "$NG"
assert_has "HTTPS port defaults to 8443" 'published: "8443"' "$NG"
assert_has "HTTPS port maps to 443" "target: 443" "$NG"

# Defaults must hold with an empty .env - these are what a user who never edits
# the file actually runs with.
assert_has "default context window" 'LLAMA_ARG_CTX_SIZE: "4096"' "$LL"
assert_has "default slot count" 'LLAMA_ARG_N_PARALLEL: "4"' "$LL"
assert_has "default offload is every layer" 'LLAMA_ARG_N_GPU_LAYERS: "-1"' "$LL"
assert_has "default model path" "LLAMA_ARG_MODEL: /models/model.gguf" "$LL"
assert_has "jinja templating on (tool calls)" 'LLAMA_ARG_JINJA: "1"' "$LL"
# llama.cpp reads --parallel from LLAMA_ARG_N_PARALLEL; LLAMA_ARG_PARALLEL is
# accepted silently and ignored, which left the slot count at its auto default.
assert_lacks "slot count does not use the ignored name" "LLAMA_ARG_PARALLEL:" "$LL"

# ── Case 2: Jetson overlay ────────────────────────────────────────
case_start "Jetson overlay"
new_project
cat >"$PROJ/.env" <<'EOF'
COMPOSE_FILE=docker-compose.yml:docker-compose.jetson.yml
LLAMA_IMAGE=ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin
CTX_SIZE=2048
PARALLEL=1
CACHE_TYPE_K=q8_0
CACHE_TYPE_V=q8_0
MODEL_FILE=/models/qwen.gguf
HTTPS_PORT=9443
EOF
CFG="$(compose_config)"
LL="$(service_block "$CFG" llama-server)"

# COMPOSE_FILE is read by compose itself from .env - no wrapper needed, which is
# what makes the documented `docker compose up -d` correct on a Jetson.
assert_has "overlay is applied from COMPOSE_FILE in .env" "nvidia.com/gpu=all" "$LL"
assert_lacks "legacy nvidia reservation is cleared by !reset" "driver: nvidia" "$CFG"
assert_has "reservations survive as an empty block" "reservations: {}" "$LL"
assert_has "entrypoint points at the server binary" "/usr/local/bin/llama-server" "$LL"
assert_has "cold start gets 300s of grace" "start_period: 5m0s" "$LL"
assert_has "Jetson image is used" "image: ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin" "$LL"

# The overlay must not lose anything the base file set.
assert_eq "models mount survives the overlay" "$PROJ/models" "$(mount_source "$LL" /models)"
assert_has "loopback-only raw port survives the overlay" "host_ip: 127.0.0.1" "$LL"
assert_has "context window from .env" 'LLAMA_ARG_CTX_SIZE: "2048"' "$LL"
assert_has "slot count from .env" 'LLAMA_ARG_N_PARALLEL: "1"' "$LL"
assert_has "K cache quantisation from .env" "LLAMA_ARG_CACHE_TYPE_K: q8_0" "$LL"
assert_has "V cache quantisation from .env" "LLAMA_ARG_CACHE_TYPE_V: q8_0" "$LL"
assert_has "model file from .env" "LLAMA_ARG_MODEL: /models/qwen.gguf" "$LL"
assert_has "HTTPS port from .env" 'published: "9443"' "$(service_block "$CFG" nginx)"
assert_has "proxy still waits for health" "condition: service_healthy" "$(service_block "$CFG" nginx)"

# Applied by hand, in the order the overlay's own header documents.
CFG2="$(cd "$PROJ" && env -i PATH="$PATH" HOME="$HOME" \
        docker compose -f docker-compose.yml -f docker-compose.jetson.yml config 2>&1)"
assert_has "-f -f gives the same GPU wiring" "nvidia.com/gpu=all" "$CFG2"
assert_lacks "-f -f clears the legacy reservation too" "driver: nvidia" "$CFG2"

# Order matters: the overlay alone is not a project, and applying it first would
# let the base file put the legacy reservation back.
CFG3="$(cd "$PROJ" && env -i PATH="$PATH" HOME="$HOME" \
        docker compose -f docker-compose.jetson.yml -f docker-compose.yml config 2>&1)"
assert_has "reversed order reintroduces the legacy path" "driver: nvidia" "$CFG3"

# ── Case 3: !reset is doing the work, not the merge order ─────────
# The overlay's whole reason to exist is that the base file's GPU reservation
# must be *removed*, not overridden - requesting the GPU twice reintroduces the
# hang CDI avoids. Compose merges lists by appending, so without the tag the
# reservation survives. Assert both halves against the same synthetic pair, so
# "the reservation is gone" cannot pass for the wrong reason.
case_start "!reset clears the inherited device reservation"
mkdir -p "$TMPROOT/reset"
printf 'services:\n  a:\n    image: x\n    deploy: {resources: {reservations: {devices: [{driver: nvidia, count: all, capabilities: [gpu]}]}}}\n' \
  >"$TMPROOT/reset/docker-compose.yml"
printf 'services:\n  a:\n    deploy: {resources: {reservations: {devices: !reset []}}}\n    devices: ["nvidia.com/gpu=all"]\n' \
  >"$TMPROOT/reset/over-reset.yml"
printf 'services:\n  a:\n    deploy: {resources: {reservations: {devices: []}}}\n    devices: ["nvidia.com/gpu=all"]\n' \
  >"$TMPROOT/reset/over-plain.yml"
reset_cfg() {
  (cd "$TMPROOT/reset" && env -i PATH="$PATH" HOME="$HOME" \
     docker compose -f docker-compose.yml -f "$1" config 2>&1)
}
RC="$(reset_cfg over-reset.yml)"
assert_lacks "with !reset the legacy reservation is gone" "driver: nvidia" "$RC"
assert_has "with !reset the CDI request remains" "nvidia.com/gpu=all" "$RC"
RP="$(reset_cfg over-plain.yml)"
assert_has "without !reset the legacy reservation survives" "driver: nvidia" "$RP"

# ── Case 4: MODELS_DIR is a bind source, not a shell path ─────────
# A differential test: for every legal (and one illegal) form of MODELS_DIR,
# what lib/env.sh tells the scripts must be what compose actually mounts. This
# is the check that would have caught `MODELS_DIR=~/models` sending several GB
# to a directory literally named '~' while the container mounted an empty
# $HOME/models - with every script reporting the model as present.
case_start "MODELS_DIR resolves the same for the scripts and for compose"
new_project
. "$PROJECT_DIR/scripts/lib/env.sh"
ENV_PROJECT_DIR="$PROJ"   # what compose resolves a relative bind source against

check_models_dir() {  # raw value, expected host path ("" = compose must refuse)
  local raw="$1" want="$2" got_env="" got_compose="" rc=0
  printf 'MODELS_DIR=%s\n' "$raw" >"$PROJ/.env"
  local cfg; cfg="$(compose_config)"
  got_compose="$(mount_source "$cfg" /models)"

  ENV_FILE="$PROJ/.env"
  local value; value="$(env_get MODELS_DIR)"
  got_env="$(env_bind_path "$value" 2>/dev/null)" || rc=1

  if [[ -z "$want" ]]; then
    if [[ -n "$got_compose" ]]; then
      fail "compose refuses [$raw]" "it mounted $got_compose"
    else
      assert_has "compose reports [$raw] as an undefined volume" "undefined volume" "$cfg"
    fi
    (( rc == 1 )) && pass "env_bind_path refuses [$raw]" \
                  || fail "env_bind_path refuses [$raw]" "it returned $got_env"
  else
    assert_eq "compose mounts [$raw] at $want" "$want" "$got_compose"
    assert_eq "env_bind_path agrees for [$raw]" "$want" "$got_env"
  fi
}

check_models_dir './models'            "$PROJ/models"
check_models_dir "$TMPROOT/data"       "$TMPROOT/data"
check_models_dir '~/models'            "$HOME/models"
check_models_dir '${HOME}/models'      "$HOME/models"
check_models_dir '$HOME/models'        "$HOME/models"
check_models_dir '${NOPE:-./models}'   "$PROJ/models"
check_models_dir './models  # inline'  "$PROJ/models"
check_models_dir '"./models"'          "$PROJ/models"
check_models_dir 'models'              ""

# A CRLF line ending is invisible in every error message it causes.
printf 'MODELS_DIR=./models\r\n' >"$PROJ/.env"
CFG="$(compose_config)"
assert_eq "CRLF .env still mounts ./models" "$PROJ/models" "$(mount_source "$CFG" /models)"
ENV_FILE="$PROJ/.env"
assert_eq "env_bind_path agrees on a CRLF .env" "$PROJ/models" "$(env_bind_path "$(env_get MODELS_DIR)")"

# `..` is collapsed lexically by compose, and a symlink in the path is *not*
# resolved - so the reader must not use realpath, which would resolve it.
printf 'MODELS_DIR=./templates/../models\n' >"$PROJ/.env"
assert_eq "compose collapses .. in a bind source" "$PROJ/models" "$(mount_source "$(compose_config)" /models)"
assert_eq "env_bind_path collapses .. the same way" "$PROJ/models" "$(env_bind_path "$(env_get MODELS_DIR)")"
ln -sfn "$TMPROOT/data" "$PROJ/modlink"
printf 'MODELS_DIR=./modlink\n' >"$PROJ/.env"
assert_eq "compose leaves a symlinked bind source alone" "$PROJ/modlink" "$(mount_source "$(compose_config)" /models)"
assert_eq "env_bind_path leaves it alone too" "$PROJ/modlink" "$(env_bind_path "$(env_get MODELS_DIR)")"

# The interpolation the scripts do must match compose's, because the scripts
# export what they read and an exported value *overrides* the .env entry it came
# from - so getting this wrong changes what compose itself resolves.
printf 'BASE=%s\nMODELS_DIR=${BASE}/models\n' "$TMPROOT/data" >"$PROJ/.env"
CFG="$(compose_config)"
assert_eq "compose chains one .env key into another" "$TMPROOT/data/models" "$(mount_source "$CFG" /models)"
ENV_FILE="$PROJ/.env"
assert_eq "env_get chains the same way" "$TMPROOT/data/models" "$(env_get MODELS_DIR)"
# ... and re-exporting what was read must not change the answer.
CFG="$(cd "$PROJ" && env -i PATH="$PATH" HOME="$HOME" MODELS_DIR="$(env_get MODELS_DIR)" \
       docker compose config 2>&1)"
assert_eq "an exported MODELS_DIR resolves identically" "$TMPROOT/data/models" "$(mount_source "$CFG" /models)"

# Nothing in a value is executed, by compose or by the reader.
printf 'MODELS_DIR=./models$(touch %s/PWNED)\n' "$TMPROOT" >"$PROJ/.env"
ENV_FILE="$PROJ/.env"; env_get MODELS_DIR >/dev/null
compose_config >/dev/null
[[ -e "$TMPROOT/PWNED" ]] && fail "a command substitution in .env is not executed" \
                          || pass "a command substitution in .env is not executed"
unset ENV_FILE

# ── Case 5: an invalid .env fails before anything starts ──────────
case_start "invalid configuration is refused, not half-applied"
new_project
printf 'MODELS_DIR=models\n' >"$PROJ/.env"
CFG="$(compose_config)"
assert_has "a bare relative MODELS_DIR invalidates the project" "invalid compose project" "$CFG"
assert_lacks "nothing is rendered for it" "container_name: llama-server" "$CFG"

new_project
printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.missing.yml\n' >"$PROJ/.env"
CFG="$(compose_config)"
assert_has "a missing overlay is named" "docker-compose.missing.yml" "$CFG"

# ── Case 6: nginx.conf, running ───────────────────────────────────
# The proxy is the only network-facing part of the stack, and its defaults are
# the kind that pass every static reading: a 1 MiB body limit is not visible in
# a config file that does not mention bodies. So run it.
case_start "nginx proxy behaviour"

NGINX_IMAGE="nginx:alpine"
if ! docker info >/dev/null 2>&1; then
  skipped "docker daemon unavailable - nginx behaviour not exercised"
elif ! docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
  skipped "$NGINX_IMAGE not present locally - nginx behaviour not exercised"
else
  ND="$TMPROOT/nginx"
  mkdir -p "$ND/certs"
  # A self-signed CA-flagged certificate: enough for a real handshake that curl
  # can verify with --cacert. Certificate *generation* is gen-certs.sh's own
  # test; what is under test here is the server block that loads one.
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -keyout "$ND/certs/server.key" -out "$ND/certs/server.crt" \
    -subj "/CN=llama-test" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1

  # Stub upstream: answers any path, accepts any body size, and echoes back the
  # headers the proxy is supposed to add. Same image as the proxy, so this
  # pulls nothing.
  cat >"$ND/upstream.conf" <<'EOF'
events { worker_connections 32; }
http {
  server {
    listen 8080;
    client_max_body_size 0;
    location /health { return 200 "OK"; }
    location / {
      add_header Content-Type application/json;
      return 200 '{"len":"$content_length","proto":"$http_x_forwarded_proto","host":"$http_host"}';
    }
  }
}
EOF

  NETWORK="llmtest-$$"
  docker network create "$NETWORK" >/dev/null 2>&1
  UP="llmtest-up-$$"; PX="llmtest-px-$$"
  CONTAINERS+=("$UP" "$PX")
  docker run -d --name "$UP" --network "$NETWORK" --network-alias llama-server \
    -v "$ND/upstream.conf:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE" >/dev/null 2>&1

  start_proxy() {  # $1 = nginx.conf to mount
    docker rm -f "$PX" >/dev/null 2>&1
    docker run -d --name "$PX" --network "$NETWORK" -p 127.0.0.1::443 \
      -v "$1:/etc/nginx/nginx.conf:ro" -v "$ND/certs:/etc/nginx/certs:ro" \
      "$NGINX_IMAGE" >/dev/null 2>&1
    PORT="$(docker port "$PX" 443/tcp 2>/dev/null | head -1)"; PORT="${PORT##*:}"
    local i
    for i in $(seq 40); do
      curl -sk --max-time 2 "https://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
      sleep 0.25
    done
    return 1
  }

  if start_proxy "$PROJECT_DIR/nginx/nginx.conf"; then
    pass "the repo's nginx.conf loads and serves TLS"
    BASE="https://127.0.0.1:$PORT"

    assert_eq "/health is proxied" "OK" "$(curl -sk --max-time 5 "$BASE/health")"

    RESP="$(curl -sk --max-time 5 -X POST "$BASE/v1/chat/completions" \
            -H 'Content-Type: application/json' -d '{"messages":[]}')"
    assert_has "a small POST reaches the upstream" '"len":"15"' "$RESP"
    assert_has "X-Forwarded-Proto says https" '"proto":"https"' "$RESP"

    # The defect: a prompt larger than nginx's 1 MiB default was rejected by the
    # proxy with a 413 the server never saw, while the same request succeeded on
    # 127.0.0.1:8080.
    python3 -c "
import sys, json
sys.stdout.write(json.dumps({'messages':[{'role':'user','content':'x'*3000000}]}))" >"$ND/big.json"
    CODE="$(curl -sk --max-time 20 -o "$ND/big.out" -w '%{http_code}' -X POST \
            "$BASE/v1/chat/completions" -H 'Content-Type: application/json' \
            --data-binary @"$ND/big.json")"
    assert_eq "a 3 MB prompt is forwarded, not rejected" "200" "$CODE"

    # And the limit is what makes the difference - without the directive the
    # very same request is a 413, so this is not an assertion that cannot fail.
    grep -v 'client_max_body_size' "$PROJECT_DIR/nginx/nginx.conf" >"$ND/nolimit.conf"
    if start_proxy "$ND/nolimit.conf"; then
      CODE="$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
              "https://127.0.0.1:$PORT/v1/chat/completions" \
              -H 'Content-Type: application/json' --data-binary @"$ND/big.json")"
      assert_eq "without client_max_body_size the same prompt is a 413" "413" "$CODE"
    else
      fail "nginx.conf without client_max_body_size still starts"
    fi

    # TLS: a client that trusts the certificate must succeed, and one that does
    # not must fail. The second half is what a proxy serving plaintext would
    # also pass, so both are asserted.
    start_proxy "$PROJECT_DIR/nginx/nginx.conf" >/dev/null
    BASE="https://127.0.0.1:$PORT"
    if curl -s --max-time 5 --cacert "$ND/certs/server.crt" "https://127.0.0.1:$PORT/health" >/dev/null; then
      pass "a client trusting the certificate connects"
    else
      fail "a client trusting the certificate connects"
    fi
    if curl -s --max-time 5 "$BASE/health" >/dev/null 2>&1; then
      fail "an untrusting client is refused" "curl verified an unknown certificate"
    else
      pass "an untrusting client is refused"
    fi
  else
    fail "the repo's nginx.conf loads and serves TLS" "$(docker logs "$PX" 2>&1 | tail -3)"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────
printf '\n%s────────────────────────────────────────%s\n' "$C_HD" "$C_Z"
if (( FAIL == 0 )); then
  printf '%sAll %d assertions passed%s' "$C_OK" "$PASS" "$C_Z"
  (( SKIP )) && printf ' (%d skipped)' "$SKIP"
  printf '\n'
  exit 0
else
  printf '%s%d/%d assertions failed%s\n' "$C_NO" "$FAIL" "$((PASS+FAIL))" "$C_Z"
  printf '  %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
