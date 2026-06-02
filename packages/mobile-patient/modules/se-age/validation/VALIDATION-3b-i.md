# Phase 3b-i Validation Record

> **Date:** 2026-05-31
> **Device:** iPhone 12 (iPhone13,2) on iOS 26.x, paired to Sequoia 15.7.3 Mac via Apple CoreDevice
> **Validator:** Operator at console, observed via SSH-attached agent
> **Artifact:** [`3b-i-wire-compat-proof.age`](./3b-i-wire-compat-proof.age) (276 bytes)

## What was validated

The Swift source files in [`../ios/`](../ios/) — `SeAgeService.swift`,
`AgeRecipient.swift`, `Bech32.swift` — were dropped into a standalone
SwiftUI test harness (`~/Desktop/seAgeTest/` on the Sequoia Mac, cloned from
the operator's existing working `evoTest` Xcode skeleton). The harness
compiled cleanly, signed via `DEVELOPMENT_TEAM = 27TUX5PYAU`, deployed to
the iPhone over Apple CoreDevice, and executed end-to-end without errors.

This bypasses the Expo prebuild + CocoaPods + React Native bridge for
3b-i — the cryptographic code is library code with no Expo dependency, so
it can be validated through the operator's known-working Xcode pipeline.
3b-ii will wire the same files back into the Expo native module.

## Evidence

### iPhone screenshots (operator's local desktop, `~/Desktop/cap/`)

| File | What it shows |
|---|---|
| `IMG_8462.PNG` | Initial app launch; SE detected as available |
| `IMG_8463.PNG` | After "Generate" — recipient `age1se1qgq83eu3sw8s46dnqey8p99kmelwpt88th92jfnutj3pu570pdz9ucnmn0n` displayed |
| `IMG_8464.PNG` | iOS first-run Face ID permission prompt, with our custom reason string rendered |
| `IMG_8465.PNG` | After Face ID approval — green "ECDH succeeded ✓" + truncated 32-byte shared secret `78920b772a3d47fd26320fa1ea7901e60ac66e497b2a8d59…` |
| `IMG_8466.PNG` | Second ECDH attempt — identical shared secret returned (proves determinism of ECDH with same key, same peer) |

### Wire-compatibility proof (`3b-i-wire-compat-proof.age`)

The 276-byte file is a valid `age` stanza encrypted to the iPhone's
generated recipient, produced by the **macOS** `age` binary using
**`age-plugin-se` v0.1.4**:

```bash
RECIPIENT='age1se1qgq83eu3sw8s46dnqey8p99kmelwpt88th92jfnutj3pu570pdz9ucnmn0n'
echo -n 'verum-phase-3b-i — iphone⇄mac wire-compat proof — 2026-05-31' \
  | age -r "$RECIPIENT" > 3b-i-wire-compat-proof.age
```

Stanza format (first three lines):
```
age-encryption.org/v1
-> piv-p256 9VqHAA AwdEK036fHJ6eea5K7LqrabTWqsFeYTSY3MCm6c7WwcA
CK0A4tEBxopnHPFiyRgD5Fu+WRjsUReYjBhQ7V8mRD0
```

This confirms:

1. **`Bech32.swift`** produces age-plugin-se-compatible recipient encoding
   — the macOS `age` binary accepted the iPhone's recipient string without
   checksum errors.
2. **`AgeRecipient.swift`** correctly serializes a P-256 compressed point
   into the `age1se1...` bech32 envelope.
3. **`SeAgeService.swift`** produces a valid P-256 public key in the
   Secure Enclave, with the correct compressed-point encoding (prefix
   `0x02` for Y-even).
4. Wire compatibility is end-to-end: a clinician's Mac (or any
   `age`-equipped device with `age-plugin-se`) can encrypt to a patient's
   iPhone-generated recipient.

The artifact CANNOT be decrypted anywhere except on that specific iPhone
12's Secure Enclave with the operator's Face ID — which is exactly the
security property the LNCS §7.4 demo relies on.

### Bech32 cross-validation (pre-iPhone)

Before iPhone validation, `Bech32.swift` was cross-validated against a
recipient produced by the **macOS** `age-plugin-se` binary on Sequoia
(2026-05-31 Phase 2 test): `age1se1qwg6zhcp8strap5recwypq5r8kvrzy5jzdrg6383mfv32yzfme5pwxf2a4e`
decoded to a 33-byte 0x03-prefixed compressed P-256 pubkey and re-encoded
byte-identical. This proved `Bech32.swift` is BIP-173-correct before any
iPhone hardware was involved.

## Reproduction procedure

To re-validate on a fresh iPhone:

```bash
# On a Mac with Xcode 16+ (Sequoia recommended):
cp -R ~/.remote/github.com/@ramene/memory-oracle/packages/mobile-patient/modules/se-age/ios \
      ~/Desktop/seAgeHarness/ios

# Create a new SwiftUI Xcode project ("seAgeTest", iOS 14+ deployment target)
# Drop seAgeHarness/ios/{Bech32,AgeRecipient,SeAgeService}.swift into the project
# (Skip SeAgeModule.swift — that's the Expo bridge, not needed for standalone)
# Replace ContentView.swift with the harness from this commit's git history
#   (or rebuild it; ~200 lines of SwiftUI calling SeAgeService.{isAvailable,
#    getOrCreateIdentity, performKeyAgreement, deleteIdentity})
# Add INFOPLIST_KEY_NSFaceIDUsageDescription to the project build settings
# Set DEVELOPMENT_TEAM, pick physical iPhone, ⌘R

# On the iPhone:
# 1. Tap "Generate Secure Enclave identity" — no Face ID prompt
# 2. Copy the displayed age1se1... recipient
# 3. Tap "Test Face ID + ECDH (self-pair)" — Face ID fires; on approval,
#    32-byte shared secret renders

# Cross-validate on the Mac:
echo 'test' | age -r '<paste-recipient>' > test.age
# → produces ~250-byte file with `-> piv-p256 ...` stanza
```

## What this does NOT yet validate

- Decryption of an age stanza on the iPhone (3c — needs stanza parser +
  HKDF + ChaCha20-Poly1305 unwrap)
- The relay HTTP routes for the encounter handshake (3c)
- The Expo native-module integration of these Swift files (3b-ii — Expo
  prebuild + CocoaPods + JS-side wiring)
- The full dual-device demo with the clinician iPad scanning a patient QR
  (3d — produces the LNCS §7.4 paper figure)

Each remaining sub-phase composes on top of this 3b-i foundation. No
further novel cryptography is required — only protocol plumbing.
