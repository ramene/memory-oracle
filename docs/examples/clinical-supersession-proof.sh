#!/usr/bin/env bash
# clinical-supersession-proof.sh
#
# Empirical proof that supersession sidecars correctly surface a 2024 cardiology
# correction OVER a 2008 PCP note — the warfarin → apixaban scenario.
#
# Simulates the ER physician's LLM at 2026-05-17, asking: "what's this patient on?"
# Confirms the merged retrieval output puts the correction (andexanet alfa, NOT FFP)
# BEFORE the stale assertion in the body the LLM would read.

set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../.." && pwd )"
SYNTH_PROJECTS="$REPO_ROOT/docs/examples/clinical-records"
ISOLATED_DB="/tmp/clinical-proof.db"

echo "================================================================"
echo "  Clinical supersession proof — Jane Doe (DOB 1959)"
echo "  ER scenario, 2026-05-17 14:33Z"
echo "================================================================"
echo ""
echo "[setup] synthetic patient memory: $SYNTH_PROJECTS"
echo "[setup] isolated index:           $ISOLATED_DB"
echo ""

# Build an isolated index over the synthetic patient corpus only
rm -f "$ISOLATED_DB" "${ISOLATED_DB}-wal" "${ISOLATED_DB}-shm"
MEMORY_INDEX_DB="$ISOLATED_DB" CLAUDE_PROJECTS_ROOT="$SYNTH_PROJECTS" \
  node ~/.bin/memory-index-build.mjs

echo ""
echo "================================================================"
echo "  STEP 1 — Vector RAG counterfactual (raw file content)"
echo "  What the ER LLM would see if retrieving the raw 2008 file"
echo "================================================================"
echo ""
sed -n '/^## Reversal protocol/,/^## Drug interactions/p' \
  "$SYNTH_PROJECTS/patient-jane-doe-1959/memory/medication_anticoagulant.md" | head -10
echo ""
echo "→ STALE OUTCOME: ER LLM recommends FFP + Vitamin K. Wrong reversal agent."
echo "  Patient bleeds out while wrong agent is administered. Vector RAG fails."
echo ""
echo ""
echo "================================================================"
echo "  STEP 2 — memory-oracle supersession-merged retrieval"
echo "  Same ER LLM query, with supersession sidecar in play"
echo "================================================================"
echo ""

# ER LLM's query — emulated
QUERY="patient anticoagulant reversal acute bleed Jane Doe"

MEMORY_INDEX_DB="$ISOLATED_DB" \
  node ~/.bin/memory-search.mjs "$QUERY" --budget=20000 --k=1

echo ""
echo "================================================================"
echo "  STEP 3 — Litmus check"
echo "================================================================"
echo ""

OUTPUT=$(MEMORY_INDEX_DB="$ISOLATED_DB" node ~/.bin/memory-search.mjs "$QUERY" --budget=20000 --k=1 2>/dev/null)

# The supersession block must appear BEFORE the stale reversal protocol in the merged output
SUPERSEDE_POS=$(echo "$OUTPUT" | grep -n "andexanet alfa" | head -1 | cut -d: -f1)
STALE_POS=$(echo "$OUTPUT" | grep -n "Fresh Frozen Plasma" | head -1 | cut -d: -f1)

if [ -z "$SUPERSEDE_POS" ] || [ -z "$STALE_POS" ]; then
  echo "FAIL: missing one of the markers (super=$SUPERSEDE_POS, stale=$STALE_POS)" >&2
  exit 1
fi

if [ "$SUPERSEDE_POS" -lt "$STALE_POS" ]; then
  echo "PASS — corrected reversal (andexanet alfa, line $SUPERSEDE_POS) appears BEFORE"
  echo "       the stale reversal (FFP, line $STALE_POS) in the merged retrieval."
  echo ""
  echo "An LLM reading this output sees the correction first, treats it as authoritative,"
  echo "and recommends andexanet alfa for the bleed. Patient survives."
  echo ""
  echo "Bonus: the original 2008 protocol is PRESERVED in the same output — so a future"
  echo "clinician investigating WHY the supersession exists can read the historical"
  echo "context. Provenance is intact."
else
  echo "FAIL: stale assertion (line $STALE_POS) appears BEFORE correction (line $SUPERSEDE_POS)" >&2
  exit 1
fi

echo ""
echo "================================================================"
echo "  CLEANUP"
echo "================================================================"
rm -f "$ISOLATED_DB" "${ISOLATED_DB}-wal" "${ISOLATED_DB}-shm"
echo "[cleanup] removed $ISOLATED_DB"
echo ""
echo "Proof complete. See docs/examples/clinical-supersession-proof.md for narrative."
