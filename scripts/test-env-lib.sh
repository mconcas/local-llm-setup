#!/usr/bin/env bash
# test-env-lib.sh - Hermetic tests for scripts/lib/env.sh, the shared .env reader.
#
# Every script in this repo decides what to do from values this library returns:
# where the model lives, which compose file to merge, which image to run, how big
# the KV cache is. A reader that disagrees with compose does not produce a wrong
# message, it produces a *consistent and wrong* view of the deployment - every
# check goes green against a configuration the container never had.
#
# So the interesting half of this suite is differential: for each way a value can
# be written, it asks `docker compose config` what compose resolves and asserts
# the library returns the same string. Compose is the specification; a hand-
# written expectation would only pin what I believed compose does. The forms
# below were not guessed - each one was first observed to *diverge*:
#
#   MODELS_DIR='${HOME}/models'   compose keeps it literal; the reader expanded
#                                 it, so the model went to $HOME/models while
#                                 compose refused the project as a named volume
#   export MODELS_DIR=/data/x     compose honours the `export`; the reader
#                                 dropped the key, so every script used ./models
#                                 while the container mounted /data/x
#   MODELS_DIR=   /data/x         compose trims; the reader kept the spaces and
#                                 reported a valid path as a bare relative one
#   CTX_SIZE="4096" # tuned       compose strips both; the reader kept the quotes
#   A="$$5"                       `$$` is compose's escape for one '$'
#   A="l1\nl2"                    escapes, and either quote may span lines
#   A=${UNSET:?why}               compose refuses the whole project; the reader
#                                 invented an empty string for it
#
# `docker compose config` is client-side and never contacts the daemon, so the
# differential cases need no daemon, image, GPU, model or network - only the
# compose CLI, without which they are skipped with the reason printed. The unit
# cases below need nothing at all.
#
# Usage:
#   ./scripts/test-env-lib.sh          # run all cases
#   ./scripts/test-env-lib.sh -v       # also print each assertion
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

# assert_eq LABEL EXPECTED ACTUAL - compares printable renderings so a trailing
# space or a stray CR is visible in the failure rather than invisible in it.
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$(vis "$2")], got [$(vis "$3")]"; fi
}
assert_has() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "no [$2] in [$(vis "$3")]"; fi
}
vis() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\r/\\r/g' -e 's/\t/\\t/g' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'; }

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# The library under test is sourced into *this* shell. Every fixture points it
# at its own file through ENV_FILE, so nothing here reads the repo's real .env.
# shellcheck source=lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"

# The reader consults the process environment before the file, which is compose's
# own precedence - so the suite has to control that environment rather than
# inherit it. A host that has run setup.sh exports several of these names.
for v in MODELS_DIR MODEL_FILE COMPOSE_FILE LLAMA_IMAGE CTX_SIZE PARALLEL TARGET A B C D E U M; do
  unset "$v"
done
export HOME="${HOME:-/root}"

# write_env CONTENT - materialise a .env from a %b-interpreted string and point
# ENV_FILE at it. Returns the path.
ENV_N=0
write_env() {
  ENV_N=$((ENV_N+1))
  local d="$TMPROOT/env$ENV_N"
  mkdir -p "$d"
  printf '%b\n' "$1" >"$d/.env"
  ENV_FILE="$d/.env"
  printf '%s' "$d"
}

# ── Differential: the reader against compose itself ───────────────
#
# One compose project whose only job is to echo the value of TARGET back out.
# Both sides answer either a value or "the project cannot be read at all", and
# the assertion is that they answer the same thing.

DIFF_DIR="$TMPROOT/differential"
mkdir -p "$DIFF_DIR"
cat >"$DIFF_DIR/docker-compose.yml" <<'YAML'
services:
  probe:
    image: busybox
    environment:
      OUT: "${TARGET}"
YAML

HAVE_COMPOSE=0
if docker compose version >/dev/null 2>&1; then HAVE_COMPOSE=1; fi

