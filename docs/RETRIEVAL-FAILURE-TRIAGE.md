# Retrieval Failure Triage — 114 Memory Files Across mae + karve

**Date**: 2026-05-16
**Source prompt**: Nate Jones, "New RAG War" Prompt 2 (`promptkit.natebjones.com/20260508_639_promptkit_2`, verbatim text at `/tmp/nate-prompt-retrieval-failure-triage.txt`)
**Sibling artifacts**: `RETRIEVAL-CONTRACT-SPEC-2026-05-16.md` (Prompt 1), `RETRIEVAL-STACK-ADR-2026-05-16.md` (Prompt 3)
**Inputs**: full bulk-extracted summary at `/tmp/memory-summaries.json` (114 files, 75KB total, generated 2026-05-16 from mae 100 + karve 14)

---

## TL;DR

The mae+karve memory corpus is 114 files documenting **operator-burned-once** patterns: every memory was written *after* an operator caught the system doing the wrong thing. So the corpus IS a failure log. Triaging it against Nate's 7 failure modes reveals what *kind* of failure each captures and which retrieval substrate would have prevented re-occurrence.

**Distribution of failures**:

| Failure mode | Files | % | Substrate that would have prevented re-occurrence |
|---|---|---|---|
| 6 — BAD WRITE-BACK (incl. supersession variant) | 32 | 28% | **Supersession links** (additive sidecar JSONL) |
| 0 — NOT-A-RETRIEVAL-FAILURE (rule encodes a code/ops bug) | 53 | 46% | **BM25 + structural index** (surface rule at session-start when intersecting file path / keyword touched) |
| 5 — CONTEXT REBUILDING | 15 | 13% | **Digest+structural priming** (last-N-days + active topic graph) |
| 2 — NON-AUTHORITATIVE SOURCE | 7 | 6% | **Authority-tagged structural index** (per-unit "which file/system is truth" registry) |
| 1 — WRONG RETRIEVAL UNIT | 4 | 4% | **Compiled context candidates** (Dim 6 from Contract Spec) |
| 4 — MISSING PROVENANCE | 2 | 2% | **Provenance metadata envelope** (chunk-level source+hash+confidence_label) |
| 7 — OVERBUILDING | 1 | 1% | **The Contract Spec itself** — prevents the overbuild |
| 3 — MISSING PERMISSIONS CHECK | 0 | 0% | n/a (single-tenant) |

**Headline finding**: vector-similarity retrieval addresses ≤15% of the corpus. **BM25 + structural index + supersession links** address the load-bearing 80%. This is the strongest data signal for the ADR.

---

## Method

