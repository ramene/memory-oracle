#!/bin/bash
# End-to-end curl validation of pair-relay.
#
# Spins up the relay on a free port and runs the full online pairing flow:
#   phone claim → desktop reads claim → desktop delivers age file → phone polls
#   → cleanup, asserting the 204-before-ready states and the for/nonce guards.
#
# Requires: node 22+, curl, jq.

set -euo pipefail

cd "$(dirname "$0")/.."

PORT=$(node -e "const s=require('net').createServer(); s.listen(0,()=>{console.log(s.address().port);s.close()})")
BASE="http://localhost:$PORT"

echo "════ pair-relay curl validation ════"
echo "PORT=$PORT BASE=$BASE"

PORT=$PORT node --experimental-strip-types server.ts > /tmp/pair-relay-test.log 2>&1 &
RELAY_PID=$!
trap "kill $RELAY_PID 2>/dev/null; rm -f /tmp/pair-relay-test.log /tmp/pair-{claim,age,poll}.json" EXIT

for i in $(seq 1 20); do
  if curl -sf "$BASE/healthz" > /dev/null 2>&1; then break; fi
  sleep 0.2
done
if ! curl -sf "$BASE/healthz" > /dev/null; then
  echo "✗ relay did not start"; cat /tmp/pair-relay-test.log; exit 1
fi

NONCE="f1e2d3c4b5a60718"
DEVICE_RECIP="age1se1qdevice-fake-for-curl-validation"
WRONG_RECIP="age1se1qattacker-fake-for-curl-validation"

echo "── [1] healthz ──"
curl -s "$BASE/healthz" | jq -c .

echo
echo "── [2] desktop GET /pair/claim?nonce — should be 204 (no claim yet) ──"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/pair/claim?nonce=$NONCE")
echo "  HTTP $HTTP"; [ "$HTTP" = "204" ] || { echo "✗ expected 204, got $HTTP"; exit 1; }

echo
echo "── [3] phone POST /pair/claim ──"
curl -sf -X POST "$BASE/pair/claim" \
  -H 'Content-Type: application/json' \
  -d "$(cat <<JSON
{
  "v": 1,
  "kind": "verum-pair-claim",
  "nonce": "$NONCE",
  "device_recipient": "$DEVICE_RECIP",
  "device_label": "Ramene's iPhone 15 Pro",
  "issued_at": "$(date -u +%FT%TZ)"
}
JSON
)" > /tmp/pair-claim.json
cat /tmp/pair-claim.json | jq -c .
jq -e .ok /tmp/pair-claim.json > /dev/null || { echo "✗ claim not accepted"; exit 1; }

echo
echo "── [4] desktop GET /pair/claim?nonce — should now return the claim ──"
curl -sf "$BASE/pair/claim?nonce=$NONCE" > /tmp/pair-claim.json
cat /tmp/pair-claim.json | jq -c .
GOT_RECIP=$(jq -r .device_recipient /tmp/pair-claim.json)
[ "$GOT_RECIP" = "$DEVICE_RECIP" ] || { echo "✗ device_recipient mismatch"; exit 1; }

echo
echo "── [5] phone GET /pair?for&nonce — should be 204 (age file not delivered) ──"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/pair?for=$DEVICE_RECIP&nonce=$NONCE")
echo "  HTTP $HTTP"; [ "$HTTP" = "204" ] || { echo "✗ expected 204, got $HTTP"; exit 1; }

echo
echo "── [6] desktop POST /pair with WRONG 'for' — should be 400 (guard) ──"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/pair" \
  -H 'Content-Type: application/json' \
  -d "{\"nonce\":\"$NONCE\",\"for\":\"$WRONG_RECIP\",\"age_file_b64\":\"QUdFLUZJTEU=\"}")
echo "  HTTP $HTTP"; [ "$HTTP" = "400" ] || { echo "✗ expected 400, got $HTTP"; exit 1; }

echo
echo "── [7] desktop POST /pair (correct) — deliver age file ──"
curl -sf -X POST "$BASE/pair" \
  -H 'Content-Type: application/json' \
  -d "{\"nonce\":\"$NONCE\",\"for\":\"$DEVICE_RECIP\",\"age_file_b64\":\"YWdlLWVuY3J5cHRpb24ub3JnL3YxCg==\"}" > /tmp/pair-age.json
cat /tmp/pair-age.json | jq -c .

echo
echo "── [8] phone GET /pair with WRONG 'for' — should be 403 ──"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/pair?for=$WRONG_RECIP&nonce=$NONCE")
echo "  HTTP $HTTP"; [ "$HTTP" = "403" ] || { echo "✗ expected 403, got $HTTP"; exit 1; }

echo
echo "── [9] phone GET /pair (correct) — should return age_file_b64 ──"
curl -sf "$BASE/pair?for=$DEVICE_RECIP&nonce=$NONCE" > /tmp/pair-poll.json
cat /tmp/pair-poll.json | jq -c .
jq -e .age_file_b64 /tmp/pair-poll.json > /dev/null || { echo "✗ no age_file_b64 returned"; exit 1; }

echo
echo "── [10] inbox V2 stub — should return empty envelopes ──"
curl -sf "$BASE/inbox?for=$DEVICE_RECIP" | jq -c .

echo
echo "── [11] cleanup DELETE /pair?nonce ──"
curl -sf -X DELETE "$BASE/pair?nonce=$NONCE" | jq -c .
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/pair/claim?nonce=$NONCE")
[ "$HTTP" = "204" ] || { echo "✗ expected 204 after delete, got $HTTP"; exit 1; }

echo
echo "════ ✓✓✓ all 11 steps green ════"
