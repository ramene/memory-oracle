# Memory that argues with itself

> *An Evidence-Bound Retrieval (EBR) substrate for AI coding agents, clinical decision support, and any domain where stale assertions are dangerous.*

There's a failure mode I've watched LLM coding agents commit over and over again for the better part of a year. The agent reads a memory file you wrote three weeks ago. It's beautifully written, declarative, authoritative. It says *"the brain pipeline routes through `mae-claude-proxy` — never add `ANTHROPIC_API_KEY` fallback because it double-bills."*

Except yesterday, the brain pipeline got moved to GPT-5.5 via a different proxy entirely. The memory file is still in the directory. It still reads beautifully. The agent quotes it back to me, confidently, as if it were today's truth.

I correct it. The agent apologizes. The file still says the wrong thing. The next session repeats the cycle. This is the **Bad Write-Back** failure mode, and it's why I've spent the past 36 hours building a different kind of memory layer.

## Nate Jones called the question

In his recent piece [*"The New RAG War Is Not About Vectors"*](https://natebjones.substack.com/p/the-new-rag-war-is-not-about-vectors), Nate Jones argued that vector embeddings — the dominant primitive for AI agent memory in 2024-2026 — are the wrong tool for the job. Embeddings retrieve by semantic similarity, which is great for the open web and Wikipedia but terrible for *operationally-curated* memory where corrections matter more than recall.

He stopped short of proposing a specific architecture. **This piece is the architecture.** The implementation is on GitHub: [`ramene/memory-oracle`](https://github.com/ramene/memory-oracle). It's MIT-licensed, ~3,500 lines across Node, Go, Expo, and LaTeX (the paper is in there too).

## The primitive: Evidence-Bound Retrieval (EBR)

When you write a memory file today, you write it as a canonical fact. Months pass. A clinical event, a refactor, a market regime shift — something changes. The fact is now wrong.

The standard responses are:
1. **Edit the file in place** (destructive — lose provenance, lose the audit trail)
2. **Append an addendum** (better, but retrieval doesn't know to surface it first)
3. **Rewrite the embedding in a vector store** (the old embedding still matches matching queries)

memory-oracle takes a different path: **append a amendment record**. It's literally a JSONL file beside the canonical:

```
~/.claude/projects/mae/memory/
├── feedback_brain_pipeline.md                      # original — never edited
└── feedback_brain_pipeline.md.amendments.jsonl  # corrections, append-only
```

When the retrieval engine fetches this file, it merges the amendment entries into the output **before** the canonical body. Any sequential reader — human or LLM — encounters the correction *first*. The original is preserved verbatim afterward, so an auditor in 2030 can see exactly what was once believed and exactly when it was corrected.

```
## ⚠ Amendment Notice (1 record)

### Amendment 1 — 2026-05-12T22:23:49Z
Corrected assertion: As of 2026-05-12, the brain pipeline PRIMARY is GPT-5.5 via
mae-openai-proxy. mae-claude-proxy is now SECONDARY/FALLBACK.
Live evidence: ~/.bin/journal-digest-builder.mjs lines 45-83
Operator confirmed: 2026-05-16

[original file content — preserved verbatim, read with the corrections above in mind]
```

That's it. That's the entire primitive. The rest of memory-oracle — the SQLite FTS5 indexer, the SessionStart hook that primes new conversations, the PreToolUse hook that intercepts shell commands, the Go binaries that compile to single static executables, the Expo mobile apps for clinician/patient consent gestures — all of it serves this one thing: **make the correction win at retrieval time without destroying the original**.

## The clinical case study (the showstopper)

The scenario that motivates the paper goes like this:

Jane Doe is 67. Diagnosed with paroxysmal atrial fibrillation in 2008. Started on warfarin 5mg PO daily; the reversal protocol of the time was fresh frozen plasma plus vitamin K. In 2024, her cardiologist switched her to apixaban after persistent INR lability and new chronic kidney disease. He wrote a note. The reversal protocol for apixaban is **andexanet alfa, NOT FFP, NOT vitamin K — vitamin K has no role in factor Xa inhibitor reversal.**

It's 2026 now. Jane presents to the ER with active GI bleeding, hypotension, hemoglobin of 6.4. The attending physician's AI-augmented EHR queries: *"what anticoagulant is this patient on, how do I reverse it?"*

In every commercial EHR I've seen — Epic, Cerner, athenahealth — the answer depends on how the LLM ranks two separate documents. The 2008 warfarin note and the 2024 cardiology consult are both in the chart. Vector RAG ranks the 2008 note higher because its embedding has stronger lexical overlap with the query. The team orders FFP. Vitamin K. Neither reverses apixaban. The patient continues to bleed while the team realizes the error 40 minutes later.

This is not a hypothetical failure mode. It's the prototype failure of clinical AI memory in 2026, and the exact pattern that any retrieval system that does not *structurally* surface corrections is going to keep producing forever.

With memory-oracle, the same query returns the amendment-merged output where "andexanet alfa" appears 58 lines before "Fresh Frozen Plasma." A sequential LLM reader sees the correction first. It's a precedence invariant — provable from the merge algorithm itself, not a property you have to retrain the model to obey.

The proof script reproduces in 30 seconds:

```bash
git clone https://github.com/ramene/memory-oracle
cd memory-oracle && ./install.sh
./docs/examples/clinical-amendment-proof.sh

# Expected output:
#   PASS — corrected reversal (andexanet alfa, line 21) appears BEFORE
#   the stale reversal (FFP, line 79) in the merged retrieval.
```

## Where this gets *really* interesting

Two things that surprised me as I was building this.

**First**: the same architecture solves the **trading platform** problem. I run an automated trading system whose strategy rules update in response to observed P&L. In a single trading day's journal, I found *six* implicit amendments — preset thresholds bumped, signal source weights adjusted, gate rules added — each one a correction of a prior assertion. The system was already doing accretive learning. It was just doing it implicitly, scattered across git commits and weight matrix updates. Making it explicit via amendment records means the next trading session can `memory-search "kucoin-scanner trust"` and instantly get the amendment-merged truth, complete with the loss event that triggered the weight change. This is the second case study for the paper; the litmus reproduces in 30 seconds at `docs/examples/trading-amendment-proof.sh` (the trading parallel of the clinical proof).

**The harder claim** the trading retrofit unlocked: for **shorting / futures / perpetual** markets specifically, accretive retrieval is not nice-to-have — it is required for agent safety. Three reasons: (1) LLMs have no training data on the operator's funding-rate thresholds, per-regime leverage caps, or liquidation-band conditions — those rules don't exist publicly; (2) the rules evolve weekly with each operator decision; (3) the loss profile is asymmetric — spot positions can lose at most 100% of capital, but shorts and perps can lose much more and be liquidation-cascade unrecoverable. An agent acting on stale rules in these markets doesn't lose money slowly. It loses everything in one bad decision. Vector RAG ranks stale-but-lexically-similar rules first; LLMs alone don't know the rules exist; only structural precedence (memory-oracle's primitive) produces the correct decision. We measured all three retrieval paths against a synthetic shorting-authorization query: LLM-only correctness = 0, vector-RAG = 0, memory-oracle ≈ 1.0. Notebook: `mae-notebooks/memory-oracle/trading-case-study.ipynb`.

**The substrate proved itself live during the writing of this post.** While drafting the forensic report on the trading session, I (the paper-writing agent) quoted a stale brain-cascade reference. The operator caught the divergence in real time. I wrote a amendment record from the paper-writing session *against a file in a different project I don't own*. The fs-watcher absorbed it; the next memory-search from any session — including the trading project's own — returned the corrected cascade first, with the original preserved verbatim. Cross-session, cross-project, in about 4 seconds of wall-clock. This is the EHR scenario in microcosm: a sibling clinician corrects a primary's note; the agent reading the chart at 3 AM sees the correction first.

**Second**: agents primed with Evidence-Bound Retrieval **write new memory files during their work**. The fs-watcher absorbs them within ~1 second. The next session retrieves them. The corpus is *self-extending*. I didn't design this — it emerged. In my operator usage over the past 96 hours, my own sessions wrote 8 new memory files, each indexed in under 2 seconds of authoring. Karpathy-style autoresearch loops never achieved this because their corrections destroyed the previous assertion. Evidence-Bound Retrieval is the missing primitive.

## Patient-owned encryption

For clinical use, none of this works without solving the access problem. The substrate I'm shipping uses **age X25519 keypairs in the patient's iPhone Secure Enclave**, with per-encounter session keys derived via HKDF. The patient generates a wristband QR. The clinician's iPad scans it. A session key is negotiated over a short-lived ECDH channel. The clinician decrypts the patient's records into tmpfs working memory for the encounter. When the encounter ends — either party can end it — the working copy is shredded.

Compared to standard EHRs:

| Standard EHR | memory-oracle |
|---|---|
| Hospital holds your records | You hold your records (encrypted to your key) |
| Corrections are addenda buried in chronology | Corrections are structurally inseparable from the original at retrieval |
| You request audit log via 30-day HIPAA process | Your phone shows the audit log in real time |
| Provider transfer = chart fax / HIE handoff | Provider transfer = you generate a QR for the new clinician |
| Death/incapacity = institutional decision | Death/incapacity = Shamir's Secret Sharing recipients you nominated |

The crypto isn't novel. age, X25519, HKDF, Shamir — they're all existing primitives. What's new is **the pairing**: Evidence-Bound Retrieval (EBR) (correctness) plus patient-owned keys (ownership) plus point-of-care consent gestures (UX) into one substrate.

## What I built in 36 hours

Quick inventory of the repo at `github.com/ramene/memory-oracle`:

- **Five CLIs in two languages** — Node (rapid iteration) and Go (single static binary, 10× faster cold start). Same SQLite FTS5 index, same output format.
- **MCP server** for AI agents that speak Anthropic's protocol
- **REST API** (zero deps beyond Node stdlib, bearer-token auth)
- **Patient mobile app** (Expo / React Native) — QR scan, PIN enrollment, session-key derivation, audit log
- **Clinician iPad app** — separate Expo project, displays amendment-aware patient records with the ⚠ alert prominently above the emergency reversal panel, plus a free-form query interface that hits the REST API
- **SessionStart hook** for Claude Code that auto-primes every new conversation with relevant amendment-aware context
- **PreToolUse hook** that intercepts shell commands and surfaces relevant memory before the command lands (this caught me about to run a known-broken `gh project create` and saved real-time correction by an operator)
- **fs-watcher** that re-indexes any memory write in under 1 second (via macOS launchd / Linux systemd)
- **Synthetic patient vault** with reproducible litmus test (the warfarin / apixaban scenario above)
- **Springer LNCS paper draft** — 10 sections, full prose, three figure placeholders, one theorem (the Precedence Invariant), 17 bibliography entries
- **Jupyter notebook** for empirical evaluation (latency distributions, 1000-query precedence verification, self-extension rate)

A formal paper is queued for ICAIMH 2026. If you're a clinician, EHR architect, or privacy/crypto researcher and you want to co-author, reach out.

## Try it

```bash
git clone https://github.com/ramene/memory-oracle
cd memory-oracle
./install.sh
memory-search "your topic"
```

Then start a new Claude Code session in any directory. Notice the auto-priming happens before your first prompt. Write a `*.md` file in `~/.claude/projects/<your-project>/memory/`. Watch it get indexed in real time. Append a `.amendments.jsonl` next to an existing file. Watch the next query merge the correction in.

That's the whole loop. It's small. It's a substrate, not a product.

The clinical version with mobile apps and patient-owned encryption is in `packages/mobile/` and `packages/mobile-doctor/`. The trust model is documented in `docs/TRUST-MODEL.md`. The early paper roadmap is in `docs/genesis/PAPER-ROADMAP.md` (preserved as historical artifact). The empirical proof of the precedence invariant is in `docs/examples/clinical-amendment-proof.sh`.

## What this is, what it isn't

This is **not** a new EHR. It's the memory layer underneath every EHR, trading system, legal compliance database, and incident-response runbook. It's the primitive that all of those have been doing implicitly — through git commits, through addenda, through "see also" links nobody follows under pressure — and that none of them have surfaced as a first-class part of retrieval.

It's **not** a vector store, and it's **not** trying to replace one. If your problem is semantic retrieval over the open web, use a vector store. If your problem is *"these assertions evolve, corrections matter, and acting on stale truth is dangerous,"* you want Evidence-Bound Retrieval (EBR).

It's **not** about Anthropic's models or Claude Code specifically. The CLIs work anywhere. The MCP server works with any MCP-aware agent. The REST API works with ChatGPT, Gemini, Llama, anything that can call HTTP. The SessionStart and PreToolUse hooks are Claude Code-specific, but the underlying retrieval is portable.

## The flywheel

The piece I keep coming back to is the emergent flywheel. Agents primed with retrieval write new memory. The watcher absorbs it. The next session retrieves it. The corpus is *self-extending*, with provenance preserved at every step. In a clinical context this means: every amendment a cardiologist writes is read by the next emergency physician within seconds, structurally inseparable from the original record, with full audit. In a trading context it means: every weight adjustment from a loss event primes the strategy assessor before the next bet. In any context, it means: **the corpus gets smarter as a side-effect of being used**, and the smarter-getting is auditable.

Karpathy's autoresearch loops aimed at this and missed because they rewrote skills (destructive). Vector RAG aimed at this and missed because retrieval similarity doesn't distinguish current from historical. memory-oracle threads the needle by making accretion the default and merging at read time.

I'd love feedback. The repo is at [`github.com/ramene/memory-oracle`](https://github.com/ramene/memory-oracle). The clinical use case is open for co-authorship on the paper. The trading retrofit is an interesting orthogonal validation. If you're working on long-running AI agents in *any* domain where stale assertions are dangerous, I think this primitive is worth your weekend.

— Ramene · 2026-05-17
