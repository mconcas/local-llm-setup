#!/usr/bin/env bash
# gen-certs.sh - Generate a self-signed CA + server certificate for TLS.
#
# Usage:
#   ./scripts/gen-certs.sh [HOSTNAME_OR_IP ...]
#
# Examples:
#   ./scripts/gen-certs.sh                       # defaults to hostname + 127.0.0.1
#   ./scripts/gen-certs.sh myserver.lan 10.0.0.5 # add SANs for LAN access
#
# Certs are written to ./certs/.  Distribute certs/ca.crt to clients.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CERT_DIR="$PROJECT_DIR/certs"

DAYS_CA=3650       # 10 years for the CA
DAYS_CERT=825      # ~2 years for the server cert

mkdir -p "$CERT_DIR"

# ── Collect SANs ───────────────────────────────────────────────
SANS=("DNS:localhost" "IP:127.0.0.1" "DNS:$(hostname -f 2>/dev/null || hostname)")

for arg in "$@"; do
  # Detect whether the argument looks like an IP address
  if [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SANS+=("IP:$arg")
  else
    SANS+=("DNS:$arg")
  fi
done

# Deduplicate
IFS=$'\n' SANS=($(printf '%s\n' "${SANS[@]}" | sort -u)); unset IFS
SAN_STRING=$(IFS=','; echo "${SANS[*]}")

echo "==> Generating TLS certificates in $CERT_DIR"
echo "    SANs: $SAN_STRING"

# ── CA key + cert ──────────────────────────────────────────────
if [[ ! -f "$CERT_DIR/ca.key" ]]; then
  echo "==> Creating CA key and certificate …"
  openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes \
    -key "$CERT_DIR/ca.key" \
    -sha256 -days "$DAYS_CA" \
    -subj "/CN=llama-local-ca" \
    -out "$CERT_DIR/ca.crt"
else
  echo "==> CA already exists, reusing."
fi

# ── Server key + CSR + cert ────────────────────────────────────
echo "==> Creating server key and certificate …"
openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null

openssl req -new -nodes \
  -key "$CERT_DIR/server.key" \
  -subj "/CN=llama-server" \
  -out "$CERT_DIR/server.csr"

openssl x509 -req \
  -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca.crt" \
  -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial \
  -days "$DAYS_CERT" \
  -sha256 \
  -extfile <(printf "subjectAltName=%s" "$SAN_STRING") \
  -out "$CERT_DIR/server.crt" 2>/dev/null

rm -f "$CERT_DIR/server.csr"

chmod 600 "$CERT_DIR"/*.key
chmod 644 "$CERT_DIR"/*.crt

echo ""
echo "✔ Certificates written to $CERT_DIR/"
echo "  ca.crt       - CA certificate (distribute to clients)"
echo "  ca.key       - CA private key (keep secret)"
echo "  server.crt   - Server certificate"
echo "  server.key   - Server private key"
echo ""
echo "On client machines, trust the CA with:"
echo "  curl --cacert certs/ca.crt https://<server>:8443/v1/models"
echo ""
echo "Or add it system-wide (Debian/Ubuntu):"
echo "  sudo cp certs/ca.crt /usr/local/share/ca-certificates/llama-local-ca.crt"
echo "  sudo update-ca-certificates"
