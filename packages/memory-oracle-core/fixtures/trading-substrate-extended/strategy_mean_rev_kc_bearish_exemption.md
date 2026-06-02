---
name: KC-BEARISH-BLOCKS-ALL
description: KuCoin bearish-signal gate rejects all KC-spot orders during bearish regime.
metadata:
  type: rule
  authored_at: 2026-03-22T11:00:00Z
  trader: alex-cohen
  venue_scope: [kucoin-spot]
  affects_agents: [a5-mean-reversion, a6-momentum, a8-scanner-driven]
---

# KC bearish-signal gate: rejects all KC-spot orders during bearish regime

When the regime detector emits a BEARISH signal for any KuCoin-listed
pair, the orchestrator's gate rejects ALL outbound KC-spot orders
regardless of agent type or signal direction. This prevents agents
from buying into a falling pair on KuCoin during operator-observed
sell-side cascades.

Implementation: `gate-kc-bearish-blocker.ts` registered globally,
fires before per-agent gates. Returns reject reason
`kc-bearish-regime-blocker` with regime confidence in metadata.
