---
name: SITOUT-AUTO-ENGAGE
description: Sit-out gate auto-engages after N consecutive losses.
metadata:
  type: gate
  authored_at: 2026-03-01T10:00:00Z
  trader: alex-cohen
  parameter: sitout.auto_engage
  default: true
  threshold: 3-consecutive-losses
---

# Sit-out auto-engage: ON by default

After 3 consecutive losing entries on the same agent within a single
trading session, the sit-out gate auto-engages and the agent is paused
for the remainder of the session. Intent: prevent agents from
death-spiral martingaling during regime detection mis-classification.

Implementation: `gates/sitout-auto-engage.ts` reads the per-session
loss counter; if `consecutive_losses(agent) >= 3` and `sitout.auto_engage
== true`, set `agent.paused_until = session_end` and emit a
`sitout-auto-engaged` event.
