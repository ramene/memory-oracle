---
name: KC-SPOT-NO-SHORTING-RULE
description: KuCoin spot accounts cannot short. Hard rule for all KC-venue agents.
metadata:
  type: feedback
  authored_at: 2026-04-09T23:14:00Z
  trader: alex-cohen
  venue_scope: [kucoin-spot]
  capital_band: 10-USD-ladder
  regime_context: any
---

# Hard rule: KuCoin spot agents cannot short

Effective immediately for all KuCoin spot agents (`a5-mean-reversion`,
`a6-momentum`, `a8-scanner-driven`). Authored 2026-04-09 after the
operator's "kid blew $206 USDT instantly" incident.

For every BUY-side signal that the orchestrator turns into a SELL
proposal: if `venue == 'kucoin-spot'` and `balance(symbol) == 0`,
REJECT with reason `kc-spot-no-shorting`. No exceptions. KuCoin does not
support spot shorting; agents that emit BEARISH signals and try to SELL
tokens they don't hold are rejected at the execution-gate boundary.
