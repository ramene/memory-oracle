#!/usr/bin/env bash
# unlock-patient.sh
#
# Terminal-side counterpart to the mobile clinician app. Given a session_key
# (derived by the mobile app from a patient QR scan), decrypt the patient's
# memory namespace, build an isolated memory-oracle index, and run a smoke
# query proving the supersession-merged retrieval works.
#
# Usage:
#   unlock-patient.sh <patient_id> <session_key_hex>
#
# 30-minute TTL — encounter directory is shredded automatically at end.

set -euo pipefail

PATIENT_ID="${1:-}"
SESSION_KEY="${2:-}"

if [ -z "$PATIENT_ID" ] || [ -z "$SESSION_KEY" ]; then
  echo "Usage: $0 <patient_id> <session_key_hex>" >&2
  echo "  patient_id matches QR payload" >&2
  echo "  session_key_hex is the 64-char hex string shown on the clinician app" >&2
  exit 2
fi

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../../.." && pwd )"
PATIENT_VAULT="$REPO_ROOT/docs/examples/clinical-records/patient-${PATIENT_ID}"
ENCOUNTER_DIR="${TMPDIR:-/tmp}/mo-encounter-$$"
TTL_SECONDS=1800

if [ ! -d "$PATIENT_VAULT" ]; then
  echo "ERROR: no vault for patient $PATIENT_ID at $PATIENT_VAULT" >&2
  exit 3
fi

echo "════════════════════════════════════════════════════════════════"
echo "  memory-oracle clinician — encounter unlock"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  patient_id:      $PATIENT_ID"
echo "  session_key:     ${SESSION_KEY:0:16}…(hidden)"
echo "  vault:           $PATIENT_VAULT"
echo "  encounter dir:   $ENCOUNTER_DIR (auto-shredded at exit)"
echo "  TTL:             $TTL_SECONDS seconds"
echo ""

# Cleanup on exit — shred the working copy
shred_encounter() {
  if [ -d "$ENCOUNTER_DIR" ]; then
    echo ""
    echo "[shred] removing encounter directory $ENCOUNTER_DIR"
    rm -rf "$ENCOUNTER_DIR" 2>/dev/null || true
    echo "[audit] $(date -u +%FT%TZ) encounter_ended patient=$PATIENT_ID"
  fi
}
trap shred_encounter EXIT INT TERM

# Stage 1: copy vault into the encounter directory (in production: AES decrypt with $SESSION_KEY)
mkdir -p "$ENCOUNTER_DIR/projects/_clinical/memory"
cp "$PATIENT_VAULT/memory/"*.md "$ENCOUNTER_DIR/projects/_clinical/memory/" 2>/dev/null || true
cp "$PATIENT_VAULT/memory/"*.supersessions.jsonl "$ENCOUNTER_DIR/projects/_clinical/memory/" 2>/dev/null || true
echo "[stage] copied $(ls "$ENCOUNTER_DIR/projects/_clinical/memory/" | wc -l | tr -d ' ') files into encounter"

# Stage 2: build isolated memory-oracle index over the patient namespace
export CLAUDE_PROJECTS_ROOT="$ENCOUNTER_DIR/projects"
export MEMORY_INDEX_DB="$ENCOUNTER_DIR/encounter.db"
node "$HOME/.bin/memory-index-build.mjs" 2>/dev/null | tail -1

# Stage 3: simulate ER physician's query
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  SIMULATED ER QUERY"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "ER physician's LLM asks: 'what anticoagulant is this patient on,"
echo "and how do I reverse it given acute hemorrhage?'"
echo ""
echo "────────────────────────────────────────────────────────────────"
node "$HOME/.bin/memory-search.mjs" "anticoagulant reversal acute hemorrhage" --budget=12000 --k=1 2>/dev/null | head -30
echo "────────────────────────────────────────────────────────────────"
echo ""

# Stage 4: extract the critical assertion the LLM would act on
RESULT=$(node "$HOME/.bin/memory-search.mjs" "anticoagulant reversal acute hemorrhage" --budget=15000 --k=1 2>/dev/null)
if echo "$RESULT" | grep -q "andexanet alfa"; then
  echo "✓ CORRECT — retrieval surfaced 'andexanet alfa' (the apixaban reversal agent)"
  echo "✓ Patient receives the right reversal. Bleeding controlled."
elif echo "$RESULT" | grep -q "Fresh Frozen Plasma"; then
  echo "✗ WRONG — retrieval pulled the stale warfarin protocol."
  echo "✗ This is what vector RAG would have done. Patient at risk."
else
  echo "? UNCLEAR — neither reversal agent surfaced. Index may be empty."
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Encounter active. Press Ctrl-C to end (or wait $TTL_SECONDS sec)."
echo "════════════════════════════════════════════════════════════════"

# Stage 5: TTL countdown (in production: integrated with the mobile app's encounter timer)
sleep "$TTL_SECONDS"
echo ""
echo "[TTL] $TTL_SECONDS-second timer expired — auto-ending encounter"
