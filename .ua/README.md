# .ua — understand-anything knowledge graph (in-repo overlay)

This directory carries the **understand-anything (UA)** knowledge graph for
**llm-money-flow** (UA scope `llm-money-flow`) — the cross-cutting value/attention
flow across memory-oracle + the digest builder. memory-oracle is its primary home.
It lives in-repo so the graph versions with the code and auto-refreshes on push.

- `knowledge-graph.json` — nodes / edges / layers / tour, rendered by the UA dashboard.

## How it is served (tailnet-only, token-gated — never public)
Served live on **sequoia** (192.168.100.30 / tailnet 100.117.102.126):

    ~/.bin/ua-scoped-ctl.sh llm-money-flow 5180 ua-money-flow start   # stop|status

- LAN     http://192.168.100.30:5180/?token=ua-money-flow
- Tailnet http://100.117.102.126:5180/?token=ua-money-flow

The dashboard reads `$GRAPH_DIR/.ua/knowledge-graph.json`; the data endpoint 403s
without the token. Tailscale **Funnel is forbidden**. Vanity home:
**https://understand.noodles.haus** (tailnet, valid TLS via Caddy ACME DNS-01).

## How it is regenerated (regen-on-push)
Built by the UA Claude-Code plugin (scan -> tree-sitter static analysis -> LLM
file-analyzer subagents -> merge -> layers/tour). Because this scope is
cross-cutting, regen re-scopes across memory-oracle + digest sources. GitHub
**cloud** runners cannot reach the tailnet, so regen runs on a **self-hosted runner
on sequoia** (or the local git-hook fallback): `.github/workflows/understand.yml`
on push to `develop` regenerates this graph, commits it back (signed), and refreshes
the served dashboard via `ua-scoped-ctl.sh`.

See `docs/ua-graphs-in-repo-and-regen-2026-09-09.md` for the full design + enable steps.
