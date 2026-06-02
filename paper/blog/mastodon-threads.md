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

## Variant D: Phase 3 demo thread (5 toots, image-led, June 2026)

> Attach the screenshots in order. F3 → F4 → F8 → F7b → F6. Caption each with the figure handle.

**1/5** [📷 F3 — patient home with QR + pending request inbox]

Shipped Phase 3 of `memory-oracle` — the substrate's clinical claim, end-to-end on two real iOS devices.

Patient iPhone (SwiftUI, CryptoKit, Secure Enclave): generates an `age1se1…` recipient as a QR. Inbox shows pending encounter requests, each row naming the requesting clinician + scopes + TTL.

**2/5** [📷 F4 — patient consent form, pre-biometrics]

Before Face ID fires, the full consent surface is visible: who's asking, what they're asking for, for how long. Approval is gated on Face ID against the SE-bound key. The private key never leaves the iPhone.

The wrapped session keys returned to the clinician are age v1 `piv-p256` stanzas cryptographically bound to the clinician's recipient. No shared secret. No server-side key escrow.

**3/5** [📷 F8 — HIPAA §164.526 audit trail]

Every cryptographic and consent event is appended to a local audit log: `encounter_request_sent`, `approval_received`, `records_decrypted`, `ebr_alert_conflict`, `ebr_alert_acknowledged` / `_overridden`, `encounter_expired_shred`.

HIPAA §164.526 has required amendment-tracking forever and never had a machine-readable substrate for it. Now it has one.

**4/5** [📷 F7b — EBR Alert: AI Overview surfaces penicillin allergy at point of action]

The citation-card moment. The active clinician drafts `prescribe amoxicillin 500mg PO TID`. Before the order commits, `get_citation_card()` checks the accretive record. Patient has a 2014 Penicillin anaphylaxis — amoxicillin is a β-lactam in the same cross-reactive class.

A Google-style "AI Overview" surfaces it: TL;DR, explanation, sources, policy attribution (`amendment-supersedes-original`). Two routes: *Acknowledge & withdraw* or *Override (document reason)*. Both write to the audit log.

This is the exact moment current EHRs are silent.

**5/5** [📷 F6 — multi-identity: two clinicians, two SE keys, two-factor switch]

The substrate's multi-clinician claim is cryptographically honest. Two independent clinician identities on the same iPad, each backed by its own Secure Enclave-bound key, each gated by PIN-plus-Face ID two-factor switch (PINs stored as salted SHA-256, SE keys never leave the device).

A second clinician's record-write is signed by a key materially distinct from the first. That's what makes the EBR alert in toot 4 a real multi-clinician event and not a UI gloss.

Eight figures in §7.4 of the LNCS manuscript; walkthrough + synthetic corpus reproduce every moment.

Repo: github.com/ramene/memory-oracle (MIT) #AI #ClinicalAI #HIPAA
