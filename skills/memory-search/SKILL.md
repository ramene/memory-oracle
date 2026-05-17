---
name: memory-search
description: Query the operator's full memory bank (supersession-aware, BM25 ranked, 174+ files across all projects) for the truth about what's been decided, tried, banned, or superseded. Use BEFORE asserting any architectural fact from memory and IMMEDIATELY AFTER context compaction to re-prime working context.
allowed-tools:
  - Bash
---

# Skill: memory-search — Supersession-Aware Memory Retrieval

> The operator's "knowable past" addressable in <300ms, with corrections for stale memory baked in.

## Why this exists

The operator's memory bank under `~/.claude/projects/*/memory/*.md` is ~150-200 files of *rules, decisions, and state*. Each file was authoritative when written — but **older files are NOT marked as superseded when newer events contradict them**. Two memory files in this corpus today (2026-05-16) confidently assert that "Haiku via mae-claude-proxy is the brain inference path" when the actual path has been **GPT-5.5 via mae-openai-proxy** since 2026-05-12T22:23Z.

Reading those files directly with `Read` or `cat` produces wrong answers. This Skill produces **supersession-merged** answers: it surfaces the original assertion AND any newer authoritative correction in a single result, so you can never confidently quote a stale fact.

## When to use this Skill (MANDATORY moments)

1. **After context compaction** — your priming is gone. Run this Skill with the surface area you're about to work on. Replaces 25 minutes of hand-grepping 5GB of tmux-logs with a 300ms query.
2. **Before asserting ANY architectural fact** that you "remember" — inference path, DB location, deployment process, banned patterns, OAuth flow, infra coordinates, etc. The probability that your memory of these is current is roughly equal to the age of your training data plus the staleness of the memory bank file you'd reach for. **Both are wrong.** Query first.
3. **When the operator says "no, that's wrong"** — your next move is to query and verify, not to apologize and guess again.
4. **When proposing a code change to infrastructure** that any feedback memory might constrain (deploy.sh process, Socket.IO bans, IBKR bans, dashboard ports, scp bans, etc.).
5. **At session start** if the project has accumulated memory files (mae, karve, etc.) — pull the top 10 most-relevant rules for the surface you'll be touching.

## When NOT to use it

- The query is about **current code state** — use `Read` / `Grep` directly. The memory bank is rules and decisions, not the code itself.
- The query is about **live infrastructure** — use `gcloud` / `pulumi` / `pm2` / `curl` directly. Memory rules describe how to interact with infra; the infra itself is the source of truth.
- The query is genuinely novel and has no prior memory coverage — but check first; the surprise rate of "I had no idea you'd remembered that" is high.

## How to call it

```bash
# Default: top-10 BM25 hits, 30KB budget, supersession-merged
~/.bin/memory-search.mjs "<your query in plain English or keywords>"

# Filter to a project (recommended for narrow queries)
~/.bin/memory-search.mjs "deploy process" --project=-Users-ramene--remote--plans-mae-monorepo-build

# Tighter budget for mid-session calls (avoid blowing context)
~/.bin/memory-search.mjs "<query>" --k=5 --budget=8000

# Structured JSON output for programmatic use
~/.bin/memory-search.mjs "<query>" --json
```

The Skill returns: a single markdown bundle, ranked by BM25 score, with **supersession notices surfaced ABOVE each affected file's content**. The total bundle stays under the budget so you can paste it back into context cheaply.

## How to read the output

Each result block looks like this:

```
## <project>/<file>  ⚠ HAS SUPERSESSIONS    (or no marker if pristine)
**Name**: <frontmatter name>
**Description**: <frontmatter description>
**Rank (BM25)**: <score, more negative = better match>

[ ⚠ Supersession Notice block — if any superseding records exist ]
[ Original file content — preserved verbatim ]
```

**Rule**: if a result shows "⚠ HAS SUPERSESSIONS", the corrected assertion is what you cite. The original is preserved only for audit/context, not for quoting.

## Examples (use these as templates)

### Example 1 — Inference path verification (the canonical case)

