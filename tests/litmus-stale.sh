#!/usr/bin/env bash
# litmus-stale.sh — proves supersession sidecars win over raw file content during retrieval.
#
# Creates a temp memory file with a stale assertion + a sidecar correction, runs memory-search,
# verifies the merged output prepends the correction (⚠ Supersession Notice) before the stale text.

set -euo pipefail

TMP_PROJ="${HOME}/.claude/projects/_litmus_stale_test"
TMP_FILE="$TMP_PROJ/memory/feedback_stale_assertion.md"
SIDECAR="$TMP_FILE.supersessions.jsonl"
trap 'rm -rf "$TMP_PROJ"' EXIT

mkdir -p "$(dirname "$TMP_FILE")"
cat > "$TMP_FILE" <<'EOF'
---
name: stale-assertion-test
description: Brain pipeline is X — never use Y as a fallback
type: feedback
---
The brain pipeline must use service X. Using Y as a fallback causes double-billing.
EOF

cat > "$SIDECAR" <<EOF
{"superseded_at":"2026-05-12T22:23:49Z","scope":"the claim that 'must use service X'","corrected_assertion":"Service X was retired 2026-05-12. New primary is service Y. The previous billing concern no longer applies because Y is a different vendor.","live_evidence":["/some/live/path"],"operator_confirmed":"2026-05-16T18:00:00Z","retention_policy":"retain — re-emerges if cutover reverses"}
EOF

# Force an index rebuild so the test file is queryable
node "${HOME}/.bin/memory-index-build.mjs" >/dev/null

# Query for the stale concept
OUTPUT=$("${HOME}/.bin/memory-search.mjs" "stale-assertion-test" --budget=4000 --k=1 2>/dev/null)

# Check: the supersession block must appear BEFORE the original assertion in the merged output
SUPERSEDE_POS=$(echo "$OUTPUT" | grep -n "Supersession Notice" | head -1 | cut -d: -f1)
ORIGINAL_POS=$(echo "$OUTPUT" | grep -n "must use service X" | head -1 | cut -d: -f1)

if [ -z "$SUPERSEDE_POS" ]; then
  echo "FAIL: supersession notice not in retrieval output" >&2
  exit 1
fi
if [ -z "$ORIGINAL_POS" ]; then
  echo "FAIL: original content not in retrieval output" >&2
  exit 1
fi
if [ "$SUPERSEDE_POS" -ge "$ORIGINAL_POS" ]; then
  echo "FAIL: supersession block did not precede original content (super=$SUPERSEDE_POS, orig=$ORIGINAL_POS)" >&2
  exit 1
fi

echo "PASS: supersession block (line $SUPERSEDE_POS) precedes stale assertion (line $ORIGINAL_POS)"
