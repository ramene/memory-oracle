#!/bin/bash
# Remote validation of a DEPLOYED pair-relay (Tier 1 — no app, no local server).
#
# Runs the full pairing round-trip against a live relay over TLS, simulating
# BOTH ends (phone claim + desktop deliver), and asserts the 204/400/403 guards.
# Unlike curl-test.sh this does NOT spin up a local server — it targets a URL.
#
# Must be run from a network whose egress IP is allow-listed in the GAE firewall
# (the pair-relay sits behind mae-stack-prod's allow/deny rules). From a blocked
# IP every request returns Google's edge 404 — the script detects that and says so.
#
# Usage:
#   bash curl-test-remote.sh                       # defaults to https://relay.verum.sh
#   bash curl-test-remote.sh https://relay.verum.sh
#   RELAY_BASE=https://pair-relay-dot-mae-stack-prod.uc.r.appspot.com bash curl-test-remote.sh
#
# Requires: curl, jq.

set -euo pipefail

BASE="${1:-${RELAY_BASE:-https://relay.verum.sh}}"
BASE="${BASE%/}"                                  # strip any trailing slash

# Unique per-run so repeat/concurrent runs never collide in the relay's Map,
# and so we always clean up exactly what we created.
STAMP="$(date +%s)-$$-${RANDOM}"
NONCE="relaytest${STAMP//-/}"
DEVICE_RECIP="age1se1qdevice-${STAMP}"
WRONG_RECIP="age1se1qattacker-${STAMP}"

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$1"; exit 1; }

echo "════ pair-relay REMOTE validation ════"
echo "BASE=$BASE"
echo "nonce=$NONCE"
echo

# ── [0] healthz / reachability ──
echo "── [0] GET /healthz ──"
HEALTH="$(curl -s --max-time 15 "$BASE/healthz" || true)"
if printf '%s' "$HEALTH" | grep -qi '<html'; then
  echo "$HEALTH" | head -3
  fail "got an HTML page, not JSON. Likely the GAE firewall is blocking this IP (run from the allow-listed network) OR the SSL cert is not live yet."
fi
printf '%s\n' "$HEALTH" | jq -c . || fail "healthz did not return JSON"
printf '%s' "$HEALTH" | jq -e '.ok == true' >/dev/null || fail "healthz .ok != true"
pass "relay reachable, app alive (this also proves dispatch → pair-relay, not verum-sh)"

# ── [1] desktop reads claim before phone posts → 204 ──
echo "── [1] GET /pair/claim?nonce (no claim yet) → 204 ──"
HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/pair/claim?nonce=$NONCE")"
[ "$HTTP" = "204" ] || fail "expected 204, got $HTTP"
pass "204 (no claim yet)"

# ── [2] phone POST /pair/claim ──
echo "── [2] POST /pair/claim (phone) ──"
CLAIM="$(curl -s --max-time 15 -X POST "$BASE/pair/claim" -H 'Content-Type: application/json' -d "$(cat <<JSON
{ "v": 1, "kind": "verum-pair-claim", "nonce": "$NONCE",
  "device_recipient": "$DEVICE_RECIP", "device_label": "remote-curl-test",
  "issued_at": "$(date -u +%FT%TZ)" }
JSON
)")"
printf '%s' "$CLAIM" | jq -e '.ok == true' >/dev/null || fail "claim not accepted: $CLAIM"
pass "claim accepted"

# ── [3] desktop reads claim → device_recipient ──
echo "── [3] GET /pair/claim?nonce (desktop reads) ──"
GOT="$(curl -s --max-time 15 "$BASE/pair/claim?nonce=$NONCE" | jq -r .device_recipient)"
[ "$GOT" = "$DEVICE_RECIP" ] || fail "device_recipient mismatch: $GOT"
pass "claim readable, device_recipient matches"

# ── [4] phone polls age file before delivery → 204 ──
echo "── [4] GET /pair?for&nonce (not delivered) → 204 ──"
HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/pair?for=$DEVICE_RECIP&nonce=$NONCE")"
[ "$HTTP" = "204" ] || fail "expected 204, got $HTTP"
pass "204 (age file not delivered yet)"

# ── [5] guard: deliver with WRONG 'for' → 400 ──
echo "── [5] POST /pair wrong 'for' → 400 ──"
HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$BASE/pair" -H 'Content-Type: application/json' \
  -d "{\"nonce\":\"$NONCE\",\"for\":\"$WRONG_RECIP\",\"age_file_b64\":\"QUdF\"}")"
[ "$HTTP" = "400" ] || fail "expected 400, got $HTTP"
pass "400 (for ≠ claim.device_recipient rejected)"

# ── [6] desktop delivers age file ──
echo "── [6] POST /pair (desktop delivers) ──"
DEL="$(curl -s --max-time 15 -X POST "$BASE/pair" -H 'Content-Type: application/json' \
  -d "{\"nonce\":\"$NONCE\",\"for\":\"$DEVICE_RECIP\",\"age_file_b64\":\"YWdlLWVuY3J5cHRpb24ub3JnL3YxCg==\"}")"
printf '%s' "$DEL" | jq -e '.ok == true' >/dev/null || fail "deliver failed: $DEL"
pass "age file delivered"

# ── [7] guard: poll with WRONG 'for' → 403 ──
echo "── [7] GET /pair wrong 'for' → 403 ──"
HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/pair?for=$WRONG_RECIP&nonce=$NONCE")"
[ "$HTTP" = "403" ] || fail "expected 403, got $HTTP"
pass "403 (cross-retrieval blocked)"

# ── [8] phone retrieves age file ──
echo "── [8] GET /pair (phone retrieves) ──"
AGE="$(curl -s --max-time 15 "$BASE/pair?for=$DEVICE_RECIP&nonce=$NONCE" | jq -r .age_file_b64)"
[ -n "$AGE" ] && [ "$AGE" != "null" ] || fail "no age_file_b64 returned"
pass "age_file_b64 retrieved ($AGE)"

# ── [9] inbox V2 stub ──
echo "── [9] GET /inbox (V2 stub) ──"
curl -s --max-time 15 "$BASE/inbox?for=$DEVICE_RECIP" | jq -e '.envelopes | length == 0' >/dev/null || fail "inbox stub unexpected"
pass "inbox stub returns empty envelopes"

# ── [10] cleanup ──
echo "── [10] DELETE /pair?nonce (cleanup) ──"
curl -s --max-time 15 -X DELETE "$BASE/pair?nonce=$NONCE" | jq -e '.deleted == true' >/dev/null || fail "cleanup failed"
HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/pair/claim?nonce=$NONCE")"
[ "$HTTP" = "204" ] || fail "record still present after delete (got $HTTP)"
pass "record deleted, relay left clean"

echo
printf '\033[32m════ ✓✓✓ all checks green against %s ════\033[0m\n' "$BASE"
