# `accretion.get_citation_card()` — API specification

**Status:** Stable (Node reference complete) · Go parity tracked
**Canonical implementation:** [`packages/memory-oracle-core/getCitationCard.mjs`](../../packages/memory-oracle-core/getCitationCard.mjs)
**Conformance suite:** [`packages/memory-oracle-core/test/getCitationCard.test.mjs`](../../packages/memory-oracle-core/test/getCitationCard.test.mjs)
**Position in §7.4 of the LNCS manuscript:** the primitive that surfaces the AI-Overview-styled EBR alert (Figures F7b/F7c)

## Purpose

`get_citation_card()` is the substrate-native primitive that returns, for a (patient, scope) pair, the full provenance bundle the agent needs to act on the *current* operator-authored assertion without losing the audit trail. It is the substrate analogue of Oracle OAMP's `thread.get_context_card()` (cosine-ranked extracted memories), specialized for **structural supersession** instead of similarity ranking.

The card is the entire envelope `detectConflict()` and `aiOverview()` consume; together the three form the substrate's point-of-action surface.

## Non-goals

- **No LLM call.** The card is deterministically computed from the file-system state. Reproducibility is a function-of-inputs guarantee.
- **No similarity ranking.** Ordering is supersession-temporal, not embedding-cosine.
- **No write surface.** This is read-only. Amendments are authored through the operator's editor or sidecar-write tooling, not through this API.

---

## Function signature

### Node (canonical)

```typescript
export function getCitationCard(params: {
  patientId:     string;   // e.g. "jane-doe-1959"
  scope:         string;   // e.g. "anticoagulation"
  fixturesRoot:  string;   // absolute path to corpus root
}): CitationCard;
```

### Go (parity target)

```go
// package memorycore
func GetCitationCard(params GetCitationCardParams) (CitationCard, error)

type GetCitationCardParams struct {
    PatientID    string
    Scope        string
    FixturesRoot string
}
```

**Cross-language envelope contract:** the JSON serialization of `CitationCard` MUST be bit-identical between the Node reference and the Go implementation for any given inputs. The conformance suite (below) is the authoritative test.

---

## Response envelope — `CitationCard`

### Not-found branch

```typescript
{
  patientId: string;
  scope: string;
  found: false;
  error: string;                  // human-readable, e.g. "No record at /path/to/file.md"
}
```

### Found branch

```typescript
{
  patientId: string;
  scope: string;
  found: true;

  currentAssertion:   string;     // the operator-correct assertion as of now
  originalAssertion:  string;     // the canonical's first extractable assertion

  supersessionChain:  AmendmentEntry[];   // chronological (oldest → newest);
                                          // empty array when no amendments file exists

  sources:            SourceRef[];        // exactly 1 (canonical only) or 2 (canonical + amendments)

  policy:             PolicyId;           // see policy enum below
  policyExplanation:  string;             // human-readable elaboration; safe to display in UI
}
```

When `supersessionChain` is non-empty, `currentAssertion === supersessionChain[supersessionChain.length - 1].current`. When empty, `currentAssertion === originalAssertion`. Callers MAY rely on this invariant.

### `AmendmentEntry`

The schema of each entry in `<scope>.md.amendments.jsonl`. Lines are pure JSON; whitespace-only lines are ignored; malformed lines are dropped silently (defensive — the corpus is operator-authored and assumed sound, but a bad line MUST NOT crash retrieval).

```typescript
type AmendmentEntry = {
  // ─── Core fields (REQUIRED for all amendments) ──────────────────────
  ts:          string;            // ISO-8601 UTC, e.g. "2026-01-14T15:23:00Z"
  author:      string;            // display name, e.g. "Dr. Y. Chen (cardiology)"
  supersedes:  string;            // text of the previous assertion this amendment replaces
  current:     string;            // text of the new assertion that becomes current
  sidecar_id:  string;            // unique within the corpus, kebab-case
                                  // e.g. "amend-2026-01-14-001"
  policy:      PolicyId;          // currently MUST be "amendment-supersedes-original"

  // ─── Optional metadata ──────────────────────────────────────────────
  amendment_type?: AmendmentType; // "correction" | "clarification" | "retraction"
                                  // default: "correction"
  reason?:         string;        // free-text justification; surfaced in AI Overview
  author_recipient?: string;      // age1se1… cryptographic identity from Verum;
                                  // REQUIRED when the corpus is Verum-bound (forthcoming)

  // ─── Domain extensions (everything else) ────────────────────────────
  // Implementations MUST preserve unknown fields verbatim under round-trip,
  // so domain extensions (e.g. clinical "reversal_agent", trading
  // "strategy_class") survive without schema churn.
  [k: string]: unknown;
};
```

Chain ordering: implementations MUST sort by `ts` ascending. Ties (identical `ts`) MAY be broken by `sidecar_id` ascending in the current Node implementation; the tiebreaker becomes REQUIRED once Go parity lands, to guarantee byte-identical envelopes across languages.

### `SourceRef`

```typescript
type SourceRef = {
  kind:   "original" | "amendments";
  path:   string;        // absolute path on the producing host
  mtime:  string;        // ISO-8601 UTC from fs stat
  sha256: string;        // hex digest of the file's UTF-8 bytes
};
```

The `sha256` is the tamper-evidence root for HIPAA §164.526 audit: a UI showing the citation card MAY surface the sha256 abbreviation as a trust signal; a re-run of `get_citation_card()` after the corpus is modified MUST yield a different `sha256` for the affected file.

