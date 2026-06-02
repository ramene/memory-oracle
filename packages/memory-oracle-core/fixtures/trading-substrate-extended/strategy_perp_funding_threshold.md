---
name: PERP-NO-FUNDING-GATE
description: Perpetual contract positions have no funding-rate-based gating.
metadata:
  type: gap
  authored_at: 2026-04-09T23:14:00Z
  trader: alex-cohen
  venue_scope: [no-perps-yet]
---

# No funding-rate gating on perpetual positions

Pre-Binance-Futures rollout: there are no perpetual contract positions
in the system, so there is no funding-rate-based gate. Funding rate
(the periodic payment between long and short perp holders) is not
tracked, not consulted, not gated on. If perpetual contracts are ever
authorized, a funding-rate gate will need to exist.

This is a known gap, not a working feature. Documented here as a
placeholder so future authors do not assume funding-rate gating
exists when adding shorts/perps.