You're about to change the brain pipeline or comment on inference. Your training data and the memory bank say "Haiku via mae-claude-proxy." Run:

```bash
~/.bin/memory-search.mjs "brain inference path proxy" --k=3
```

The top result is `feedback_brain_pipeline_max_plan_only.md` with a supersession block stating: "As of 2026-05-12, the brain/inference path PRIMARY is GPT-5.5 via mae-openai-proxy..." — **that's the answer you cite**, not the original file body.

### Example 2 — Pre-deploy safety check

About to run `pm2 restart` on multiple agents. Run:

```bash
~/.bin/memory-search.mjs "pm2 restart deploy multiple processes" --project=-Users-ramene--remote--plans-mae-monorepo-build --k=5
```

You'll surface `feedback_one_process_at_a_time.md` and `feedback_use_deploy_sh.md` — both rules you'd otherwise violate.

### Example 3 — Post-compaction re-priming

Context just compacted. You don't remember what surface area you were working on. Use whatever the post-compaction summary mentions:

```bash
~/.bin/memory-search.mjs "<paste the topic from the summary>" --k=10 --budget=15000
```

You get a fresh 15KB bundle of the most relevant rules + project state, supersession-resolved. Paste it back into your reasoning, continue.

## Implementation notes (for future maintainers, including future-you)

- **Index**: SQLite FTS5 at `$MEMORY_INDEX_DB` (default `~/.local/share/journal/.memory-index.db`)
- **Source files**: `$CLAUDE_PROJECTS_ROOT/*/memory/*.md` (default `~/.claude/projects/*/memory`)
- **Supersessions**: `<memory-file>.supersessions.jsonl` sidecars, additive, newest-wins on read
- **Rebuild**: `~/.bin/memory-index-build.mjs` (full rebuild) or `~/.bin/memory-index-build.mjs --watch` (fs-watcher incremental)
- **Merge tool**: `~/.bin/memory-merge.mjs <file>` for single-file supersession-merged read
- **Audit**: `~/.bin/memory-merge.mjs --audit` to list all files with supersession sidecars

## Failure modes this Skill addresses (per `RETRIEVAL-FAILURE-TRIAGE-2026-05-16.md`)

- Mode 6 (BAD WRITE-BACK / supersession): direct fix, primary purpose
- Mode 0 (operational rule needs surfacing): BM25 ranking surfaces the right rule when surface keywords match
- Mode 5 (CONTEXT REBUILDING after compaction): eliminates by being callable on-demand
- Mode 2 (NON-AUTHORITATIVE SOURCE): supersession records carry `live_evidence` paths that point at the controlling source
- Modes 1, 4, 7: addressed by adjacent layers (compiled candidates, provenance envelope, the Contract Spec itself)

## Writing back new supersessions

If you observe a memory file asserting something the operator just corrected in this session:

1. Identify the file: `~/.claude/projects/<proj>/memory/<file>.md`
2. Create or append to its sidecar: `<file>.md.supersessions.jsonl`
3. Schema (one JSON object per line):

```json
{"superseded_at": "<ISO timestamp of corrective event>", "superseded_by": "<evidence locator: session-id#line, file:line-range, commit-sha, etc.>", "scope": "<which assertion in the original is invalidated>", "corrected_assertion": "<the new truth>", "live_evidence": ["<paths/identifiers where the new truth is verifiable RIGHT NOW>"], "operator_confirmed": "<ISO + context>", "retention_policy": "<when to retire this supersession itself>"}
```

4. Rebuild the index: `~/.bin/memory-index-build.mjs` (or the fs-watcher will pick it up automatically if running)

The original file is **NEVER deleted or edited** — supersession is additive only. Audit-friendly, reversible.

## ADR reference

This Skill is Day 14 of `mae-ADR-001` (2026-05-16): "Use supersession-aware sidecars + BM25 + structural index + digest priming for Mae memory retrieval; defer pgvector embedding store." Full ADR at `~/.remote/@plans/mae-monorepo-build/docs/RETRIEVAL-STACK-ADR-2026-05-16.md`.
