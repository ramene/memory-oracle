# Phase 3c — Encounter Handshake (5 sub-step resequencing)

**Status:** ACTIVE (proceeding after operator approval 2026-05-31 evening)
**Date:** 2026-05-31
**Supersedes:** `verum-phase-3-ios-faceid-dual-device-20260531.md` (parent — original 4-phase plan; specifically expands the original "Phase 3c — Encounter handshake")
**Task:** #60 (umbrella stays; sub-phase tracking in this doc)

## Why this revision

The parent plan treated "3c — Encounter handshake" as one milestone (~2-3 days,
~600-800 LOC). During implementation, operator caught two scope issues:

1. **Conflation** — what I called "3c" actually bundles five distinct concerns
   (decrypt crypto, encrypt crypto, relay protocol, patient UI, clinician UI)
   with different risk profiles and testing pathways.
2. **mobile-doctor gap** — the original plan only enumerated changes to
   `packages/mobile-patient/`. The clinician iPad side
   (`packages/mobile-doctor/`) was implicitly assumed but never actually
   scoped. It still has its pre-Phase-3 camera-scanning skeleton; the
   `se-age` native module has not been wired in.

Splitting into 5 sub-phases with explicit ordering lets each piece be
validated through a workflow that matches its risk surface (crypto via
Mac unit tests, protocol via curl, UIs via the iPhone/iPad pipeline).

## Where we are

**Completed:**
- 3a — `packages/mobile/` → `packages/mobile-patient/` rename + scaffold (commit `d771610`)
- 3b — local `se-age` native module created (commit `9de809f`)
- 3b-i — Secure Enclave + Face ID + age-plugin-se wire compat validated on
  iPhone 12 (commit `104ccef`; evidence at
  `packages/mobile-patient/modules/se-age/validation/VALIDATION-3b-i.md`)

**In progress on disk (uncommitted at time of plan write):**
- `AgeFile.swift` (~188 lines, age v1 parser)
- `AgeCrypto.swift` (~110 lines, pure CryptoKit HKDF + ChaChaPoly + HMAC)
- `SeAgeService.swift` (+60 lines, `decryptAgeFile` + `ownCompressedPub`)
- `SeAgeModule.swift` (+11 lines, Expo bridge)
- `src/index.ts` (+19 lines, TS surface)

This in-progress work is the first deliverable of the resequenced plan: 3c-i.

## The full dual-device flow (re-anchored)

```
┌──────────────────────────┐        ┌──────────────────────────┐
│  Clinician iPad          │        │  Patient iPhone          │
│  (mobile-doctor)         │        │  (mobile-patient)        │
│                          │        │                          │
│  ① camera scans   ◀──QR──│ patient displays QR with:        │
│     patient's QR         │        │  - own age1se1... recipient
│                          │        │  - relay URL              │
│                          │        │                          │
│  ② POST EncounterRequest─┼─relay─▶│ ③ long-poll relay        │
│     to relay             │        │   sees pending request   │
│     (clinician's recipient,       │                          │
│      scopes, TTL)        │        │ ④ shows consent UI       │
│                          │        │                          │
│                          │        │ ⑤ patient taps Approve   │
│                          │        │   → Face ID fires        │
│                          │        │   → patient's SE wraps   │
│                          │        │     session key TO       │
│                          │        │     clinician's recipient│
│  ⑦ poll relay for ◀──────┼─relay──│ ⑥ POST EncounterApproval │
│     approval             │        │   (age-encrypted blob)   │
│                          │        │                          │
│  ⑧ Face ID on iPad       │        │                          │
│     → iPad SE unwraps    │        │                          │
│     session key          │        │                          │
│                          │        │                          │
│  ⑨ render record briefly │        │                          │
│  ⏱ evaporates 15 min     │        │                          │
└──────────────────────────┘        └──────────────────────────┘
```

