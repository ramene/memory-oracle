# memory-oracle

> Supersession-aware memory retrieval for AI coding agents. No vectors, no fine-tuning, no daemon — just BM25 over Markdown + additive correction sidecars + a SessionStart hook that primes every new session.

## The problem this solves

Agents parrot stale memory files because nothing tells them the file is wrong.

You write a memory note today: *"the brain pipeline routes through `mae-claude-proxy` — never add `ANTHROPIC_API_KEY` fallback."* Two weeks later the architecture changes and the brain moves to a different proxy entirely. Tomorrow you ask an agent about the inference path; it reads the original file verbatim and confidently gives you the obsolete answer. You correct it. It apologizes. The file still says the wrong thing. The next session repeats the cycle.

This is the **Bad Write-Back** failure mode: memory files calcify as authoritative truth long after the world moves on. Vector embeddings don't help — they retrieve the same stale file with high cosine similarity. Re-writing the file destroys provenance.

## The pattern

**Supersession sidecars** — additive `.jsonl` files that layer corrections beside the canonical memory file. The original is never edited. The retrieval CLI merges supersessions at read time and prepends a ⚠ Supersession Notice block so the agent sees the correction before it sees the stale claim.

```
~/.claude/projects/mae/memory/
├── feedback_brain_pipeline.md                      # canonical (never edited)
└── feedback_brain_pipeline.md.supersessions.jsonl  # additive corrections
```

When `memory-search` returns this file, the merged output starts with:

```
## ⚠ Supersession Notice (1 record)
This file contains content that has been superseded by later authoritative events.

### Supersession 1 — 2026-05-12T22:23:49Z
**Corrected assertion:** As of 2026-05-12, the brain path PRIMARY is GPT-5.5 via
mae-openai-proxy. mae-claude-proxy is now SECONDARY/FALLBACK.
**Live evidence:** /path/to/journal-digest-builder.mjs lines 45-83
**Operator confirmed:** 2026-05-16
---
[original file content, preserved verbatim]
```

The agent reads the correction first, the original second. Stale assertions can't fool retrieval because the correction is authored adjacent to the source, not in place of it.

## Architecture

Three SQLite FTS5 layers indexed at write-time:

| Layer | Source | Purpose |
|---|---|---|
| **Curated memory** | `~/.claude/projects/*/memory/*.md` | Operator-authored truth |
| **Supersession sidecars** | `*.supersessions.jsonl` next to each file | Additive corrections (never overwrite) |
| **Journal digests** | `~/.local/share/journal/digests/*.md` | Per-day transcript-distilled rollups |

Plus two retrieval CLIs:

- **`memory-search`** — BM25 query, supersession-merged, budget-capped (default 30 KB)
- **`memory-cite`** — bridge to raw transcripts (Tier 2) without indexing the firehose

Plus a SessionStart hook that auto-primes every new Claude Code session with relevant supersession-aware context before the first prompt is sent.

See [`docs/RETRIEVAL-STACK-ADR.md`](docs/RETRIEVAL-STACK-ADR.md) for the architectural decision record explaining why this design (γ) was chosen over pgvector (α) and the hybrid kitchen-sink (β).

## Install

```bash
./install.sh
```

This:
- Copies `bin/*` to `~/.bin/`
- Installs the SessionStart hook to your Claude Code `~/.claude/settings.json`
- Loads the launchd plist (macOS) or systemd unit (Linux) for the fs-watcher
- Builds the initial FTS5 index from `~/.claude/projects/*/memory/`

## Usage

```bash
# Manual query
memory-search "OpenAI proxy deploy"

# Verify a supersession citation against the raw transcript
memory-cite session-id-here#L94616 --context 3

# Add a supersession sidecar (when you observe a memory file asserting something stale)
cat <<EOF >> ~/.claude/projects/PROJECT/memory/FILE.md.supersessions.jsonl
{"superseded_at":"$(date -u +%FT%TZ)","scope":"what claim is invalidated","corrected_assertion":"the new truth","live_evidence":["/path/to/verify"],"operator_confirmed":"$(date -u +%FT%TZ)","retention_policy":"when to retire"}
EOF
# The fs-watcher picks it up and rebuilds the index in ~1s
```

## Why this isn't another RAG library

| | Vector RAG (pgvector, LangMem, etc.) | memory-oracle |
|---|---|---|
| Storage | Embeddings of chunks | Plain markdown + JSONL sidecars |
| Retrieval | Cosine similarity | BM25 keyword |
| Correction | Re-embed updated chunk (loses provenance) | Append sidecar (preserves both) |
| Compute | GPU for embedding, network for queries | None — SQLite CLI |
| Stale-file fooling | Yes (retrieves the embedding of the stale content) | No (correction merged at read time) |
| Self-extending | No (you must re-embed) | Yes (agents write new memory mid-session, indexed in ~1s) |
| Lines of code | ~10K + dependencies | ~1.5K, zero deps beyond `sqlite3` + `node` |

See [`docs/COMPARISON.md`](docs/COMPARISON.md) for the full breakdown, including the contrast with Karpathy-style autoresearch loops.

## Proven at scale

- **Corpus today**: 186 documents, 97-day span, 19 projects
- **Index size**: <10 MB
- **Query latency**: <100 ms (cold), <30 ms (warm)
- **Re-index after write**: <1 second via fs-watcher
- **Self-extension proof**: agents primed with supersession-aware retrieval write new memory files during work; the fs-watcher absorbs them; the next session retrieves them. The corpus is self-extending. Documented in `docs/examples/self-extending-loop.md`.

## License

MIT.

## Origin

Built 2026-05-16 in a single session to solve the failure mode of "agent quotes stale memory files." The full design rationale (Retrieval Contract Spec, Failure Triage, ADR) lives in `docs/`. Direct ancestor: Nate Jones's "The New RAG War Is Not About Vectors" — the systems-design framing that crystallized why vector retrieval was the wrong primitive for AI-coding-agent memory.
