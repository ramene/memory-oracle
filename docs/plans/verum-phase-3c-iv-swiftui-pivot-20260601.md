# Phase 3c-iv — SwiftUI Pivot (Expo → pure Native)

**Status:** ACTIVE
**Date:** 2026-06-01
**Supersedes (selectively):** `verum-phase-3c-five-substep-resequence-20260531.md`
**Selectively supersedes:** the **3c-iv** sub-phase only. 3a, 3b, 3b-i, 3c-i, 3c-ii, 3c-iii from
the parent plan are unchanged + remain shipped. 3c-v + 3d still ahead but
re-framed under SwiftUI (see below).
**Task:** #60 (umbrella stays in_progress)

## Why this revision (mid-phase pivot)

The parent 3c plan assumed the patient app continues as an Expo / React
Native codebase (3a renamed `packages/mobile/` → `packages/mobile-patient/`;
3c-iv was scoped as adding QR + poller + consent UI on top of that Expo
stack). After the 3c-iv-A code shipped + the Sequoia prebuild attempted,
two compounding problems surfaced:

1. **Expo SDK 54 + `react-native-svg` 15.11.2 + RN 0.81 Fabric incompatibility.**
   The Expo-canonical pin for the SVG library has a Fabric (New Architecture)
   path that references C++ types renamed in RN 0.81 (`BaseShadowNode`,
   `getConcreteProps`, `getLayoutMetrics`). The build produces 19 compile
   errors in `react-native-svg`'s `RNSVGConcreteShadowNode.h`. The fix —
   `newArchEnabled: false` — works but reverts the renderer to the legacy
   Paper pipeline and signals deeper SDK/library drift coming.

2. **The premise of "we need Expo for cross-platform" no longer holds.**
   Phase 3b-i validated the pure-SwiftUI pattern (clone evoTest skeleton →
   drop in Swift files → ⌘R → iPhone) end-to-end. The demo is iOS-only;
   the paper figure is iOS-only. Every capability we'd use Expo for has
   a clean pure-SwiftUI equivalent that has fewer moving parts:

   | 3c-iv capability | Expo current | Pure SwiftUI |
   |---|---|---|
   | QR display | `react-native-qrcode-svg` + `react-native-svg` (Fabric issue) | `CIFilter.qrCodeGenerator()` — zero deps |
   | Relay HTTP poll | `fetch` + `useEffect` + `AppState` | `URLSession` + `Timer` + `ScenePhase` |
   | Consent UI | RN components | SwiftUI views (already proved pattern in seAgeTest 3b-i) |
   | Face ID gate | `expo-local-authentication` wrap | `LAContext` directly (already used in `SeAgeService.swift`) |
   | Encrypt to recipient | `SeAge.encryptToRecipient` bridge | `SeAgeService.encryptToRecipient` direct call |
   | Audit log | `expo-secure-store` | `kSecClassGenericPassword` (already used in `SeAgeService.swift`) |
   | Random bytes | `expo-crypto.getRandomBytesAsync` | `SecRandomCopyBytes` (already used in `AgeEncryptor`) |
   | Privacy Manifest | `app.json` block → autogen | `PrivacyInfo.xcprivacy` directly in project |

Pure SwiftUI removes: node_modules + 70+ transitive dep concerns,
version-pin hell, Fabric vs Paper architectural decisions, Metro bundler,
prebuild/CocoaPods ceremony, Expo CLI dependency, the SeAgeModule Expo
bridge layer. **Net cost: ~2 hours to write the 8 new Swift UI files.**

## What stays unchanged from the parent plan

- All Swift libraries written in 3b, 3c-i, 3c-ii — they're pure CryptoKit /
  Foundation / Security and translate identically to any iOS host
- `packages/encounter-relay/` — independent Node service; patient app
  hits it via HTTP regardless of framework
- The dual-device flow design (QR + relay + Face ID + ECDH wrap)
- The reviewer-mode "Simulate clinician request" concept
- The Privacy Manifest declarations (just expressed as XML plist instead of JSON)

## What changes for 3c-iv

The Expo `packages/mobile-patient/` codebase is **deferred**, not deleted —
the JS code + reviewer-mode design + privacy manifest design + relay HTTP
client all represent real work that translates 1:1 to a future React Native
revival if cross-platform / Android demand ever materializes.

The Phase 3 demo deliverable becomes a pure SwiftUI app, mirroring the
seAgeTest pattern that already shipped 3b-i.

## New file layout (under `~/Desktop/memoryOraclePatient/`)

```
~/Desktop/memoryOraclePatient/                ← clone of seAgeTest skeleton
└── evo/
    ├── evo.xcodeproj/                        ← already-working signing (team 27TUX5PYAU)
    └── evo/
        ├── evoApp.swift                      ← @main entry (rename internal-only)
        ├── ContentView.swift                 ← state-machine: boot → home → consent → audit
        ├── HomeView.swift                    ← QR + pending list + reviewer simulate button
        ├── ConsentView.swift                 ← clinician identity + scopes + TTL countdown
        ├── AuditView.swift                   ← last-50 audit entries
        ├── RelayClient.swift                 ← URLSession HTTP client + polling
        ├── ApproveHandler.swift              ← gen session keys + encrypt + POST
        ├── DebugSimulator.swift              ← reviewer-mode fake encounter
        ├── AuditStore.swift                  ← Keychain-backed audit log
        ├── SeAgeService.swift                ← REUSED from 3b
        ├── AgeRecipient.swift                ← REUSED from 3b
        ├── Bech32.swift                      ← REUSED from 3b
        ├── AgeEncryptor.swift                ← REUSED from 3c-ii
        └── Assets.xcassets/                  ← copied from seAgeTest
```

