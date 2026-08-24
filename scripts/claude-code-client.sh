#!/usr/bin/env bash
# claude-code-client.sh - Issue a client certificate for a Claude Code
# installation and print the matching ~/.claude/settings.json `env` block.
#
# Usage:
#   ./scripts/claude-code-client.sh NAME [SERVER_HOST]
#
# NAME is the certificate CN (one per client machine); SERVER_HOST defaults to
# this host's FQDN and must be one of the server certificate's SANs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

NAME="${1:?Usage: $0 NAME [SERVER_HOST]}"
SERVER_HOST="${2:-$(hostname -f 2>/dev/null || hostname)}"

set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -n "${SIDECAR_UPSTREAM:-}" && -n "${SIDECAR_MODEL_NAMES:-}" ]]; then
  HAIKU_MODEL="${SIDECAR_MODEL_NAMES%%,*}"
else
  HAIKU_MODEL="$(basename "${MODEL_FILE:?set MODEL_FILE in .env first}")"
fi
PORT="${HTTPS_PORT:-8443}"
CLIENT_DIR='$HOME/.config/local-llm'

if [[ ! -f "certs/$NAME.crt" ]]; then
  bash "$SCRIPT_DIR/gen-certs.sh" --client "$NAME"
else
  echo "==> certs/$NAME.crt already exists, reusing."
fi

cat <<MSG

Copy to the client machine (keep $NAME.key private):

  mkdir -p $CLIENT_DIR
  scp $(whoami)@$SERVER_HOST:$PROJECT_DIR/certs/{ca.crt,$NAME.crt,$NAME.key} $CLIENT_DIR/

Add to ~/.claude/settings.json on the client (absolute paths, no ~):

  "env": {
    "ANTHROPIC_BASE_URL": "https://$SERVER_HOST:$PORT",
    "ANTHROPIC_AUTH_TOKEN": "not-needed",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "$HAIKU_MODEL",
    "ENABLE_TOOL_SEARCH": "true",
    "CLAUDE_CODE_CLIENT_CERT": "/home/USER/.config/local-llm/$NAME.crt",
    "CLAUDE_CODE_CLIENT_KEY": "/home/USER/.config/local-llm/$NAME.key",
    "NODE_EXTRA_CA_CERTS": "/home/USER/.config/local-llm/ca.crt"
  }

Verify from the client:

  curl --cacert ca.crt --cert $NAME.crt --key $NAME.key \\
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \\
    -d '{"model":"$HAIKU_MODEL","max_tokens":32,"messages":[{"role":"user","content":"ping"}]}' \\
    https://$SERVER_HOST:$PORT/v1/messages
MSG
