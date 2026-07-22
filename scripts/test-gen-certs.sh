#!/usr/bin/env bash
# test-gen-certs.sh - Hermetic tests for gen-certs.sh.
#
# The certificates this script writes are live material: nginx bind-mounts
# ./certs, so a bad pair does not fail in gen-certs.sh, it fails at the next
# `docker compose up` with "key values mismatch". The failure that mattered was
# therefore not "it crashed" but "it crashed after overwriting server.key",
# which a typo in a SAN argument was enough to cause - and none of it is
# reachable from a healthy host, where every run is a fresh success.
#
# These tests drive the real script against a private CERT_DIR with stubbed
# `hostname` and `ip`, and finish by completing an actual TLS handshake against
# the generated pair, so "the certificate is valid" is a measurement rather than
# an inspection. They need no GPU, no Docker, no model and no network.
#
# Usage:
#   ./scripts/test-gen-certs.sh          # run all cases
#   ./scripts/test-gen-certs.sh -v       # also print each assertion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/gen-certs.sh"

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

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

# ── Stubs ─────────────────────────────────────────────────────────
# gen-certs.sh probes the host with `hostname` and `ip`; both are stubbed so
# the expected SAN list is fixed rather than whatever this machine is called.
STUBBIN="$TMPROOT/bin"; mkdir -p "$STUBBIN"
cat >"$STUBBIN/hostname" <<'EOF'
#!/usr/bin/env bash
[[ "${STUB_HOSTNAME_FAIL:-0}" == 1 ]] && exit 1
printf '%s\n' "${STUB_HOSTNAME:-jetson-test.lan}"
EOF
cat >"$STUBBIN/ip" <<'EOF'
#!/usr/bin/env bash
# Mimics `ip -o addr show scope global`, including the interfaces a Jetson
# running Docker actually has - which must not end up in the certificate.
cat <<'ADDRS'
2: eth0    inet 192.168.7.7/24 brd 192.168.7.255 scope global dynamic eth0\       valid_lft 100sec
2: eth0    inet6 fd00:1234::7/64 scope global \       valid_lft forever
3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\       valid_lft forever
4: br-abc123    inet 172.18.0.1/16 brd 172.18.255.255 scope global br-abc123\       valid_lft forever
5: veth9f2    inet 172.19.0.1/16 brd 172.19.255.255 scope global veth9f2\       valid_lft forever
ADDRS
EOF
chmod +x "$STUBBIN/hostname" "$STUBBIN/ip"

# An openssl that works normally except when asked to sign, which is the one
# step that happens after the new server key exists. Standing in for whatever
# makes it fail in the field (a full disk, a broken extension, a bad CA), it is
# how the "leave the live pair alone" guarantee gets tested at all.
FAILSSL="$TMPROOT/failssl"; mkdir -p "$FAILSSL"
cat >"$FAILSSL/openssl" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == x509 && " \$* " == *" -req "* ]]; then
  echo "stub openssl: refusing to sign" >&2
  exit 1
fi
exec $(command -v openssl) "\$@"
EOF
chmod +x "$FAILSSL/openssl"

# A PATH holding only what gen-certs.sh needs, for the case that removes `ip`
# from it. Building it explicitly also pins how small that dependency set is.
MINBIN="$TMPROOT/minbin"; mkdir -p "$MINBIN"
for t in bash awk sed grep sort tr cut tail cat mktemp install rm cp mkdir dirname basename openssl; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$MINBIN/$t"
done
ln -sf "$STUBBIN/hostname" "$MINBIN/hostname"

# ── Helpers ───────────────────────────────────────────────────────
CD=""; OUT=""; RC=0

new_certdir() {       # sets CD to a fresh, empty certificate directory
  CD="$TMPROOT/certs.$((++CDN))"
  mkdir -p "$CD"
}
CDN=0

