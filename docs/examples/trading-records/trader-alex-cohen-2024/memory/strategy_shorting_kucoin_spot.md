---
name: KC-SPOT-NO-SHORTING-RULE
description: KuCoin spot accounts cannot short. Execution gate rejects sell orders where balance=0. Hard rule for all KC-venue agents.
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
`a6-momentum`, `a8-scanner-driven`). This rule was authored 2026-04-09
after the operator's "kid blew $206 USDT instantly" incident.

## The rule

For every BUY-side signal that the orchestrator turns into a SELL
proposal (e.g., a scanner-emitted bearish signal that an agent
interprets as "open a short"):

```
if venue == 'kucoin-spot' and balance(symbol) == 0:
    REJECT_REASON = "kc-spot-no-shorting"
    return reject(proposal)
```

No exceptions. KuCoin does not support spot shorting. Agents that
emit BEARISH signals and try to SELL tokens they don't hold will
be rejected at the execution-gate boundary.

## Why this rule exists (the empirical anchor)

2026-04-09T23:14:00Z: agent `a8-scanner-driven` saw `DUCK-USDT`
bearish signal at confidence 0.78. Submitted a SELL order for 1,000
DUCK without holding any. KuCoin returned `-800 "insufficient balance"`
**after 2 retries** that left two orphan `in-flight-buys` entries on
disk. The agent's per-cycle accounting saw the in-flight as committed
and **double-deployed** the same $103 USDT into another bearish
position. Result: $206 lost in 7 minutes across two failed shorts.
The hard rule prevents this class of failure permanently.

## What this rule does NOT cover

- **Mean-reversion LONG dip-buys** on bearishly-trending pairs.
  See orchestrator commit `9865d7b` for the `[MEAN-REV-LONG]` exemption
  added 2026-05-10.
- **Binance futures** or any margin venue (KC does not have futures
  to begin with; this rule is spot-only).

## Operator note

If we ever revisit shorting — and we eventually will — the path goes:
**SHADOW → testnet paper → real-money canary**. Do not back-door the
hard rule. Author a supersession sidecar on this file with the new
authorization path.

— Alex Cohen, Risk, 2026-04-09