QR and Face ID are **complementary, not competing**:
- **QR** transports identity (no network needed for the introduction)
- **Face ID** gates consent (the key-release decision happens locally
  inside the patient's SE)

## The five sub-phases

### 3c-i — age v1 DECRYPT (both sides will use it)

**Status:** code on disk, uncommitted, unvalidated

**Code:** `AgeFile.swift` (parser) + `AgeCrypto.swift` (HKDF/ChaChaPoly/HMAC
helpers) + `SeAgeService.decryptAgeFile` + bridge to JS via
`SeAge.decryptAgeFile`.

**Used by:**
- Step ⑧ on clinician iPad: decrypt the wrapped session key from the relay
- Patient-side optional: decrypt patient's own at-rest records

**Validation pathway (BEFORE committing — burned once already, twice in this
flow has been costly):**
1. Mac-side test on Sequoia: generate a regular (non-SE) CryptoKit
   P256.KeyAgreement keypair → encode pub as `age1se1...` → invoke
   `age -r '<recipient>' <plaintext>` to produce a real age file →
   parse with `AgeFile.parse` → manually compute shared secret with the
   non-SE private key → call `AgeCrypto.{pivP256WrapKey, unwrapFileKey,
   verifyHeaderHmac, payloadKey, decryptSingleChunkPayload}` →
   plaintext must match input
2. Once green on Mac → commit 3c-i
3. iPhone validation deferred to 3c-v (when clinician app needs decrypt)

**Why Mac-test first:** the age v1 spec has fiddly bits (header HMAC byte
ranges, nonce layouts, HKDF info strings, base64 padding). I implemented
to spec from memory; commit-then-iterate-on-iPhone wastes Xcode signing
cycles. Mac shell can red-line bugs in seconds.

**Acceptance:** `AgeCrypto` round-trips for a Mac-encrypted single-chunk
payload up to 64KB. Multi-chunk explicitly out of scope (patient records
are <1KB; throw clear error on >64KB).

---

### 3c-ii — age v1 ENCRYPT (patient-side, for step ⑤)

**Status:** not started

**Code:** New `AgeEncryptor.swift` + extend `SeAgeService` with
`encryptToRecipient(plaintext, recipient, useEphemeralEcdh) -> Data`.
Patient calls this in step ⑤ to wrap the session key TO the clinician's
recipient.

**Crypto mirror of 3c-i:**
- Generate ephemeral P-256 keypair (regular CryptoKit, NOT SE — ephemeral
  by definition; the SE is only for the patient's LONG-LIVED key, not
  per-encryption ephemerals)
- ECDH(ephemeral_priv, clinician_pub) → shared
- HKDF same recipe → wrap_key
- ChaCha20-Poly1305 wrap a fresh random 16-byte file_key
- HKDF-SHA256(file_key, "", "header", 32) → mac_key
- HMAC-SHA256 over the constructed header → MAC
- Generate 16-byte random nonce_salt
- HKDF-SHA256(file_key, nonce_salt, "payload", 32) → payload_key
- ChaCha20-Poly1305 single-chunk encrypt the session key

**Validation pathway:**
1. Mac-side test: encrypt a known payload with our code → write to file
   → `age -d -i <mac-side-identity-file> <our-output>` should decrypt
   cleanly via the official age CLI
2. Round-trip test: encrypt with 3c-ii, decrypt with 3c-i, check match
3. Commit when both green

**Acceptance:** files produced by `AgeEncryptor` are decryptable by the
official `age` binary (proves we're producing spec-compliant output, not
just our-own-format files).

---

### 3c-iii — relay routes + encounter schema (server + shared types)

**Status:** not started

**Code:**
- `apps/web/lib/encounter/types.ts` — TS types for `EncounterRequest` /
  `EncounterApproval` (JSON-LD, signature fields)
- `apps/web/app/api/encounter/route.ts` — POST creates a request, returns
  encounter_id
- `apps/web/app/api/encounter/[id]/route.ts` — GET long-poll for pending,
  POST submits approval, GET retrieves approval
- In-memory store (Map<encounter_id, state>) with 15-min TTL cleanup
- No persistence — fresh relay state on every deploy; that's fine for
  a demo

**Wire format** (JSON-LD for paper figure-friendliness):
```jsonc
// EncounterRequest (clinician → relay → patient)
{
  "@type": "EncounterRequest",
  "encounterId": "<uuid-v7>",
  "clinicianRecipient": "age1se1...",
  "clinicianName": "Dr. Y. Chen",
  "requestedScopes": ["allergies", "meds"],
  "ttlSeconds": 900,
  "issuedAt": "2026-05-31T14:23:00Z"
}

// EncounterApproval (patient → relay → clinician)
{
  "@type": "EncounterApproval",
  "encounterId": "<same uuid>",
  "wrappedKeys": {
    "allergies": "<base64 of age-encrypted blob>",
    "meds": "<base64 of age-encrypted blob>"
  },
  "expiresAt": "2026-05-31T14:38:00Z",
  "auditEntryId": "<memory-oracle audit ref>"
}
```

**Deploy:** the existing `apps/web/` GAE deployment already exists — these
routes ride along on the next push. No new Cloud Run service. **Decision
deferred from original plan: confirmed Next.js route over new Cloud Run.**

**Validation pathway:**
1. `curl -X POST … /api/encounter` → 200 + encounter_id
2. `curl /api/encounter/<id>` long-poll returns pending request immediately
3. `curl -X POST /api/encounter/<id>/approve` posts approval; subsequent
   GET retrieves it
4. Local Next.js dev server; deploy to staging after local-green

**Acceptance:** the request → poll → approve → retrieve cycle completes via
curl, no UI needed.

---

### 3c-iv — patient app: QR display + relay long-poll + consent UI + encrypt wiring

**Status:** not started

**Code in `packages/mobile-patient/`:**
- Add `react-native-qrcode-svg` dep (or vector equivalent)
- New screen: "My patient identity" — renders QR containing JSON
  `{"v":1,"recipient":"age1se1…","relay":"https://api.../encounter"}`
- Background poller (when app foregrounded): GET pending requests every 5s
- Consent screen surfaces: clinician name, requested scopes, TTL → big
  green Approve / red Deny
- Approve handler: for each requested scope, generate a session key (16B
  random) → call `SeAge.encryptToRecipient(sessionKey, clinicianRecipient)`
  (from 3c-ii) → POST wrappedKeys to relay
- Audit log entry per approval

**Validation:** rebuild the seAgeTest harness flow but with the full app —
this is where Expo prebuild + CocoaPods + iPhone deploy ceremony finally
becomes worth paying. Build via `npx expo run:ios --device` on Sequoia.

**Acceptance:** patient phone shows QR, polling visible in app UI, sample
consent screen renders. Full E2E waits on 3c-v.

---

### 3c-v — clinician (mobile-doctor) app: end-to-end demo

**Status:** not started

**Code in `packages/mobile-doctor/` (currently untouched in Phase 3):**
- Wire the `modules/se-age/` native module into mobile-doctor too (option:
  symlink from mobile-patient, or duplicate — symlink is cleaner but
  Expo's autolinking may not follow symlinks; duplicate is safer)
- Generate clinician's own SE identity on first launch (same flow as
  patient — `SeAge.getOrCreateIdentity('mo.clinician.namespace.v1')`)
- Wire existing camera UI: on QR scan, parse the JSON, extract patient
  recipient + relay URL
- Encounter-start screen: scope picker (allergies, meds, …), TTL slider,
  "Send request" button → POST EncounterRequest
- Polling screen with countdown
- On approval received: for each wrappedKey, call `SeAge.decryptAgeFile`
  (3c-i) → fires Face ID → renders the session key → use it to fetch +
  decrypt the actual records from memory-oracle backend (mock for demo:
  display the decrypted session key + a static "patient record" stub)
- 15-min countdown timer; on expiry, shred decrypted bytes from memory

**Validation:** the actual photographable demo. Plug iPhone (patient) +
iPad (clinician — fall back to second iPhone if no iPad) into Sequoia,
build both apps, capture the 30-second screen recording.

**Acceptance:** the LNCS §7.4 figure. Patient phone scanned by clinician
iPad, Face ID on patient phone, decrypted record briefly visible on iPad.

## Ordering rationale

```
3c-i (decrypt crypto)  ─┐
                         ├─▶ 3c-iii (relay + schema)  ─┐
3c-ii (encrypt crypto) ─┘                               ├─▶ 3c-iv (patient UI)  ─┐
                                                        │                        ├─▶ 3c-v (clinician UI + E2E)
                                                        │                        │
                                                        └─▶ 3c-v scaffold       ─┘
```

Crypto can be Mac-validated. Protocol can be curl-validated. Both UIs are
the only steps that need iPhone/iPad cycles. This sequencing burns Xcode
ceremony only at the end, when the win is the photographable demo.

## Hardware checklist (operator)

- ✅ iPhone 12 (patient) — already paired with Sequoia, Face ID-capable
- ❓ iPad with Touch ID or Face ID (clinician role) — need to confirm
  availability. If absent: a second iPhone works for the demo; the
  paper figure reads slightly better with device asymmetry but is not
  load-bearing.
- ✅ Sequoia Mac with Xcode 26, CocoaPods, signing team 27TUX5PYAU — all
  verified during 3b-i

## Estimated time

| Sub-phase | Est | Risk profile |
|---|---|---|
| 3c-i | 2-3 hours (most of code already written; Mac test + iterate + commit) | LOW once Mac-tested |
| 3c-ii | 4-6 hours | LOW (mirrors 3c-i, age CLI validates) |
| 3c-iii | 3-4 hours | LOW (simple HTTP) |
| 3c-iv | 6-8 hours (first time paying Expo prebuild + signing cost in this flow) | MEDIUM (signing surprises) |
| 3c-v | 8-12 hours (largest unknown — mobile-doctor was untouched; full E2E debugging) | HIGH |

**Total: ~25-35 hours across the five sub-phases.** Likely 3-4 calendar
sessions of focused work.

## What this revision does NOT change

- The parent plan's 3d (capture + paper figure) — still applies after 3c-v
- The original architecture decisions (Native Swift module, not embedded
  age binary; Next.js relay route, not new Cloud Run; bech32-encoded
  age1se1... recipients; CryptoKit SecureEnclave APIs)
- The hardware setup (Sequoia + iPhone 12 + signing team 27TUX5PYAU)
- The success metric (LNCS §7.4 figure, dual-device clinical demo)

## Open questions (carried from parent, surfaced anew)

1. Where do the patient's at-rest encrypted records actually live for the
   demo? Mock on iPad for the figure, or stand up a real memory-oracle
   backend? **Default: mock for the figure; backend integration is post-
   paper.**
2. Does the relay verify the clinician's signature on the EncounterRequest
   for the demo? **Default: no signature verification in the relay for
   the demo; clinician trust is established by the patient's consent
   gate, not the relay. Add signing for production hardening post-paper.**
3. Should the clinician's iPad also use Secure Enclave for its identity,
   or a softer storage (Keychain unprotected)? **Default: yes, same SE
   path — symmetry matters for the paper's "operator-owned keys" claim,
   and the iPad's iOS SE behaves identically to the iPhone's.**

## Acceptance for "Phase 3c done"

- [ ] 3c-i committed + Mac-validated against `age` CLI roundtrip
- [ ] 3c-ii committed + roundtrip with 3c-i + decryptable by `age` CLI
- [ ] 3c-iii committed + curl-validated request/poll/approve cycle
- [ ] 3c-iv committed + patient app shows QR + polls relay + renders consent UI
- [ ] 3c-v committed + full E2E demo runs on physical hardware
- [ ] Screen recording captured for 3d figure embedding

After 3c-v, only 3d (paper figure embedding + caption + §1 reference)
remains for Phase 3 to close.
