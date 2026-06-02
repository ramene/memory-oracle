---
name: CHOPDAY-MINALETHEIA-0.55
description: Aletheia signal weight floor for chop-day regime ensemble.
metadata:
  type: parameter
  authored_at: 2026-02-08T12:00:00Z
  trader: alex-cohen
  parameter: chopday.minAletheiaWeight
  default: 0.55
  signal_source: aletheia-kucoin-scanner
---

# chop-day regime: Aletheia weight floor 0.55

For ensemble-weighted entries during chop-day, the Aletheia signal
component (kucoin-scanner emitter, trust score 0.44) must contribute
weight ≥ 0.55 to the final ensemble score for the entry to pass.

Rationale: Aletheia tends to over-weight scanner-driven momentum
during chop-day, so a high floor forces the ensemble to require
strong Aletheia conviction before chop-day entries fire. 0.55
empirically chosen from Q1 2026 forward-walk validation.

Implementation: `gates/chopday-aletheia-floor.ts`.