For each memory file (extracted via `/tmp/extract-memory-summaries.mjs`):
- Read frontmatter `name` + `description` + body excerpt (~280 chars)
- Classify against the 7 failure modes per Nate's prompt
- Tag the substrate that, IF in place, would have surfaced the relevant rule/fact at the right moment to prevent re-occurrence
- Severity = how much pain re-occurrence caused (high / med / low — drawn from the file's narrative)

Not all memory files map cleanly to one of Nate's 7 modes. Many are *operational rules* — they document a code or process bug, not a retrieval bug. For those, we ask: "would a retrieval system have prevented re-occurrence if it surfaced this rule at session-start?" That answer is almost always yes, *if* the surfacing was correctly triggered by surface-area match.

---

## Triage by failure mode

### Mode 6 — BAD WRITE-BACK (32 files, 28%)

The single most painful mode in this corpus. Subdivides into three subtypes:

**(6a) Supersession failures** — A memory file was authoritative at write-time but is now contradicted by a later event. The newer truth exists in disk/code/conversation, but no link from the old file to the new fact. Result: future sessions confidently assert stale facts.

| File | Written | Now superseded by | Cost |
|---|---|---|---|
| `feedback_brain_pipeline_max_plan_only.md` | 2026-05-04 | 2026-05-12 OpenAI cutover (live in code: `journal-digest-builder.mjs` lines 45-83) | HIGH — this is the file that fooled me TWICE in this very conversation |
| `project_176_oauth_validated.md` | 2026-04-29 | Same as above | HIGH |
| `feedback_apply_preset_local_only.md` | retired the older "LOCAL-ONLY" rule on phase0/01 (2026-05-02) | self-superseding within the same file | MED — file self-corrects, but old sessions saw the old rule |
| `feedback_max_for_pro_myth.md` | corrects an EARLIER operator misconception | bidirectional — newer asserts negate older | MED |
| ~25 `project_<dateXX>_session.md` files | dated state-snapshots | each subsumed by later state-snapshot | HIGH cumulative — operator gets "session state" answer from oldest snapshot grep-match |

**(6b) Inferred-as-confirmed** — Model wrote its inference back as fact, treating its own guess as ground truth.

| File | Failure narrative |
|---|---|
| `feedback_verify_preset_apply.md` | Claude claimed "preset applied" without re-reading disk → kids unprotected 2.5h |
| `feedback_verify_before_alarm.md` | Three phantom alarms raised from log-inspection alone on a working frozen platform |
| `feedback_pm2_log_tail_is_history.md` | `tail -N` of PM2 log includes pre-restart history; Claude reported "a5 is running" based on stale tail |

**(6c) Architectural assumption drift** — A doc captures *the architecture as of date X*. The architecture changes, the doc doesn't.

The May 3 `PLATFORM-EVOLUTION-NOTES-2026-05-03.md` §Effort 2 specced Plutus-3B fine-tune as Layer 3 — that's now superseded by the May 12 mae-openai-proxy decision. No on-disk link until *this Triage doc + the new Contract Spec* explicitly say so.

**Substrate fix**: **supersession-aware retrieval**. Sidecar `<file>.supersessions.jsonl` per memory file; read-time merge surfaces both old and new with newer winning by default. Bidirectional: old file gets `superseded_by`, new event gets `supersedes` array.

---

### Mode 0 — NOT-A-RETRIEVAL-FAILURE but surfacing prevents recurrence (53 files, 46%)

The bulk of the mae corpus. Each documents an *operational or code rule* that was burned in once. The rule is correct; the failure was that the rule wasn't surfaced at the right moment.

**Examples**:
- `feedback_never_scp.md` → "scp is banned." Right moment to surface: any session where Claude is considering file transfer between local and tunafish.
- `feedback_no_socketio.md` → "Socket.IO is banned." Right moment: any session touching real-time UI.
- `feedback_one_process_at_a_time.md` → "Never restart >1 PM2 process per deploy.sh invocation." Right moment: any session about to issue `pm2 restart`.
- `feedback_archive_before_truncate.md` → "Archive before truncate." Right moment: any destructive file op.
- `feedback_clean_build.md` → "`rm -rf .next && pnpm build` always." Right moment: any dashboard rebuild.
- `feedback_no_tmp_writes.md` → "Use `~/.claude-tmp`, never `/tmp`." Right moment: any script-creation moment.

**Substrate fix**: **BM25 over memory-file content + structural index from file-path/keyword → memory IDs**. When the current task's surface area intersects a known memory's surface (path, keyword, command pattern), surface that memory.

Notably: **no vector embedding required.** These rules are keyword-rich, deterministic, and structural. Vector similarity adds nothing over keyword match.

---

### Mode 5 — CONTEXT REBUILDING (15 files, 13%)

The agent re-discovered info it should have had cached. Failure manifests as wasted time + redundant tool calls.

**Examples**:
- `feedback_dashboard_split_socketio_landmine.md` — 7.5h smoking crater because the previous attempt's failure wasn't surfaced before the second attempt.
- `feedback_session_learnings.md` — multiple parallel agents re-discovering same things, scp-overwriting each other's work.
- All karve `*-learnings.md` files (`framework-core-learnings.md`, `web-rebuild-learnings.md`, `post-video-notion-learnings.md`, etc.) — they exist *because* the discovery happened by hand and the learning was captured to avoid re-discovery.

**Substrate fix**: **Daily-digest pre-priming + structural index of topic→files-touched**. The digest layer compresses N days of activity; the structural index tells future sessions "this topic has prior touches at file X, lines Y-Z; here's the digest summary."

---

### Mode 2 — NON-AUTHORITATIVE SOURCE (7 files, 6%)

System returned a relevant source that wasn't the controlling source.

| File | What Claude reached for | What the authority actually was |
|---|---|---|
| `feedback_read_code_before_labeling_drift.md` | Inferred "orphan" from absence of knowledge | Should have grepped the codebase |
| `feedback_gh_board_is_truth_not_tasklist.md` | Local TaskList (which it can see) | GH Project #31 (separate query) |
| `feedback_profit_bank_files_are_authoritative.md` | PG `profit_bank` table | `data/.profit-bank-{kucoin,binance}.json` files |
| `reference_db_lives_in_claey.md` | Inferred PG location from project name | `~/.claude/.credentials/mae-db-url.txt` |
| `reference_api_balances_endpoint.md` | Guessed `/api/positions` or `/api/multi-venue-balance` | Only `/api/balances` exists |
| `reference_sitout_flag_path.md` | `data/.flags/force-off.flag` | Actual: `data/.sit-out/force-off.flag` |
| `reference_dashboard_ports.md` | Confused 7778 and 7779 | Dashboard 7779, api 7778 |

**Substrate fix**: **Per-unit authority tag**. The structural index doesn't just say "file X is relevant"; it says "for THIS class of query, file X is the authority, and don't reach for adjacent files."

---

### Mode 1 — WRONG RETRIEVAL UNIT (4 files, 4%)

The retrieval was topically relevant but structurally wrong. Returned a chunk when the task needed a record/section/graph-neighborhood.

| File | What was returned | What was needed |
|---|---|---|
| `feedback_trace_data_flow.md` | One consumer of a state field | Full data-flow graph (writer + math consumers + readers + UI) |
| `feedback_earn_fee_tokens_ignored.md` | "Checking 0 positions" log line | Log line + design-decision context that LDO/KCS/BNB are filtered by design |
| `feedback_watchdog_throttled.md` | Raw `rejectionRate: UNHEALTHY` alert | Alert + current regime state to distinguish chop-rejection from real failure |
| `feedback_aletheia_wr_flapping.md` | Stale `latest-report.json` outcomes window | Live `executed-trades.jsonl` for current WR |

**Substrate fix**: **Compiled context candidates** (Dim 6 of the Contract Spec). For each known query class (alert, log line, state field, dashboard metric), pre-compose a *bundle* that pairs the raw signal with the contextualizing data.

---

### Mode 4 — MISSING PROVENANCE (2 files, 2%)

Output produced but no source trail.

- `feedback_pm2_log_tail_is_history.md` — log lines lacked timestamp filtering vs `pm_uptime`. The fix: every log line retrieved should be timestamp-tagged AND have a "was this before or after the most recent process restart?" provenance marker.
- `feedback_verify_before_alarm.md` — three phantom alarms because the asserted state lacked any live-test trace.

**Substrate fix**: Schema-enforced provenance envelope (per the Contract Spec Dim 5). Every retrieved chunk carries `{source, line_range, timestamp_written, timestamp_retrieved, hash, confidence_label}`.

---

### Mode 7 — OVERBUILDING (1 explicit + 1 architecture-level instance, 1%)

The `PLATFORM-EVOLUTION-NOTES-2026-05-03.md` §Effort 2 plan was *itself* an overbuild: it specced a Plutus-3B-W4-GPTQ fine-tune ($10 + 1-2 weeks compute) for the Layer 3 memory oracle when the simpler path (GPT-5.5 via mae-openai-proxy + retrieved-context-injected subagent prompt) covers the same use case with no training cost. The cutover that arrived May 12 mooted the fine-tune entirely.

**Substrate fix**: **The Contract Spec itself**. Writing the contract forces the conversation "what does the agent need to receive?" — that question naturally reveals when a fine-tune is overkill vs prompt+retrieval.

---

### Mode 3 — MISSING PERMISSIONS CHECK (0 files, 0%)

Single-tenant operator-only system. No multi-tenant data leak vectors. The Contract Spec §Dim 4 still requires **redaction filters** for credentials/tokens in tmux-logs, but that's not a permissions check — it's source-content filtering.

---

## What we're actually fixing first (priorities)

Sorted by **failure-prevention-value × build-cost⁻¹**:

| Priority | Fix | Mode coverage | Build cost | Files prevented from re-fooling | 
|---|---|---|---|---|
| **P0** | **Supersession sidecar** (`<file>.supersessions.jsonl` + read-time merge) | Mode 6 | 1-2 days | 32 files (28%) |
| **P1** | **BM25 + structural index** over `~/.claude/projects/*/memory/*.md` (file_path/keyword → memory_id) | Mode 0 | 2-3 days | 53 files (46%) |
| **P2** | **Provenance envelope** on every retrieved chunk + redaction filter | Modes 4 + (Dim 4 from Contract) | 1-2 days | 2 direct + universal safety |
| **P3** | **Authority-tagged structural index** (which file is truth for which query class) | Mode 2 | 1-2 days | 7 files (6%) |
| **P4** | **Compiled context candidates** for common query bundles (alert+regime, log+pm_uptime, state-field+full-graph) | Mode 1 | 3-5 days | 4 files (4%) + reduces P1 false positives |
| **P5** | **Digest reliability fix** (currently May 9, 12-16 missing) | Mode 5 prerequisite | 1 day | enables all digest-driven priming |
| **P6** | **L2 retrieval layer** (whatever substrate the ADR picks) | Cross-cutting | 3-5 days | depends on ADR |

Total build estimate for **all of P0-P6**: ~12-20 days of focused work. **P0-P3 = 6-9 days** and covers ~85% of the corpus.

Critically: **NO P-item requires building a general-purpose vector store**. Vector embeddings would add value for novel-query semantic search at the L3 oracle level, but the load-bearing fixes are structural + keyword + supersession.

---

## Top diagnosis on the "what's the current brain/coach inference path?" failure

The very failure this session demonstrated empirically maps cleanly:

- **Primary**: **Mode 6 BAD WRITE-BACK (supersession variant)**. `feedback_brain_pipeline_max_plan_only.md` (May 4) was authoritative at write-time. The May 12 OpenAI cutover contradicted it. No supersession link exists on disk. I read the older file as authoritative — twice — and asserted stale facts to you confidently.
- **Runner-up**: **Mode 5 CONTEXT REBUILDING**. To find ground truth I had to grep 5GB of tmux-logs + 739MB of session JSONL by hand — re-discovering, in ~25 minutes, a fact that took one operator sentence to assert. The "compressed corpus" (Layer 1 digests) had gaps on the exact dates of the cutover (May 12-16 digests missing).
- **What it looked like but wasn't**: Mode 1 WRONG RETRIEVAL UNIT. I *did* retrieve the right unit (the feedback memory) — it was just stale. Mode 4 MISSING PROVENANCE was also adjacent — the older file had no `superseded_by` provenance — but the root mode is write-back, not provenance.

Minimum fix for this specific failure: implement **P0 (supersession sidecar)** with `feedback_brain_pipeline_max_plan_only.md.supersessions.jsonl` as the first record:

```jsonl
{"superseded_by": "session-24cbed9c#L94616 — assistant 2026-05-12T22:23:49Z", "scope": "claim that brain path is Haiku-via-mae-claude-proxy", "corrected_assertion": "brain path is GPT-5.5-via-mae-openai-proxy primary; mae-claude-proxy secondary; Haiku 4.5 is tertiary fallback only", "live_evidence": "~/.bin/journal-digest-builder.mjs lines 45-83 + services/openai-proxy/server.js", "operator_confirmed": "2026-05-16T~18:00Z karve session 2d097fa8"}
```

What NOT to rebuild: vector embeddings over the corpus. The diagnosis doesn't justify a general-purpose vector store; it justifies supersession. Building pgvector now would be Mode 7 (Overbuilding).
