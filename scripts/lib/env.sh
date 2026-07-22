# lib/env.sh - Read .env with compose's semantics.
#
# Sourced by setup.sh, download-model.sh and validate.sh. Deliberately not
# `source .env`, and deliberately not `sed 's/^KEY=//'`.
#
# .env is compose syntax, not shell. `source` *executes* it, so a value that is
# perfectly legal to compose - one containing whitespace, a bare parenthesis, a
# backtick or `$(...)` - is a syntax error, a lost key or an executed command.
# A bare sed is the opposite failure: a documented inline comment or a CRLF line
# ending stays *inside* the value, which is invisible in a path until several GB
# have landed in a directory nothing mounts, and which turns a mismatch report
# into two identical-looking strings.
#
# Rules implemented (compose v2's):
#   - the last uncommented assignment of a key wins
#   - surrounding single or double quotes are stripped
#   - an unquoted value ends at the first whitespace-preceded '#'
#   - a trailing CR (a file saved on Windows) is not part of the value
#   - ${VAR} / $VAR / ${VAR:-default} in a value are interpolated, from the
#     process environment first and then from keys assigned earlier in the file
#
# Callers set ENV_FILE to the .env they mean; it defaults to ./.env.

# Apply the quoting/comment/CRLF rules to one raw right-hand side.
env_clean_value() {
  local val="$1"
  val="${val%$'\r'}"
  if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then
    printf '%s' "${val:1:${#val}-2}"
  else
    val="${val%%[[:space:]]#*}"
    printf '%s' "${val%"${val##*[![:space:]]}"}"
  fi
}

# env_interpolate VALUE - expand ${VAR}, $VAR and ${VAR:-default} the way
# compose expands them when it reads .env itself.
#
# This is not cosmetic. Every script here exports what it read so that the child
# `docker compose` inherits it, and an environment variable *overrides* the .env
# entry it came from. So an uninterpolated export does not merely mislead the
# script - it changes what compose itself resolves: MODELS_DIR=${HOME}/models
# mounts /home/u/models under a plain `docker compose up`, but reaches compose as
# the literal string from a script that exported it, where it is no longer a path
# at all ("refers to undefined volume ${HOME}/models").
#
# Names are looked up in the caller-supplied map first (keys already read from
# this file), then in the process environment - the same precedence compose uses,
# where the shell environment wins over the file. An undefined name with no
# default expands to the empty string. Nothing is eval'd: the value is taken
# apart with bash string operations only, so a value containing $(...) or a
# backtick is data, not code.
#
# The caller passes the name of an associative array holding the earlier keys.
env_interpolate() {
  # Split deliberately: `local a="$1" b="$a"` declares every name *first*, so
  # under `set -u` the second assignment reads the unset local, not the argument.
  local mapname="${2:-}" out="" lead name ref def empty_ok
  local rest="$1"

  while [[ "$rest" == *'$'* ]]; do
    lead="${rest%%\$*}"                # text before the first $ (\$, not $*)
    out+="$lead"
    rest="${rest:${#lead}}"            # starts at the $

    # `$$` is not an escape inside a .env value - compose leaves it alone.
    if [[ "$rest" == '$$'* ]]; then
      out+='$$'; rest="${rest:2}"; continue
    fi

    if [[ "$rest" == '${'* ]]; then
      ref="${rest#\$\{}"
      [[ "$ref" == *'}'* ]] || { out+="$rest"; rest=""; break; }   # unterminated: literal
      ref="${ref%%\}*}"
      rest="${rest:${#ref}+3}"
      # `${VAR-x}` substitutes only when VAR is unset; `${VAR:-x}` also when it
      # is set but empty. compose keeps that distinction, so this does too.
      empty_ok=0
      case "$ref" in
        *:-*) name="${ref%%:-*}"; def="$(env_interpolate "${ref#*:-}" "$mapname")" ;;
        *-*)  name="${ref%%-*}";  def="$(env_interpolate "${ref#*-}" "$mapname")"; empty_ok=1 ;;
        *:\?*|*\?*) name="${ref%%[:?]*}"; name="${name%\?}"; def="" ;;
        *)    name="$ref"; def=""; empty_ok=1 ;;
      esac
    else
      ref="${rest:1}"
      name="${ref%%[^A-Za-z0-9_]*}"
      if [[ -z "$name" ]]; then        # a lone $ or $/ - not a reference
        out+='$'; rest="${rest:1}"; continue
      fi
      rest="${rest:${#name}+1}"
      def=""; empty_ok=1
    fi

    out+="$(env_lookup "$name" "$mapname" "$empty_ok")" || out+="$def"
  done

  printf '%s' "$out$rest"
}

# env_lookup NAME MAPNAME [EMPTY_IS_SET] - print NAME's value, rc=1 when the
# caller's default should be used instead. Process environment first, then keys
# read earlier in the file - compose's own precedence.
env_lookup() {
  local name="$1" mapname="${2:-}" empty_ok="${3:-1}" val="" set=0
  if [[ -n "${!name+x}" ]]; then
    val="${!name}"; set=1
  elif [[ -n "$mapname" ]]; then
    local -n _map="$mapname"
    if [[ -n "${_map[$name]+x}" ]]; then val="${_map[$name]}"; set=1; fi
  fi
  printf '%s' "$val"
  (( set )) && { (( empty_ok )) || [[ -n "$val" ]]; }
}

# env_parse MAPNAME - fill the named associative array from the .env file,
# applying all of the rules above in file order.
env_parse() {
  local mapname="$1" file="${ENV_FILE:-.env}" line key
  local -n _out="$mapname"
  _out=()
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    key="${BASH_REMATCH[1]}"
    _out["$key"]="$(env_interpolate "$(env_clean_value "${line#*=}")" "$mapname")"
  done <"$file"
}

# env_get KEY - print the effective value of one key, or nothing.
env_get() {
  local -A _env_map=()
  env_parse _env_map
  printf '%s' "${_env_map[$1]-}"
}

# env_load - export every key in the file, applying the same rules.
#
# The whole file has to be loaded rather than each key fetched by name, because
# COMPOSE_FILE and MODELS_DIR reach `docker compose` through the environment.
# Assignment is by `export "k=v"`, never by eval, so nothing in .env can run.
env_load() {
  local -A _env_map=()
  local k
  env_parse _env_map
  for k in "${!_env_map[@]}"; do
    export "$k=${_env_map[$k]}"
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
# The result is absolute and lexically cleaned, exactly as compose renders it:
# `./a/../b` becomes <project>/b, while a symlink in the path is left alone
# (compose does not resolve one, so neither does this - `realpath` would).
# Relative paths resolve against ENV_PROJECT_DIR, which is compose's project
# directory and defaults to the current one.
env_bind_path() {
  local val="$1" base="${ENV_PROJECT_DIR:-$PWD}" out
  case "$val" in
    "")            return 0 ;;
    "~")           out="$HOME" ;;
    "~/"*)         out="$HOME/${val#\~/}" ;;
    "~"*)          printf 'compose expands ~ and ~/…, but not ~user' >&2; return 1 ;;
    /*)            out="$val" ;;
    .|..|./*|../*) out="$base/$val" ;;
    *'$'*)         printf 'unresolved variable reference' >&2; return 1 ;;
    *)             printf 'a bare relative path is a named volume to compose, not a directory - write ./%s' "$val" >&2
                   return 1 ;;
  esac
  env_clean_path "$out"
}

# env_clean_path ABSPATH - collapse '.', '..' and duplicate slashes lexically.
env_clean_path() {
  local part out=()
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
