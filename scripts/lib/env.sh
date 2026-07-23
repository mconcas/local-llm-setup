# lib/env.sh - Read .env with compose's semantics.
#
# Sourced by setup.sh, download-model.sh, validate.sh and benchmark.sh.
# Deliberately not `source .env`, and deliberately not `sed 's/^KEY=//'`.
#
# .env is compose syntax, not shell. `source` *executes* it, so a value that is
# perfectly legal to compose - one containing whitespace, a bare parenthesis, a
# backtick or `$(...)` - is a syntax error, a lost key or an executed command.
# A bare sed is the opposite failure: a documented inline comment or a CRLF line
# ending stays *inside* the value, which is invisible in a path until several GB
# have landed in a directory nothing mounts, and which turns a mismatch report
# into two identical-looking strings.
#
# Compose is the specification here, not a description of it: every rule below
# was read off `docker compose config` and is pinned by a differential case in
# scripts/test-env-lib.sh, which asks compose the same question and compares.
#
# Grammar (compose v2 / compose-go's dotenv):
#   - a record is [export] KEY [spaces] = [spaces] VALUE; a line that does not
#     match that shape is ignored, as is a comment line and a blank one
#   - the last assignment of a key wins
#   - a single-quoted value is literal: no interpolation, no escapes
#   - a double-quoted value expands \n \r \t \" \\ \$ and is interpolated
#   - either quoted form may span lines, and anything after the closing quote on
#     that line is discarded
#   - an unquoted value ends at the end of the line or at the first
#     whitespace-preceded '#', and loses its surrounding whitespace
#   - `$$` is compose's escape for a literal '$'
#   - ${VAR} / $VAR / ${VAR:-d} / ${VAR-d} interpolate, from the process
#     environment first and then from keys assigned earlier in the file
#   - ${VAR:?msg}, ${VAR?msg}, ${}, an unterminated ${ and an unterminated quote
#     make compose refuse the whole project; see ENV_FATAL below
#   - CRLF line endings are tolerated
#
# Callers set ENV_FILE to the .env they mean; it defaults to ./.env.
#
# ENV_FATAL is set by env_parse to the first reason `docker compose` will refuse
# to read the file at all, or to the empty string when there is none. Parsing
# continues on a best-effort basis so a caller can still report what it found,
# but a caller that is about to act on a value should say so: every other check
# in this repo is meaningless against a project compose will not start. Because
# env_get and env_check run in a command substitution in most callers, read the
# reason with `env_check`, which prints it, rather than the variable.

ENV_FATAL=""
ENV_INTERP=""
ENV_UNESC=""
ENV_BRACED=""

# _env_fatal MSG - record the first reason only; later ones are consequences.
_env_fatal() { [[ -n "$ENV_FATAL" ]] || ENV_FATAL="$1"; }

# env_lookup NAME MAPNAME [EMPTY_IS_SET] - print NAME's value, rc=1 when the
# caller's default should be used instead. Process environment first, then keys
# read earlier in the file - compose's own precedence.
env_lookup() {
  local name="$1" mapname="${2:-}" empty_ok="${3:-1}" val="" set=0
  if [[ -n "${!name+x}" ]]; then
    val="${!name}"; set=1
  elif [[ -n "$mapname" ]]; then
    local -n _env_lookup_map="$mapname"
    if [[ -n "${_env_lookup_map[$name]+x}" ]]; then val="${_env_lookup_map[$name]}"; set=1; fi
  fi
  printf '%s' "$val"
  (( set )) && { (( empty_ok )) || [[ -n "$val" ]]; }
}

