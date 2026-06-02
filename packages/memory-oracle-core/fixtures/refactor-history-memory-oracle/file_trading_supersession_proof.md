---
name: TRADING-SUPERSESSION-PROOF-FILE
description: Trading case-study litmus script.
metadata:
  type: file
  authored_at: 2026-05-05T13:00:00Z
  files:
    - docs/examples/trading-supersession-proof.sh
---

# docs/examples/trading-supersession-proof.sh

The trading-supersession-proof litmus script demonstrates the same
substrate guarantee on the synthetic alex-cohen trader vault:
the Apr-9 KC-spot no-shorting hard rule plus the May-13 Binance Futures
authorization amendment merge correctly, with the corrected
authorization elevated above the canonical rule.

Cited from §6 of the paper as the cross-domain generalization
demonstration — same primitive that solves the clinical warfarin case
also solves the trading shorting case.
