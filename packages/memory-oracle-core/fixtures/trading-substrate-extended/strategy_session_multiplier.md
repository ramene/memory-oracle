---
name: SESSION-MULTIPLIER-1.15
description: Per-session confidence multiplier applied uniformly across regimes.
metadata:
  type: strategy
  authored_at: 2026-02-14T09:00:00Z
  trader: alex-cohen
  parameter: MAE_SESSION_CONF_MULT
  default: 1.15
---

# Session multiplier: hardcoded 1.15

Applied uniformly to every signal confidence value emerging from an
agent cycle within a single trading session. Rationale: empirically the
average agent under-states confidence by ~15% during cold-start cycles
versus warm cycles, so a uniform 1.15 multiplier corrects the bias.

Implementation: `MAE_SESSION_CONF_MULT=1.15` in env, read at orchestrator
boot, applied in `mae/orchestrator/cycle.ts:applySessionMultiplier()`.

This is the same multiplier regardless of regime (chop-day, trend-day,
news-day, chop-active). A single number applied everywhere.
