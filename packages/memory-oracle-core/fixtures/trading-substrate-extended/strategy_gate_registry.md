---
name: NO-GATE-REGISTRY
description: Pre-Phase 0.2.5 — gates run ad-hoc, no registry, no composition tracing.
metadata:
  type: architecture
  authored_at: 2026-01-15T09:00:00Z
  trader: alex-cohen
  phase: 0.2.4
---

# No gate registry (pre-Phase 0.2.5)

Each gate is its own file under `mae/gates/`, registered manually by
direct import in the orchestrator's cycle loop. No central registry
exists. Order of gate evaluation is determined by import order in
`cycle.ts`. No composition tracing: if a proposal is rejected, only
the FIRST rejecting gate's reason is captured; cascading rejections
across multiple gates are invisible.

Known gates (as of 2026-01): kc-bearish-blocker, chopday-signal-floor,
chopday-aletheia-floor, sitout-auto-engage, kc-spot-no-shorting,
balance-check.
