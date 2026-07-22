#!/usr/bin/env bash
# gen-certs.sh - Generate a self-signed CA + server certificate for TLS.
#
# The certificates in ./certs/ are live material: nginx bind-mounts them, so a
# half-written pair does not fail here, it fails at the next `docker compose up`
# with "key values mismatch" and takes the proxy down. Everything is therefore
# built in a staging directory, verified (key matches certificate, certificate
# verifies against the CA, requested SANs are present), and only then installed.
#
# On a headless Jetson the server is reached over the LAN, so this host's
# non-loopback addresses are added as SANs by default - a certificate covering
# only localhost is useless to every client that actually needs it.
#
# Usage:
#   ./scripts/gen-certs.sh                        # localhost + hostname + LAN IPs
#   ./scripts/gen-certs.sh myserver.lan 10.0.0.5  # add SANs
#   ./scripts/gen-certs.sh --check                # verify what is installed
#   ./scripts/gen-certs.sh --force                # also replace the CA
#   ./scripts/gen-certs.sh --no-auto-ip           # localhost + hostname only
#   ./scripts/gen-certs.sh --reset-sans           # forget names added earlier
#
# Options:
#   --check        report on the installed certificates and exit; writes nothing
#   --force        regenerate the CA too (every client must re-trust ca.crt)
#   --no-auto-ip   do not add this host's own addresses as SANs
#   --reset-sans   start from a bare SAN list instead of keeping the names the
#                  current certificate already covers
#   -h, --help     this text
#
# Environment:
#   CERT_DIR       where certificates live (default: <project>/certs)
#
# Exit status: 0 success, 1 operational failure, 2 bad arguments.
# Certs are written to ./certs/.  Distribute certs/ca.crt to clients.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CERT_DIR="${CERT_DIR:-$PROJECT_DIR/certs}"

DAYS_CA=3650       # 10 years for the CA
DAYS_CERT=825      # ~2 years for the server cert

MODE=generate
AUTO_IP=1
KEEP_SANS=1
FORCE_CA=0
EXTRA_SANS=()

# ── Arguments ──────────────────────────────────────────────────
# A malformed SAN used to reach openssl, which failed with its stderr sent to
# /dev/null after the new server key had already been written over the old one.
# Everything is validated before anything is generated.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)      MODE=check; shift ;;
    --force)      FORCE_CA=1; shift ;;
    --no-auto-ip) AUTO_IP=0; shift ;;
    --reset-sans) KEEP_SANS=0; shift ;;
    -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*)           echo "Unknown option: $1" >&2; exit 2 ;;
    *)            EXTRA_SANS+=("$1"); shift ;;
  esac
done

