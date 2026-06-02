# trading-substrate-extended

Extended trading-substrate corpus for §8 BEIR-style multi-corpus retrieval panel.

Builds on the existing `docs/examples/trading-records/trader-alex-cohen-2024`
single-pair canonical+amendment vault (KC-spot-no-shorting rule + Binance
Futures shorting authorization). This extended corpus adds 8 more
operator-grounded canonical+amendment pairs derived from the
amendment-shaped events documented in:

- `paper/lncs/main.tex` §6 (six May-10 amendment-shaped events)
- `reference_accretion_pattern_in_mae.md` (operator-authored 2026-05-17)
- The existing trading-case-study.ipynb §6 operator-corpus probe

Each pair is one canonical `.md` file plus one `.md.amendments.jsonl` sidecar.
Field convention matches the existing trading vault (`superseded_at`,
`corrected_assertion`, `source`, `live_evidence`, `operator_confirmed`,
`retention_policy`).

## Corpus contents

| Canonical file | Amendment | Originating event |
|---|---|---|
| `strategy_shorting_kucoin_spot.md` | Apr-9 hard rule → May-13 Binance Futures 3-stage rollout | KC-spot incident + 2026-05-13 risk decision |
| `strategy_session_multiplier.md` | Hardcoded 1.15 → regime-aware blend at MAE_SESSION_CONF_MULT=143 | May-10 amendment #1 |
| `strategy_mean_rev_kc_bearish_exemption.md` | KC bearish blocks ALL → MEAN-REV-LONG exempt (9865d7b) | May-10 amendment #2 |
| `strategy_chopday_signal_confidence_floor.md` | minSignalConfidence 0.72 → 0.65 (APE / ENJ) | May-10 amendment #3 |
| `strategy_chopday_aletheia_weight.md` | minAletheiaWeight 0.55 → 0.40 (kucoin-scanner) | May-10 amendment #4 |
| `strategy_sitout_auto_engage.md` | Auto-engage ON → force-off flag | May-10 amendment #5 |
| `strategy_gate_registry.md` | Pre-Phase 0.2.5 (no registry) → 6-gate registry + composition tracer | May-10 amendment #6 |
| `strategy_brain_cascade.md` | 4-tier MONITOR with Haiku-direct T4 → 5-tier COACH + 4-tier MONITOR (Haiku LAST, no direct API) | May-23 commit 5a82f50 + 5a3f6d8 reorder |
| `strategy_perp_funding_threshold.md` | No funding-rate-based gating → +0.05%/8h add gate, +0.08%/8h circuit breaker | May-13 risk committee (Binance Futures rollout) |

All amendment records preserve the canonical assertion for audit. None of
these would be retrievable from public training data; the operator-specific
rules are the substrate's reason to exist (§3 paper claim).