# Most cases need "a project that already has certificates" as a starting
# point, not a fresh CA. Generating a 4096-bit CA per case cost more than the
# rest of the suite put together, so one is generated (and fully asserted on)
# in the first case and copied afterwards.
seed_certdir() {
  new_certdir
  cp "$MASTER"/ca.crt "$MASTER"/ca.key "$MASTER"/server.crt "$MASTER"/server.key "$CD/"
  chmod 600 "$CD"/*.key; chmod 644 "$CD"/*.crt
}
MASTER=""

run_gc() {            # run the real script against $CD
  OUT="$(CERT_DIR="$CD" PATH="$STUBBIN:$PATH" bash "$TARGET" "$@" 2>&1)"; RC=$?
}

expect_rc()  { (( RC == $1 )) && pass "rc=$1 ($2)" || fail "expected rc=$1, got $RC ($2)" "${OUT:0:400}"; }
expect_out() { grep -qE -- "$1" <<<"$OUT" && pass "output matches /$1/" || fail "output missing /$1/" "${OUT:0:400}"; }
expect_not_out() { grep -qE -- "$1" <<<"$OUT" && fail "output should not match /$1/" "${OUT:0:400}" || pass "output free of /$1/"; }
expect_file() { [[ -f "$1" ]] && pass "$(basename "$1") exists" || fail "$1 missing"; }

# The single most important property: whatever nginx would load must be a
# matching pair signed by the CA that clients were given.
expect_consistent() {  # $1=label
  local cm km
  cm="$(openssl x509 -in "$CD/server.crt" -noout -modulus 2>/dev/null)"
  km="$(openssl rsa  -in "$CD/server.key" -noout -modulus 2>/dev/null)"
  if [[ -n "$cm" && "$cm" == "$km" ]]; then pass "server key and certificate match ($1)"
  else fail "server key/certificate mismatch ($1)" "nginx would refuse to start"; fi
  if openssl verify -CAfile "$CD/ca.crt" "$CD/server.crt" >/dev/null 2>&1; then
    pass "server certificate verifies against ca.crt ($1)"
  else fail "server certificate does not verify against ca.crt ($1)"; fi
}

# `openssl x509 -checkhost/-checkip` exits 0 whether or not the name matches -
# the verdict is only in its output. Testing the exit status gives an assertion
# that cannot fail, which is precisely the defect class this suite exists for.
covers() {            # $1=-checkhost|-checkip  $2=name
  openssl x509 -in "$CD/server.crt" -noout "$1" "$2" 2>/dev/null | grep -q ' does match'
}
sans_of() { openssl x509 -in "$CD/server.crt" -noout -ext subjectAltName 2>&1 | tr -d '\n'; }

expect_san_host() {   # $1=name
  covers -checkhost "$1" && pass "certificate covers host $1" \
    || fail "certificate does not cover host $1" "$(sans_of)"
}
expect_no_san_host() {
  covers -checkhost "$1" && fail "certificate unexpectedly covers host $1" "$(sans_of)" \
    || pass "certificate does not cover host $1"
}
expect_san_ip() {     # $1=address
  covers -checkip "$1" && pass "certificate covers IP $1" \
    || fail "certificate does not cover IP $1" "$(sans_of)"
}
expect_no_san_ip() {
  covers -checkip "$1" && fail "certificate unexpectedly covers IP $1" "$(sans_of)" \
    || pass "certificate does not cover IP $1"
}

# The address probe spells an IPv6 address one way and openssl spells it
# another, so carrying names forward without normalising puts every address in
# the certificate twice, once per spelling.
expect_no_dup_sans() {
  local dupes
  dupes="$(openssl x509 -in "$CD/server.crt" -noout -ext subjectAltName 2>/dev/null \
             | tail -n +2 | tr -d ' ' | tr ',' '\n' | sort | uniq -d)"
  [[ -z "$dupes" ]] && pass "no duplicate SAN entries" || fail "duplicate SAN entries" "$dupes"
}

snapshot() { md5sum "$CD"/*.crt "$CD"/*.key 2>/dev/null | sort; }
expect_untouched() {  # $1=snapshot taken before  $2=label
  if [[ "$(snapshot)" == "$1" ]]; then pass "certificate directory untouched ($2)"
  else fail "certificate directory was modified ($2)" "a failed run must never replace live material"; fi
}
expect_no_staging() {
  local leftovers
  leftovers="$(find "$CD" -maxdepth 1 -name '.staging.*' 2>/dev/null)"
  [[ -z "$leftovers" ]] && pass "no staging directory left behind" || fail "staging directory left behind" "$leftovers"
}
expect_mode() {       # $1=file  $2=mode
  local m; m="$(stat -c '%a' "$1" 2>/dev/null)"
  [[ "$m" == "$2" ]] && pass "$(basename "$1") is mode $2" || fail "$(basename "$1") is mode ${m:-absent}, expected $2"
}

# ── TLS handshake harness ─────────────────────────────────────────
# An inspection of the certificate cannot show that a TLS stack will accept it;
# a handshake can. The server loads exactly the files nginx would mount.
cat >"$TMPROOT/handshake.py" <<'PYEOF'
import socket, ssl, sys, threading

certdir, name, cafile = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    sctx.load_cert_chain(certdir + "/server.crt", certdir + "/server.key")
except Exception as e:
    print("SERVER-LOAD-FAILED: %s" % e); sys.exit(2)

srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(1)
port = srv.getsockname()[1]
result = {}


def serve():
    try:
        c, _ = srv.accept()
        with sctx.wrap_socket(c, server_side=True) as s:
            s.recv(16)
    except Exception:
        pass


t = threading.Thread(target=serve, daemon=True)
t.start()

cctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
if cafile == "-":
    cctx.load_default_certs()
else:
    cctx.load_verify_locations(cafile)
try:
    with socket.create_connection(("127.0.0.1", port), timeout=10) as raw:
        with cctx.wrap_socket(raw, server_hostname=name) as s:
            s.send(b"hi")
    print("HANDSHAKE-OK")
except Exception as e:
    print("HANDSHAKE-FAILED: %s" % type(e).__name__ + ": " + str(e))
PYEOF

handshake() {  # $1=server_hostname  $2=cafile or "-"
  python3 "$TMPROOT/handshake.py" "$CD" "$1" "${2:-$CD/ca.crt}" 2>&1
}
expect_handshake() {   # $1=name  $2=cafile  $3=label
  local r; r="$(handshake "$1" "$2")"
  [[ "$r" == HANDSHAKE-OK ]] && pass "TLS handshake succeeds ($3)" || fail "TLS handshake failed ($3)" "$r"
}
expect_no_handshake() {
  local r; r="$(handshake "$1" "$2")"
  [[ "$r" == HANDSHAKE-OK ]] && fail "TLS handshake succeeded but should not ($3)" || pass "TLS handshake refused ($3)"
}

# ══════════════════════════════════════════════════════════════════
# Cases
# ══════════════════════════════════════════════════════════════════

case_start "fresh generation produces a usable, consistent set"
new_certdir
run_gc
MASTER="$CD"          # every later case starts from this set instead of paying
                      # for another 4096-bit CA
expect_rc 0 "fresh run"
expect_file "$CD/ca.crt"; expect_file "$CD/ca.key"
expect_file "$CD/server.crt"; expect_file "$CD/server.key"
expect_consistent "fresh"
expect_no_staging
[[ -f "$CD/server.csr" ]] && fail "server.csr left behind" || pass "no CSR left behind"
expect_out 'Creating CA key and certificate'
expect_out 'docker compose restart nginx'
expect_mode "$CD/server.key" 600
expect_mode "$CD/ca.key" 600
expect_mode "$CD/server.crt" 644
expect_mode "$CD/ca.crt" 644

case_start "the default SAN list covers how the box is actually reached"
expect_san_host localhost
expect_san_host jetson-test.lan
expect_san_ip 127.0.0.1
expect_san_ip 192.168.7.7          # LAN address: the headless-Jetson case
expect_san_ip fd00:1234::7
# Docker's own bridges are not routes a client arrives by, and putting them in
# the certificate only makes the SAN list harder to read.
expect_no_san_ip 172.17.0.1
expect_no_san_ip 172.18.0.1
expect_no_san_ip 172.19.0.1

case_start "the leaf certificate declares a purpose"
EXT="$(openssl x509 -in "$CD/server.crt" -noout -text 2>/dev/null)"
grep -q 'CA:FALSE' <<<"$EXT" && pass "basicConstraints CA:FALSE" || fail "leaf has no basicConstraints CA:FALSE"
grep -q 'TLS Web Server Authentication' <<<"$EXT" && pass "extendedKeyUsage serverAuth" || fail "leaf has no serverAuth EKU"
grep -q 'Digital Signature' <<<"$EXT" && pass "keyUsage digitalSignature" || fail "leaf has no keyUsage"
CAEXT="$(openssl x509 -in "$CD/ca.crt" -noout -text 2>/dev/null)"
grep -q 'CA:TRUE' <<<"$CAEXT" && pass "CA certificate is a CA" || fail "ca.crt is not marked CA:TRUE"

case_start "a real TLS stack accepts the generated pair"
expect_handshake localhost "$CD/ca.crt" "by name, with the CA"
expect_handshake 127.0.0.1 "$CD/ca.crt" "by IP, with the CA"
expect_handshake jetson-test.lan "$CD/ca.crt" "by hostname, with the CA"
expect_no_handshake localhost "-" "without the CA in the trust store"
expect_no_handshake elsewhere.lan "$CD/ca.crt" "for a name the certificate does not cover"

case_start "re-running reuses the CA so distributed ca.crt keeps working"
CA_BEFORE="$(md5sum "$CD/ca.crt" | cut -d' ' -f1)"
SRV_BEFORE="$(md5sum "$CD/server.crt" | cut -d' ' -f1)"
cp "$CD/ca.crt" "$TMPROOT/ca-distributed.crt"
run_gc 10.0.0.5
expect_rc 0 "adding a SAN"
expect_out 'CA already exists, reusing'
[[ "$(md5sum "$CD/ca.crt" | cut -d' ' -f1)" == "$CA_BEFORE" ]] \
  && pass "CA is unchanged" || fail "CA was replaced by an ordinary re-run" "every client would have to re-trust it"
[[ "$(md5sum "$CD/server.crt" | cut -d' ' -f1)" != "$SRV_BEFORE" ]] \
  && pass "server certificate was reissued" || fail "server certificate was not reissued"
expect_consistent "after adding a SAN"
expect_san_ip 10.0.0.5
expect_san_ip 192.168.7.7
expect_handshake localhost "$TMPROOT/ca-distributed.crt" "against the previously distributed ca.crt"

case_start "malformed SAN arguments are refused without touching live material"
BEFORE="$(snapshot)"
run_gc ""
expect_rc 2 "empty argument"
expect_out 'empty hostname/IP argument'
expect_untouched "$BEFORE" "empty argument"

run_gc "my server.lan"
expect_rc 2 "hostname with a space"
expect_out 'neither a valid hostname nor an IP address'
expect_untouched "$BEFORE" "hostname with a space"

run_gc 300.1.1.1
expect_rc 2 "octet above 255"
expect_out 'octet is above 255'
expect_untouched "$BEFORE" "octet above 255"

run_gc 10.0.0.256
expect_rc 2 "last octet above 255"
expect_out 'octet is above 255'

# A five-octet typo used to become a DNS SAN: a certificate that verifies here
# and matches nothing any client will ever ask for.
run_gc 10.0.0.1.5
expect_rc 2 "five octets"
expect_out 'not a valid IPv4 address'
expect_untouched "$BEFORE" "five octets"

run_gc 10.0.0
expect_rc 2 "three octets"
expect_out 'not a valid IPv4 address'

run_gc --nonsense
expect_rc 2 "unknown option"
expect_out 'Unknown option'
expect_untouched "$BEFORE" "unknown option"
expect_no_staging

case_start "an openssl failure after key generation still leaves the old pair"
# The old script generated the new server key straight over the live one and
# sent openssl's explanation to /dev/null, so a failure anywhere after that
# point left nginx with a key that did not match its certificate - discovered
# at the next `docker compose up`, as a refusal to start.
seed_certdir
BEFORE="$(snapshot)"
OUT="$(CERT_DIR="$CD" PATH="$FAILSSL:$STUBBIN:$PATH" bash "$TARGET" 2>&1)"; RC=$?
expect_rc 1 "openssl fails while signing"
expect_out 'refusing to sign'
expect_out 'nothing in .* was changed'
expect_untouched "$BEFORE" "openssl failure during signing"
expect_no_staging

# A malformed address is refused before any of that, by argument validation.
run_gc fd00::1::2
expect_rc 2 "an address with two :: is not an address"
expect_out 'neither a valid hostname nor an IP address'
run_gc ':::'
expect_rc 2 "three colons"
run_gc '1:2:3:4:5:6:7:8:9'
expect_rc 2 "nine groups"
expect_untouched "$BEFORE" "malformed IPv6"

case_start "legitimate exotic SANs are accepted"
seed_certdir
run_gc '*.lan.local' fd00::99 my-host_1
expect_rc 0 "wildcard, IPv6 and underscore"
expect_consistent "exotic SANs"
expect_san_host anything.lan.local
expect_san_ip fd00::99
expect_san_host my-host_1

case_start "half a CA is reported, not silently reused"
seed_certdir
BEFORE="$(snapshot)"
rm -f "$CD/ca.crt"
run_gc
expect_rc 1 "ca.crt missing"
expect_out 'holds only half a CA \(ca.crt is missing\)'
expect_out -- '--force'
expect_no_staging
# The old script printed "CA already exists, reusing", then failed to sign with
# its stderr discarded - after having already written the new server.key.
[[ "$(md5sum "$CD/server.key" | cut -d' ' -f1)" == "$(cut -d' ' -f1 <<<"$(grep server.key <<<"$BEFORE")")" ]] \
  && pass "server.key was not replaced by the failed run" || fail "server.key was replaced by a run that could not finish"

seed_certdir
rm -f "$CD/ca.key"
run_gc
expect_rc 1 "ca.key missing"
expect_out 'holds only half a CA \(ca.key is missing\)'

run_gc --force
expect_rc 0 "--force repairs a half CA"
expect_consistent "after --force"

case_start "a CA that does not match its key is refused"
seed_certdir
openssl genrsa -out "$CD/ca.key" 2048 2>/dev/null      # key from a different CA
BEFORE="$(snapshot)"
run_gc
expect_rc 1 "mismatched CA"
expect_out 'do not belong together'
expect_untouched "$BEFORE" "mismatched CA"
run_gc --force
expect_rc 0 "--force replaces the CA"
expect_consistent "after --force on a mismatched CA"

case_start "an expired CA is refused rather than used to sign"
seed_certdir
openssl genrsa -out "$TMPROOT/old-ca.key" 2048 2>/dev/null
openssl req -new -key "$TMPROOT/old-ca.key" -subj /CN=old-ca -out "$TMPROOT/old-ca.csr" 2>/dev/null
openssl x509 -req -in "$TMPROOT/old-ca.csr" -signkey "$TMPROOT/old-ca.key" -days -1 \
  -extfile <(printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n') \
  -out "$TMPROOT/old-ca.crt" 2>/dev/null
cp "$TMPROOT/old-ca.key" "$CD/ca.key"; cp "$TMPROOT/old-ca.crt" "$CD/ca.crt"
BEFORE="$(snapshot)"
run_gc
expect_rc 1 "expired CA"
expect_out 'expired on'
expect_untouched "$BEFORE" "expired CA"
run_gc --check
expect_rc 1 "--check sees the expiry"
expect_out 'ca.crt has expired'

case_start "a CA certificate that is not a CA is refused"
# x509 -req will sign with a leaf certificate as the issuer without complaint.
# The result fails in the client, with "invalid CA certificate" and no hint
# about which file on the server is wrong.
seed_certdir
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=not-a-ca \
  -addext basicConstraints=critical,CA:FALSE \
  -keyout "$CD/ca.key" -out "$CD/ca.crt" 2>/dev/null
chmod 600 "$CD/ca.key"
BEFORE="$(snapshot)"
run_gc
expect_rc 1 "ca.crt is not a CA"
expect_out 'not a CA certificate'
expect_untouched "$BEFORE" "ca.crt is not a CA"
run_gc --check
expect_rc 1 "--check sees it too"
expect_out 'basicConstraints CA:TRUE is missing'
run_gc --force
expect_rc 0 "--force replaces it with a real CA"
expect_consistent "after --force on a non-CA"
expect_handshake localhost "$CD/ca.crt" "with a proper CA"

case_start "a CA about to expire warns but still signs"
seed_certdir
openssl x509 -req -in "$TMPROOT/old-ca.csr" -signkey "$TMPROOT/old-ca.key" -days 5 \
  -extfile <(printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n') \
  -out "$CD/ca.crt" 2>/dev/null
cp "$TMPROOT/old-ca.key" "$CD/ca.key"
run_gc
expect_rc 0 "CA expiring soon still signs"
expect_out 'WARNING: the CA expires on'
expect_consistent "CA expiring soon"

case_start "--force says what it costs"
seed_certdir
cp "$CD/ca.crt" "$TMPROOT/ca-old.crt"
run_gc --force
expect_rc 0 "--force"
expect_out 'every client must install the new certs/ca.crt'
expect_consistent "after --force"
expect_no_handshake localhost "$TMPROOT/ca-old.crt" "against the CA that --force replaced"
expect_handshake localhost "$CD/ca.crt" "against the new CA"
FOREIGN="$CD"          # a genuinely different CA, reused below

case_start "--check distinguishes present from valid"
seed_certdir
run_gc --check
expect_rc 0 "consistent material"
expect_out 'Certificates are consistent'
expect_out 'SANs:'
expect_out 'expires:'

openssl genrsa -out "$CD/server.key" 2048 2>/dev/null   # the nginx-killing state
run_gc --check
expect_rc 1 "server key does not match"
expect_out 'server.crt does not match server.key'
expect_out 'nginx will refuse to start'

seed_certdir
cp "$FOREIGN/server.crt" "$CD/server.crt"; cp "$FOREIGN/server.key" "$CD/server.key"
run_gc --check
expect_rc 1 "certificate from another CA"
expect_out 'not signed by the CA in ca.crt'

new_certdir
run_gc --check
expect_rc 1 "nothing installed"
expect_out 'missing: ca.crt'
expect_out 'missing: server.key'
expect_out 'Repair with'

# A host that serves TLS needs the pair nginx loads and the CA certificate its
# clients trust. The CA private key belongs anywhere but there, so --check must
# not report the safer arrangement as a fault.
seed_certdir
rm -f "$CD/ca.key"
run_gc --check
expect_rc 0 "ca.key kept off the serving host"
expect_out 'Certificates are consistent'
expect_out 'cannot reissue certificates'

case_start "names already in service survive a re-run"
# Re-running to add an address used to reissue from a bare list, silently
# dropping every name added by an earlier run - the certificate narrowed, and
# whichever client used the missing name failed with a mismatch nobody had
# touched.
seed_certdir
run_gc extra.lan
expect_rc 0 "adding a name"
expect_san_host extra.lan
run_gc 10.9.9.9
expect_rc 0 "adding an address afterwards"
expect_out 'kept from the current certificate'
expect_no_dup_sans
expect_san_ip fd00:1234::7
run_gc fd00:1234:0:0:0:0:0:7
expect_rc 0 "the same address in its other spelling"
expect_no_dup_sans
expect_san_ip fd00:1234::7
expect_san_host extra.lan
expect_san_ip 10.9.9.9
expect_san_host localhost
run_gc --reset-sans
expect_rc 0 "--reset-sans"
expect_not_out 'kept from the current certificate'
expect_no_san_host extra.lan
expect_no_san_ip 10.9.9.9
expect_san_host localhost
expect_consistent "after --reset-sans"

case_start "--no-auto-ip keeps the certificate to localhost and the hostname"
seed_certdir
run_gc --no-auto-ip --reset-sans
expect_rc 0 "--no-auto-ip"
expect_consistent "--no-auto-ip"
expect_san_host localhost
expect_san_host jetson-test.lan
expect_san_ip 127.0.0.1
expect_no_san_ip 192.168.7.7

case_start "a host with no address probe still gets a working certificate"
seed_certdir
OUT="$(CERT_DIR="$CD" PATH="$MINBIN" bash "$TARGET" 2>&1)"; RC=$?
expect_rc 0 "no ip(8) available"
expect_out 'no non-loopback address found'
expect_consistent "no ip(8) available"
expect_san_ip 127.0.0.1

case_start "an unusable system hostname is reported, not embedded"
seed_certdir
OUT="$(CERT_DIR="$CD" STUB_HOSTNAME='my box' PATH="$STUBBIN:$PATH" bash "$TARGET" 2>&1)"; RC=$?
expect_rc 0 "hostname with a space"
expect_out 'not a valid DNS name'
expect_consistent "unusable hostname"
expect_san_host localhost

seed_certdir
OUT="$(CERT_DIR="$CD" STUB_HOSTNAME='10.0.0.5' PATH="$STUBBIN:$PATH" bash "$TARGET" --no-auto-ip --reset-sans 2>&1)"; RC=$?
expect_rc 0 "hostname is an address literal"
expect_out 'not a valid DNS name'
expect_no_san_host 10.0.0.5
expect_no_san_ip 10.0.0.5

seed_certdir
OUT="$(CERT_DIR="$CD" STUB_HOSTNAME_FAIL=1 PATH="$STUBBIN:$PATH" bash "$TARGET" 2>&1)"; RC=$?
expect_rc 0 "hostname(1) fails"
expect_consistent "hostname(1) fails"
expect_san_host localhost
expect_san_ip 127.0.0.1

case_start "missing openssl is named as the cause"
new_certdir
NOSSL="$TMPROOT/nossl"; mkdir -p "$NOSSL"
for t in bash awk sed grep sort tr cut tail cat mktemp install rm cp mkdir dirname basename; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOSSL/$t"
done
ln -sf "$STUBBIN/hostname" "$NOSSL/hostname"
OUT="$(CERT_DIR="$CD" PATH="$NOSSL" bash "$TARGET" 2>&1)"; RC=$?
expect_rc 1 "no openssl"
expect_out 'openssl is not installed'
expect_out 'apt-get install'

case_start "--help documents the options that exist"
run_gc --help
expect_rc 0 "--help"
expect_out 'Usage:'
expect_out -- '--check'
expect_out -- '--force'
expect_out -- '--no-auto-ip'
expect_out -- '--reset-sans'
expect_out 'CERT_DIR'

case_start "the certificate directory is left tidy in every state"
seed_certdir
run_gc >/dev/null 2>&1
run_gc 300.1.1.1 >/dev/null 2>&1
run_gc --check >/dev/null 2>&1
expect_no_staging
UNEXPECTED="$(find "$CD" -maxdepth 1 -mindepth 1 ! -name 'ca.crt' ! -name 'ca.key' \
              ! -name 'server.crt' ! -name 'server.key' ! -name 'ca.srl' 2>/dev/null)"
[[ -z "$UNEXPECTED" ]] && pass "only certificate material in the directory" \
  || fail "unexpected files in the certificate directory" "$UNEXPECTED"

# ══════════════════════════════════════════════════════════════════
printf '\n%sSummary%s\n' "$C_HD" "$C_Z"
printf '  %s%d passed%s, %s%d failed%s\n' "$C_OK" "$PASS" "$C_Z" "$C_NO" "$FAIL" "$C_Z"
if (( FAIL > 0 )); then
  printf '\n  Failed assertions:\n'
  printf '    - %s\n' "${FAILED_NAMES[@]}"
  echo ""
  exit 1
fi
echo ""
exit 0
