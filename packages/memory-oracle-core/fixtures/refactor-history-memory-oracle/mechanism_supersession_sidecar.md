---
name: SUPERSESSION-SIDECAR-MECHANISM
description: The mechanism layer of accretive memory — supersession sidecar files store amendments next to canonical assertions.
metadata:
  type: mechanism
  authored_at: 2026-04-20T12:00:00Z
  layer: MECHANISM
  file_extension: .supersessions.jsonl
---

# Supersession sidecar — the mechanism layer

Each canonical memory file (`*.md`) has an optional sidecar named
`*.md.supersessions.jsonl`. The sidecar stores one JSON record per line,
each representing a single supersession event that elevates a corrected
assertion over the canonical text.

Schema fields: `superseded_at`, `scope`, `corrected_assertion`,
`source`, `live_evidence`, `operator_confirmed`, `retention_policy`.

The merge primitive (`bin/memory-merge.mjs`) reads the canonical `.md`
plus the `.supersessions.jsonl` sidecar and produces a merged output
with the latest supersession first. This is the substrate's core
retrieval contract.

Vocabulary: the noun is "supersession sidecar"; the verb is "supersedes"
(record A supersedes record B).
