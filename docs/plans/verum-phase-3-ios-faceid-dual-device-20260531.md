# Verum Phase 3 — iOS Face ID + Dual-Device Clinical Demo

**Status:** SCOPE (not yet started)
**Date:** 2026-05-31
**Task:** #60 (Verum FIDO2 Phase 3)
**Paper-anchor:** LNCS §7.4 figure (clinician iPad + patient iPhone)
**Predecessor:** Phase 2 SE plugin shipped in verum PR #6 (2026-05-31)

---

## Goal

Ship a working dual-device flow that produces the photographable demonstration
called out in LNCS §7.4. The screenshot is the deliverable; the working flow is
the prerequisite.

```
┌──────────────────────────┐        ┌──────────────────────────┐
│  Clinician iPad          │        │  Patient iPhone          │
│  (memory-oracle Dr.)     │        │  (memory-oracle Patient) │
│                          │        │                          │
│  [Camera] ─── scan ───▶  │QR code │  encrypted memory        │
│                          │◀───────│  namespace pointer       │
│  ┌──────────────────┐    │        │                          │
│  │ Encounter intent │────┼─push──▶│ ┌──────────────────────┐ │
│  │ "Dr. X, 15 min,  │    │        │ │ Approve Dr. X        │ │
│  │  Allergies+Meds" │    │        │ │ for Allergies+Meds   │ │
│  └──────────────────┘    │        │ │ for 15 min?          │ │
│                          │        │ │  [Face ID ✓]         │ │
│  ┌──────────────────┐    │        │ └──────────────────────┘ │
│  │ Allergies        │◀───┼──key───│         │                │
│  │ • penicillin     │    │ wrap   │         ▼                │
│  │ • shellfish      │    │        │ wrapped session key      │
│  │ Meds             │    │        │ (recipient = Dr. X's     │
│  │ • metformin 500  │    │        │  age-plugin-se pub)      │
│  └──────────────────┘    │        │                          │
│  ⏱ evaporates 15 min     │        │ audit: 2026-05-31T14:23  │
└──────────────────────────┘        └──────────────────────────┘
```

## Non-goals

- Production HIPAA certification (this is a research demo for the paper).
- App Store submission (TestFlight at most).
- Replacing the existing PIN stand-in across the whole app surface — only
  the encounter flow needs the patient-side Face ID gate.
- Multi-patient bulk workflows (single-encounter demo only).
- Android parity (paper screenshot is iOS-specific; Android can land later).

---

## What already exists

| Path | What it is | Status |
|------|------------|--------|
| `packages/mobile-doctor/` | Clinician iPad app skeleton (camera + QR) | named `memory-oracle Dr.`, slug `memory-oracle-doctor` |
| `packages/mobile/` | Originally specced as clinician phone, has Face ID infoPlist | named `memory-oracle clinician`, slug `memory-oracle-clinician` ⚠ collides |
| Verum Phase 2 `--se` | Apple Secure Enclave-bound age identities on macOS 13+ | shipped PR #6 (2026-05-31) |
| `paper/lncs/main.tex` §7.4 | Dual-device demo description | references the figure that this phase produces |

## What's missing

1. **No patient-side app exists.** Both Expo apps are clinician-facing.
2. **No encounter-handshake protocol** between devices.
3. **No iOS-side `age-plugin-se` equivalent** — the plugin is a macOS CLI; iOS needs a native Swift module that does the same Secure Enclave operations.

---

## Phase 3a — Repurpose `mobile/` as the patient app (~2 days)

The cheapest fix: rename `packages/mobile/` → `packages/mobile-patient/`,
update slug/displayName, rewrite the camera permission strings, and replace the
camera-scanning UI with a single "Pending Requests" screen.

**Footgun:** the `mobile/` app already has `NSFaceIDUsageDescription` set up
for clinician self-auth. Repurpose the same plist key for patient consent —
the underlying API is the same `expo-local-authentication.authenticateAsync()`,
only the prompt copy changes. Don't duplicate.

**Files to change:**
- `packages/mobile/app.json` — rename, fix collision, rewrite usage strings
- `packages/mobile/package.json` — bump name
- `packages/mobile/App.tsx` (or `app/_layout.tsx`) — strip clinician scaffolding
- `pnpm-workspace.yaml` — update path if directory renames
- README — re-describe as patient app

**Decision needed before writing code:** rename to `mobile-patient/` (matches
`mobile-doctor/` symmetry) OR rename to `mobile-encounter/` (more accurate —
the patient app is really just an encounter-approval surface, not a general
patient-facing PHR). Default: `mobile-patient/`.

---

## Phase 3b — iOS Secure Enclave Swift module (~3-4 days)

This is the Phase 3 equivalent of what `age-plugin-se` does on macOS, but
inside the iOS app process (no CLI; no plugin chain). Implementation
options:

