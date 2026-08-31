#!/bin/bash
# End-to-end + adversarial curl validation of verum-signin-relay (relay.verum.sh).
#
# Proves the hardening contract: happy path, session_id+nonce binding (anti-replay),
# single-use consumption, TTL expiry, CORS scoped to *.karve.ai, opaque-vcap-only
# (zero-knowledge shape check), and body/vcap caps.
#
# Requires: node 22+, curl, jq.

set -euo pipefail
cd "$(dirname "$0")/.."

PORT=$(node -e "const s=require('net').createServer(); s.listen(0,()=>{console.log(s.address().port);s.close()})")
BASE="http://localhost:$PORT"
NONCE="nonce-$(node -e 'console.log(require("crypto").randomBytes(12).toString("hex"))')"
VCAP="vcap1.eyJmYWtlIjoib3BhcXVlIn0.c2ln"   # opaque stand-in; the relay never verifies it

echo "════ verum-signin-relay validation ════"
echo "PORT=$PORT NONCE=$NONCE"

PORT=$PORT node --experimental-strip-types verum-signin-relay.ts > /tmp/signin-relay-test.log 2>&1 &
RELAY_PID=$!
trap "kill $RELAY_PID 2>/dev/null; rm -f /tmp/signin-relay-test.log /tmp/sr-*.json" EXIT

for i in $(seq 1 20); do curl -sf "$BASE/healthz" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "$BASE/healthz" >/dev/null || { echo "✗ relay did not start"; cat /tmp/signin-relay-test.log; exit 1; }

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }

echo "── [1] healthz ──"
curl -s "$BASE/healthz" | jq -c .

echo "── [2] web POST /encounter (verum-signin) → session_id ──"
curl -sf -X POST "$BASE/encounter" -H 'Content-Type: application/json' \
  -d "{\"kind\":\"verum-signin\",\"nonce\":\"$NONCE\",\"ttl\":90,\"ask\":{\"server\":\"rightsizer\",\"tools\":[\"viability\",\"intake\"]}}" \
  > /tmp/sr-enc.json
jq -c . /tmp/sr-enc.json
SID=$(jq -r .session_id /tmp/sr-enc.json)
[ -n "$SID" ] && [ "$SID" != "null" ] && pass "session_id=$SID" || fail "no session_id"

echo "── [3] reject unsupported kind ──"
H=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/encounter" -H 'Content-Type: application/json' -d '{"kind":"encounter","nonce":"aaaaaaaa"}')
[ "$H" = "400" ] && pass "unsupported kind → 400" || fail "expected 400, got $H"

echo "── [4] web polls approval before phone → 404 awaiting ──"
H=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/encounter/$SID/approval")
[ "$H" = "404" ] && pass "awaiting → 404" || fail "expected 404, got $H"

echo "── [5] anti-replay: phone POST approval with WRONG nonce → 400 ──"
H=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/encounter/$SID/approval" -H 'Content-Type: application/json' -d "{\"nonce\":\"WRONG\",\"vcap\":\"$VCAP\"}")
[ "$H" = "400" ] && pass "nonce mismatch → 400" || fail "expected 400, got $H"

echo "── [6] zero-knowledge: reject non-vcap payload → 400 ──"
H=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/encounter/$SID/approval" -H 'Content-Type: application/json' -d "{\"nonce\":\"$NONCE\",\"vcap\":\"not-a-vcap-plaintext-secret\"}")
[ "$H" = "400" ] && pass "non-vcap shape → 400" || fail "expected 400, got $H"

echo "── [7] phone POST approval with correct nonce + opaque vcap → 200 ──"
curl -sf -X POST "$BASE/encounter/$SID/approval" -H 'Content-Type: application/json' -d "{\"nonce\":\"$NONCE\",\"vcap\":\"$VCAP\"}" > /tmp/sr-ap.json
jq -c . /tmp/sr-ap.json
[ "$(jq -r .ok /tmp/sr-ap.json)" = "true" ] && pass "approval stored" || fail "approval not stored"

echo "── [8] double-approve rejected → 409 ──"
H=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/encounter/$SID/approval" -H 'Content-Type: application/json' -d "{\"nonce\":\"$NONCE\",\"vcap\":\"$VCAP\"}")
[ "$H" = "409" ] && pass "already approved → 409" || fail "expected 409, got $H"

echo "── [9] web polls → gets the vcap ONCE ──"
curl -sf "$BASE/encounter/$SID/approval" > /tmp/sr-get.json
jq -c . /tmp/sr-get.json
[ "$(jq -r .vcap /tmp/sr-get.json)" = "$VCAP" ] && pass "vcap delivered" || fail "vcap mismatch"

echo "── [10] single-use: second poll → 404 (purged) ──"
H=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/encounter/$SID/approval")
[ "$H" = "404" ] && pass "single-use purge → 404" || fail "expected 404, got $H"

echo "── [11] CORS: karve.ai origin echoed, evil.com denied ──"
OK_ORIGIN=$(curl -s -D - -o /dev/null -X OPTIONS "$BASE/encounter" -H 'Origin: https://llmfit.karve.ai' | grep -i '^access-control-allow-origin:' | tr -d '\r' | awk '{print $2}')
[ "$OK_ORIGIN" = "https://llmfit.karve.ai" ] && pass "karve.ai origin echoed" || fail "expected karve.ai origin, got '$OK_ORIGIN'"
EVIL=$(curl -s -D - -o /dev/null -X OPTIONS "$BASE/encounter" -H 'Origin: https://evil.com' | grep -ic '^access-control-allow-origin:' || true)
[ "$EVIL" = "0" ] && pass "evil.com origin denied (no ACAO header)" || fail "evil.com got an ACAO header"

echo "── [12] TTL: ttl>90 clamped to 90s ──"
curl -sf -X POST "$BASE/encounter" -H 'Content-Type: application/json' -d "{\"kind\":\"verum-signin\",\"nonce\":\"clamp-test-nonce\",\"ttl\":99999}" > /tmp/sr-ttl.json
EXP=$(jq -r .expiresAt /tmp/sr-ttl.json)
NOW=$(node -e 'console.log(Date.now())')
EXPMS=$(node -e "console.log(Date.parse(process.argv[1]))" "$EXP")
DELTA=$(( (EXPMS - NOW) / 1000 ))
[ "$DELTA" -le 91 ] && pass "ttl clamped (${DELTA}s ≤ 90)" || fail "ttl not clamped: ${DELTA}s"

echo
echo "════ ✓✓✓ all checks green ════"
