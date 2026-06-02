---
name: BRAIN-CASCADE-4-TIER-MONITOR
description: 4-tier MONITOR brain cascade with Haiku-direct T4 fallback.
metadata:
  type: architecture
  authored_at: 2026-05-21T08:56:00Z
  trader: alex-cohen
  component: brain-cascade
  cascade_type: MONITOR
  tiers: 4
---

# Brain cascade: 4-tier MONITOR with Haiku-direct T4

MONITOR mode brain cascade for low-stakes per-cycle monitoring queries.
Four tiers in order: T1 Sonnet via OpenClaw, T2 Opus via OpenClaw,
T3 Llama-3.1-70B via OpenClaw, T4 Haiku direct to api.anthropic.com.

T4 direct-Haiku fallback is the safety net: if OpenClaw is unreachable
or all three OpenClaw paths return rate-limit, T4 hits Anthropic's
Haiku endpoint directly with the operator's account key. This bypasses
the OpenClaw proxy entirely.

Implementation: `mae/brain/cascade/monitor.ts`, configured as a frozen
config in `mae/brain/configs/MONITOR_4TIER.ts`. Direct API calls to
api.anthropic.com and api.openai.com are non-zero in this cascade.