die()  { printf 'ERROR: %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2; exit "${3:-1}"; }
warn() { printf 'WARNING: %s\n' "$1" >&2; }

command -v openssl >/dev/null 2>&1 || die "openssl is not installed." "install it with: sudo apt-get install -y openssl"

# ── SAN classification ─────────────────────────────────────────
# "300.1.1.1" is a typo, not a hostname: classifying it as DNS would produce a
# certificate that looks fine and matches nothing. "fd00::1" is an address, not
# a hostname either - as a DNS SAN it silently fails to cover https://[fd00::1].
is_ipv4()  { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
ipv4_ok()  {
  local o IFS=.
  for o in $1; do (( 10#$o <= 255 )) || return 1; done
  return 0
}
# Structure matters as much as the alphabet: "fd00::1::2" is hex and colons
# throughout and is not an address. Expanding it and counting the groups is the
# check, because the expansion is what ends up in the certificate.
is_ipv6()  {
  local a="$1" exp g stripped
  [[ "$a" == *:* && "$a" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ "$a" != *:::* ]] || return 1
  stripped="${a//::/}"
  (( ( ${#a} - ${#stripped} ) / 2 <= 1 )) || return 1   # at most one "::"
  exp="$(expand_ipv6 "$a")"
  local -a groups=()
  IFS=: read -ra groups <<<"$exp"
  (( ${#groups[@]} == 8 )) || return 1
  for g in "${groups[@]}"; do [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; done
  return 0
}
# openssl prints an IPv6 SAN as eight groups with leading zeros stripped and
# hex digits upper-cased, so "fd00::7" from the address probe and "FD00:0:0:0:0:
# 0:0:7" carried over from the certificate in service are the same address in
# two spellings - and a plain sort -u keeps both, putting every address in the
# certificate twice. Normalise to openssl's spelling before deduplicating.
expand_ipv6() {
  local a="$1" head tail g out=() n
  [[ "$a" == *:* ]] || { printf '%s' "$a"; return; }
  [[ "$a" == *.* ]] && { printf '%s' "$a"; return; }   # IPv4-mapped: leave alone
  if [[ "$a" == *::* ]]; then
    head="${a%%::*}"; tail="${a#*::}"
  else
    head="$a"; tail=""
  fi
  local -a hg=() tg=()
  [[ -n "$head" ]] && IFS=: read -ra hg <<<"$head"
  [[ -n "$tail" ]] && IFS=: read -ra tg <<<"$tail"
  n=$(( 8 - ${#hg[@]} - ${#tg[@]} ))
  (( n < 0 )) && { printf '%s' "$a"; return; }
  for g in ${hg+"${hg[@]}"}; do out+=("$g"); done
  if [[ "$a" == *::* ]]; then
    while (( n-- > 0 )); do out+=("0"); done
  fi
  for g in ${tg+"${tg[@]}"}; do out+=("$g"); done
  local i part res=""
  for i in "${!out[@]}"; do
    part="${out[$i]}"
    part="$(printf '%s' "$part" | tr 'a-f' 'A-F')"
    while [[ "${#part}" -gt 1 && "$part" == 0* ]]; do part="${part#0}"; done
    res+="${res:+:}${part:-0}"
  done
  # Anything that did not expand to eight well-formed groups is not an address
  # this function understands; hand it back untouched rather than inventing a
  # different, valid-looking one.
  local -a chk=(); IFS=: read -ra chk <<<"$res"
  (( ${#chk[@]} == 8 )) || { printf '%s' "$a"; return; }
  for part in "${chk[@]}"; do
    [[ "$part" =~ ^[0-9A-F]{1,4}$ ]] || { printf '%s' "$a"; return; }
  done
  printf '%s' "$res"
}
# Rewrites an "IP:<v6>" entry into openssl's spelling; anything else is passed
# through untouched.
normalise_san() {
  local e="$1"
  [[ "$e" == IP:*:* ]] || { printf '%s' "$e"; return; }
  printf 'IP:%s' "$(expand_ipv6 "${e#IP:}")"
}

is_host()  {
  local h="$1"
  (( ${#h} <= 253 )) || return 1
  [[ "$h" == \*.* ]] && h="${h#\*.}"          # wildcard certificates are legal
  # Digits and dots only is a mistyped address (10.0.0.1.5, 10.0.0), never a
  # name a client will ask for - accepting it as DNS is how a typo turns into a
  # certificate that verifies here and matches nothing in the field.
  [[ "$h" =~ ^[0-9.]+$ ]] && return 1
  [[ "$h" =~ ^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?(\.[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?)*$ ]]
}

# Prints the SAN entry for one argument, or exits with a named cause.
classify_san() {
  local a="$1"
  if [[ -z "$a" ]]; then
    die "empty hostname/IP argument." "pass a name like myserver.lan or an address like 10.0.0.5" 2
  elif is_ipv4 "$a"; then
    ipv4_ok "$a" || die "'$a' looks like an IPv4 address but an octet is above 255." \
                        "check for a typo; a name with digits only is not a valid hostname either" 2
    printf 'IP:%s' "$a"
  elif [[ "$a" =~ ^[0-9.]+$ ]]; then
    die "'$a' is not a valid IPv4 address." "expected four octets 0-255, e.g. 192.168.1.50" 2
  elif is_ipv6 "$a"; then
    printf 'IP:%s' "$a"
  elif is_host "$a"; then
    printf 'DNS:%s' "$a"
  else
    die "'$a' is neither a valid hostname nor an IP address." \
        "hostnames may contain letters, digits, '-' and '.' only (no spaces)" 2
  fi
}

# ── Installed material ─────────────────────────────────────────
CA_KEY="$CERT_DIR/ca.key"; CA_CRT="$CERT_DIR/ca.crt"
SRV_KEY="$CERT_DIR/server.key"; SRV_CRT="$CERT_DIR/server.crt"

key_modulus()  { openssl rsa  -in "$1" -noout -modulus 2>/dev/null; }
cert_modulus() { openssl x509 -in "$1" -noout -modulus 2>/dev/null; }

pair_matches() {
  local m k
  m="$(cert_modulus "$1")" || return 1
  k="$(key_modulus "$2")"  || return 1
  [[ -n "$m" && "$m" == "$k" ]]
}
is_ca() { openssl x509 -in "$1" -noout -text 2>/dev/null | grep -q 'CA:TRUE'; }
cert_sans() { openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n'; }
cert_expiry() { openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2-; }

# ── --check ────────────────────────────────────────────────────
# Presence is not validity: the interesting states (a key that does not match
# its certificate, an expired CA, a certificate signed by a CA that has since
# been replaced) all have all four files on disk.
if [[ "$MODE" == check ]]; then
  rc=0
  echo "==> Checking certificates in $CERT_DIR"
  # ca.key is deliberately not required: what a serving host needs is the pair
  # nginx loads plus the CA certificate clients were given. Keeping the CA key
  # elsewhere is good practice, and reporting its absence as a fault would make
  # this check fire on the safer setup.
  for f in "$CA_CRT" "$SRV_CRT" "$SRV_KEY"; do
    [[ -f "$f" ]] || { echo "  missing: ${f#$CERT_DIR/}"; rc=1; }
  done
  if (( rc == 0 )); then
    if [[ -f "$CA_KEY" ]]; then
      pair_matches "$CA_CRT" "$CA_KEY" || { echo "  ca.crt does not match ca.key"; rc=1; }
    fi
    is_ca "$CA_CRT" || { echo "  ca.crt is not a CA certificate (basicConstraints CA:TRUE is missing)"; rc=1; }
    pair_matches "$SRV_CRT" "$SRV_KEY" || { echo "  server.crt does not match server.key (nginx will refuse to start)"; rc=1; }
    openssl verify -CAfile "$CA_CRT" "$SRV_CRT" >/dev/null 2>&1 \
      || { echo "  server.crt is not signed by the CA in ca.crt"; rc=1; }
    openssl x509 -in "$CA_CRT" -noout -checkend 0 >/dev/null 2>&1 \
      || { echo "  ca.crt has expired ($(cert_expiry "$CA_CRT"))"; rc=1; }
    openssl x509 -in "$SRV_CRT" -noout -checkend 0 >/dev/null 2>&1 \
      || { echo "  server.crt has expired ($(cert_expiry "$SRV_CRT"))"; rc=1; }
  fi
  if (( rc == 0 )); then
    echo "  SANs:    $(cert_sans "$SRV_CRT")"
    echo "  expires: $(cert_expiry "$SRV_CRT")  (CA: $(cert_expiry "$CA_CRT"))"
    [[ -f "$CA_KEY" ]] || echo "  note:    ca.key is not here, so this host cannot reissue certificates"
    echo "✔ Certificates are consistent."
  else
    echo ""
    echo "  Repair with: ./scripts/gen-certs.sh [hostnames/IPs]"
    echo "  (add --force if the CA itself is the problem; clients must then re-trust ca.crt)"
  fi
  exit "$rc"
fi

mkdir -p "$CERT_DIR"

# ── Collect SANs ───────────────────────────────────────────────
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
SANS=("DNS:localhost" "IP:127.0.0.1")
if [[ -n "$HOSTNAME_FQDN" ]] && is_host "$HOSTNAME_FQDN"; then
  SANS+=("DNS:$HOSTNAME_FQDN")
elif [[ -n "$HOSTNAME_FQDN" ]]; then
  warn "the system hostname '$HOSTNAME_FQDN' is not a valid DNS name; leaving it out of the certificate."
fi

# Addresses of this host, so a Jetson reached at http://192.168.x.y validates.
# Docker's own bridges are excluded: they are never how a client arrives.
AUTO_ADDRS=()
if (( AUTO_IP )) && command -v ip >/dev/null 2>&1; then
  while read -r ifname addr; do
    [[ "$ifname" =~ ^(docker|br-|veth|virbr|tun|tap) ]] && continue
    AUTO_ADDRS+=("$addr")
  done < <(ip -o addr show scope global 2>/dev/null \
             | awk '{ sub(/\/.*/, "", $4); print $2, $4 }')
  for a in ${AUTO_ADDRS+"${AUTO_ADDRS[@]}"}; do SANS+=("IP:$a"); done
fi

# Names are added to a certificate one `gen-certs.sh <name>` at a time, and a
# later re-run (to add an address, or from setup.sh) used to quietly drop every
# one of them: the certificate narrowed, and the client that depended on the
# missing name failed with a name-mismatch nobody had touched. Keep what is
# already in service unless asked not to.
CARRIED=()
if (( KEEP_SANS )) && [[ -f "$SRV_CRT" ]]; then
  while read -r entry; do
    [[ -n "$entry" ]] || continue
    SANS+=("$entry"); CARRIED+=("$entry")
  done < <(openssl x509 -in "$SRV_CRT" -noout -ext subjectAltName 2>/dev/null \
             | tail -n +2 | tr -d ' ' | tr ',' '\n' \
             | sed -e 's/^IPAddress:/IP:/' -e 's/^DNS:/DNS:/' \
             | grep -E '^(DNS|IP):.')
fi

for arg in ${EXTRA_SANS+"${EXTRA_SANS[@]}"}; do
  SANS+=("$(classify_san "$arg")")
done

# Deduplicate while keeping the entries one per line (a hostname can never
# contain whitespace by now, but word splitting on IFS=$'\n' is still the only
# form that is correct if one ever does).
NORMALISED=()
for entry in "${SANS[@]}"; do NORMALISED+=("$(normalise_san "$entry")"); done
mapfile -t SANS < <(printf '%s\n' "${NORMALISED[@]}" | sort -u)
SAN_STRING="$(IFS=','; printf '%s' "${SANS[*]}")"

echo "==> Generating TLS certificates in $CERT_DIR"
echo "    SANs: $SAN_STRING"
if (( ${#CARRIED[@]} > 0 )); then
  echo "    (kept from the current certificate; --reset-sans to start over)"
fi
if (( AUTO_IP )) && (( ${#AUTO_ADDRS[@]} == 0 )); then
  echo "    (no non-loopback address found - clients on other machines will need"
  echo "     ./scripts/gen-certs.sh <this-host-ip> once the network is up)"
fi

# ── Staging ────────────────────────────────────────────────────
STAGE="$(mktemp -d "$CERT_DIR/.staging.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT INT TERM

run_openssl() {   # run openssl, and show its error instead of swallowing it
  local out
  if ! out="$(openssl "$@" 2>&1)"; then
    printf '%s\n' "$out" >&2
    die "openssl $1 failed (see above); nothing in $CERT_DIR was changed."
  fi
}

# ── CA key + cert ──────────────────────────────────────────────
# The old check was `[[ -f ca.key ]]`, so an interrupted first run - a key with
# no certificate - reported "CA already exists, reusing" and then failed to sign
# with its stderr discarded. Both files have to be there, match, and be valid.
CA_STATE=missing
if [[ -f "$CA_KEY" && -f "$CA_CRT" ]]; then
  if ! pair_matches "$CA_CRT" "$CA_KEY"; then
    CA_STATE=broken
  elif ! is_ca "$CA_CRT"; then
    # x509 -req signs happily with a leaf certificate as the issuer; the result
    # is rejected by every client with "invalid CA certificate", which is a long
    # way from where the mistake was made.
    CA_STATE=notca
  elif ! openssl x509 -in "$CA_CRT" -noout -checkend 0 >/dev/null 2>&1; then
    CA_STATE=expired
  else
    CA_STATE=ok
  fi
elif [[ -f "$CA_KEY" || -f "$CA_CRT" ]]; then
  CA_STATE=partial
fi

if (( FORCE_CA )) || [[ "$CA_STATE" == missing ]]; then
  [[ "$CA_STATE" == ok ]] && warn "replacing the existing CA: every client must install the new certs/ca.crt."
  echo "==> Creating CA key and certificate ..."
  ( umask 077; run_openssl genrsa -out "$STAGE/ca.key" 4096 )
  run_openssl req -x509 -new -nodes \
    -key "$STAGE/ca.key" -sha256 -days "$DAYS_CA" \
    -subj "/CN=llama-local-ca" -out "$STAGE/ca.crt"
  NEW_CA=1
else
  case "$CA_STATE" in
    partial) die "$CERT_DIR holds only half a CA ($( [[ -f "$CA_KEY" ]] && echo ca.crt || echo ca.key ) is missing)." \
                 "an interrupted run left this; re-run with --force to create a new CA" ;;
    broken)  die "ca.crt and ca.key do not belong together." \
                 "re-run with --force to create a new CA (clients must then re-trust ca.crt)" ;;
    notca)   die "ca.crt is not a CA certificate (it has no basicConstraints CA:TRUE)." \
                 "anything it signs is rejected by clients; re-run with --force to create a real CA" ;;
    expired) die "the CA in ca.crt expired on $(cert_expiry "$CA_CRT")." \
                 "re-run with --force to create a new CA (clients must then re-trust ca.crt)" ;;
  esac
  echo "==> CA already exists, reusing."
  cp "$CA_KEY" "$STAGE/ca.key"; cp "$CA_CRT" "$STAGE/ca.crt"
  NEW_CA=0
  # A CA that outlives its own signature window makes every future run fail.
  openssl x509 -in "$CA_CRT" -noout -checkend 2592000 >/dev/null 2>&1 \
    || warn "the CA expires on $(cert_expiry "$CA_CRT"); re-run with --force before then."
fi

# ── Server key + CSR + cert ────────────────────────────────────
echo "==> Creating server key and certificate ..."
( umask 077; run_openssl genrsa -out "$STAGE/server.key" 2048 )

run_openssl req -new -nodes \
  -key "$STAGE/server.key" -subj "/CN=llama-server" -out "$STAGE/server.csr"

# basicConstraints/keyUsage/extendedKeyUsage are not decoration: clients that
# apply RFC 5280 strictly (Go, Java, recent Chrome) reject a leaf certificate
# that claims no purpose, and the old certificates carried none.
cat >"$STAGE/ext.cnf" <<EOF
subjectAltName=$SAN_STRING
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF

run_openssl x509 -req \
  -in "$STAGE/server.csr" \
  -CA "$STAGE/ca.crt" -CAkey "$STAGE/ca.key" -CAcreateserial \
  -days "$DAYS_CERT" -sha256 \
  -extfile "$STAGE/ext.cnf" \
  -out "$STAGE/server.crt"

# ── Verify before installing ───────────────────────────────────
pair_matches "$STAGE/server.crt" "$STAGE/server.key" \
  || die "the generated certificate does not match the generated key." "this is a bug; $CERT_DIR was not touched"
openssl verify -CAfile "$STAGE/ca.crt" "$STAGE/server.crt" >/dev/null 2>&1 \
  || die "the generated certificate does not verify against the CA." "this is a bug; $CERT_DIR was not touched"
GOT_SANS="$(cert_sans "$STAGE/server.crt")"
for san in "${SANS[@]}"; do
  # openssl renders "DNS:x" as "DNS:x" and "IP:1.2.3.4" as "IPAddress:1.2.3.4"
  # (spaces stripped above), so compare on the value. IPv6 is skipped because
  # openssl rewrites it into its expanded form.
  [[ "$san" == IP:*:* ]] && continue
  val="${san#*:}"
  [[ "$GOT_SANS" == *"$val"* ]] \
    || die "the generated certificate is missing the requested SAN '$san'." "$CERT_DIR was not touched"
done

# ── Install ────────────────────────────────────────────────────
install_file() { install -m "$1" "$2" "$3"; }
if (( NEW_CA )); then
  install_file 600 "$STAGE/ca.key" "$CA_KEY"
  install_file 644 "$STAGE/ca.crt" "$CA_CRT"
fi
install_file 600 "$STAGE/server.key" "$SRV_KEY"
install_file 644 "$STAGE/server.crt" "$SRV_CRT"
# The serial file stays in the staging directory: OpenSSL 3 picks a random
# serial per signature anyway, and this CA only ever holds one leaf.
rm -f "$CERT_DIR/server.csr"   # left behind by earlier versions of this script

echo ""
echo "✔ Certificates written to $CERT_DIR/"
echo "  ca.crt       - CA certificate (distribute to clients)"
echo "  ca.key       - CA private key (keep secret)"
echo "  server.crt   - Server certificate, expires $(cert_expiry "$SRV_CRT")"
echo "  server.key   - Server private key"
echo ""
# nginx reads the certificates once at startup, so a running proxy keeps serving
# the previous ones - which is why a regenerated SAN list appears to have had no
# effect. validate.sh checks for exactly this.
echo "If the stack is already running, reload the proxy so it picks these up:"
echo "  docker compose restart nginx"
echo ""
echo "On client machines, trust the CA with:"
echo "  curl --cacert certs/ca.crt https://<server>:8443/v1/models"
echo ""
echo "Or add it system-wide (Debian/Ubuntu):"
echo "  sudo cp certs/ca.crt /usr/local/share/ca-certificates/llama-local-ca.crt"
echo "  sudo update-ca-certificates"
