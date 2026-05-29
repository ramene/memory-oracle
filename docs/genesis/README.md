# Genesis — originating-incident archive

> **⚠ Archive notice.** This directory preserves the engineering documents
> written during the 2026-05-16 incident that motivated the memory-oracle
> substrate. They contain pre-scrub operator-specific names (internal project
> identifiers, services, paths, OAuth client IDs) that are **not part of the
> substrate's public-facing surface**. They predate the public-repo scrub PRs
> (#9 and the genesis-archive PR). Read them as historical artifacts of the
> reasoning that produced the design — do not use them as reference for
> production deployments. The substrate has evolved significantly since they
> were written.

## What this is

memory-oracle began as a one-session fix for a specific failure mode the
author encountered: an AI coding agent confidently quoting a memory file two
weeks after the world had moved on. The four documents in this directory
capture the reasoning that turned that one observed failure into a substrate
design.

In chronological order:

| Document | Captures |
|---|---|
| `RETRIEVAL-FAILURE-TRIAGE.md` | The failure-mode taxonomy that named **six distinct ways AI memory can fail** (Mode 0 through Mode 7), and identified the specific failure mode the incident demonstrated empirically |
| `RETRIEVAL-CONTRACT-SPEC.md` | The engineering contract any candidate substrate must satisfy — what the retrieval system must deliver before an AI session starts acting |
| `RETRIEVAL-STACK-ADR.md` | The architectural decision record explaining why the chosen design was preferred over pgvector (option $\alpha$) and a hybrid kitchen-sink approach (option $\beta$) |
| `PAPER-ROADMAP.md` | The early planning document outlining the eventual paper structure, before the manuscripts took their current shape |

## Why these are preserved rather than rewritten

Two reasons:

1. **The reasoning is the artifact.** Generic-placeholder rewrites would
   produce a sanitised document that no longer captures *why* specific
   alternatives were rejected. The genesis docs are honest about the
   incident's particulars, and that honesty is what makes them useful as
   historical reasoning.

2. **The narrative is the substrate's origin story.** The substrate
   eventually became a peer-review-ready system (see [`README.md`](../../README.md)
   and [`paper/`](../../paper/)), but it began as one operator's response to
   one specific failure. Preserving the originating documents lets future
   readers see the path from incident to substrate.

## Current state — read these instead

For the current architecture, vocabulary, and empirical results, use the
post-scrub artifacts at the top of the repository:

- [README.md](../../README.md) — current project overview, install, usage
- [paper/lncs/main.tex](../../paper/lncs/main.tex) — clinical-AI manuscript
- [paper/coala-extension/main.tex](../../paper/coala-extension/main.tex) — CoALA episodic-memory position paper
- [docs/COMPARISON.md](../COMPARISON.md) — substrate comparison (current)
- [docs/PRIVACY.md](../PRIVACY.md) — privacy model (current)
- [docs/TRUST-MODEL.md](../TRUST-MODEL.md) — trust model (current)

## Internal-name caveat in detail

The four archived documents contain references to:

- Specific operator-private project names (`mae-monorepo-build`, `builds.karve.ai`)
- Specific inference-service identifiers (`mae-claude-proxy`, `mae-openai-proxy`)
- Specific Cloud SQL and Cloud Run instance names
- OAuth client IDs from the originating incident
- Absolute filesystem paths under `/Users/ramene/`

None of these names are part of the substrate's design. They are present
because the documents were written as engineering artifacts inside an active
incident, not as polished public-facing reference. The substrate itself
(`bin/`, `hooks/`, `runtime/`, the papers in `paper/`) is generic and
deployable by any operator.
