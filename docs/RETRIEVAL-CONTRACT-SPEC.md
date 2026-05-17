# Retrieval Contract Spec — Mae Memory-Oracle Architecture

**Date**: 2026-05-16
**Author**: Ramene (operator) + Claude (Opus 4.7, session 2d097fa8 in karve, applying Nate Jones' "New RAG War" Prompt 1)
**Supersedes**: §Effort 2 of `PLATFORM-EVOLUTION-NOTES-2026-05-03.md` (the Plutus-substrate Layer 3 spec)
**Source prompt**: `promptkit.natebjones.com/20260508_639_promptkit_2` (verbatim text cached at `/tmp/nate-prompt-retrieval-contract-spec.txt`)

---

## TL;DR

This document is the *engineering artifact* that names what Mae's memory-oracle retrieval system must deliver before a Claude session starts acting. It exists because the prior architecture spec (PLATFORM-EVOLUTION-NOTES, 2026-05-03) is now stale on its load-bearing substrate decision: it specced Plutus-3B fine-tune as Layer 3, but Plutus was retired May 1, the brain/coach path moved to Haiku-via-mae-claude-proxy on May 4, and the OpenAI cutover that re-targets Layer 3 to GPT-5.5-via-mae-openai-proxy started May 12 and is in-flight as of today.

The forensic exercise of recovering that timeline — 25 minutes of greping 5GB of tmux-logs + 739MB of session JSONL to surface a 4-day-old architectural decision — *is the existence proof for this document*. We cannot keep operating without a written retrieval contract.

---

## Input Gate (per Nate's prompt §1)

### 1. Agent description
The retrieval consumer is Claude (CLI / Code / agent-spawned subagents) running against the operator's projects:
- `mae-monorepo-build` (Mae trading platform, primary)
- `builds.karve.ai` (MCP/x402 ecosystem)
- `claude-src/claude-code-working` (the custom Claude Code fork)
- Sibling projects: skill repos, plans repos, journal

**Tools the agent can call**: Read, Write, Edit, Bash, Grep, Agent (subagent spawning), TaskCreate/Update/List, ScheduleWakeup, ExitPlanMode, MCP tools (Substack, x402, Polymarket, EaaS, Gmail, Google Drive, NotebookLM, GitHub, etc.), and `claude-code` itself via the custom fork.

**Actions the agent takes**: code modification, infra ops (`pulumi up`, `gcloud`, `pm2`), trade-execution decisions via Mae coach, PR creation, GH Project #31 board mutation, multi-session memory writes (`feedback_*.md`, `project_*.md`, `reference_*.md`), Cloud Run service deploys, OAuth-token rotations, Cloud SQL operations.

### 2. Work objects
The named entities the agent operates on per task — what the retrieval bundle is FOR:

- **Tmux-log artifacts** — hooks (PostToolUse), transcripts (JSONL exports), term (raw terminal frames), streaming (capture-pane). ~5GB across 2026-02 → 2026-05.
- **Memory bank entries** — `feedback_*.md` (rules), `project_*.md` (state), `reference_*.md` (lookups). ~56 in mae alone; similar density per project.
- **GH Project #31 board items** — 94 Todos, ~60% shipped-but-unflipped per the May 2 empirical audit.
- **Git artifacts** — commits, PRs, repo trees across the 4 active repos.
- **Live infra state** — Cloud Run service revisions (`mae-claude-proxy`, `mae-openai-proxy`, `openclaw-gateway`), Cloud SQL endpoints (`mae-db` on `mae-prod-claey`, `mae-trading-db` on `claey-338919`), Secret Manager versions, PM2 process map, Pulumi stack outputs.
- **Daily digests** — `~/.local/share/journal/digests/YYYY-MM-DD.md`, the Layer 1 output, ~3-15KB/day.
- **The current session itself** — running tally of edits + decisions + tool calls, with running compression.

### 3. Current retrieval stack — ACTUAL state as of 2026-05-16

**Inference fabric** (corrected; the previous spec was wrong by 12 days):

- `mae-openai-proxy` — Cloud Run service in `claey-338919`, OAuth via `auth.openai.com` (Codex CLI client_id `app_EMoamEEZ73f0CkXaXp7hrann`) → `chatgpt.com/backend-api/codex/responses`. ChatGPT Plus/Pro/Business subscription billing. **PRIMARY for L1 digest builder as of cutover that started 2026-05-12T22:23 UTC.** 173 occurrences in the originating session JSONL across May 12-16.
- `mae-claude-proxy` — Cloud Run service in `claey-338919`, OAuth via `platform.claude.com` (Anthropic Claude Code client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`) → `api.anthropic.com/v1/messages`. Max Plan subscription billing. **Now SECONDARY/FALLBACK in L1.** Still primary for any non-cutover paths.
- `claude-custom` fork — `/Users/ramene/.remote/claude-src/claude-code-working` (commit `ae396db`, Apr 1 fork). Basis for both OAuth patterns.

**Retrieval layers**:

- **L1 — Daily digest cron**: SHIPPED at `~/.bin/journal-digest-builder.mjs` (454 lines), cron `55 23 * * *`. Provider chain (in order): `gpt-5.5 via mae-openai-proxy (openai-responses shape)` → `sonnet-4-6 via mae-claude-proxy` → `haiku-4-5 via mae-claude-proxy`. Output: `~/.local/share/journal/digests/YYYY-MM-DD.md`. **Reliability gaps**: digests missing for 2026-05-09, 2026-05-12 through 2026-05-16. Likely cause: provider chain not exhausting gracefully or input-size budget violation on some days. **OPEN BUG.**
- **L2 — pgvector retrieval**: NOT BUILT. Intended target: `mae-db` Cloud SQL in `mae-prod-claey` (Pulumi M1 stack `mae-platform-prod` — RUNNABLE on db-f1-micro). `memory-search` Skill: not written. ADR: not written.
- **L3 — Memory-oracle subagent**: NOT BUILT. Substrate corrected: previously specced as Plutus-3B fine-tune; now intended as GPT-5.5-via-mae-openai-proxy with retrieved context injected via subagent prompt. **No fine-tune required.**

**Currently for memory queries (no retrieval mechanism)**: hand-grep `~/.local/share/tmux-logs/`, hand-read memory bank files, hand-scan 739MB session JSONL. **This is the failure mode this doc is the response to.**

### 4. Two sample tasks
- **Does well** — *"Look up commit SHA + diff for fix X."* `git log --oneline | grep` → `git show <sha>`. Fast, deterministic, source-of-truth lookup. No retrieval-layer help needed.
- **Does badly** — *"What's the current brain/coach inference path?"* Verbatim from this very session: required 25 minutes of hand-grep across the corpus, with two superseded memory files (`feedback_brain_pipeline_max_plan_only.md` from May 4 and `project_176_oauth_validated.md` from Apr 29) giving wrong answers before ground truth was reached. **This is the empirical existence proof for the whole spec.**

---

## The Seven Dimensions

### Dimension 1 — Work object

The retrieval system's work object is **"the operator's intent for THIS session, anchored to durable rules + recent decisions + current platform state"**, parameterized by:
- **Project** (`mae-monorepo-build` / `builds.karve.ai` / etc.) → identifies which memory bank
- **Surface area** (file paths touched, package names, infra components named in the user prompt or recent tool calls)
- **Actor** = single operator. Multi-session continuity is a hard requirement.

NOT "a query." NOT "a document." The business object is operator-intent-this-session, and every retrieval bundle is in service of preserving continuity of that intent across compaction events and session boundaries.

### Dimension 2 — Retrieval units required

Per session-prime (or major task transition):

| Unit type | Count per task | Size each | Selection rule |
|---|---|---|---|
| Surface-matched feedback rules | 5-20 | 500B-2KB | File-path or keyword intersection, recency, **not superseded** |
| Active project state | 3-10 | 1-5KB | In-flight initiatives intersecting surface, **not superseded** |
| Reference lookups | 5-20 | 200B-1KB | Infra coords touched by task |
| Recent digests | 3-7 | 3-15KB | Last N days, gap-tolerant |
| Tmux-log windows | 2-5 spans | 5-50 lines each | Around prior touches of the same surface |
| GH Project #31 board slice | 3-15 | 500B-2KB | Items intersecting surface |
| Live infra state snapshot | 1 | 1-3KB | Cloud Run URLs + PM2 list + Cloud SQL endpoints (only when task touches infra) |
| Current-session running tally | 1 (compressed) | 2-10KB | Edits + decisions + tool calls SO FAR THIS SESSION |

**Total budget per priming**: **30-80KB context**. Vs raw 5GB corpus = **~60-160K× compression at the priming-context level**. Vs no retrieval = ∞× over what's actually addressable today.

### Dimension 3 — Authoritative source per unit

| Unit | Source path | Stale-tolerance | Supersession mechanism |
|---|---|---|---|
| Feedback rule | `~/.claude/projects/<proj>/memory/feedback_*.md` | real-time on read | **NONE — CRITICAL GAP** |
| Project state | `~/.claude/projects/<proj>/memory/project_*.md` | real-time on read | **NONE — CRITICAL GAP** |
| Reference lookup | `~/.claude/projects/<proj>/memory/reference_*.md` | weekly | n/a (stable coords) |
| Daily digest | `~/.local/share/journal/digests/YYYY-MM-DD.md` | daily (cron 23:55, but reliability gaps May 9, 12-16) | none — frozen on write |
| Tmux-log window | `~/.local/share/tmux-logs/YYYY/MM/DD/{hooks,transcripts,term,streaming}/...` | append-only; historical windows immutable | n/a — raw truth |
| GH Project item | GitHub GraphQL `node(id: PVTI_lAHO...)` | real-time on read | GH-managed |
| Live infra state | `gcloud run services describe`, `pulumi stack output`, `pm2 list`, GCP Secret Manager `versions list` | real-time on read | source-of-truth IS the live system |
| Current session activity | tmux-logs of THIS session + in-process tally | real-time | none yet |

**Critical gap**: memory files have no supersession mechanism. `feedback_brain_pipeline_max_plan_only.md` (May 4) and `project_176_oauth_validated.md` (Apr 29) BOTH assert "Haiku via mae-claude-proxy is the brain path." Both are contradicted by the 2026-05-12 OpenAI cutover decision. Currently NO label on the older files says "superseded by [decision X on date Y]."

**This is the single most important new write-back primitive.** Without supersession, every priming retrieval risks reasserting stale architecture as authoritative. See §Write-back contract (Dim 7).

### Dimension 4 — Permissions model

- **Audience**: single operator. No multi-tenant concerns.
- **Data ownership**: laptop + GitHub + GCP `claey-338919` + GCP `mae-prod-claey` + Cloud SQL + Secret Manager — all operator-controlled.
- **Filter requirements** (must redact before model sees retrieved text):
  - API keys, OAuth tokens, DB passwords, session cookies — these appear in tmux-logs verbatim when env vars get echoed or `curl` commands run with `-H 'Cookie: ...'`.
  - **OFF-LIMITS dirs**: `.claude/.credentials/`, `.env`, `.env.local`, `*.bak`, anything under `.credentials/`.
  - Pattern-based scrub before retrieval: `(api_key|secret|token|password|cookie|bearer)\s*[=:]\s*['"]?[a-zA-Z0-9+/=_-]{16,}` → `<REDACTED:type:length>`.
  - Wallet/crypto private keys: pattern `0x[a-fA-F0-9]{40,64}` redact only if appearing in `pk=` / `private_key=` / `seed=` context (otherwise it's a public address, OK).
- **No escalation flow** — single user, no role-based filtering.
- **What's logged about redaction**: count + types per retrieval bundle, in provenance metadata (Dim 5).

### Dimension 5 — Provenance requirements

Every retrieved chunk MUST carry:

```json
{
  "source": "<absolute path + line range OR API endpoint + identifier>",
  "timestamp_written": "<ISO original creation>",
  "timestamp_retrieved": "<ISO when oracle read it>",
  "hash": "sha256:<32-char prefix of source-content hash at retrieval time>",
  "supersedes": ["<chunk_id of older assertion this replaces>"],
  "superseded_by": ["<chunk_id of newer assertion that replaces this>"],
  "redactions_applied": { "count": 3, "types": ["api_key", "session_cookie"] },
  "confidence_label": "observed | inferred | user-confirmed | stale-candidate | rejected | authoritative"
}
```

**Audit purposes**:
- When operator catches hallucination ("you said X but actual is Y"), they can: (a) trace which chunk the assertion came from, (b) mark that chunk superseded with link to corrected source, (c) the corrected source becomes authoritative.
- Post-hoc: "why did the agent say X?" → trace to chunk hash → if hash mismatches current source, source drifted between retrieval and operator-correction.
- Future Layer 3 oracle training corpus.
- Operator-facing dashboard: "memory hits this session: 12; supersessions detected: 2; redactions applied: 18".

### Dimension 6 — Compiled context candidates

**Pre-build + cache** (refresh cadence in parens):

1. **Daily digests** — *exists* (L1 shipped); fix the reliability gaps for May 9, 12-16.
2. **Project state index** — table per project of `{memory_file → frontmatter + supersession_link + write_timestamp}`, rebuilt on every memory file write (file-watcher invalidation). **NEW.**
3. **Surface map** — `file_path → recent_touches_30d → relevant_memory_ids`, nightly rebuild + write-time invalidation. **NEW.**
4. **Live infra snapshot** — current Cloud Run URLs, PM2 process names, Cloud SQL endpoints, Pulumi stack outputs. Refresh every 60 min via cron; ad-hoc refresh on `gcloud` / `pulumi` / `pm2` tool-call observation. **NEW.**
5. **Vector index over digests + memories** — initial backfill once on `mae-db` pgvector; incremental on write. (This is L2 — to be built per ADR.)

**Rebuilt per task** (no cache):
- Surface intersection (which memories match current task's keywords + paths)
- Tmux-log windows around specific dates the task references
- GH Project #31 board slice intersecting the surface
- Current-session running tally (it IS the session)

### Dimension 7 — Write-back contract

After each session (or every N tool calls in long sessions), the oracle writes:

| Label | What it captures | Storage |
|---|---|---|
| `observed` | Raw fact from hooks log | tmux-logs/hooks (already captured) |
| `inferred` | LLM-derived session summary | `~/.local/share/journal/inferred/<session-id>.md` **NEW** |
| `user-confirmed` | Explicit memory write user requested | existing memory bank (`feedback_*.md` / `project_*.md`) |
| `stale-candidate` | Memory file the oracle saw cited but later contradicted by a newer authoritative assertion | `~/.claude/projects/<proj>/memory/_supersessions.jsonl` **NEW** |
| `rejected` | Memory candidate operator vetoed in-session | `~/.local/share/journal/rejected/<date>.jsonl` **NEW** |
| `authoritative` | Durable rule | existing memory bank |

**Supersession write-back — the load-bearing new primitive.**

When the oracle observes:
- memory file `A.md` (written `D1`) asserts proposition `P`
- user message at `D2 > D1` says `¬P` (or asserts contradictory `P'`)
- → write a supersession record:

```jsonl
{"superseded_id": "feedback_brain_pipeline_max_plan_only.md", "superseded_at": "2026-05-12T22:23:49Z", "superseded_by": "session-24cbed9c#L94616 (assistant turn proposing mae-openai-proxy architecture)", "summary": "Brain path is no longer Haiku-via-mae-claude-proxy; cutover to GPT-5.5-via-mae-openai-proxy initiated."}
```

Future retrievals against the surface see BOTH the old assertion AND the supersession, with the newer winning by default. The original memory file is NOT deleted — supersession is additive, never destructive.

**Bidirectional**: the original `feedback_brain_pipeline_max_plan_only.md` gets a sidecar `feedback_brain_pipeline_max_plan_only.md.supersessions.jsonl` listing all newer assertions that contradict any part of it. Read-time merge.

---

## Status

| Component | State | Next concrete step |
|---|---|---|
| L1 digest cron | ✅ shipped via mae-openai-proxy primary; reliability gaps May 9, 12-16 | Triage why May 12-16 digests didn't write; fix provider-chain exhaustion or input-budget logic |
| L2 pgvector + `memory-search` Skill | 🟡 not built; substrate decision pending | Write Retrieval Stack ADR (Nate's Prompt 3) before committing to pgvector — alternatives include hybrid BM25 + vector, structural index over memory files, skip-to-L3 |
| L3 memory-oracle subagent | 🟡 not built; substrate corrected to GPT-5.5-via-mae-openai-proxy (no fine-tune) | After ADR. Subagent prompt + retrieval pipeline. |
| Supersession write-back | 🔴 not designed | Write the supersession-detection prompt + sidecar JSONL format; backfill against the ~150 memory files across all projects |
| Redaction filter | 🟡 partial (operator manually careful) | Implement the pattern-based scrub at retrieval-bundle assembly time |
| Provenance schema | 🔴 not designed | Implement the chunk-metadata JSON envelope above |
| Compiled snapshots (#2-5 in Dim 6) | 🔴 not designed | Per-snapshot mini-spec + cron |

---

## Next: Prompts 2 + 3

This Contract Spec is the **input** for the next two artifacts:

- **Prompt 2 — Retrieval Failure Triage** against the 56+ feedback memory files in mae and the 51 in karve. For each: classify the failure mode it documents, identify which retrieval substrate would have prevented it. Output: a triage table + a "what we're actually fixing" list with priorities.
- **Prompt 3 — Retrieval Stack ADR**. Decide formally: pgvector-only (original L2 plan) vs hybrid (pgvector + BM25 + structural) vs skip-to-L3 (memory-oracle subagent over digests + structural index, no general-purpose vector store). With honest tradeoffs and a rollback plan.

The Contract Spec + Triage + ADR is the trio Nate's framing produces. Once the trio is in hand, the build sequence becomes concrete and the substrate is not at risk of being wrong.
