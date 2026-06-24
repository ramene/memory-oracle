# memory-oracle

> An accretive, evidence-bound memory substrate for AI agents. Plain markdown + dated amendment records + a deterministic merge — no vectors, no fine-tuning, no model in the retrieval loop.

## What this is

memory-oracle is the reference implementation of **Evidence-Bound Retrieval (EBR)** — a substrate that binds every retrieval to the most recent operator-authored evidence by construction. Not by similarity. Not by a trained critic. Not by reinforcement signal.

It is offered as a concrete realization of the **episodic memory layer** in [CoALA](https://arxiv.org/abs/2309.02427) (Sumers, Yao, Narasimhan, Griffiths — TMLR 2024) — Princeton's four-memory taxonomy for language agents (working / semantic / procedural / episodic).

## Papers

- ⭐ **[*Evidence-Bound Retrieval: A Substrate for CoALA's Episodic Memory Layer*](paper/coala-extension/main.tex)** — position paper extending CoALA's episodic layer with the EBR substrate. Theorem 1 (the structural precedence invariant). Composition with the other three CoALA memory types. Target venues: NeurIPS 2026 workshops (FMDM, R2-FM), ICLR 2027 workshop tracks, ACL position-paper track.
- **[*Evidence-Bound Retrieval for Clinical AI: An Accretive Memory Substrate with Patient-Owned Keys*](paper/lncs/main.tex)** — full clinical-AI manuscript. Springer LNCS shape. Empirical evidence from N=1,000 queries plus a real-corpus probe. Clinical (warfarin → apixaban) and trading (KuCoin no-shorting rule) case studies.

Companion CTA post: [*From Forgetting to Amending*](paper/blog/from-forgetting-to-amending.md).

## The problem EBR solves

Agents quote stale memory files because nothing tells them the file is wrong.

A patient is on warfarin per a 2008 chart note. The 2024 cardiology consult switched her to apixaban — vitamin K does not reverse apixaban. Both notes are in the chart. The patient presents to the ER with active bleeding and the team asks the AI-augmented EHR for the reversal protocol. Vector RAG ranks the 2008 note higher because the older note is longer and the lexical overlap with the query is stronger. The team orders FFP and vitamin K. Neither works.

This is the **Bad Write-Back** failure mode. Vector embeddings don't help — they retrieve the same stale file with high cosine similarity. Re-writing the canonical note destroys provenance. The right primitive is not a better retriever; it is a different file layout.

## The mechanism — amendment records

When the cardiologist makes the change, they write one JSON line into a sidecar beside the canonical note:

```
~/.claude/projects/<project>/memory/
├── medication_anticoagulant.md                     # canonical, never edited
└── medication_anticoagulant.md.amendments.jsonl    # corrections, append-only
```

Each sidecar line records one dated, operator-authored correction:

```json
{
  "amended_at":           "2026-03-14T11:02:00Z",
  "amended_by":           "Dr. Reyes, MD",
  "superseded_assertion": "Patient is on warfarin 5 mg/day.",
  "corrected_assertion":  "Patient transitioned to apixaban 5 mg BID on 2026-03-12.",
  "live_evidence":        "EHR/encounter/E-71412/note-2.txt#L42",
  "operator_confirmed":   true
}
```

When the retrieval CLI reads the file, it merges the amendments into the output **before** the canonical body. Any sequential reader — human or LLM — encounters the correction first. The canonical text is preserved verbatim, so an auditor in 2030 can see exactly what was once believed and exactly when it was corrected.

```
## ⚠ Amendment Notice (1 record)

### Amendment 1 — 2026-03-14T11:02:00Z
Corrected assertion: Patient transitioned to apixaban 5 mg BID on 2026-03-12.
Live evidence: EHR/encounter/E-71412/note-2.txt#L42
Amended by: Dr. Reyes, MD
---
[canonical file content — preserved verbatim, read with the corrections above in mind]
```

The precedence is **structural**, not statistical (Theorem 1 of the position paper): the merge routine prepends amendments by construction. No critic forward pass, no similarity tiebreak, no reinforcement loop.

## Architecture

```
canonical Markdown file  +  amendment sidecar (JSONL)
                        ↓
                memory-merge.mjs   (precedence invariant: amendments prepended)
                        ↓
              SQLite FTS5 index    ($MEMORY_INDEX_DB)
                        ↓
       memory-search (BM25, Tier 1)  |  memory-cite (forensic, Tier 2)
                        ↓
                Claude Code agent context
```

Three retrieval tiers:

| Tier | Tool | Purpose | Typical latency |
|---|---|---|---|
| **1 — BM25 keyword** | `memory-search.mjs <query>` | "What is the current value of X?" | ~250 ms |
| **1.5 — Structural** | SQL over the `surface_map` table | "Which files in project P were amended this week?" | ~40 ms |
| **2 — Forensic** | `memory-cite <session-id>#L<line>` | Recover a file's full amendment timeline | ~10 s |

Plus a **SessionStart hook** that auto-primes every new Claude Code session with amendment-aware context before the first prompt is sent.

## Empirical results

From the papers + the [companion notebooks](notebooks/memory-oracle/):

- **Synthetic vault stress test, N=1,000 queries** (clinical + trading): EBR returns the post-amendment assertion on **100.0%** of queries; vector-RAG on **10%**; a control LLM with no retrieval on **0%**. Required-litmus gap: **0.9**.
- **Real-corpus probe** — the author's own production substrate, **239 documents** across **21 projects** over **108 days**: **6/6** known cross-session corrections retrievable in BM25 search; median latency **257 ms**.
- **Latency** (Go binary, cold start): **21.68 ms** median, 51 ms p95. **6.0×** speedup vs. the Node CLI cold path.
- **Capture freshness**: **366 ms** median between an operator writing an amendment and the index returning it.
- **Index hygiene under contention**: 30/30 concurrent amendment writes indexed; 0 data loss; 7/30 events incurred transient SQLite-busy retries the substrate handled internally.

Full numbers + figures in [`paper/lncs/main.tex`](paper/lncs/main.tex) §5–§8.

## Notebooks (Colab Free, anonymous-clickable)

| Notebook | Paper section | Colab |
|---|---|---|
| `clinical-case-study.ipynb` | §5 Clinical Case Study | [![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/ramene/memory-oracle/blob/main/notebooks/memory-oracle/clinical-case-study.ipynb) |
| `trading-case-study.ipynb` | §6 Cross-Domain Generalization | [![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/ramene/memory-oracle/blob/main/notebooks/memory-oracle/trading-case-study.ipynb) |
| `empirical-evaluation.ipynb` | §8 Empirical Evaluation | [![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/ramene/memory-oracle/blob/main/notebooks/memory-oracle/empirical-evaluation.ipynb) |

## Install

```bash
git clone https://github.com/ramene/memory-oracle
cd memory-oracle
./install.sh
```

This:
- Copies `bin/*` to `~/.bin/` (`memory-search.mjs`, `memory-index-build.mjs`, `memory-merge.mjs`, `memory-cite.mjs`, `memory-structural-index.mjs`)
- Installs the SessionStart hook to `~/.bin/claude-hook-session-start.sh`
- (macOS) loads the launchd plist for the fs-watcher that incrementally re-indexes after every memory-file write
- (Linux) emits the systemd unit + activation command at install time
- Builds the initial FTS5 index from `~/.claude/projects/*/memory/`

Idempotent. Re-running upgrades in place. Configurable: set `MEMORY_INDEX_DB` and `CLAUDE_PROJECTS_ROOT` in your shell rc to override defaults.

## Substrate propagation

`./install.sh` is the **single propagation path** for the whole EBR substrate across machines (noodles / sequoia / tunafish + any future box). Deploying to a machine is just:

```bash
git pull && ./install.sh
```

No hand-copying tools to each host. Beyond the oracle CLIs above, the installer also (all idempotent, safe to re-run):

- **Substrate fleet tools** → `~/.bin/` + `chmod +x`: `brain-sync.sh`, `vault-autosync.sh`, `git-remote-verum` (sovereign git remote-helper), `claude-hook-substrate-guard.mjs`, and the M3 tools `mae-substrate-export.mjs` / `mae-substrate-import.mjs` / `mae-substrate-merge.mjs` / `mae-verum-pubkeys.mjs`.
- **Claude Code hooks** auto-registered in `~/.claude/settings.json` via an idempotent `python3` merge (creates the file/keys if missing, de-dupes by command before appending):
  - `SessionStart` → `$HOME/.bin/claude-hook-session-start.sh` (the amendment-aware banner)
  - `PreToolUse` matcher `Bash` → `node $HOME/.bin/claude-hook-substrate-guard.mjs` (routes substrate recall through the oracle)
- **Cron jobs** (host-detected via `hostname -s`, written to `~/.claude-tmp/*.log`):
  - `vault-autosync` every 3 min on **all** hosts.
  - `brain-sync` per host, staggered so the mesh converges without collisions, each pointed at the other two peers via `BRAIN_MACHINES`:

    | Host | Schedule | `BRAIN_MACHINES` |
    |---|---|---|
    | noodles | `*/15 * * * *` | `local,sequoia,tunafish` |
    | sequoia | `5,20,35,50 * * * *` | `local,noodles,tunafish` |
    | tunafish | `10,25,40,55 * * * *` | `local,noodles,sequoia` |
    | (unknown host) | — | vault-autosync only; brain-sync skipped with a notice |
- **verum binary** at `~/.bin/verum`: if not already `verum 0.11.0`, downloads the arch-matched asset (`uname -m`/`uname -s`) from the `v0.11.0` GitHub release via `gh release download … -R ramene/verum`, untars, installs. If `gh` or the asset is unavailable, it prints a manual-fallback note and continues (install does not fail).
- **Mesh ssh aliases** in `~/.ssh/config` (dedup-safe, skips the current host): `noodles` (192.168.100.2), `sequoia` (.14), `tunafish` (.12) — each `User ramene`, `IdentityFile ~/.ssh/id_ed25519_ramene_auth`, `StrictHostKeyChecking accept-new`.

### Deploying to a new machine

1. Generate the verum identity once on the box: `node ~/.bin/mae-verum-pubkeys.mjs --gen-ed25519 --gen-x25519` (private keys stay local, 0600).
2. `git clone https://github.com/ramene/memory-oracle && cd memory-oracle && ./install.sh`.
3. Add the new host to the per-host `case` blocks in `install.sh` (cron schedule + `BRAIN_MACHINES`) and to the `add_mesh_host` calls, so the mesh knows about it.
4. Distribute any shared verum namespace key out-of-band (the brain is sovereign — no third party holds it).

## Usage

```bash
# Query — amendment-merged, budget-capped, BM25-ranked
memory-search "deploy process safety rules" --k=8

# Verify an amendment citation against the raw transcript (Tier 2 forensic)
memory-cite session-id-here#L94616 --context 3

# Write a new amendment when you observe a file asserting something stale
cat <<EOF >> ~/.claude/projects/<project>/memory/<file>.md.amendments.jsonl
{"amended_at":"$(date -u +%FT%TZ)","superseded_assertion":"<the stale claim>","corrected_assertion":"<the new truth>","live_evidence":["/path/to/verify"],"operator_confirmed":"$(date -u +%FT%TZ)","retention_policy":"indefinite"}
EOF
# The fs-watcher picks it up and rebuilds the index in ~1 second.
```

The canonical file is **never deleted or edited**. Amendments are additive. Audit-friendly, fully reversible (delete one JSONL line to undo).

## Why this isn't another RAG library

| | Vector RAG (pgvector, LangMem, MemGPT, …) | memory-oracle / EBR |
|---|---|---|
| Storage | Embeddings of chunks in a vector DB | Plain Markdown + JSONL sidecars on disk |
| Retrieval primitive | Cosine similarity over learned embeddings | BM25 keyword + structural precedence merge |
| Correction mechanism | Re-embed the updated chunk (provenance lost) | Append an amendment record (provenance preserved) |
| Compute requirements | GPU for embedding, network for queries | None — SQLite CLI |
| Stale-file fooling | Yes — old embedding still ranks high | No — amendments prepended by construction |
| Self-extending | No — you must re-embed | Yes — fs-watcher absorbs new files in ~1 s |
| Lines of code | ~10K + dependencies | ~1.5K, zero deps beyond `sqlite3` + `node` |
| Audit trail | Lost on re-embed | Full — canonical + dated amendment chain |

Full comparison + the contrast with learned distillation approaches (CRAG, Self-RAG, FLARE) lives in [`docs/COMPARISON.md`](docs/COMPARISON.md) and the position paper's Related Work.

## Composition with the CoALA framework

EBR is the **substrate for the episodic layer** of [CoALA](https://arxiv.org/abs/2309.02427). It does not replace the other three layers; it composes with them:

| CoALA layer | What EBR does to it |
|---|---|
| **Semantic** (durable knowledge, `CLAUDE.md`, project docs) | Amendments attach to canonical semantic files — the file is never edited; the correction wins at retrieval time. |
| **Procedural** (skills, `skill.md`) | A skill can itself be amended; procedural corrections do not require modifying the canonical instructions. |
| **Working** (the context window) | EBR delivers amendment-merged retrievals into working memory the same way RAG does — but the prepended amendments make the most recent operator-authored correction visible to the agent first. |
| **Episodic** (CoALA's *"hardest layer"*) | EBR is the substrate. The deletion / obsolescence problem (CoALA's open question) is resolved structurally: nothing is deleted, amendments are accreted, precedence is enforced by the merge routine. |

## Repository layout

```
memory-oracle/
├── bin/                          # Node CLIs: memory-search, memory-merge, memory-index-build, memory-cite
├── hooks/                        # Claude Code SessionStart + PreToolUse hooks (portable)
├── runtime/                      # launchd plist (macOS) + systemd unit (Linux) for the fs-watcher
├── skills/memory-search/         # Installable Skill (SKILL.md)
├── notebooks/memory-oracle/      # Colab-runnable clinical + trading + empirical-evaluation notebooks
├── paper/
│   ├── coala-extension/          # ⭐ Position paper (CoALA episodic-memory substrate)
│   ├── lncs/                     #    Clinical-AI manuscript (Springer LNCS)
│   ├── blog/                     #    Companion CTA posts
│   ├── figures/                  #    Paper figures (PNG)
│   └── EVIDENCE-OF-PLATFORM.md   #    The substrate's self-evidence — why it works in production
├── docs/                         # Current docs (comparison, privacy, trust model)
│   └── genesis/                  # Originating-incident archive (ADR, contract spec, failure-mode triage)
├── packages/go-cli/              # Standalone Go binary of memory-search (single static executable)
├── tests/                        # Litmus scripts proving the precedence invariant holds
├── install.sh                    # Idempotent installer
└── LICENSE                       # MIT
```

## Status

| Surface | State |
|---|---|
| Substrate code (`bin/`, `hooks/`, `runtime/`) | Stable, in daily use |
| Position paper (CoALA extension) | Drafted, workshop-submission-ready |
| Clinical-AI manuscript (LNCS) | Drafted, submission-ready |
| Notebooks (clinical, trading, empirical) | Colab-runnable, paper-quality measurements |
| Reference implementation | MIT-licensed, public |
| Independent reproduction | **Open call** — fork the repo, run the notebooks on your own corpus, [open an issue](https://github.com/ramene/memory-oracle/issues) with your numbers |

## License

MIT.

## Origin

memory-oracle began as a one-session fix for a single observed failure: an AI agent confidently quoting a memory file two weeks after the world had moved on. The substrate evolved over eleven days into a Springer-LNCS clinical-AI paper, a CoALA position paper, three Colab-runnable case-study notebooks, a real-corpus probe of the author's own production memory bank (6/6 retrievable cross-session corrections), and an MIT-licensed reference implementation.

The originating incident-triage, the retrieval-stack ADR, and the failure-mode taxonomy live in [`docs/genesis/`](docs/genesis/) as a preserved archive of how the substrate was reasoned into existence. They contain pre-scrub operator-specific naming and are not part of the substrate's public-facing surface — see the [`docs/genesis/README.md`](docs/genesis/README.md) callout.

Direct intellectual ancestor: Nate Jones's [*The New RAG War Is Not About Vectors*](https://natebjones.substack.com/p/the-new-rag-war-is-not-about-vectors) — the systems framing that named why vector retrieval was the wrong primitive for AI-agent memory. The substrate is the architecture that answers his framing.
