# memory-oracle clinician (mobile)

> POC mobile app for the QR + patient-contact decryption flow documented in [`docs/PRIVACY.md`](../../docs/PRIVACY.md).
>
> Clinician scans a patient wristband QR → app derives session key → terminal uses session key to decrypt that patient's memory namespace → memory-oracle surfaces the supersession-merged truth.

## What's in the box

| File | Purpose |
|---|---|
| `App.js` | Expo React Native app — QR scanner, PIN enrollment, session-key derivation, audit log |
| `package.json` | Expo 52 + expo-camera + expo-crypto + expo-secure-store |
| `app.json` | Expo config — iOS NSCameraUsageDescription, Android CAMERA permission |
| `demo/generate-patient-qr.html` | Patient wristband QR generator (open in any browser — synthetic test patients only) |
| `demo/unlock-patient.sh` | Terminal-side counterpart — takes the derived session key, decrypts the patient namespace, runs an ER query, reports correct-vs-stale outcome |

## End-to-end demo (5 minutes, phone in hand)

### Prerequisites

- Phone with [Expo Go](https://expo.dev/client) installed (free, iOS App Store / Google Play)
- macOS or Linux machine on the same Wi-Fi as the phone
- Node 18+ + npm
- This repo cloned

### Step 1 — start the mobile app on a dev server

```bash
cd packages/mobile
npm install
npx expo start --tunnel
```

`--tunnel` works even if your phone is on cellular. A QR code appears in the terminal. **Scan it with Expo Go.** The app loads on your phone.

### Step 2 — enroll a clinician PIN (one-time)

On first launch, the app prompts for a 6+ digit PIN. This stands in for institutional clinician identity (in production: KMS + YubiKey + biometric per `docs/PRIVACY.md` Layer 3).

The PIN-derived secret is stored in iOS Keychain / Android Keystore via `expo-secure-store`.

### Step 3 — generate a patient wristband QR

In your laptop's browser, open:

```
file:///path/to/memory-oracle/packages/mobile/demo/generate-patient-qr.html
```

Or any static-file server. The page renders a QR for synthetic patient `jane-doe-1959` (the warfarin → apixaban patient from the clinical proof). Click "Generate" to randomize the salt.

### Step 4 — scan the QR

In the clinician app, tap to the camera screen and aim at the QR on your laptop monitor. The app:

1. Parses the QR JSON (`{v: 1, patient_id, salt}`)
2. Computes `session_key = SHA256(clinician_secret + patient_id + salt)`
3. Displays the 64-char hex session key + writes an audit entry

### Step 5 — unlock the patient on the terminal

Copy the session key from the phone display. On your laptop:

```bash
cd memory-oracle
./packages/mobile/demo/unlock-patient.sh jane-doe-1959 <session_key_hex>
```

The script:
1. Copies the patient's memory namespace into a tmpfs encounter directory (in production: AES decrypt with the session key)
2. Builds an isolated memory-oracle FTS5 index over that namespace
3. Simulates an ER LLM query: *"what anticoagulant is this patient on, and how do I reverse it given acute hemorrhage?"*
4. Reports whether retrieval surfaced `andexanet alfa` (correct, supersession-aware) or `Fresh Frozen Plasma` (stale, what vector RAG would do)
5. Auto-shreds the encounter directory after 30-min TTL or Ctrl-C

Expected output:

```
✓ CORRECT — retrieval surfaced 'andexanet alfa' (the apixaban reversal agent)
✓ Patient receives the right reversal. Bleeding controlled.
```

## What's POC vs production

| Component | POC (this) | Production |
|---|---|---|
| Clinician identity | 6-digit PIN | KMS + YubiKey + biometric |
| Per-patient salt source | Random in QR generator | Institutional patient-record system, salt rotated quarterly |
| Session key derivation | SHA256 of (secret \|\| patient_id \|\| salt) | HKDF-SHA256 with proper info-context separation |
| Patient namespace storage | Plaintext markdown in `docs/examples/` | Encrypted via git-crypt-revived (age + SSS for break-glass) |
| Session-key transfer phone → terminal | Manual copy-paste of hex string | Bluetooth LE with proximity gating, or QR-back |
| Audit log | `SecureStore` on the phone (last 100 entries) | Institutional audit system, 7-year retention, tamper-evident |
| TTL | Fixed 30 min | Configurable per encounter type (ER vs scheduled visit vs telemedicine) |
| Break-glass override | Not implemented | Dual-signoff senior physician, immediate audit alert |

## Audit log inspection

In the app, the "ready" screen shows the total audit entry count. The "unlocked" screen shows the last 5 entries with timestamp + event + patient_id.

Production: ship audit entries to the institutional system continuously over the encounter's network connection, retain locally only as a write-ahead buffer.

## Known POC limitations

- **No biometric gate before scan** — production should require Face ID / Touch ID before deriving the session key
- **PIN never rotates** — production needs PIN rotation policy + lockout-after-N-failed-attempts
- **No physical-proximity verification** — Bluetooth LE proximity gating, prevents the device from being used remotely. Required for HIPAA.
- **No KMS roundtrip** — production needs institutional KMS to verify clinician is on-shift, on-floor, and patient is on the clinician's roster *before* releasing the session key

These are tracked in the GH project board under `QR + mobile decryption flow — design doc + reference impl`.

## Status

- Source: complete (this POC)
- iOS Simulator: untested (need Xcode)
- Real iPhone via Expo Go: PRIMARY target — should work on first try
- Android: should work but not validated

If `npx expo start --tunnel` complains about Expo CLI not installed, run `npm install -g expo-cli` first.
