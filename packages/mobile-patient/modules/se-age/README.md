# se-age — Apple Secure Enclave-backed age recipients

> Local Expo native module. Generates `age1se1...` recipients backed by the
> iPhone's Secure Enclave, performs Face ID-gated ECDH. Wire-compatible
> with the macOS [`age-plugin-se`](https://github.com/remko/age-plugin-se)
> binary (so a clinician's Mac running `verum add-age-recipient --se` can
> consume keys produced by this iOS module).

## Phase 3b status

**3b-i: VALIDATED on real iPhone (iPhone 12, iOS 26.x, 2026-05-31).**
See [`validation/VALIDATION-3b-i.md`](./validation/VALIDATION-3b-i.md)
for the full record, screenshots, and the
[`3b-i-wire-compat-proof.age`](./validation/3b-i-wire-compat-proof.age)
artifact.

| Surface | Status |
|---|---|
| Swift impl (SeAgeModule, SeAgeService, AgeRecipient, Bech32) | ✓ |
| TS bridge | ✓ |
| Expo native module wiring (expo-module.config.json + podspec) | ✓ code-complete; 3b-ii will validate via prebuild |
| Bech32 cross-validation against age-plugin-se output | ✓ byte-identical roundtrip on macOS |
| Swift typecheck + parse on macOS | ✓ |
| Standalone SwiftUI harness on real iPhone | ✓ 3b-i |
| SE key generation on real iPhone | ✓ 3b-i (IMG_8463 + decoded 33B 0x02-prefixed P-256 pub) |
| Face ID prompt fires + ECDH returns shared secret | ✓ 3b-i (IMG_8464 + IMG_8465) |
| Cross-device wire compat: Mac age encrypts to iPhone recipient | ✓ 3b-i (276-byte `piv-p256` stanza in validation/) |
| `npx expo prebuild` + Expo native module link | ⏳ 3b-ii (after 3c protocol work) |
| Decrypt an age stanza on iPhone (Face ID-gated) | ✓ 3c-i Mac-validated; iPhone validation in 3c-v |

### 3c-i status (2026-05-31)

`AgeFile.swift` (age v1 parser) + `AgeCrypto.swift` (CryptoKit HKDF +
ChaChaPoly + HMAC helpers) + `SeAgeService.decryptAgeFile` shipped.
Mac round-trip validated end-to-end against the real `age` + `age-plugin-se`
binaries — reproducible via [`validation/test-3c-i-decrypt.sh`](./validation/test-3c-i-decrypt.sh).

One spec-correctness bug caught + fixed before iPhone deploy: header HMAC
byte range originally included the trailing space after `---`; age spec
excludes it. Test would have failed on iPhone with cryptic mismatch error.

Resequenced 3c plan: [`.claude/plans/verum-phase-3c-five-substep-resequence-20260531.md`](../../../../.claude/plans/verum-phase-3c-five-substep-resequence-20260531.md)

## Surface

```ts
import SeAge from 'se-age';

if (!SeAge.isAvailable()) {
  // Simulator or pre-iPhone-5s hardware. Disable SE features.
}

const recipient = await SeAge.getOrCreateIdentity('mo.patient.namespace.v1');
// → "age1se1q..."   (first call generates; subsequent calls return existing)

const sharedSecret = await SeAge.performKeyAgreement(
  'mo.patient.namespace.v1',
  clinicianRecipient,           // age1se1q...
  'Approve Dr. Chen for 15 min',
);
// → Uint8Array(32)    (Face ID fires; secret is HKDF input for stanza key wrap in 3c)
```

## Implementation notes

- Uses CryptoKit's `SecureEnclave.P256.KeyAgreement.PrivateKey`, not the
  lower-level `SecKey` API. CryptoKit handles compressed-point parsing
  via `P256.KeyAgreement.PublicKey(compressedRepresentation:)` — no
  manual point decompression needed.
- Private key is stored as a `dataRepresentation` token (~140 bytes,
  opaque) in the iOS keychain under
  `kSecAttrService=ai.memoryoracle.patient.se-age` + `kSecAttrAccount=<tag>`.
  The token is a reference; the actual private key bits live in the
  Secure Enclave and never leave.
- Access control: `[.privateKeyUsage, .userPresence]` with
  `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`. Matches the
  macOS verum `--se` default of `any-biometry-or-passcode`.
- Bech32 impl is BIP-173 (NOT bech32m). HRP `age1se` is what
  `age-plugin-se` uses.

## Validation plan (operator runs on iPhone)

```bash
cd packages/mobile-patient
npm install
npx expo prebuild --platform ios       # generates ios/ directory + Podfile
cd ios && pod install && cd ..
npx expo run:ios --device              # build + install on plugged-in iPhone
```

Then in the app: tap "Generate SE Identity" → should produce an
`age1se1...` recipient without firing Face ID. Tap "Test Face ID + ECDH"
→ Face ID prompt fires; on approval, app shows a 32-byte shared secret
hex string.

**Cross-validation against macOS verum:**

```bash
# 1. Copy the recipient from the iPhone display
# 2. On a Mac:
echo 'test plaintext' | age -r 'age1se1q...iphone_recipient...' > test.age
# 3. Send test.age to the iPhone (AirDrop or similar) — Phase 3c-only:
#    iPhone runs SeAge.performKeyAgreement with the ephemeral pub from the
#    age stanza, derives wrapping key, unwraps file key, decrypts.
```

(Full age stanza decrypt lives in 3c; 3b only proves the SE primitive +
the recipient encoding round-trip.)

## Footguns

- **Will not work in iOS Simulator.** `SecureEnclave.isAvailable` returns
  false there; key generation fails. Must use a real device.
- **Expo Go cannot load this module.** Custom native modules require a
  dev build via `npx expo run:ios` (or EAS Build). The patient app
  ceases to be Expo Go-compatible the moment this module is wired.
- **Bech32 ≠ bech32m.** age uses bech32 (BIP-173). If you swap in
  bech32m by accident (BIP-350), recipients will look identical-ish but
  fail checksum validation against age-plugin-se.
- **Don't store the SE key tag in JS land as anything but a constant
  string.** If you derive the tag from user input you'll have a key per
  random input, with no way to recover.
