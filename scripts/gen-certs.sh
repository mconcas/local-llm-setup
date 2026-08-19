#!/usr/bin/env bash
# gen-certs.sh - Generate a self-signed CA, server certificate, and client
# certificates for mutual TLS. nginx refuses connections from clients that do
# not present a certificate signed by this CA.
#
# Usage:
#   ./scripts/gen-certs.sh [HOSTNAME_OR_IP ...]   # CA + server cert + default client cert
#   ./scripts/gen-certs.sh --client NAME          # issue an additional client cert
#
# Examples:
#   ./scripts/gen-certs.sh                        # SANs: hostname + localhost + 127.0.0.1
#   ./scripts/gen-certs.sh myserver.lan 10.0.0.5  # add SANs for LAN access
#   ./scripts/gen-certs.sh --client laptop        # issue certs/laptop.{crt,key}
#
# Certs are written to ./certs/. Distribute to each client its own
# NAME.crt + NAME.key pair together with ca.crt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CERT_DIR="$PROJECT_DIR/certs"

DAYS_CA=3650       # 10 years for the CA
DAYS_CERT=825      # ~2 years for server and client certs

mkdir -p "$CERT_DIR"

ensure_ca() {
  if [[ ! -f "$CERT_DIR/ca.key" ]]; then
    echo "==> Creating CA key and certificate …"
    openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes \
      -key "$CERT_DIR/ca.key" \
      -sha256 -days "$DAYS_CA" \
      -subj "/CN=llama-local-ca" \
      -out "$CERT_DIR/ca.crt"
    chmod 600 "$CERT_DIR/ca.key"
  else
    echo "==> CA already exists, reusing."
  fi
}

issue_client_cert() {
  local name="$1"
  echo "==> Creating client key and certificate for '$name' …"
  openssl genrsa -out "$CERT_DIR/$name.key" 2048 2>/dev/null
  openssl req -new -nodes \
    -key "$CERT_DIR/$name.key" \
    -subj "/CN=$name" \
    -out "$CERT_DIR/$name.csr"
  openssl x509 -req \
    -in "$CERT_DIR/$name.csr" \
    -CA "$CERT_DIR/ca.crt" \
    -CAkey "$CERT_DIR/ca.key" \
    -CAcreateserial \
    -days "$DAYS_CERT" \
    -sha256 \
    -extfile <(printf "extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature") \
    -out "$CERT_DIR/$name.crt" 2>/dev/null
  rm -f "$CERT_DIR/$name.csr"
  chmod 600 "$CERT_DIR/$name.key"
  chmod 644 "$CERT_DIR/$name.crt"
}

# ── Client-only mode ───────────────────────────────────────────
if [[ "${1:-}" == "--client" ]]; then
  CLIENT_NAME="${2:?Usage: $0 --client NAME}"
  if [[ "$CLIENT_NAME" == "ca" || "$CLIENT_NAME" == "server" ]]; then
    echo "Error: '$CLIENT_NAME' is a reserved name." >&2
    exit 1
  fi
  ensure_ca
  issue_client_cert "$CLIENT_NAME"
  echo ""
  echo "✔ Client certificate written to $CERT_DIR/"
  echo "  Give the client: $CLIENT_NAME.crt, $CLIENT_NAME.key, ca.crt"
  echo "  Test: curl --cacert certs/ca.crt --cert certs/$CLIENT_NAME.crt --key certs/$CLIENT_NAME.key https://<server>:8443/v1/models"
  exit 0
fi

# ── Collect SANs ───────────────────────────────────────────────
SANS=("DNS:localhost" "IP:127.0.0.1" "DNS:$(hostname -f 2>/dev/null || hostname)")

for arg in "$@"; do
  if [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SANS+=("IP:$arg")
  else
    SANS+=("DNS:$arg")
  fi
done

IFS=$'\n' SANS=($(printf '%s\n' "${SANS[@]}" | sort -u)); unset IFS
SAN_STRING=$(IFS=','; echo "${SANS[*]}")

echo "==> Generating TLS certificates in $CERT_DIR"
echo "    SANs: $SAN_STRING"

ensure_ca

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
  -extfile <(printf "subjectAltName=%s\nextendedKeyUsage=serverAuth" "$SAN_STRING") \
  -out "$CERT_DIR/server.crt" 2>/dev/null

rm -f "$CERT_DIR/server.csr"

chmod 600 "$CERT_DIR"/*.key
chmod 644 "$CERT_DIR"/*.crt

# ── Default client cert ────────────────────────────────────────
if [[ ! -f "$CERT_DIR/client.crt" ]]; then
  issue_client_cert "client"
else
  echo "==> Default client cert already exists, reusing."
fi

echo ""
echo "✔ Certificates written to $CERT_DIR/"
echo "  ca.crt       - CA certificate (distribute to clients)"
echo "  ca.key       - CA private key (keep secret, signs client certs)"
echo "  server.crt   - Server certificate"
echo "  server.key   - Server private key"
echo "  client.crt   - Default client certificate"
echo "  client.key   - Default client private key"
echo ""
echo "mTLS is enforced: every client needs a certificate signed by this CA."
echo "Issue one per client with:"
echo "  ./scripts/gen-certs.sh --client NAME"
echo ""
echo "Test from a client:"
echo "  curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \\"
echo "       https://<server>:8443/v1/models"
