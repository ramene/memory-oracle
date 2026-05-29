# ADR — Retrieval Stack for Mae Memory-Oracle

**ADR number**: mae-ADR-001 (first formal ADR in this lineage)
**Date**: 2026-05-16
**Status**: PROPOSED (awaiting operator confirmation)
**Decider**: Ramene (operator)
**Authored**: Claude Opus 4.7 in karve session 2d097fa8, applying Nate Jones' "New RAG War" Prompt 3 (`promptkit.natebjones.com/20260508_639_promptkit_2`, verbatim text at `/tmp/nate-prompt-retrieval-stack-adr.txt`)

**Inputs to this ADR**:
- Contract Spec: `RETRIEVAL-CONTRACT-SPEC-2026-05-16.md`
- Failure Triage: `RETRIEVAL-FAILURE-TRIAGE-2026-05-16.md` (114 memory files classified)
- Live system evidence: `journal-digest-builder.mjs` (L1 shipped); `mae-openai-proxy` + `mae-claude-proxy` (inference fabric); `mae-db` Cloud SQL pgvector-capable on `mae-prod-claey`
- The empirical failure pattern of this very session (25 min hand-grep to surface a 4-day-old architectural fact)

---

## Decision (one sentence)

**For Mae's memory-oracle Layer 2, we will build a hybrid of supersession-aware sidecar JSONL + BM25 + structural index + digest priming, and *defer* the general-purpose pgvector embedding store until a concrete query class arrives that semantic similarity demonstrably wins on.**

---

## Context (the triggering pressure)

The Mae platform accumulates ~5GB/quarter of tmux-logs, ~150 cumulative memory bank files, and a 739MB-and-growing originating-session JSONL. Three pressures converged this week:

1. **Empirical failure today**: A 4-day-old architectural decision (May 12 OpenAI cutover) was un-recoverable from the corpus without 25 minutes of hand-grep. Two memory-bank files in the operator's `~/.claude/projects/*/memory/` directory confidently asserted superseded facts. The operator had to manually re-establish ground truth in conversation — twice.
2. **Nate Jones publishes "The New RAG War Is Not About Vectors"** (2026-05-13). Framing: retrieval contract > vector-store choice. Three prompts (Contract Spec, Failure Triage, Stack ADR) operationalize the framing. We adopted the prompts.
3. **The May 3 PLATFORM-EVOLUTION-NOTES Layer 3 spec** is now mooted on its load-bearing substrate decision: Plutus-3B fine-tune was specced when Plutus was still the inference path; Plutus was retired May 1, replaced by Haiku-via-mae-claude-proxy on May 4, then re-replaced by GPT-5.5-via-mae-openai-proxy on May 12. We must not commit a substrate choice based on a stale architecture snapshot again.

---

## The Retrieval Contract this decision serves

(Full spec at `RETRIEVAL-CONTRACT-SPEC-2026-05-16.md`.) Three-line summary:

> The agent is Claude (CLI/Code/subagents) operating multi-session across mae-monorepo-build, builds.karve.ai, claude-src/claude-code-working, and adjacent repos. The retrieval system must deliver a 30-80KB priming bundle composed of: surface-matched feedback rules (with supersession resolution), active project state, recent digests, tmux-log windows around prior touches, GH Project board slice, live infra state snapshot, and current-session running tally. Bundle must carry provenance metadata, credential-redacted content, and bidirectional supersession links so stale assertions don't masquerade as authoritative.

The contract names **what** must be delivered. This ADR decides **how**.

---

## Alternatives considered

### Alternative α — pgvector-only (the original May 3 Layer 2 plan, mooted on substrate)

**Description**: Embed every tmux-log line + every memory file + every PR description into pgvector on `mae-db`. Build a `memory-search` Skill that takes a natural-language query and returns top-K matching windows. SessionStart hook prepends top-K. This is what Layer 2 in `PLATFORM-EVOLUTION-NOTES-2026-05-03.md` specced.

