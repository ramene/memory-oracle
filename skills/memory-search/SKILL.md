---
name: memory-search
description: Query your project's memory bank with amendment-aware Evidence-Bound Retrieval (EBR). Returns BM25-ranked results with operator-authored corrections surfaced above the canonical text. Use before asserting any architectural fact you "remember" and immediately after context compaction to re-prime working context.
allowed-tools:
  - Bash
---

# Skill: memory-search — Evidence-Bound Retrieval (EBR) for Your Memory Bank

> Your "knowable past" addressable in ~250ms, with operator-authored corrections surfaced first, by construction.

## Why this exists

A typical project accumulates memory files at `~/.claude/projects/<project>/memory/*.md` — *rules, decisions, conventions, state*. Each file was authoritative when written. But over time the world changes and older files become **silently obsolete**: the assertion still reads cleanly, retrieval still finds it, but it is no longer the truth.

Reading those files directly with `Read` or `cat` produces wrong answers. This Skill produces **amendment-merged** answers: it surfaces the canonical assertion AND any newer operator-authored correction in a single result, with the correction **prepended by construction** so the reader sees it first. The substrate guarantee is structural — not similarity-based, not learned, not heuristic — and is described formally in the [Evidence-Bound Retrieval paper](https://github.com/ramene/memory-oracle/blob/main/paper/coala-extension/main.tex).

## When to use this Skill (mandatory moments)

1. **After context compaction** — your priming is gone. Run this Skill with the surface area you're about to work on. Replaces minutes of hand-grepping with a sub-second query.
2. **Before asserting any architectural fact** that you "remember" — service endpoints, DB locations, deployment processes, banned patterns, auth flows, infra coordinates, etc. The probability that your memory of these is current is roughly equal to the age of your training data plus the staleness of the memory bank file you'd reach for. **Both are likely wrong.** Query first.
3. **When the operator says "no, that's wrong"** — the next move is to query and verify, not apologize and guess again.
4. **When proposing a change to infrastructure** that any feedback memory might constrain (deploy process, port assignments, vendor bans, restart procedures, etc.).
5. **At session start** when the project has accumulated memory files — pull the top-N most-relevant rules for the surface you'll be touching.

## When NOT to use it

- The query is about **current code state** — use `Read` / `Grep` directly. The memory bank holds rules and decisions, not the code itself.
- The query is about **live infrastructure** — use `gcloud` / `kubectl` / `pulumi` / `curl` directly. Memory rules describe how to interact with infra; the infra itself is the source of truth.
- The query is genuinely novel and has no prior memory coverage — but check first; the surprise rate of "I had no idea you'd remembered that" is high.

## How to call it

```bash
# Default: top-10 BM25 hits, 30 KB budget, amendment-merged
~/.bin/memory-search.mjs "<your query in plain English or keywords>"

# Filter to a specific project (recommended for narrow queries)
~/.bin/memory-search.mjs "<query>" --project=<project-key>
# The project key matches Claude Code's directory encoding under ~/.claude/projects/<key>/.

# Tighter budget for mid-session calls (avoid blowing context)
~/.bin/memory-search.mjs "<query>" --k=5 --budget=8000

# Structured JSON output for programmatic use
~/.bin/memory-search.mjs "<query>" --json
```

The Skill returns: a single markdown bundle, ranked by BM25 score, with **amendment notices surfaced ABOVE each affected file's content**. The total bundle stays under the budget so you can paste it back into context cheaply.

## How to read the output

Each result block looks like this:

```
## <project>/<file>   ⚠ HAS AMENDMENTS    (or no marker if pristine)
**Name**: <frontmatter name>
**Description**: <frontmatter description>
**Rank (BM25)**: <score, more negative = better match>

[ ⚠ Amendment Notice block — if any amendment records exist on this file ]
[ Canonical file content — preserved verbatim ]
```

**Rule**: if a result shows "⚠ HAS AMENDMENTS", the corrected assertion is what you cite. The canonical body is preserved only for audit/context, not for quoting.

## Examples

### Example 1 — Verifying an architectural fact before quoting it

You're about to comment on, or change, an infrastructure detail you "remember" — a service endpoint, an auth flow, a deploy procedure. Run:

```bash
~/.bin/memory-search.mjs "<service-or-feature> <surface>" --k=3
```

If a result is marked `⚠ HAS AMENDMENTS`, **the amended assertion is the answer you cite** — not the canonical body. The canonical body explains what was true before; the amendment explains what is true now.

### Example 2 — Pre-deploy safety check

About to run a multi-process restart, a destructive migration, or anything else where prior incidents may have written safety rules. Run:

```bash
~/.bin/memory-search.mjs "<operation> <subject>" --project=<your-project-key> --k=5
```

You'll surface feedback memories the operator wrote after the last time this exact operation went wrong. The amendment layer will tell you which of those rules are still current.

### Example 3 — Post-compaction re-priming

Context just compacted. You don't remember what surface area you were working on. Use whatever the post-compaction summary mentions:

```bash
~/.bin/memory-search.mjs "<paste the topic from the summary>" --k=10 --budget=15000
```

You get a fresh ~15 KB bundle of the most relevant rules + project state, amendment-resolved. Paste it back into your reasoning, continue.

## Implementation notes (for future maintainers, including future-you)

- **Index**: SQLite FTS5 at `$MEMORY_INDEX_DB` (default `~/.local/share/journal/.memory-index.db`).
- **Source files**: `$CLAUDE_PROJECTS_ROOT/*/memory/*.md` (default `~/.claude/projects/*/memory`).
- **Amendments**: `<canonical-file>.md.amendments.jsonl` sidecars (legacy `.supersessions.jsonl` extension also supported for backwards compatibility). Append-only, newest-wins on read.
- **Rebuild**: `~/.bin/memory-index-build.mjs` (full rebuild) or `~/.bin/memory-index-build.mjs --watch` (fs-watcher incremental).
- **Merge tool**: `~/.bin/memory-merge.mjs <file>` for single-file amendment-merged read.
- **Audit**: `~/.bin/memory-merge.mjs --audit` to list all files that have amendment sidecars.

## Failure modes this Skill addresses

- **BAD WRITE-BACK** (the canonical EBR failure): older memory file asserts X; world moves on to ~X; nothing tells retrieval the file is stale. Direct fix, primary purpose.
- **OPERATIONAL RULE NOT SURFACED**: BM25 ranking surfaces the relevant feedback rule when surface keywords match a query.
- **CONTEXT REBUILDING AFTER COMPACTION**: eliminated by being callable on-demand with a tight budget.
- **NON-AUTHORITATIVE SOURCE**: amendment records carry `live_evidence` paths that point at the controlling source so the citation can be verified.

## Writing back new amendments

If you observe a memory file asserting something the operator just corrected in this session:

1. Identify the canonical file: `~/.claude/projects/<project>/memory/<file>.md`
2. Create or append to its amendment sidecar: `<file>.md.amendments.jsonl`
3. Schema (one JSON object per line; field names preserved verbatim for backwards compatibility):

```json
{
  "amended_at":         "<ISO timestamp of the corrective event>",
  "amended_by":         "<who authored the correction>",
  "superseded_assertion": "<the specific claim in the canonical file that is no longer true>",
  "corrected_assertion":  "<the new truth, in one sentence>",
  "live_evidence":      ["<paths or identifiers where the new truth is verifiable RIGHT NOW>"],
  "operator_confirmed": "<ISO timestamp + context, or true if implicit>",
  "retention_policy":   "<when this amendment itself stops being relevant — or 'indefinite'>"
}
```

4. Rebuild the index: `~/.bin/memory-index-build.mjs` (or the fs-watcher picks it up automatically if running).

The canonical file is **never deleted or edited** — amendments are additive. The substrate's merge routine prepends them at retrieval time so the reader sees the correction first. Audit-friendly, fully reversible (delete one JSONL line to undo).

## Further reading

- **The EBR position paper** — formal statement of the precedence invariant + composition with the CoALA agent-memory taxonomy: [`paper/coala-extension/main.tex`](https://github.com/ramene/memory-oracle/blob/main/paper/coala-extension/main.tex)
- **The clinical-AI manuscript** — empirical results on N=1{,}000 queries + a real-corpus probe: [`paper/lncs/main.tex`](https://github.com/ramene/memory-oracle/blob/main/paper/lncs/main.tex)
- **Reference implementation** — [`github.com/ramene/memory-oracle`](https://github.com/ramene/memory-oracle)