# _env_interp VALUE [MAPNAME] - the implementation of env_interpolate, which
# answers in the global ENV_INTERP rather than on stdout.
#
# Deliberately not a command substitution: a `${VAR:?}` anywhere in the file is
# fatal to compose, and a fatal recorded inside `$(...)` dies with the subshell
# that recorded it. Answering in a global also keeps a trailing newline in a
# multi-line value, which `$(...)` would strip.
#
# It expands ${VAR}, $VAR, ${VAR:-default} and the `$$` escape the way compose
# expands them when it reads .env itself. This is not cosmetic. Every script here exports what it read so that the child
# `docker compose` inherits it, and an environment variable *overrides* the .env
# entry it came from. So an uninterpolated export does not merely mislead the
# script - it changes what compose itself resolves: MODELS_DIR=${HOME}/models
# mounts /home/u/models under a plain `docker compose up`, but reaches compose as
# the literal string from a script that exported it, where it is no longer a path
# at all ("refers to undefined volume ${HOME}/models").
#
# Nothing is eval'd: the value is taken apart with bash string operations only,
# so a value containing $(...) or a backtick is data, not code.
_env_interp() {
  # Split deliberately: `local a="$1" b="$a"` declares every name *first*, so
  # under `set -u` the second assignment reads the unset local, not the argument.
  local mapname="${2:-}" out="" lead ref body name def empty_ok
  local rest="$1"

  while [[ "$rest" == *'$'* ]]; do
    lead="${rest%%\$*}"                # text before the first $ (\$, not $*)
    out+="$lead"
    rest="${rest:${#lead}}"            # starts at the $

    # `$$` is compose's escape for a literal dollar sign.
    if [[ "$rest" == '$$'* ]]; then
      out+='$'; rest="${rest:2}"; continue
    fi

    if [[ "$rest" == '${'* ]]; then
      _env_braced "${rest:2}" || {
        _env_fatal "an unterminated \${ in a value"
        out+="$rest"; rest=""; break
      }
      body="$ENV_BRACED"
      rest="${rest:${#body}+3}"
      if [[ -z "$body" ]]; then
        _env_fatal "an empty \${} reference in a value"
        continue
      fi
      # `${VAR-x}` substitutes only when VAR is unset; `${VAR:-x}` also when it
      # is set but empty. compose keeps that distinction, so this does too.
      empty_ok=0
      case "$body" in
        *:-*) name="${body%%:-*}"; _env_interp "${body#*:-}" "$mapname"; def="$ENV_INTERP" ;;
        *:\?*) name="${body%%:\?*}"
               _env_required "$name" "${body#*:\?}" 0 "$mapname"
               def="" ;;
        *\?*) name="${body%%\?*}"
              _env_required "$name" "${body#*\?}" 1 "$mapname"
              def="" ;;
        *-*)  name="${body%%-*}"; _env_interp "${body#*-}" "$mapname"; def="$ENV_INTERP"; empty_ok=1 ;;
        *)    name="$body"; def=""; empty_ok=1 ;;
      esac
    else
      ref="${rest:1}"
      # A reference name starts with a letter or underscore: `$1abc` is not one,
      # and compose leaves it in the value untouched.
      if [[ "$ref" != [A-Za-z_]* ]]; then
        out+='$'; rest="${rest:1}"; continue
      fi
      name="${ref%%[^A-Za-z0-9_]*}"
      rest="${rest:${#name}+1}"
      def=""; empty_ok=1
    fi

    out+="$(env_lookup "$name" "$mapname" "$empty_ok")" || out+="$def"
  done

  ENV_INTERP="$out$rest"
}

# env_interpolate VALUE [MAPNAME] - _env_interp on stdout, for callers that want
# one value and do not care about ENV_FATAL.
env_interpolate() {
  _env_interp "$1" "${2:-}"
  printf '%s' "$ENV_INTERP"
}

# _env_braced REST - put the body of a ${...} reference whose opening brace has
# already been consumed into ENV_BRACED, counting nested braces so ${A:-${B:-z}}
# is one reference. rc=1 when it is never closed. The answer is a global because
# the caller indexes past it by length, and `$(...)` would silently shorten a
# body ending in a newline.
_env_braced() {
  local s="$1"
  local n=${#s} i=0 depth=1 ch
  while (( i < n )); do
    ch="${s:i:1}"
    if [[ "$ch" == '{' ]]; then (( depth++ ))
    elif [[ "$ch" == '}' ]]; then
      (( depth-- ))
      (( depth == 0 )) && { ENV_BRACED="${s:0:i}"; return 0; }
    fi
    (( i++ ))
  done
  return 1
}

# _env_required NAME MSG EMPTY_IS_SET MAPNAME - record the fatal error compose
# raises for ${VAR:?msg} / ${VAR?msg} when VAR has no value.
_env_required() {
  local name="$1" msg="$2" empty_ok="$3" mapname="${4:-}"
  env_lookup "$name" "$mapname" "$empty_ok" >/dev/null && return 0
  _env_fatal "required variable $name is missing a value${msg:+: $msg}"
}

# _env_unescape VALUE - apply the escapes compose honours inside a double-quoted
# value, answering in ENV_UNESC. `\$` becomes `$$` rather than `$` so that the
# interpolation pass that follows renders it as one literal dollar instead of
# treating it as a reference. Answers in a global for the same reason _env_interp
# does: a value whose last character is a newline survives, and `$(...)` would
# eat it.
_env_unescape() {
  local s="$1"
  local out="" i=0 n=${#s} ch nx
  while (( i < n )); do
    ch="${s:i:1}"
    if [[ "$ch" != '\' ]] || (( i + 1 >= n )); then out+="$ch"; (( i++ )); continue; fi
    nx="${s:i+1:1}"
    case "$nx" in
      n)  out+=$'\n' ;;
      r)  out+=$'\r' ;;
      t)  out+=$'\t' ;;
      '"') out+='"' ;;
      '\') out+='\' ;;
      '$') out+='$$' ;;
      *)  out+="\\$nx" ;;            # an unknown escape keeps its backslash
    esac
    (( i += 2 ))
  done
  ENV_UNESC="$out"
}

