# Mastodon thread variants

> Multiple lengths for different posting contexts. Each is self-contained and links back to the full Substack/Medium piece + the repo.

## Variant A: short solo toot (one post, ~500 chars)

🧠 Shipped `memory-oracle` — Evidence-Bound Retrieval for AI agents.

The problem: agents parrot stale memory files. Vector RAG can't tell "true today" from "true in 2008."

The fix: corrections as additive JSONL sidecars beside canonical files. Merged at retrieval time. Original preserved.

Clinical proof: 2008 warfarin note + 2024 apixaban amendment → ER LLM gets andexanet alfa, not FFP. Patient survives.

Repo: github.com/ramene/memory-oracle (MIT) #AI #ClinicalAI

## Variant B: short thread (3 toots)

**1/3** Shipped memory-oracle — a Evidence-Bound Retrieval substrate for AI agents. The problem it solves: agents confidently parrot stale memory files because vector RAG can't structurally surface corrections.

The primitive is small: corrections are JSONL sidecars beside canonical files, merged at retrieval time so the agent encounters the correction *before* the stale assertion.

**2/3** Clinical test case: patient on warfarin 2008, switched to apixaban 2024. ER bleed 2026. The AI is asked how to reverse it.

Vector RAG ranks the 2008 warfarin note higher → orders FFP. Wrong reversal. Patient bleeds out.

memory-oracle merges the 2024 amendment into retrieval. "andexanet alfa" appears 58 lines before "FFP." Patient survives.

**3/3** Full repo: github.com/ramene/memory-oracle (MIT). Includes Node + Go CLIs, MCP server, REST API, Expo mobile apps (patient iPhone + clinician iPad with consent QR flow), and a 10-section Springer LNCS paper draft.

Looking for clinical + crypto co-authors for the paper. Domain extends to algorithmic trading and any domain where corrections > recall.

## Variant C: long thread (8 toots — full argument)

**1/8** 36 hours ago I noticed my LLM coding agent quoting a memory file I'd written three weeks earlier — confidently, authoritatively, completely wrong because the architecture had moved on. The file was still in the directory. The agent treated it as canon.

This is the Bad Write-Back failure mode. Every long-running AI agent eventually hits it.

**2/8** Vector RAG can't fix this. Cosine similarity matches "warfarin" in 2008 and "warfarin" in 2026. Re-embedding a corrected chunk doesn't invalidate the original embedding. The agent has to reason about which is current, and under pressure it picks wrong.

Nate Jones wrote about this last week. He stopped short of proposing an architecture.

**3/8** Here's the architecture I shipped: **Evidence-Bound Retrieval (EBR)**.

When a fact changes, you append a JSONL sidecar beside the canonical memory file. Original is never edited. The retrieval engine merges amendment records into the output *before* the canonical body.

Any sequential reader — LLM or human — encounters the correction first.

**4/8** Clinical test case for the paper: synthetic patient Jane Doe, 67. Warfarin 2008. Switched to apixaban 2024 (the cardiologist wrote an amendment). ER bleeding 2026.

The reversal agent for warfarin (FFP + vitamin K) DOES NOT REVERSE apixaban. The factor Xa inhibitor needs andexanet alfa.

A vector RAG system retrieves the 2008 protocol and recommends FFP. Patient dies.

**5/8** memory-oracle's retrieval merges the 2024 amendment block into the output. "andexanet alfa" appears at line 21. "Fresh Frozen Plasma" appears at line 79. The LLM reads the correction 58 lines before it ever sees the stale protocol.

This is a precedence invariant, provable from the merge algorithm. I have a theorem in the paper for it.

**6/8** Patient-owned encryption layer (using age X25519 in iOS Secure Enclave + per-encounter session keys via HKDF + Shamir's Secret Sharing for break-glass). The hospital storage holds ciphertext only. Either party can end the encounter cryptographically.

Read TRUST-MODEL.md in the repo for the full architecture.

**7/8** The piece that surprised me: agents primed with Evidence-Bound Retrieval *write new memory files during work*. The fs-watcher absorbs them in ~1 second. The next session retrieves them. The corpus self-extends.

This is the property Karpathy-style autoresearch loops aimed at and missed (they overwrote skills, lost provenance).

**8/8** Repo: github.com/ramene/memory-oracle (MIT)

Node + Go CLIs, MCP server, REST API, Expo apps for patient iPhone + clinician iPad, Springer LNCS paper draft, reproducible clinical proof.

Looking for clinical + privacy co-authors for ICAIMH 2026. The substrate generalizes beyond clinical — already retrofit a trading platform too.

#AI #ClinicalAI #RAG