**Why rejected**:
- The Failure Triage shows ≤15% of the corpus would benefit from semantic-similarity retrieval over keyword/structural match.
- The dominant failure mode (28%) is **supersession** — a problem vectors don't solve at all (a stale memory and its newer corrected truth are *semantically identical*; both will be top-K matches).
- Embedding job over 5GB of tmux-logs is bursty + expensive; embedding model choice is itself a separate decision; per-query latency adds 100-500ms minimum.
- Builds Mode 7 (Overbuilding) risk straight in: 1-2 weeks of infra work for a substrate that doesn't address the load-bearing failure mode.

### Alternative β — Hybrid: pgvector + BM25 + structural index (kitchen-sink)

**Description**: Build all three substrates concurrently. pgvector for semantic, BM25 for keyword, structural index for path/authority. Reranker combines. This is what most "sophisticated RAG" tutorials advocate.

**Why rejected**:
- 3-5× the build cost of γ for ~10-20% additional coverage.
- Reranker tuning is a project unto itself; without eval infra, we'd be flying blind on whether the vector component is even contributing.
- Adds two failure surfaces (embedding drift; reranker tuning) for a marginal win.
- The Triage data does not support the marginal win. We can always add vectors later as a *bolt-on* if a concrete query class arrives that misses keyword search.

### Alternative γ — Skip vectors; BM25 + structural index + supersession sidecars + digest priming + memory-oracle-as-prompt **[CHOSEN]**

**Description**:
1. **Supersession sidecars** — `<memory-file>.supersessions.jsonl` per memory file, with `superseded_by`/`scope`/`corrected_assertion`/`live_evidence` records. Read-time merge: newer wins by default; both surface in audit view.
2. **BM25 over memory-file content** — SQLite FTS5 index colocated with each project's memory dir; rebuilt incrementally on file write via fs-watcher. Sub-millisecond queries; no embedding cost.
3. **Structural index** — Postgres on `mae-db` table mapping `file_path → memory_ids touched in feedback rules`, `topic → authority_source`, `query_class → controlling_source`. Rebuilt nightly + write-time invalidation. Lives next to the existing config_keys schema (no new DB).
4. **Digest priming** — `~/.local/share/journal/digests/YYYY-MM-DD.md` (L1, already shipped; gap-fix tracked as P5 in the Triage). Last-7-days digest read at session-start.
5. **Memory-oracle subagent** — when the surface-area-match retrieval pulls too many candidates (>budget), spawn a Haiku-bucket subagent via `mae-openai-proxy` OR `mae-claude-proxy` (whichever has token budget) with the candidate set as context, asking "which of these are load-bearing for THIS task?" Returns a culled set. **No fine-tune required.**
6. **Provenance envelope** on every retrieved chunk (per Contract Spec Dim 5).
7. **Redaction filter** at retrieval-bundle assembly time (per Contract Spec Dim 4).

**Why chosen**:
- Covers 85%+ of the Triage corpus on direct-prevention basis.
- Build cost ~6-9 days (P0-P3 in the Triage) vs ~10-15 for α and ~15-25 for β.
- No new long-running infra component to maintain (no embedding model, no embedding job cron).
- Composes cleanly with the existing L1 digest layer.
- The structural-index + supersession primitives are *prerequisites* for any future vector layer anyway — if we add vectors later they'll be more useful once these layers exist.

---

## Biggest risk of the proposed decision

**The risk**: there's a class of query that BM25+structural can't handle and vector similarity could. Probable candidates: "find related discussion of $vague_concept across $time_window," "what's the *spirit* of how we approached $similar_problem before," "this code feels like something we've debated before but I don't remember the search terms." These are the queries that semantic similarity is genuinely well-suited for. If they're frequent enough, skipping vectors costs us recall.

**Mitigation**:
- The Contract Spec defines a `memory-search` Skill interface that's substrate-agnostic. Vectors can be added as an additional backend later without changing callers.
- The mae-db pgvector extension is one `CREATE EXTENSION vector;` away on Cloud SQL — adding it later is a 1-hour task, not a 1-week task. We're not painting ourselves into a corner.
- We'll instrument the `memory-search` Skill to log queries that returned <3 useful results. After 30 days, review the misses. If a clear pattern of "this was a semantic-similarity miss" emerges, add the vector backend then with evidence in hand.

