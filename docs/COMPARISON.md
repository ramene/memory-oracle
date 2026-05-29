# Comparison: memory-oracle vs prior art

## vs Karpathy-style autoresearch loops

Karpathy-style autoresearch loops (autonomous skill improvement: an LLM rewrites skill definitions on a schedule, ships the improved version) and memory-oracle target overlapping pain — *"how does an AI coding agent learn from its own work?"* — but choose opposite architectures.

| Dimension | Karpathy autoresearch | memory-oracle |
|---|---|---|
| **Trigger** | Scheduled cron (typically 2–8 hours) | Event-driven (fs.watch + SessionStart hook) |
| **What mutates** | Skill DEFINITIONS — the "what to do" layer | NOTHING — memory is additive only |
| **Safety boundary** | Works on `working-<skill>/` copies; originals sacred | Supersession sidecars (`.jsonl`) layered over originals at read time |
| **Drift failure mode** | Auto-rewriter injects unintended changes that compound across cycles; operator must discard | Cannot drift — sidecars are append-only; canonical files are never edited |
| **Operator coupling** | Detached — runs in background, results via email | Live in session flow — primes at start, captures during work |
| **Corpus extension** | LLM proposes skill edits, operator approves/discards | Agents write `reference_*` / `project_*` / `feedback_*` files mid-session, auto-indexed |
| **Flywheel property** | ❌ Same skills processed each cycle, no compounding | ✅ Every session that retrieves and discovers writes new corpus that primes the next session |
| **Failure observability** | Needs explicit alerting wrapper (Resend, watchdog) — silent failures are the default | Hook log records every fire unconditionally; index_meta timestamps each rebuild |

**The substantive difference**: Karpathy's autoresearch is a *batch refinery* — schedule, mutate, ship. memory-oracle is a *live nervous system* — events, additive truth, immediate index. The Karpathy approach is *replacement-based learning* (rewrite the skill). memory-oracle is *accretion-based learning* (add the correction beside the original, preserve provenance).

Both ship working systems. They optimize for different things. Karpathy's is good when you want skill capabilities to grow autonomously over time without operator presence. memory-oracle is good when you want *truth* to stay current and provable in every retrieval.

## vs Vector RAG (pgvector, LangMem, Chroma, etc.)

| | Vector RAG | memory-oracle |
|---|---|---|
| Index primitive | Embeddings of text chunks | BM25 over markdown + structural surface map |
| Storage | Vector DB (pgvector / Pinecone / Chroma) | SQLite FTS5 file |
| Retrieval shape | "Most semantically similar" | "Best keyword match, with citations" |
| Correction mechanism | Re-embed updated chunk (destroys provenance) | Append `.supersessions.jsonl` (preserves both) |
| Stale-content failure | Yes — embedding of stale chunk still ranks high for matching queries | No — correction is merged into retrieval output |
| Compute cost | GPU for embedding pipeline, network for query | None — local `sqlite3` CLI |
| Latency | 50–500 ms (network-bound) | <100 ms cold, <30 ms warm (local FS) |
| Onboarding cost | API key, embedding model selection, chunk-size tuning | `./install.sh` |
| Lines of code | ~10K + dependencies | ~1.5K, deps: `sqlite3` CLI + `node` |
| Cross-LLM portability | Couples you to embedding provider | Markdown corpus works with any LLM that can call the CLI |

The vector-RAG approach was designed for *retrieval over unbounded document corpora* (Wikipedia, internal wikis, the open web). It's overbuilt for the AI-coding-agent memory case, which is:

- **Small** (hundreds of files, MBs not GBs)
- **High signal** (operator-curated, deliberate)
- **Stale-prone** (architectural decisions invalidate prior assertions monthly)
- **Provenance-critical** (operator needs to know *why* a memory exists and *whether* it's still true)

BM25 + supersession sidecars matches that problem shape. Vector embeddings don't.

## vs Karpathy's wider "agentic loop" thesis

Karpathy's broader argument (in his recent talks) is that agents should *learn from their own runs* via tool feedback loops. memory-oracle agrees with the goal and adds a missing primitive: **a corpus that can be corrected without being rewritten.** Without that primitive, every "agent learning loop" eventually drifts because the agent's own past assertions become accumulated noise. With supersession sidecars, the corpus accumulates *true things* while preserving the *historical record of what was once believed true*.

## What memory-oracle is NOT

- **Not a replacement for `/scaffold` or skill-bootstrapping flows.** Those handle "start a new thing." memory-oracle handles "bring prior context to bear on whatever you're doing."
- **Not a replacement for project documentation or ADRs.** Memory files capture operational truth that's too fast-moving for an ADR; ADRs capture deliberate decisions. Both belong in the same repo, often.
- **Not a universal long-term memory.** It's scoped to operator-curated content. The raw transcript firehose (1+ GB JSONL) is intentionally NOT indexed — see `docs/genesis/RETRIEVAL-STACK-ADR.md` for why bulk-indexing the firehose hurts more than helps.

## Where Karpathy autoresearch + memory-oracle could compose

You could run a Karpathy-style autoresearch loop that *writes supersession sidecars* instead of rewriting skills. The loop becomes accretive instead of mutative. The autoresearch agent observes "this assertion no longer matches live state," appends a sidecar with the correction, and the corpus stays self-correcting without ever losing the original assertion. That's the synthesis. Neither this repo nor Karpathy's autoresearch ships that today; it'd be a worthwhile follow-on.
