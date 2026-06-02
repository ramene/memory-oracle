---
name: CHOPDAY-MINSIGNAL-0.72
description: Minimum signal confidence floor for chop-day regime entries.
metadata:
  type: parameter
  authored_at: 2026-01-30T08:00:00Z
  trader: alex-cohen
  parameter: chopday.minSignalConfidence
  default: 0.72
  affected_pairs: [APE-USDT, ENJ-USDT]
---

# chop-day regime: minSignalConfidence floor 0.72

When the regime detector classifies the day as chop-day, agent entry
proposals require signal confidence ≥ 0.72 to pass the per-cycle gate.
Rationale: chop-day regimes exhibit high mean-reversion noise; lower
confidence signals produce too many false entries that get stopped out
within 1-2 cycles.

Applies particularly to APE-USDT and ENJ-USDT where chop-day false
positives dominate the loss profile. Implementation in
`gates/chopday-signal-floor.ts`. Default 0.72 is empirically derived
from Q4 2025 backtest sweep.