**Smaller risks**:
- BM25 over feedback memories may miss when the rule's surface signal isn't in the rule text (e.g., a rule about "PM2 restart" that doesn't mention `pm2 restart` verbatim — uses "redeploy" instead). Mitigation: structural index *also* maps file paths and the rule's named keywords (frontmatter `name` + `description`). Two probes per query.
- Digest reliability gaps (currently May 9, 12-16 missing) need fixing before priming becomes truly trustworthy. Tracked as Triage P5.
- Supersession is a write-back primitive we don't have yet; building it is part of P0 — we must not skip it under deadline pressure.

---

## ADR — `mae-ADR-001`: Memory-Oracle Retrieval Stack

### Title
Use supersession-aware sidecars + BM25 + structural index + digest priming for Mae memory retrieval; defer pgvector embedding store.

### Status
PROPOSED, 2026-05-16. Awaiting operator confirmation.

### Context
See "Context" above. Triggering pressure: this session's empirical failure mode + Nate Jones' May 13 publication + the now-stale May 3 Layer 3 substrate decision.

### Decision
Build Layer 2 of the memory architecture as the **γ stack** described above:

1. **P0 — Supersession sidecar** (1-2 days): `<file>.supersessions.jsonl` schema + read-time merge function + backfill of known supersessions (start with the `feedback_brain_pipeline_max_plan_only.md` → May 12 cutover entry).
2. **P1 — BM25 (FTS5) index** (2-3 days): SQLite FTS5 per `~/.claude/projects/*/memory/` directory; fs-watcher-driven incremental updates; query API at <10ms.
3. **P2 — Provenance envelope + redaction filter** (1-2 days): JSON metadata wrapper on every retrieved chunk; pattern-based credential scrubber at assembly time.
4. **P3 — Authority-tagged structural index** (1-2 days): Postgres table on `mae-db` mapping `(query_class, surface) → controlling_source` plus `file_path → memory_ids` map; rebuilt on memory-file write.
5. **P5 — L1 digest reliability fix** (1 day): triage why May 9 and May 12-16 digests didn't write. Likely cause: provider-chain exhaustion or input-byte budget violation. Restore daily-digest coverage.
6. **P4 — Compiled context candidates** (3-5 days, can ship after P0-P3): pre-composed bundles for known query classes (alert+regime, log+pm_uptime, state-field+full-data-flow-graph).
7. **L3 memory-oracle subagent** (2-3 days, after P0-P4): wire a culling-subagent prompt against GPT-5.5 (primary via mae-openai-proxy) / Sonnet-4.6 (secondary via mae-claude-proxy). NO fine-tune.
8. **`memory-search` Skill** (1 day): user-facing Skill that wraps BM25 + structural lookup + (optional) culling subagent. Substrate-agnostic interface — vector backend can be added later.

### Consequences

**Positive**:
- ~85% of the 114-file corpus failure modes addressed in ~6-9 days of focused build.
- No new long-running infra component (embedding model + bursty embedding job avoided).
- Composes with existing L1 digest layer.
- Backfills supersession data on the load-bearing pain points (Mae's most painful file — `feedback_brain_pipeline_max_plan_only.md` — gets its sidecar in the P0 first commit).
- Substrate-agnostic Skill interface preserves option to add vectors later without rewrite.

**Negative**:
- Misses "semantic similarity over vague-concept queries" use case. Estimated <15% of memory-search calls based on Triage. If this estimate is wrong, we'll see it in the <3-useful-results telemetry.
- Two storage substrates (SQLite FTS5 + Postgres structural index + JSONL sidecars + Markdown digests) — more surfaces to keep coherent than a single pgvector schema would be.
- BM25 quality depends on memory-file text actually containing the surface keywords. Some rules will need light rewrite to surface their trigger conditions in their text.

### Verification plan

1. **Day 1 (after P0 ships)**: re-pose this session's "what's the current brain/coach inference path?" query. Verify the supersession sidecar on `feedback_brain_pipeline_max_plan_only.md` surfaces the May 12 correction and the model answers correctly *from the priming bundle alone* without re-grepping.
2. **Week 1 (after P0-P3 ship)**: run 20 historical queries from the operator's recent corrections (extracted from the originating session JSONL — anywhere the operator typed "no, actually..." or "wrong..."). Measure: how many would the new retrieval stack have answered without operator correction?
3. **Week 2 (after P5 ships)**: digest coverage at 100% of last 30 days, zero gaps. Reliability monitoring as a permanent telemetry surface.
4. **Week 4 (after P4 ships)**: review `memory-search` Skill telemetry — query log + result-count distribution + operator-correction events. If <3-useful-results rate is >20%, revisit the no-vector decision.
5. **Week 8**: full audit. If any of P0-P4 isn't pulling weight, retire it. If the <3-useful-results pattern reveals a clear semantic-similarity miss, add pgvector as the 5th backend.

### Rollback plan

Each layer is independently reversible.

- **Rollback P0 (supersessions)**: delete sidecar files. Memory files revert to "frozen on write" semantics. Cost: re-incur the failure mode this ADR's session demonstrated.
- **Rollback P1 (BM25)**: delete FTS5 index files. `memory-search` Skill falls back to filename glob + grep. Cost: 10-100× slower priming.
- **Rollback P2 (provenance/redaction)**: revert chunk-assembly code. Cost: provenance audit trail gone; redaction risk re-introduced.
- **Rollback P3 (structural index)**: drop the Postgres tables. Cost: authority-source lookups regress to "ask Claude to figure it out."
- **Rollback P5 (digest)**: leave gaps. Cost: priming completeness regresses.
- **Add pgvector later (the inverse of rollback)**: `CREATE EXTENSION vector;` on mae-db, then add an embedding-backend implementation behind the `memory-search` Skill interface. ~1 hour of work plus initial backfill.

### Alternatives explicitly rejected (recorded for audit)

- **α (pgvector-only)**: rejected on Triage data — addresses ≤15% of corpus failure modes, doesn't solve the load-bearing supersession problem.
- **β (hybrid kitchen-sink)**: rejected on cost/benefit — 3-5× build cost of γ for ~10-20% additional coverage that we don't have evidence we need.

### Triggering pressure (for posterity)

The decision is dated 2026-05-16 because:
- L1 digest layer reliability is degrading (5 of last 8 days missing)
- Stale memory files fooled THIS session twice on a load-bearing architectural assertion within a single conversation
- Nate Jones' framework (Contract / Triage / ADR) gave us the discipline to write this down before shipping the wrong substrate
- The May 3 Plutus-Layer-3 spec is empirically dead; we cannot let its successor commit the same overbuilding mistake

---

## Build sequence (concrete next moves)

Once this ADR is accepted:

1. **Today / tomorrow**: write `feedback_brain_pipeline_max_plan_only.md.supersessions.jsonl` as the first manual supersession record (the example from the Triage doc). This is a 5-minute task that immediately addresses the worst pain point and proves the format.
2. **Day 1-2**: implement supersession-merge function in a shared `~/.bin/memory-merge.mjs` script + add to the digest-builder priming step.
3. **Day 3-5**: build the FTS5 BM25 index + fs-watcher; expose as `memory-search` CLI.
4. **Day 6-7**: build the structural index Postgres tables + write-time invalidation.
5. **Day 8**: digest gap-fix (P5).
6. **Day 9-13**: compiled context candidates (P4) + memory-oracle culling subagent.
7. **Day 14**: ship `memory-search` Skill as the user-facing entry point.

End-state at Day 14: A Claude session can be primed at start with a 30-80KB retrieval bundle drawn from the full ~5GB+ corpus, with supersession-resolved memory rules, fresh digests, surface-matched tmux-log windows, redaction-clean content, and full provenance metadata — covering 85%+ of the failure modes documented in the corpus, *without* a single vector embedding.

The vision the operator named at the start of this thread — "this operational against the full 2-3 months of tmux logs, hooks, and transcripts used as context in a given session, no matter if the session is compacted" — is achievable in ~14 days with this stack. It was never blocked on inference; it was blocked on the absence of a written contract and a triaged failure mode map. We now have both.
