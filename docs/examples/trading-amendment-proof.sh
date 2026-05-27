#!/usr/bin/env bash
# trading-amendment-proof.sh
#
# Empirical proof that amendment records correctly surface a 2026-05-13
# operator-ratified shorting rollout OVER the 2026-04-09 hard "no shorting"
# rule — the KuCoin → Binance Futures progression scenario.
#
# Simulates the coach LLM at 2026-05-23, asking: "can this agent open a short
# on ENJ during a regime flip?" Confirms the merged retrieval puts the
# 3-stage rollout authorization (with its funding-rate gates + circuit-breaker)
# BEFORE the original "kc-spot-no-shorting" hard rule in the body the LLM
# would read.

set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../.." && pwd )"
SYNTH_PROJECTS="$REPO_ROOT/docs/examples/trading-records"
ISOLATED_DB="/tmp/trading-proof.db"

echo "================================================================"
echo "  Trading amendment proof — Trader Alex Cohen"
echo "  Coach scenario, 2026-05-23 21:00Z"
echo "  Question: can agent open a Binance Futures short on ENJ now?"
echo "================================================================"
echo ""
echo "[setup] synthetic trader memory: $SYNTH_PROJECTS"
echo "[setup] isolated index:          $ISOLATED_DB"
echo ""

# Build an isolated index over the synthetic trader corpus only
rm -f "$ISOLATED_DB" "${ISOLATED_DB}-wal" "${ISOLATED_DB}-shm"
MEMORY_INDEX_DB="$ISOLATED_DB" CLAUDE_PROJECTS_ROOT="$SYNTH_PROJECTS" \
  node ~/.bin/memory-index-build.mjs

echo ""
echo "================================================================"
echo "  STEP 1 — Vector RAG counterfactual (raw file content)"
echo "  What the coach LLM would see retrieving the raw Apr-9 rule"
echo "================================================================"
echo ""
sed -n '/^## The rule/,/^## Why this rule exists/p' \
  "$SYNTH_PROJECTS/trader-alex-cohen-2024/memory/strategy_shorting_kucoin_spot.md" | head -16
echo ""
echo "→ STALE OUTCOME: coach LLM sees blanket 'NO SHORTING' rule, blocks the agent."
echo "  The May-13 authorization for Binance Futures shorts is invisible (it's"
echo "  in a sibling sidecar file, not in this canonical rule). The agent misses"
echo "  the authorized opportunity. Vector RAG fails — old rule out-ranks new rule"
echo "  because the canonical text has more lexical overlap with 'shorting'."
echo ""
echo ""
echo "================================================================"
echo "  STEP 2 — memory-oracle amendment-merged retrieval"
echo "  Same coach LLM query, with amendment record in play"
echo "================================================================"
echo ""

# Coach LLM's query — emulated. Avoid putting unique marker strings in the
# query itself so the litmus markers below cannot match the query echo at
# the top of memory-search's output.
QUERY="agent shorting authorization rollout funding gate"

MEMORY_INDEX_DB="$ISOLATED_DB" \
  node ~/.bin/memory-search.mjs "$QUERY" --budget=20000 --k=1

echo ""
echo "================================================================"
echo "  STEP 3 — Litmus check"
echo "================================================================"
echo ""

OUTPUT=$(MEMORY_INDEX_DB="$ISOLATED_DB" node ~/.bin/memory-search.mjs "$QUERY" --budget=20000 --k=1 2>/dev/null)

# The amendment block must appear BEFORE the canonical hard rule
# in the merged output. We use two markers, each chosen to appear in
# exactly one place and NOT in the search-query echo at the top of
# memory-search output:
#  - "Stage 1 (SHADOW)" appears only in the amendment's corrected_assertion
#  - "kid blew" appears only in the canonical body's "Why this rule exists"
SUPERSEDE_POS=$(echo "$OUTPUT" | grep -n "Stage 1 (SHADOW)" | head -1 | cut -d: -f1)
STALE_POS=$(echo "$OUTPUT" | grep -n "kid blew" | head -1 | cut -d: -f1)

if [ -z "$SUPERSEDE_POS" ] || [ -z "$STALE_POS" ]; then
  echo "FAIL: missing one of the markers (super=$SUPERSEDE_POS, stale=$STALE_POS)" >&2
  exit 1
fi

if [ "$SUPERSEDE_POS" -lt "$STALE_POS" ]; then
  LEAD=$((STALE_POS - SUPERSEDE_POS))
  echo "PASS — May-13 Binance Futures authorization (line $SUPERSEDE_POS) appears BEFORE"
  echo "       the Apr-9 KC-spot hard rule (line $STALE_POS) in the merged retrieval."
  echo "       Lead = $LEAD lines."
  echo ""
  echo "A coach LLM reading this output sees the NEW authorization first, with all"
  echo "its gate conditions: 3-stage rollout, funding_rate_threshold, max_leverage_in_regime,"
  echo "circuit_breaker_action. It applies the gates correctly. If all pass, the agent"
  echo "opens the short on Binance Futures — NOT on KuCoin spot (the old hard rule"
  echo "still applies there, and is correctly preserved in the canonical body below)."
  echo ""
  echo "Bonus: the original Apr-9 rule is PRESERVED in the same output — so a future"
  echo "operator investigating WHY shorting is allowed on Binance but not KC can read"
  echo "the historical context. Provenance is intact."
else
  echo "FAIL: canonical (line $STALE_POS) appears BEFORE amendment (line $SUPERSEDE_POS)" >&2
  exit 1
fi

echo ""
echo "================================================================"
echo "  CLEANUP"
echo "================================================================"
rm -f "$ISOLATED_DB" "${ISOLATED_DB}-wal" "${ISOLATED_DB}-shm"
echo "[cleanup] removed $ISOLATED_DB"
echo ""
echo "Proof complete. This is the trading-platform parallel of the clinical"
echo "warfarin → apixaban proof. Same primitive (Evidence-Bound Retrieval (EBR)), same"
echo "precedence invariant (Theorem 1), different domain. See"
echo "paper/lncs/main.tex §6 Cross-Domain Generalization for the writeup."
