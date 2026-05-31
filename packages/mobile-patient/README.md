# memory-oracle Patient (Phase 3a scaffold)

> Patient-side encounter-approval app for the dual-device clinical demo
> (LNCS §7.4). Pairs with [`packages/mobile-doctor/`](../mobile-doctor/) on
> the clinician's iPad and the long-lived `--se` identity issued via
> [`verum add-age-recipient --se`](https://github.com/ramene/verum) on the
> clinician's Mac.
>
> **Status:** 3b — Secure Enclave + Face ID wired via the local
> [`se-age`](./modules/se-age/) native module. Code-complete; on-device
> validation pending. Tracking plan:
> `.claude/plans/verum-phase-3-ios-faceid-dual-device-20260531.md`.

## What this app will do (3a + 3b + 3c)

1. Patient launches the app. On first launch, a Secure Enclave-bound age
   identity is generated for their memory namespace (3b).
2. Clinician's iPad scans the patient's QR (containing the age public
   recipient + a relay URL) → POSTs an `EncounterRequest` to the relay (3c).
3. The patient app long-polls the relay, sees the request, surfaces it on
   the "Pending requests" screen.
4. Patient taps the request → app shows clinician identity, requested scopes
   (e.g., `allergies`, `meds`), TTL (default 15 min).
5. Patient confirms → Face ID prompt fires (gated by `kSecAttrAccessControl`
   in the native SE module, NOT just `expo-local-authentication`) (3b).
6. On success, the native module performs ECDH against the clinician's
   public recipient and returns wrapped session keys per scope.
7. App POSTs an `EncounterApproval` back to the relay; clinician's iPad
   decrypts and renders the patient record for the TTL window.
8. Audit entry written to `SecureStore`-backed log (mirror in 3c to the
   memory-oracle audit endpoint for the HIPAA §164.526 trail).

## What 3a + 3b shipped

**3a (rename):**
- Directory renamed `packages/mobile/` → `packages/mobile-patient/`
- App identity: `memory-oracle Patient`; slug `memory-oracle-patient`;
  iOS bundle `ai.memoryoracle.patient`
- Camera permissions stripped (patient doesn't scan)
- `NSFaceIDUsageDescription` rewritten for consent-approval context

**3b (Secure Enclave wiring):**
- New local Expo native module: [`modules/se-age/`](./modules/se-age/)
  - Swift impl uses `SecureEnclave.P256.KeyAgreement.PrivateKey` (CryptoKit)
  - Access control: `[.privateKeyUsage, .userPresence]` — matches macOS
    verum `--se` default of `any-biometry-or-passcode`
  - Bech32 (BIP-173) impl cross-validated against actual `age-plugin-se`
    output: roundtrip-identical for the recipient produced on the
    Sequoia Mac (2026-05-31)
- `expo-camera` + `@expo/ngrok` removed from deps (dead since 3a)
- `App.js` now:
  - Detects Secure Enclave availability on boot
  - "Generate Secure Enclave identity" button → calls
    `SeAge.getOrCreateIdentity()` and displays the `age1se1...` recipient
  - "Test Face ID + ECDH (self-pair)" button → fires Face ID, performs
    ECDH with the patient's own recipient, displays truncated shared
    secret on success
  - Audit log records each operation
- `demo/` preserved as 3c reference material (clinician-side QR format)

## How to build + run (3b — Expo Go no longer supported)

The custom Swift module requires a dev build:

```bash
cd packages/mobile-patient
npm install
npx expo prebuild --platform ios     # generates ios/ + Podfile
cd ios && pod install && cd ..
npx expo run:ios --device            # build + install on plugged-in iPhone
```

On the iPhone you should see:

- "memory-oracle Patient" title + "Phase 3b · Secure Enclave wired"
- A yellow notice explaining the 3b smoke-test scope
- "Generate Secure Enclave identity" button — first tap creates a
  Secure Enclave key (no Face ID; keygen is non-interactive) and shows
  the `age1se1...` recipient
- "Test Face ID + ECDH (self-pair)" button — Face ID prompt fires; on
  approval, shows truncated 32-byte shared secret
- Audit log accumulates entries

**Will NOT work in iOS Simulator** — `SecureEnclave.isAvailable` returns
false. The app surfaces this with an error screen.

**Cross-validation against macOS verum:**

After generating the iPhone recipient, copy it to a Mac and verify that
`age` accepts it as a recipient:

```bash
echo 'test plaintext' | age -r 'age1se1q...iphone_recipient...' > test.age
ls -l test.age   # produced; age accepted the recipient format
```

Full decrypt-on-iPhone of a macOS-produced ciphertext lives in 3c
(needs the age stanza parser + HKDF-wrap unwind).

## What's POC vs production

This whole app is a research demo for the LNCS paper. Production deployment
would require:

- Real clinician identity proofing (institutional KMS + WebAuthn)
- Encrypted relay with end-to-end auth between patient phone and
  clinician device (no plaintext metadata at the relay)
- Patient onboarding flow with backup keys (Shamir M-of-N via Verum
  `split-key` for device-loss recovery)
- Audit shipping to an institutional system with 7-year tamper-evident
  retention, not just on-device SecureStore
- App Store / TestFlight distribution with proper privacy manifests

The paper claim is "operator-owned, biometric-gated keys with
amendment-aware retrieval at the point of care." This app proves the
biometric-gate path end-to-end on one operator's device. Productionization
is out of scope.

## Files

| File | Purpose |
|---|---|
| `App.js` | 3a scaffold — pending-requests stub + audit log + placeholder approval |
| `app.json` | Expo config — name, slug, bundle id, Face ID infoPlist string |
| `package.json` | Expo 54 + expo-secure-store + expo-status-bar (deps unchanged from pre-rename — 3b will adjust) |
| `index.js` | Expo root component registration |
| `demo/` | Clinician-side QR utilities preserved as 3c reference material |

## See also

- Phase 3 scope: `.claude/plans/verum-phase-3-ios-faceid-dual-device-20260531.md`
- Phase 2 (macOS `--se` flag): https://github.com/ramene/verum/pull/6
- Paper §7.4: `paper/lncs/main.tex` (figure target — produced in 3d)
