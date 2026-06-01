#!/bin/bash
# End-to-end curl validation of encounter-relay (Phase 3c-iii).
#
# Spins up the relay on a free port, runs the full request/poll/approve/
# retrieve cycle, asserts each step, then shuts down.
#
# Requires: node 22+, curl, jq.

set -euo pipefail

cd "$(dirname "$0")/.."

# Find a free port
PORT=$(node -e "const s=require('net').createServer(); s.listen(0,()=>{console.log(s.address().port);s.close()})")
BASE="http://localhost:$PORT"

echo "════ encounter-relay 3c-iii curl validation ════"
echo "PORT=$PORT BASE=$BASE"

# Start relay
PORT=$PORT node --experimental-strip-types server.ts > /tmp/relay-test.log 2>&1 &
RELAY_PID=$!
trap "kill $RELAY_PID 2>/dev/null; rm -f /tmp/relay-test.log /tmp/relay-{enc,pending,approval,result}.json" EXIT

# Wait for relay to be ready
for i in $(seq 1 20); do
  if curl -sf "$BASE/healthz" > /dev/null 2>&1; then break; fi
  sleep 0.2
done
if ! curl -sf "$BASE/healthz" > /dev/null; then
  echo "✗ relay did not start"
  cat /tmp/relay-test.log
  exit 1
fi

echo "── [1] healthz ──"
curl -s "$BASE/healthz" | jq -c .

echo
echo "── [2] clinician POST /encounter ──"
PATIENT_RECIP="age1se1qpatient-fake-for-curl-validation"
CLINICIAN_RECIP="age1se1qclinician-fake-for-curl-validation"
curl -sf -X POST "$BASE/encounter" \
  -H 'Content-Type: application/json' \
  -d "$(cat <<JSON
{
  "@type": "EncounterRequest",
  "clinicianRecipient": "$CLINICIAN_RECIP",
  "clinicianName": "Dr. Test",
  "patientRecipient": "$PATIENT_RECIP",
  "requestedScopes": ["allergies", "meds"],
  "ttlSeconds": 900,
  "issuedAt": "$(date -u +%FT%TZ)"
}
JSON
)" > /tmp/relay-enc.json
cat /tmp/relay-enc.json | jq -c .
ENC_ID=$(jq -r .encounterId /tmp/relay-enc.json)
[ -n "$ENC_ID" ] || { echo "✗ no encounterId returned"; exit 1; }

echo
echo "── [3] patient GET /encounter?for=<patient> — should see the pending ──"
curl -sf "$BASE/encounter?for=$PATIENT_RECIP" > /tmp/relay-pending.json
cat /tmp/relay-pending.json | jq -c .
PEND_COUNT=$(jq '.requests | length' /tmp/relay-pending.json)
if [ "$PEND_COUNT" != "1" ]; then echo "✗ expected 1 pending, got $PEND_COUNT"; exit 1; fi

echo
echo "── [4] clinician GET /encounter/<id>/approval — should be 404 (none yet) ──"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/encounter/$ENC_ID/approval")
echo "  HTTP $HTTP"
if [ "$HTTP" != "404" ]; then echo "✗ expected 404, got $HTTP"; exit 1; fi

echo
echo "── [5] patient POST /encounter/<id>/approval ──"
curl -sf -X POST "$BASE/encounter/$ENC_ID/approval" \
  -H 'Content-Type: application/json' \
  -d "$(cat <<JSON
{
  "@type": "EncounterApproval",
  "encounterId": "$ENC_ID",
  "wrappedKeys": {
    "allergies": "BASE64_FAKE_AGE_BLOB_FOR_TEST",
    "meds": "BASE64_FAKE_AGE_BLOB_FOR_TEST_TOO"
  },
  "expiresAt": "$(date -u -v+15M +%FT%TZ 2>/dev/null || date -u -d '+15 minutes' +%FT%TZ)"
}
JSON
)" > /tmp/relay-approval.json
cat /tmp/relay-approval.json | jq -c .

echo
echo "── [6] clinician GET /encounter/<id>/approval — should now return the approval ──"
curl -sf "$BASE/encounter/$ENC_ID/approval" > /tmp/relay-result.json
cat /tmp/relay-result.json | jq -c .
SCOPES=$(jq '.wrappedKeys | keys | length' /tmp/relay-result.json)
if [ "$SCOPES" != "2" ]; then echo "✗ expected 2 wrapped scopes, got $SCOPES"; exit 1; fi

echo
echo "── [7] cleanup ──"
curl -sf -X DELETE "$BASE/encounter/$ENC_ID" | jq -c .

echo
echo "════ ✓✓✓ all 7 steps green ════"