1. **Use `LAContext` + `SecKey` directly via a native Expo module** (~3 days)
   - Swift module wraps `kSecAttrTokenIDSecureEnclave` key generation
   - `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`
     gates the decrypt operation
   - Bridge to JS via `requireNativeModule()` (Expo SDK 50+ pattern)
   - **Pro:** No third-party deps; full control over UX
   - **Con:** We have to re-derive the age recipient format ourselves
     (`age1se1...` is bech32-encoded compressed P-256 pubkey — non-trivial
     but ~200 lines of Swift + a known reference impl in age-plugin-se's Go
     source we can port)

2. **Embed `age` + `age-plugin-se` as iOS frameworks** (~5-7 days)
   - Cross-compile the Go `age` binary + Swift `age-plugin-se` for iOS arm64
   - Spawn-via-NSTask is forbidden on iOS — must link as a library
   - **Pro:** Wire-compatible with macOS-side verum (clinician's Mac could
     produce age recipients that the iPhone consumes verbatim)
   - **Con:** Significantly more work; iOS framework packaging for Go
     binaries is painful

**Recommendation:** Option 1. Cross-compatibility doesn't matter for the
demo — the patient phone produces wrapped keys for the clinician's `age-se`
identity; the clinician decrypts on their Mac (or iPad with the same native
module). Both endpoints use the same Swift module, so wire format alignment
is trivial.

**Files to create:**
- `packages/mobile-patient/modules/se-age/` (Expo native module)
  - `ios/SeAge.swift` — Secure Enclave key gen + ECDH + Face ID gate
  - `ios/SeAge.podspec`
  - `src/SeAge.ts` — TS-side bridge
  - `expo-module.config.json`

---

## Phase 3c — Encounter handshake (~2-3 days)

Patient phone holds the long-lived "memory namespace" age identity in its
Secure Enclave. Clinician scans patient QR (which contains the public
recipient + a relay URL). Encounter request travels patient→phone via a
relay (NOT P2P — too fragile for a demo; use a tiny HTTP echo on a known
host).

**Wire format (JSON-LD because it shows up nicely in the paper figure):**
```json
{
  "@type": "EncounterRequest",
  "clinicianId": "age1se1q...",          // Dr. X's SE pubkey
  "clinicianName": "Dr. Y. Chen",         // human-readable
  "requestedScopes": ["allergies","meds"],
  "ttlSeconds": 900,
  "issuedAt": "2026-05-31T14:23:00Z",
  "signature": "0x..."                    // signed by clinicianId privkey
}
```

Patient response (after Face ID approval):
```json
{
  "@type": "EncounterApproval",
  "encounterId": "uuid-v7-here",
  "wrappedKeys": {
    "allergies": "AGE_BINARY_BLOB_BASE64",  // encrypted to clinicianId
    "meds": "AGE_BINARY_BLOB_BASE64"
  },
  "expiresAt": "2026-05-31T14:38:00Z",
  "auditEntryId": "...",                     // for HIPAA §164.526 trail
  "patientSignature": "0x..."
}
```

**Relay:** trivial Cloud Run service (`memory-oracle-relay`) — single
endpoint, in-memory queue, TLS, no persistence. ~30 lines of Go. Deploy via
`gcloud run deploy`. Strip after the demo.

**Files to create:**
- `apps/relay/` (new Go service) OR `apps/web/app/api/encounter/[id]/route.ts`
  (Next.js route — cheaper, reuses existing deploy)
- `packages/encounter-schema/` (TS types shared between both apps)
- `packages/mobile-doctor/lib/encounter-client.ts`
- `packages/mobile-patient/lib/encounter-server.ts`

**Recommendation:** stuff the relay in the existing Next.js `apps/web/`
deployment as `/api/encounter/*` routes. Saves a deploy unit.

---

## Phase 3d — Photographable demo + paper figure (~1 day)

After 3a-3c are wired, the demo is:

```
$ pnpm --filter @memory-oracle/mobile-doctor ios -d "Ramene's iPad"
$ pnpm --filter @memory-oracle/mobile-patient ios -d "Ramene's iPhone"

# On iPad: tap "Start Encounter" → camera opens → scan QR on iPhone screen
# On iPhone: notification fires → tap → Face ID prompt → approve
# On iPad: record renders → 15-min countdown visible → record disappears at 0
```

**Capture:**
- Screen recording of full flow (15 sec clip)
- Still: iPad mid-render, iPhone showing the Face ID approval screen, both
  in one photo (use a 3rd phone/camera or screen-mirror both to a Mac and
  composite)

**Paper figure target:** insert into `paper/lncs/main.tex` §7.4 as
`fig:dual-device-encounter`. Caption ~80 words. Reference from §1
contribution list.

---

## Sequencing + dependencies

```
Phase 3a (rename + scaffold)
  └─▶ Phase 3b (Secure Enclave native module)
       └─▶ Phase 3c (encounter handshake)
            └─▶ Phase 3d (capture + paper figure)
```