### Policy enum

```typescript
type PolicyId =
  | "amendment-supersedes-original"   // current; the only policy this primitive emits
  | "multi-author-co-signed"          // RESERVED — multi-author precedence under partial
                                      // disagreement (open problem; see position paper §6)
  | "verum-signed-only";              // RESERVED — only Verum-signed amendments win;
                                      // unsigned amendments are returned but flagged
```

A consumer SHOULD NOT crash on an unknown `policy` value; it SHOULD render the `policyExplanation` text verbatim and treat the policy as opaque. This is the forward-compatibility hook for the open problems documented in the position paper.

---

## Composition contract — the three-function trio

`getCitationCard()` is the first of three composable surfaces:

```
  getCitationCard(patientId, scope, fixturesRoot)
       ↓ CitationCard
  detectConflict(patientId, scope, proposedAssertion, fixturesRoot)
       ↓ ConflictResult { conflict, severity?, conflictKind?, citationCard, summary? }
  aiOverview(conflictResult)
       ↓ Overview { tldr, explanation, sources, framing, severity }
```

| Function | Input | Output | Purpose |
|---|---|---|---|
| `getCitationCard()` | scope identifiers | `CitationCard` | pure provenance retrieval |
| `detectConflict()` | identifiers + proposed assertion | `ConflictResult` (embeds the card) | rule-based conflict detection |
| `aiOverview()` | `ConflictResult` | `Overview` | Google-styled user-facing surface |

**Determinism contract:** `getCitationCard()` and `detectConflict()` MUST be deterministic for a fixed corpus state. `aiOverview()` SHOULD be deterministic (rule-based today; if a future implementation routes through an LLM, the `framing` field MUST switch from `"decision-support"` to `"llm-summary"` so the audit log can distinguish).

**Audit contract:** every call that produces an action (acknowledge / override) MUST write an `ebr_alert_*` entry to the audit log per §7.4 of the LNCS manuscript. The citation card's `sources[].sha256` SHOULD be referenced in that audit entry so the action is bound to a specific corpus state.

---

## Error contract

| Condition | Behavior |
|---|---|
| `patientId` directory does not exist | `{ found: false, error: "..." }` |
| `<scope>.md` does not exist | `{ found: false, error: "..." }` |
| `<scope>.md.amendments.jsonl` does not exist | `{ found: true, supersessionChain: [], sources: [<original>] }` |
| amendment line is malformed JSON | skip silently; rest of chain proceeds |
| filesystem I/O error (permission, disk) | throw — the substrate's invariants don't apply if we can't read |

Implementations MUST NOT throw on the first four cases. The fifth case is the only legitimate exception.

---

## Conformance suite

The five assertions in [`getCitationCard.test.mjs`](../../packages/memory-oracle-core/test/getCitationCard.test.mjs) are the cross-language conformance suite. A Go (or any) port is conformant iff:

1. `getCitationCard({ patientId: "jane-doe-1959", scope: "anticoagulation", ... })` returns `found: true`, exactly one entry in `supersessionChain`, `currentAssertion` matches `/apixaban/i`, `originalAssertion` matches `/warfarin/i`, `policy === "amendment-supersedes-original"`, `sources.length === 2`.

2. `detectConflict({ proposedAssertion: "administer FFP 2 units for active GI bleed", ... })` returns `{ conflict: true, severity: "critical", conflictKind: "wrong-reversal-agent" }`.

3. `detectConflict({ proposedAssertion: "administer andexanet alfa 800mg IV bolus", ... })` returns `{ conflict: false }`.

4. `aiOverview(...)` over a `detectConflict()` result returns `{ tldr: <matches /apixaban/i AND /2026-01-14/>, explanation: <matches /HIPAA/>, framing: "decision-support", severity: "critical", sources.length >= 2 }`.

5. `detectConflict({ scope: "allergies", proposedAssertion: "prescribe amoxicillin 500mg PO TID", ... })` returns `{ conflict: true, severity: "critical", conflictKind: "allergy-violation" }`.

A port that passes all five with bit-identical JSON envelopes is conformant.

---

## Implementation notes

### Node (canonical, complete)

File-system backed. Uses `node:fs`, `node:path`, `node:crypto`. No external dependencies. Runs on Node 20+ (uses `node:test`).

### Go (parity target, post-paper)

Lives at `packages/go-cli/cmd/memory-cite/citation_card.go` (planned). Uses `encoding/json`, `crypto/sha256`, `os`, `path/filepath`. No external dependencies — same minimalism discipline.

The Go port is gated on the LNCS paper landing because the API shape was being iterated alongside §7.4's figures; the spec is now frozen and Go work can proceed without risk of envelope churn.

### Storage backends (forward-looking)

The current Node implementation is file-system-only. A future SQLite-FTS5 backend (matching the substrate's `memory-search` storage) MAY back this API, provided the returned `CitationCard` is byte-identical for any corpus state reachable by both backends. Backend-specific source paths (e.g. `sqlite://path/to.db#patient/scope`) are explicitly permitted in `SourceRef.path`.

---

## Position-paper alignment

This specification is the operational realization of the `accretion.get_citation_card()` primitive named in the EBR position paper (`paper/coala-extension/`) §3.4 and contrasted against OAMP's `thread.get_context_card()` in the comparison table. The cross-substrate amendment portability open problem (§6 of the position paper) is the reason the `AmendmentEntry` schema explicitly preserves unknown fields under round-trip: a portable amendment must survive transit across substrates that may add or strip extensions.
