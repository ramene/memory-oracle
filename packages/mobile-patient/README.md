# memory-oracle Patient (Phase 3a scaffold)

> Patient-side encounter-approval app for the dual-device clinical demo
> (LNCS §7.4). Pairs with [`packages/mobile-doctor/`](../mobile-doctor/) on
> the clinician's iPad and the long-lived `--se` identity issued via
> [`verum add-age-recipient --se`](https://github.com/ramene/verum) on the
> clinician's Mac.
>
> **Status:** 3a — rename + scaffold only. Compiles and runs; no real Face
> ID gating yet, no relay wiring yet. Tracking plan:
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

## What 3a actually shipped

- Directory renamed from `packages/mobile/` → `packages/mobile-patient/`
- App display name: `memory-oracle Patient`; slug:
  `memory-oracle-patient`; iOS bundle id: `ai.memoryoracle.patient`
- iOS `NSCameraUsageDescription` removed (patient doesn't scan)
- iOS `NSFaceIDUsageDescription` rewritten for consent-approval context
- Android `CAMERA` permission removed
- `App.js` replaced with a scaffold that shows:
  - "Pending requests" screen (always empty in 3a — no relay yet)
  - Placeholder "Record approval" button (writes an audit entry; no real
    Face ID, no real key release)
  - Audit log viewer (last 10 entries)
- `demo/generate-patient-qr.html` and `demo/unlock-patient.sh` preserved
  in place as **reference material for 3c** (clinician-side QR format the
  patient app will need to interoperate with — not used by this app
  directly).

## How to run the scaffold

```bash
cd packages/mobile-patient
npm install
npx expo start --tunnel
```

Scan the QR code in the terminal with Expo Go on a real iPhone (Secure
Enclave operations in 3b will not work on the iOS Simulator). You should
see:

- "memory-oracle Patient" title + "Phase 3a scaffold" subtitle
- A yellow scaffold notice explaining what's missing
- An empty pending-requests box
- A placeholder approval button that just adds an audit entry

If that renders, 3a is good and we move to 3b (the native SE module).

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