# env_clean_value RAW - apply the unquoted-value rules (inline comment, trailing
# whitespace) to one raw right-hand side. Quoted values never reach this.
env_clean_value() {
  local val="$1"
  val="${val%$'\r'}"
  val="${val%%[[:space:]]#*}"
  printf '%s' "${val%"${val##*[![:space:]]}"}"
}

# env_parse MAPNAME - fill the named associative array from the .env file,
# applying all of the rules above in file order.
env_parse() {
  local mapname="$1" file="${ENV_FILE:-.env}"
  local -n _env_parse_out="$mapname"
  _env_parse_out=()
  ENV_FATAL=""
  [[ -f "$file" ]] || return 0

  local src
  src="$(<"$file")"                       # trailing newlines are irrelevant here
  src="${src//$'\r'$'\n'/$'\n'}"          # a file saved on Windows
  src="${src%$'\r'}"

  local n=${#src} i=0 line rhs key start close raw
  while (( i < n )); do
    line="${src:i}"; line="${line%%$'\n'*}"
    if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*=(.*)$ ]]; then
      _env_stray "$line" "$src" "$i"       # a comment and a blank line are fine
      (( i += ${#line} + 1 )); continue
    fi
    key="${BASH_REMATCH[2]}"
    rhs="${BASH_REMATCH[3]}"
    start=$(( i + ${#line} - ${#rhs} ))
    while [[ "${src:start:1}" == [[:blank:]] ]]; do (( start++ )); done

    case "${src:start:1}" in
      "'")
        close="$(_env_close "$src" $(( start + 1 )) "'" 0)" || {
          _env_fatal "an unterminated single quote in $key"
          _env_parse_out["$key"]="${src:start+1}"
          break
        }
        _env_parse_out["$key"]="${src:start+1:close-start-1}"
        i=$(( close + 1 ))
        ;;
      '"')
        close="$(_env_close "$src" $(( start + 1 )) '"' 1)" || {
          _env_fatal "an unterminated double quote in $key"
          _env_unescape "${src:start+1}"
          _env_interp "$ENV_UNESC" "$mapname"
          _env_parse_out["$key"]="$ENV_INTERP"
          break
        }
        raw="${src:start+1:close-start-1}"
        _env_unescape "$raw"
        _env_interp "$ENV_UNESC" "$mapname"
        _env_parse_out["$key"]="$ENV_INTERP"
        i=$(( close + 1 ))
        ;;
      *)
        raw="${src:start}"; raw="${raw%%$'\n'*}"
        _env_interp "$(env_clean_value "$raw")" "$mapname"
        _env_parse_out["$key"]="$ENV_INTERP"
        i=$(( start + ${#raw} + 1 ))
        continue
        ;;
    esac
    # Whatever follows the closing quote on that line is not part of the value -
    # compose reads it as the start of the next record, so it can be fatal.
    line="${src:i}"; line="${line%%$'\n'*}"
    _env_stray "$line" "$src" "$i"
    (( i += ${#line} + 1 ))
  done
  return 0
}

# _env_stray LINE SRC OFFSET - a line that is not an assignment is not silently
# ignored by compose: it reads the text up to the first '=' as a key, and a key
# containing a space makes it refuse the whole file. So a stray sentence left in
# .env, or a second word after a quoted value, stops the stack - and a reader
# that skipped the line would report a configuration compose never accepted.
_env_stray() {
  local line="$1" key lineno before stripped
  key="${line%%=*}"
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  [[ -z "$key" || "$key" == '#'* ]] && return 0
  [[ "$key" == *[[:space:]]* ]] || return 0
  before="${2:0:$3}"
  local stripped="${before//$'\n'/}"          # `${#x//y/}` is a bash parse error
  lineno=$(( ${#before} - ${#stripped} + 1 ))
  _env_fatal "line $lineno: key cannot contain a space (\"$key\")"
}

# _env_close SRC FROM QUOTE ESCAPES - print the index of the closing quote, rc=1
# when there is none. A double-quoted value may contain an escaped quote.
_env_close() {
  local s="$1" i="$2" q="$3" esc="$4" n=${#1} ch
  while (( i < n )); do
    ch="${s:i:1}"
    if (( esc )) && [[ "$ch" == '\' ]]; then (( i += 2 )); continue; fi
    [[ "$ch" == "$q" ]] && { printf '%s' "$i"; return 0; }
    (( i++ ))
  done
  return 1
}

# env_get KEY - print the effective value of one key, or nothing.
env_get() {
  local -A _env_get_map=()
  env_parse _env_get_map
  printf '%s' "${_env_get_map[$1]-}"
}

# env_check - print the reason `docker compose` will refuse to read this .env,
# rc=1 when there is one. Prints nothing and returns 0 for a readable file.
# Safe in a command substitution, which is the point: ENV_FATAL itself does not
# survive one.
env_check() {
  local -A _env_check_map=()
  env_parse _env_check_map
  [[ -z "$ENV_FATAL" ]] && return 0
  printf '%s' "$ENV_FATAL"
  return 1
}

# env_load - export every key in the file, applying the same rules.
#
# The whole file has to be loaded rather than each key fetched by name, because
# COMPOSE_FILE and MODELS_DIR reach `docker compose` through the environment.
# Assignment is by `export "k=v"`, never by eval, so nothing in .env can run.
env_load() {
  local -A _env_load_map=()
  local k
  env_parse _env_load_map
  for k in "${!_env_load_map[@]}"; do
    export "$k=${_env_load_map[$k]}"
  done
}

# env_bind_path VALUE - print the host directory compose will bind-mount for
# VALUE, or fail with the reason it will not mount anything at all.
#
# A bind source is not an ordinary path string. Compose expands a leading `~`,
# resolves `./` and `../` against the project directory - and treats a *bare*
# relative path ("models", "data/models") as the name of a named volume, which
# makes the whole project invalid because no such volume is declared. The
# scripts here read the same value as a plain shell path, so all three forms
# diverge from what the container gets:
#
#   MODELS_DIR=models     scripts write ./models, compose refuses to start
#   MODELS_DIR=~/models   scripts write a directory literally named '~',
#                         compose mounts an empty $HOME/models
#
# The second is the dangerous one: several GB land somewhere the container never
# looks, and a check that stats the path as bash sees it goes green while the
# container crash-loops on a model it cannot find.
# The result is what compose renders, which is not the same treatment for every
# form: a relative or `~` path is made absolute and lexically cleaned, so
# `./a/../b` becomes <project>/b and `~/models/` loses its trailing slash, while
# an *absolute* path is passed through byte for byte - compose does not clean
# `/data/../models`, so neither does this. A symlink is left alone either way
# (compose does not resolve one, and `realpath` would).
# Relative paths resolve against ENV_PROJECT_DIR, which is compose's project
# directory and defaults to the current one.
env_bind_path() {
  local val="$1" base="${ENV_PROJECT_DIR:-$PWD}" out
  case "$val" in
    "")            return 0 ;;
    "~")           out="$HOME" ;;
    "~/"*)         out="$HOME/${val#\~/}" ;;
    "~"*)          printf 'compose expands ~ and ~/…, but not ~user' >&2; return 1 ;;
    /*)            printf '%s' "$val"; return 0 ;;   # compose leaves it verbatim
    .|..|./*|../*) out="$base/$val" ;;
    *'$'*)         printf 'unresolved variable reference' >&2; return 1 ;;
    *)             printf 'a bare relative path is a named volume to compose, not a directory - write ./%s' "$val" >&2
                   return 1 ;;
  esac
  env_clean_path "$out"
}

# env_clean_path ABSPATH - collapse '.', '..' and duplicate slashes lexically.
env_clean_path() {
  local part
  local out=()
  local IFS=/
  for part in $1; do
    case "$part" in
      ""|.) ;;
      ..)   [[ ${#out[@]} -gt 0 ]] && unset 'out[-1]' ;;
      *)    out+=("$part") ;;
    esac
  done
  printf '/%s' "${out[*]}"
}