Bundle id: `ai.memoryoracle.patient`
Signing team: `27TUX5PYAU` (already configured in evoTest skeleton)
Deployment target: iOS 14 (matches existing SE module)
Architecture: Old (Paper) — Fabric not required for QR + Consent UI

## Privacy Manifest

Direct `PrivacyInfo.xcprivacy` XML plist in the Xcode project, declaring
the same content as the JSON we put in the Expo app.json:

- `NSPrivacyTracking` = false
- `NSPrivacyTrackingDomains` = []
- `NSPrivacyCollectedDataTypes` = []
- `NSPrivacyAccessedAPITypes`:
  - UserDefaults (CA92.1)
  - FileTimestamp (0A2A.1)
  - SystemBootTime (35F9.1)
  - DiskSpace (E174.1)

## ATS / relay URL

Direct `NSAppTransportSecurity` block in Info.plist with
`NSAllowsArbitraryLoads: true` for the LAN-IP demo (relay at
`http://192.168.100.5:8080`). For production at `verum.sh`/`mae.sh`:
delete the ATS block entirely; HTTPS handles itself.

Relay URL stored as a `UserDefaults` value with a compile-time default;
operator can override at runtime via a settings screen (optional polish).

## Validation pathway (mirror of 3b-i)

1. On Sequoia: clone evoTest skeleton → `~/Desktop/memoryOraclePatient/`
2. Drop in 4 reused Swift files (SeAgeService, AgeRecipient, Bech32, AgeEncryptor)
3. Write 8 new Swift files (ContentView, HomeView, ConsentView, AuditView,
   RelayClient, ApproveHandler, DebugSimulator, AuditStore)
4. Update `evo.xcodeproj/project.pbxproj`:
   - Bundle id: `haus.noodles.evo` → `ai.memoryoracle.patient`
   - Add `INFOPLIST_KEY_NSFaceIDUsageDescription`
   - Add `INFOPLIST_KEY_NSAppTransportSecurity` for LAN-IP demo
   - Add Required-Reasons API declarations to `PrivacyInfo.xcprivacy`
5. Operator: open `evo.xcodeproj` in Xcode 26.3 → pick iPhone 12 → ⌘R
6. Smoke walkthrough:
   - App launches; SE check succeeds; identity loaded
   - QR renders containing `{"v":1,"recipient":"age1se1...","relay":"http://192.168.100.5:8080"}`
   - Tap "Simulate clinician request" → relay POST → pending request appears within ~5s
   - Tap pending → Consent view shows clinician + scopes + TTL countdown
   - Tap Approve → Face ID prompt → on approval, wrapped keys POSTed to relay
   - Check relay via curl: `GET /encounter/<id>/approval` returns the wrapped keys

## Acceptance criteria for 3c-iv done

- [ ] `~/Desktop/memoryOraclePatient/evo.xcodeproj` opens in Xcode
- [ ] Build clean (zero errors) on Sequoia
- [ ] App launches on iPhone 12, SE detected, identity generated
- [ ] QR renders correctly with patient recipient + relay URL
- [ ] Reviewer-mode simulate button posts to relay
- [ ] Polling picks up pending request within 5s
- [ ] Consent screen → Approve → Face ID prompt → wrapped keys POST'd
- [ ] Audit log records the approval
- [ ] One commit per logical change, pushed to memory-oracle branch
- [ ] Plan + code in git; the SwiftUI app source preserved for paper reproducibility

## 3c-v and 3d under the new framing

**3c-v** (clinician iPad app): same pivot — pure SwiftUI clone of seAgeTest /
memoryOraclePatient pattern. Reuses the same 4 Swift libs + adds:
- `AgeDecryptor.swift` (which is `AgeFile.swift` + `AgeCrypto.swift` + the
  decrypt orchestration we already have in `SeAgeService.decryptAgeFile`)
- Clinician home screen with camera-scan-QR (`AVCaptureSession`)
- Encounter request issuance + polling
- Decrypted record render (briefly, with auto-shred timer)

**3d** (paper figure): unchanged. Capture the dual-device demo, embed in
LNCS §7.4.

## Deferred — not deleted

Everything under `packages/mobile-patient/` (Expo) and the JS code in
`screens/`, `hooks/`, `lib/` stays in git on the `feat/phase-3-mobile-patient`
branch. Marked deferred with this plan doc as the reason. If the project
ever needs Android or cross-platform, that work resurrects in ~1 day.

## What I'd do differently next time

The signal to pivot was visible after 3b-i. When the pure-SwiftUI pattern
shipped working end-to-end via the evoTest skeleton, the Expo path's
unique advantages (cross-platform, JS UI ergonomics) became theoretical
for an iOS-only research demo. I should have re-questioned the framework
choice at the 3c-i / 3c-ii boundary instead of pushing through to a
Sequoia prebuild before noticing the cost.

Lesson: **when an alternate path ships working, immediately re-evaluate
whether the original path's costs are still justified.** Especially for
demo deliverables where the simplest reliable path wins.