# compose_says - what `docker compose config` resolves TARGET to, or ERR.
# The JSON rendering re-escapes a literal '$' as '$$'; undo that to recover the
# value the container would actually receive.
compose_says() {
  docker compose --project-directory "$DIFF_DIR" config --format json 2>/dev/null | python3 -c '
import json,sys
try:
  v = json.load(sys.stdin)["services"]["probe"]["environment"]["OUT"]
except Exception:
  print("ERR", end=""); sys.exit()
out=[]; i=0
while i < len(v):
  if v[i:i+2] == "$$": out.append("$"); i += 2
  else: out.append(v[i]); i += 1
print("VAL:" + "".join(out), end="")'
}

# lib_says - the same question asked of the library.
lib_says() {
  local reason
  if reason="$(env_check)"; then printf 'VAL:%s' "$(env_get TARGET)"
  else printf 'ERR'; fi
}

# assert_same_as_compose CONTENT - the whole point of this file.
assert_same_as_compose() {
  local content="$1" expect actual
  printf '%b\n' "$content" >"$DIFF_DIR/.env"
  ENV_FILE="$DIFF_DIR/.env"
  expect="$(compose_says)"
  actual="$(lib_says)"
  if [[ "$expect" == "$actual" ]]; then pass "$(vis "$content") -> $(vis "${expect#VAL:}")"
  else fail "$(vis "$content")" "compose says [$(vis "$expect")], the reader says [$(vis "$actual")]"; fi
}

case_start "Differential - quoting, against compose"
if (( HAVE_COMPOSE )); then
  assert_same_as_compose 'TARGET=plain'
  assert_same_as_compose 'TARGET="double quoted"'
  assert_same_as_compose "TARGET='single quoted'"
  assert_same_as_compose 'TARGET='
  assert_same_as_compose 'TARGET=""'
  assert_same_as_compose 'TARGET=   leading-space-is-trimmed'
  assert_same_as_compose 'TARGET=trailing-space-is-trimmed   '
  assert_same_as_compose 'TARGET=  "quoted after spaces"'
  assert_same_as_compose 'TARGET="quoted" and junk after the quote'
  assert_same_as_compose "TARGET='quoted' and junk after the quote"
  assert_same_as_compose 'TARGET = spaces around the equals'
  assert_same_as_compose 'TARGET=a"b'
  assert_same_as_compose "TARGET=it's"
else
  skipped "quoting rules (docker compose CLI not available)"
fi

case_start "Differential - comments, against compose"
if (( HAVE_COMPOSE )); then
  assert_same_as_compose 'TARGET=value # an inline comment'
  assert_same_as_compose 'TARGET=value#not-a-comment-without-a-space'
  assert_same_as_compose 'TARGET="quoted" # comment after a quoted value'
  assert_same_as_compose "TARGET='a # inside single quotes'"
  assert_same_as_compose 'TARGET="a # inside double quotes"'
  assert_same_as_compose '# TARGET=commented-out\nTARGET=real'
  assert_same_as_compose 'TARGET=first\n# TARGET=commented-out'
else
  skipped "comment rules (docker compose CLI not available)"
fi

case_start "Differential - export, records and precedence, against compose"
if (( HAVE_COMPOSE )); then
  assert_same_as_compose 'export TARGET=exported'
  assert_same_as_compose 'export   TARGET="exported and quoted"'
  assert_same_as_compose '\texport TARGET=indented-export'
  assert_same_as_compose 'A=1\nexport TARGET=${A}'
  assert_same_as_compose 'TARGET=first\nTARGET=last-wins'
  assert_same_as_compose '=novalue\nTARGET=x'
  assert_same_as_compose 'not a record at all\nTARGET=x'
  assert_same_as_compose '\nTARGET=after-a-blank-line'
  assert_same_as_compose 'TARGET=crlf-tolerated\r'
  assert_same_as_compose 'TARGET="crlf after a quote"\r'
else
  skipped "record rules (docker compose CLI not available)"
fi

case_start "Differential - interpolation, against compose"
if (( HAVE_COMPOSE )); then
  export B="from-the-environment"
  assert_same_as_compose 'TARGET=${B}'
  assert_same_as_compose 'B=from-the-file\nTARGET=${B}'   # the environment wins
  unset B
  assert_same_as_compose 'A=x\nTARGET=${A}/models'
  assert_same_as_compose 'A=x\nTARGET=$A$A'
  assert_same_as_compose 'A=x\nTARGET="${A}/models"'
  assert_same_as_compose "A=x\nTARGET='\${A}/models'"
  assert_same_as_compose 'TARGET=${UNSET_NAME}'
  assert_same_as_compose 'TARGET=${UNSET_NAME:-fallback}'
  assert_same_as_compose 'TARGET=${UNSET_NAME-fallback}'
  assert_same_as_compose 'E=\nTARGET=${E:-fallback}'
  assert_same_as_compose 'E=\nTARGET=${E-fallback}'
  assert_same_as_compose 'TARGET=${A:-${B:-nested}}'
  assert_same_as_compose 'TARGET=${A:-"quotes in a default"}'
  assert_same_as_compose 'TARGET=$$literal-dollar'
  assert_same_as_compose 'TARGET="$$literal-dollar"'
  assert_same_as_compose "TARGET='\$\$not-an-escape-in-single-quotes'"
  assert_same_as_compose 'TARGET=${A:-$$}'
  assert_same_as_compose 'TARGET=$'
  assert_same_as_compose 'TARGET=a$ b'
  assert_same_as_compose 'TARGET=$1notaname'
  assert_same_as_compose 'TARGET=$(id)'
  assert_same_as_compose 'TARGET=`id`'
else
  skipped "interpolation rules (docker compose CLI not available)"
fi

case_start "Differential - escapes and multi-line values, against compose"
if (( HAVE_COMPOSE )); then
  assert_same_as_compose 'TARGET="a\\"b"'
  assert_same_as_compose 'TARGET="a\\\\b"'
  assert_same_as_compose 'TARGET="a\\$b"'
  assert_same_as_compose 'TARGET="a\\nb"'
  assert_same_as_compose 'TARGET="a\\tb"'
  assert_same_as_compose 'TARGET="a\\qb"'
  assert_same_as_compose "TARGET='a\\\\nb'"
  assert_same_as_compose 'TARGET=a\\nb'
  assert_same_as_compose 'M="line1\nline2"\nTARGET=${M}'
  assert_same_as_compose "M='line1\nline2'\nTARGET=\${M}"
  assert_same_as_compose 'M="line1\nline2"\nTARGET=parsed-after-the-value'
  assert_same_as_compose "M='line1\nline2'\nTARGET=parsed-after-the-value"
else
  skipped "escape rules (docker compose CLI not available)"
fi

case_start "Differential - the forms compose refuses outright"
if (( HAVE_COMPOSE )); then
  assert_same_as_compose 'TARGET=${UNSET_NAME:?a stated reason}'
  assert_same_as_compose 'TARGET=${UNSET_NAME?a stated reason}'
  assert_same_as_compose 'E=\nTARGET=${E:?empty is missing for :?}'
  assert_same_as_compose 'TARGET=${}'
  assert_same_as_compose 'TARGET=${UNTERMINATED'
  assert_same_as_compose "TARGET='unterminated single quote"
  assert_same_as_compose 'TARGET="unterminated double quote'
  # A value that IS set satisfies the required form, and the project is fine.
  assert_same_as_compose 'A=x\nTARGET=${A:?must be set}'
  assert_same_as_compose 'E=\nTARGET=${E?empty counts as set for ?}'
else
  skipped "fatal forms (docker compose CLI not available)"
fi

# ── Unit: what the reader reports, not just what it resolves ──────
#
# The differential cases prove the two agree. These pin the surface the scripts
# in this repo actually consume: the reason string, the exit code, which keys
# env_load exports, and the bind-source rules compose has no CLI answer for.

case_start "env_check names the reason compose will refuse the file"
write_env 'MODELS_DIR=${NOPE:?set this first}' >/dev/null
if reason="$(env_check)"; then
  fail "a required-variable form is reported" "env_check returned 0"
else
  pass "a required-variable form is reported"
  assert_has "the reason names the variable" "NOPE" "$reason"
  assert_has "the reason carries the author's message" "set this first" "$reason"
fi

write_env 'MODELS_DIR=/data/models' >/dev/null
if reason="$(env_check)"; then pass "a readable .env is not reported"
else fail "a readable .env is not reported" "$reason"; fi
assert_eq "and prints nothing" "" "$reason"

write_env 'MODELS_DIR="/data/models' >/dev/null
reason="$(env_check)" && fail "an unterminated quote is reported" "env_check returned 0" || pass "an unterminated quote is reported"
assert_has "the reason names the key" "MODELS_DIR" "$reason"

write_env 'MODELS_DIR=${HOME/models' >/dev/null
reason="$(env_check)" && fail "an unterminated brace is reported" "env_check returned 0" || pass "an unterminated brace is reported"
assert_has "the reason names the construct" '${' "$reason"

# A file that does not exist is not an error: setup.sh runs before there is one.
ENV_FILE="$TMPROOT/nonexistent/.env"
if reason="$(env_check)"; then pass "a missing .env is not a fatal error"
else fail "a missing .env is not a fatal error" "$reason"; fi
assert_eq "and reads as empty" "" "$(env_get MODELS_DIR)"

# The state must not leak between reads: a fatal file followed by a clean one.
write_env 'A=${NOPE:?boom}' >/dev/null
env_check >/dev/null
write_env 'A=fine' >/dev/null
if env_check >/dev/null; then pass "a later clean file clears the earlier reason"
else fail "a later clean file clears the earlier reason" "ENV_FATAL=$ENV_FATAL"; fi

case_start "env_load exports what compose would see"
write_env 'MODELS_DIR=/data/models\nCTX_SIZE="4096" # tuned for 8GB\nexport PARALLEL=2\nLLAMA_IMAGE=${IMG:-dustynv/llama_cpp:r36}' >/dev/null
env_load
assert_eq "an ordinary value" "/data/models" "${MODELS_DIR:-}"
assert_eq "a quoted value with a trailing comment" "4096" "${CTX_SIZE:-}"
assert_eq "an exported key" "2" "${PARALLEL:-}"
assert_eq "a defaulted value" "dustynv/llama_cpp:r36" "${LLAMA_IMAGE:-}"
unset MODELS_DIR CTX_SIZE PARALLEL LLAMA_IMAGE

# Nothing in .env may run, whatever it contains.
write_env 'MODELS_DIR=$(touch '"$TMPROOT"'/pwned)\nOTHER=`touch '"$TMPROOT"'/pwned2`' >/dev/null
env_load >/dev/null 2>&1
if [[ -e "$TMPROOT/pwned" || -e "$TMPROOT/pwned2" ]]; then
  fail "a command substitution in a value is data, not code" "the file was created"
else
  pass "a command substitution in a value is data, not code"
fi
assert_eq "and survives as text" '$(touch '"$TMPROOT"'/pwned)' "${MODELS_DIR:-}"
unset MODELS_DIR OTHER

case_start "env_bind_path - what compose bind-mounts"
ENV_PROJECT_DIR="/opt/proj"
assert_eq "an absolute path is itself" "/data/models" "$(env_bind_path /data/models)"
assert_eq "./ resolves against the project" "/opt/proj/models" "$(env_bind_path ./models)"
assert_eq "../ resolves against the project" "/opt/models" "$(env_bind_path ../models)"
assert_eq "a lexical .. is collapsed" "/opt/proj/b" "$(env_bind_path ./a/../b)"
# Compose cleans a relative or ~ path and leaves an absolute one byte for byte.
assert_eq "an absolute path keeps its duplicate slashes" "//data//models//" "$(env_bind_path //data//models//)"
assert_eq "an absolute path keeps a lexical .." "/data/../models" "$(env_bind_path /data/../models)"
assert_eq "a relative path is cleaned" "/opt/proj/a/b" "$(env_bind_path ./a//b)"
assert_eq "a ~ path is cleaned" "$HOME/b" "$(env_bind_path '~/a/../b')"
assert_eq "a leading ~ expands" "$HOME/models" "$(env_bind_path '~/models')"
assert_eq "a bare ~ is the home directory" "$HOME" "$(env_bind_path '~')"
assert_eq "an empty value is empty" "" "$(env_bind_path '')"
if out="$(env_bind_path models 2>&1)"; then
  fail "a bare relative path is refused" "returned 0 with [$out]"
else
  pass "a bare relative path is refused"
  assert_has "and says compose reads it as a named volume" "named volume" "$out"
  assert_has "and gives the working form" "./models" "$out"
fi
if out="$(env_bind_path '~user/models' 2>&1)"; then
  fail "~user is refused" "returned 0 with [$out]"
else pass "~user is refused"; fi
if out="$(env_bind_path 'lit$eral' 2>&1)"; then
  fail "a relative path with a \$ is refused" "returned 0 with [$out]"
else pass "a relative path with a \$ is refused"; fi
assert_eq "an absolute path may contain a literal \$" '/data/a$b' "$(env_bind_path '/data/a$b')"
unset ENV_PROJECT_DIR

case_start "env_bind_path against compose's own resolution"
if (( HAVE_COMPOSE )); then
  BIND_DIR="$TMPROOT/bind"
  mkdir -p "$BIND_DIR"
  cat >"$BIND_DIR/docker-compose.yml" <<'YAML'
services:
  probe:
    image: busybox
    volumes:
      - ${MODELS_DIR}:/models:ro
YAML
  bind_case() {
    local raw="$1" theirs ours
    printf 'MODELS_DIR=%s\n' "$raw" >"$BIND_DIR/.env"
    theirs="$(docker compose --project-directory "$BIND_DIR" config --format json 2>/dev/null | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["services"]["probe"]["volumes"][0]["source"], end="")
except Exception: print("REFUSED", end="")')"
    ENV_FILE="$BIND_DIR/.env"
    ENV_PROJECT_DIR="$BIND_DIR"
    if ours="$(env_bind_path "$(env_get MODELS_DIR)" 2>/dev/null)"; then :; else ours="REFUSED"; fi
    unset ENV_PROJECT_DIR
    assert_eq "MODELS_DIR=$raw" "$theirs" "$ours"
  }
  bind_case "/data/models"
  bind_case "./models"
  bind_case "./a/../models"
  bind_case "../models"
  bind_case '~/models'
  bind_case 'models'
  bind_case '${HOME}/models'
  bind_case "/data//models/"
else
  skipped "bind-source resolution (docker compose CLI not available)"
fi

case_start "the reader is not confused by this repo's own .env.example"
EX="$(cd "$SCRIPT_DIR/.." && pwd)/.env.example"
if [[ -f "$EX" ]]; then
  ENV_FILE="$EX"
  if reason="$(env_check)"; then pass ".env.example is readable by compose"
  else fail ".env.example is readable by compose" "$reason"; fi
  for k in MODELS_DIR MODEL_FILE COMPOSE_FILE LLAMA_IMAGE CTX_SIZE PARALLEL; do
    v="$(env_get "$k")"
    if [[ -n "$v" ]]; then pass "$k has a value"; else fail "$k has a value" "empty"; fi
    case "$v" in
      *'#'*) fail "$k did not absorb a comment" "[$(vis "$v")]" ;;
      *)     pass "$k did not absorb a comment" ;;
    esac
  done
  assert_eq "MODELS_DIR is a form compose can bind-mount" \
    "0" "$(ENV_PROJECT_DIR=/opt/proj env_bind_path "$(env_get MODELS_DIR)" >/dev/null 2>&1; echo $?)"
else
  skipped ".env.example is present"
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