Total: **~8-10 working days** spread over 2-3 calendar weeks
(accounting for Xcode signing pain + TestFlight provisioning).

**Hardware needed:**
- ✅ Mac (have — both Monterey + Sequoia)
- ✅ iPhone with Face ID (operator has)
- ⚠ iPad (need confirmation; can fall back to a second iPhone for the demo
  shot, but the paper figure reads better with the device asymmetry)
- ✅ Apple Developer account (operator has)

---

## Risks + footguns

1. **Apple Developer signing rabbit-hole.** Provisioning profiles for two
   apps × two devices. Budget 4-6 hours of pure Xcode pain.

2. **`expo-local-authentication` is not enough alone.** It gates a UI
   prompt but doesn't bind the auth to a key operation in the Secure
   Enclave. We need the native `kSecAttrAccessControl` flow with
   `LAContext` passed into `SecKeyCreateSignature()`. This is exactly
   what the Phase 3b native module solves — don't try to shortcut with
   just the Expo wrapper.

3. **Bech32 + age recipient format.** Get this wrong and the patient
   phone produces wrapped keys the clinician can't decrypt. Reference
   impl: `age-plugin-se/main.go` (Go) — port to Swift carefully and add
   roundtrip tests (Swift-encoded recipient must match age-plugin-se
   CLI's recipient for the same key).

4. **Relay timing.** If we put the relay on Cloud Run with min-instances=0,
   first request after a cold start takes 4-8 seconds. Bad for demo recording.
   Set `min-instances=1` for the demo window OR use the Next.js route on
   the always-on GAE deployment.

5. **Audit trail.** Per §164.526 the encounter approval must produce a
   tamper-evident audit entry. The paper uses this. Make sure the
   `EncounterApproval.auditEntryId` actually points to a real record in
   memory-oracle's existing audit log, not a placeholder. Wire to
   existing `accretion.amend()` endpoint.

6. **The `mobile/` app name collision.** Two apps both call themselves
   the clinician right now. Whoever does Phase 3a needs to rename + verify
   no other repo references the old slug (search: `memory-oracle-clinician`
   in app.json, Xcode workspaces, EAS config, README).

7. **PIN stand-in code in `mobile/README.md`.** That code path stays for
   non-encounter screens; only the encounter approval screen gets the
   Face ID flow. Don't try to rip out the PIN globally — out of scope.

---

## Open questions (resolve before starting 3a)

1. **Patient app name:** `mobile-patient/` vs `mobile-encounter/`?
   (default: `mobile-patient/`)
2. **Relay host:** Next.js route on existing GAE deploy, or new Cloud Run?
   (default: Next.js route — saves a deploy unit)
3. **Encounter TTL configurable, or fixed 15 min for the demo?**
   (default: fixed 15 min — keeps the figure caption simple)
4. **Audit trail destination:** memory-oracle's existing audit log, or a
   fresh `encounter_audit` table?
   (default: memory-oracle's existing log — proves the HIPAA §164.526
    integration claim)
5. **Should the clinician app also use Secure Enclave on the iPad?**
   (default: yes — symmetry, and it validates the Phase 3b module on a
    second device, plus the wrapped key is targeted at the iPad's SE pubkey
    so the iPad must hold the private key to decrypt)

---

## Acceptance criteria for "Phase 3 done"

- [ ] `pnpm --filter @memory-oracle/mobile-doctor ios` runs on real iPad
- [ ] `pnpm --filter @memory-oracle/mobile-patient ios` runs on real iPhone
- [ ] Round-trip encounter completes in <30 seconds wall-clock (excluding
      Face ID human delay)
- [ ] Patient phone's Secure Enclave private key is never exfiltrated
      (validated via `kSecAttrTokenIDSecureEnclave` attribute inspection)
- [ ] Wrapped session key on the wire is opaque to the relay (relay only
      sees ciphertext)
- [ ] Photographable demo captured (screen recording + still photo)
- [ ] Figure embedded in `paper/lncs/main.tex` §7.4 with caption
- [ ] Paper §1 contribution list updated to cite the figure
- [ ] PR opened against `memory-oracle/develop` with all four sub-phases

---

## What this does NOT change

- `verum` repo — Phase 3 lives in `memory-oracle/`, NOT in verum. The
  verum SE flag from Phase 2 is for the clinician's Mac (long-term key
  storage); Phase 3 builds the iOS-side equivalent in a separate
  codebase.
- The Phase 2 PR — no rework needed.
- The position paper — Phase 3 only touches LNCS §7.4. Position paper
  remains as-shipped in PR #15.

---

*Supersedes:* nothing. Original Phase 3 description in
`verum/doc/fido2-biometric-unlock.md` is now stale (the helper-LaunchAgent
design was dropped during Phase 2); that doc should be amended in a
separate cleanup PR — out of scope here.
