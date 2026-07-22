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

# env_get KEY - print the effective value of one key, or nothing.
env_get() {
  local key="$1" file="${ENV_FILE:-.env}" val
  [[ -f "$file" ]] || return 0
  val="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -1)" || return 0
  env_clean_value "${val#*=}"
}

# env_load - export every key in the file, applying the same rules.
#
# The whole file has to be loaded rather than each key fetched by name, because
# COMPOSE_FILE and MODELS_DIR reach `docker compose` through the environment.
# Assignment is by `export "k=v"`, never by eval, so nothing in .env can run.
env_load() {
  local file="${ENV_FILE:-.env}" line key
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    key="${BASH_REMATCH[1]}"
    export "$key=$(env_clean_value "${line#*=}")"
  done <"$file"
}
