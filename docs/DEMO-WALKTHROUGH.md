# Memory-Oracle / Verum / EBR — Three-Demo Walkthrough

Operator-runnable script for the LNCS §7.4 paper figure: the dual-device
encounter handshake plus the EBR conflict-detection moment that
differentiates accretive citation cards from current EHR design.

Last updated: 2026-06-02. Phase 3 work shipped on branch
`feat/phase-3-mobile-patient`.

---

## Prerequisites (one-time per machine)

- Sequoia Mac (192.168.100.5) with Xcode 26.3, signing team `27TUX5PYAU`
- Two iOS devices on the same Wi-Fi as Sequoia:
  - **iPhone**: patient device (iPhone 12 with Face ID is the proven hardware)
  - **iPad**: clinician device (or a second iPhone if iPad unavailable)
- Pre-existing `~/Desktop/seAgeTest/` skeleton (validated in 3b-i; the
  setup scripts clone from this)
- Repo cloned at `~/.remote/github.com/@ramene/memory-oracle`

---

## Setup (run once per device)

### 1. Patient SwiftUI app → iPhone

```bash
cd ~/.remote/github.com/@ramene/memory-oracle
git pull
bash packages/mobile-patient-swiftui/setup-on-sequoia.sh
open ~/Desktop/memoryOraclePatient/evo/evo.xcodeproj
```

In Xcode: ⇧⌘K → pick iPhone → ⌘R. On first launch, tap **Allow** to:
1. Local Network access (so the relay at 192.168.100.5:8080 is reachable)
2. Face ID (deferred until first encounter approval)

### 2. Clinician SwiftUI app → iPad

```bash
bash packages/mobile-clinician-swiftui/setup-on-sequoia.sh
open ~/Desktop/memoryOracleClinician/evo/evo.xcodeproj
```

In Xcode: switch the device picker to iPad → ⇧⌘K → ⌘R. On first launch:
1. Local Network → Allow
2. Camera → Allow (the first time you tap "Scan patient QR")
3. Face ID → Allow (the first time decryption fires OR identity switch)

### 3. Encounter relay (Sequoia, persistent during demo)

In a tmux pane on Sequoia:

```bash
cd ~/.remote/github.com/@ramene/memory-oracle/packages/encounter-relay
PORT=8080 npm start
```

Leave it running. Logs the routes; you'll see the demo's POSTs/GETs scroll.

### 4. Confirm both apps + relay reachable

```bash
# From any machine on the LAN
curl http://192.168.100.5:8080/healthz
# → {"ok":true,"encounters":0,"ts":"…"}
```

Both apps should show **relay ✓ reachable** on their home screen.

---

## Demo 1 — Dual-device consent handshake (LNCS §7.4 figure)

The flow the paper figure depicts. Targets: ~30-second screen recording
plus two stills (Face ID prompt on patient phone, decrypted record
mid-render on clinician iPad).

### Cast
- **Patient**: iPhone, "memory-oracle Patient" app
- **Clinician**: iPad, "memory-oracle Dr.", identity **Dr. Y. Chen**
  (create it on first launch with any PIN — the demo doesn't validate the
  PIN here; Demo 3 will exercise the multi-identity switch flow)

### Steps

1. **Patient device**: app open at home screen. Large QR visible
   encoding `{v:1, recipient: "age1se1...", relay: "http://192.168.100.5:8080"}`
2. **Clinician device**: tap **"Scan patient QR"** (large blue button).
   Camera opens with a centered reticle.
3. Aim camera at the patient's QR. Haptic buzz on scan; transitions to
   encounter-config screen.
4. **Clinician device**: confirm patient recipient (auto-filled from QR),
   pick scopes (default: `allergies`, `meds`). Bump TTL slider to **15 min**.
   Tap **"Send to patient"**.
5. **Clinician device**: "Awaiting patient approval…" with elapsed timer.
6. **Patient device** (within ~5 seconds): pending request appears in
   orange-bordered card — *"Dr. Y. Chen requesting: allergies, meds.
   Valid for 15 min — tap to review."*
7. **Patient device**: tap the request → Consent screen with:
   - Clinician name + recipient (selectable)
   - Scope chips (green-bordered)
   - Live TTL countdown ("14:53")
   - Big **green Approve** button + red Deny
8. **Patient device**: tap **Approve** → **Face ID prompt fires** with
   reason *"Approve Dr. Y. Chen to access allergies, meds for 15 min"*.
   Touch / look at sensor.
9. **Patient device**: green "Approved ✓" confirmation; wrapped session
   keys POSTed to relay.
10. **Clinician device** (within ~3 seconds of Patient step 9):
    **Face ID prompt fires on iPad** with reason
    *"Decrypt session key for 'allergies'"* (or 'meds' — whichever scope
    decrypts first; iOS caches LAContext briefly so subsequent scopes
    in the same approval use the same auth).
11. **Clinician device**: records render with live TTL countdown card at
    top. Each scope shows: scope label, mock record text in monospace,
    "session key: <32 hex chars>…" (cryptographic proof artifact for the
    paper figure).

### Capture moments

- **Still 1**: Patient iPhone mid-Face-ID-prompt (step 8)
- **Still 2**: Clinician iPad with both records visible + countdown
  showing time remaining (step 11)
- **Screen recording**: steps 2 → 11, ~30 seconds end-to-end

---

## Demo 2 — TTL expiry / auto-shred

Demonstrates the "time-limited access" claim.

1. After Demo 1 steps 1-11, leave the records visible on clinician
   device. Don't tap "End encounter".
2. Set TTL to a SHORT value before the encounter (e.g., 60 seconds via
   the slider in step 4) for a fast demo.
3. Watch the countdown card on clinician device. As it approaches 30s,
   the timer text turns **red**.
4. At 0s: records disappear; "expired" state shows. Session keys cleared
   from memory.
5. **Audit log** (clinician home → "View audit log →") shows:
   `encounter_expired_shred` entry.

---

## Demo 3 — Multi-clinician + EBR conflict + AI Overview (NEW in 3c-vi)

The demo that anchors the paper's value claim: *current EHRs would not
catch this; EBR + citation cards do.* Targets: photographable AI Overview
sheet showing the warfarin → apixaban supersession surfaced via
get_citation_card.

### Cast
- **Patient**: iPhone, same as Demo 1
- **Clinician**: iPad, two identities on the same device:
  - **Dr. Y. Chen** (cardiology — already created in Demo 1)
  - **Dr. R. Singh** (ER — created via the gear-icon menu just before
    this demo)
- **Synthetic corpus**: `jane-doe-1959` with the apixaban switch
  amendment (in `packages/memory-oracle-core/fixtures/`)

### Pre-demo setup

On clinician device, if you haven't already:
1. Tap **gear icon** (top-right of home) → Identities sheet
2. Tap **"Add new identity"**
3. Enter name: `Dr. R. Singh`
4. PIN: `5678` (any 4+ digits)
5. Confirm PIN. Tap **Create identity**.
6. You're back on the Identities sheet. Tap **Dr. R. Singh**.
7. **Step 1 of 2** — Enter PIN `5678` → tap Next
8. **Step 2 of 2** — Tap **Run Face ID** → authenticate
9. Active identity is now Dr. R. Singh. Tap **Done**.

The home screen now shows Dr. R. Singh's identity. Notice the recipient
in the identity card is different from Dr. Chen's — they have
independent Secure Enclave keys.

### Steps

1. **Patient device**: present QR (same as Demo 1).
2. **Clinician device** (as Dr. R. Singh): tap **"Scan patient QR"**,
   scan, configure encounter with scope **`anticoagulation`** + 15-min
   TTL. Tap **"Send to patient"**.
3. **Patient device**: pending request appears — "Dr. R. Singh
   requesting: anticoagulation". Tap, Approve, Face ID.
4. **Clinician device**: Face ID fires for decrypt. Records render —
   the patient's `anticoagulation.md` content surfaces (warfarin record
   from 2022-08-14).

   ⚠ **Important**: the rendered record shown to clinician is the
   ORIGINAL — current EHR design would show only this. EBR's value is
   surfacing the AMENDMENT chain at the moment of action, NOT in the
   read view. That's what step 5 below proves.

5. **Clinician device**: tap **"Add note / order"** button (blue, below
   the records).
6. Sheet opens. Scope: `anticoagulation`. Type in the assertion text:

   ```
   administer FFP 2 units for active GI bleed
   ```

   Tap **"Check & submit"**.
7. **THE PAPER MOMENT**: The EBR Alert sheet slides up with:
   - **Severity banner**: red, "Critical conflict / Wrong reversal agent"
   - **AI Overview TL;DR**: *"Patient was switched from warfarin to
     apixaban on 2026-01-14. The reversal agent you've proposed is for
     warfarin — not apixaban."*
   - **Explanation**: multi-paragraph, "On **2026-01-14**, Dr. Y. Chen
     (cardiology) amended this patient's anticoagulation record…" with
     the full reasoning about apixaban + andexanet alfa + HIPAA §164.526
     audit trail.
   - **Sources (2)**: expandable. Original record (mtime, current="apixaban
     5mg BID") + Amendment from 2026-01-14 by Dr. Y. Chen ("Switched from
     warfarin to apixaban per ESC 2026 guidelines").
   - **Citation card**: scope, policy, amendment count.
   - Buttons: **green "Acknowledge & withdraw"** | **red "Override
     (document reason)"**
   - Disclaimer: *"Decision support — surfacing the patient's existing
     record. Not a clinical AI judgment. Clinician retains authority."*

### Capture moments

- **Paper figure**: the AI Overview sheet at step 7, ideally with the
  Sources callout expanded (tap the chevron). This is THE shot for
  LNCS §7.4.
- **Still 2**: tap "Acknowledge & withdraw" — confirmation. Then go to
  audit log and screenshot the entries: `ebr_alert_conflict` →
  `ebr_alert_acknowledged`. Demonstrates the audit trail per HIPAA
  §164.526.

### Variant — the override path

Repeat steps 1-7. At step 7 tap **"Override (document reason)"**.
A text editor appears below. Type a justification (e.g., "no
andexanet on formulary; PCC unavailable; bridging therapy
emergent"). Tap **"Override anyway"** (red, only enabled when
reason is non-empty).

Audit log entry: `ebr_alert_overridden` with the reason text. This
demonstrates the "decision support not diagnosis" framing — clinician
retains authority, but the override is **documented**.

### Variant — penicillin allergy

Different conflict class. Steps:
1. New encounter, scope `allergies`.
2. Add note: `prescribe amoxicillin 500mg PO TID`
3. EBR alert fires with severity=critical, kind=allergy-violation.
   AI Overview: *"Patient has a documented allergy: Penicillin (anaphylaxis, 2014).
   Your proposed medication is in the same allergen class…"*

---

## Demo 4 — (optional) Identity-switch security

Quick demo of the multi-identity defense for shared-iPad scenario.

1. Clinician device has two identities (Dr. Chen, Dr. Singh).
   Active: Dr. Singh.
2. **Hand the iPad to someone else** with the screen unlocked.
3. Other person taps gear → Identities → **Dr. Y. Chen** → tap.
4. **PIN entry sheet** appears. Other person doesn't know Dr. Chen's
   PIN → cannot proceed past step 1 of 2.
5. Even if they guessed the PIN, **Face ID** step would fail (they're
   not Dr. Chen).
6. Audit log: `identity_switch_pin_failed` (or `_faceid_failed`).

---

## Cleanup between demo runs

To reset the relay (clears all encounters):
```bash
# Ctrl+C the relay process, then re-run npm start
```

To reset audit logs on the iOS apps: delete + re-install both apps via
Xcode (long press app icon → Remove). Note: on patient app, this also
forces the Local Network Privacy prompt again on next install.

To reset identities on the clinician app: delete the app + re-install.
The SE keys remain in keychain but the identity records (which point
at them) are gone, so functionally you start over.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Relay badge "⚠ unreachable" | iPhone on cellular, not Wi-Fi; OR Sequoia firewall enabled; OR relay not running | Check Wi-Fi; verify `curl http://192.168.100.5:8080/healthz` from Mac; restart relay |
| "Cannot connect to host" -1004 in app, but Safari can reach the relay | Local Network Privacy not granted | iPhone Settings → Privacy & Security → Local Network → toggle the app ON |
| Face ID never prompts on patient Approve | Pre-3c-iv-fix build | git pull; rebuild via the setup script; the Face ID gate is in `ApproveHandler.swift` |
| EBR alert never fires regardless of input | Synthetic corpus path wrong | Verify fixtures exist at `packages/memory-oracle-core/fixtures/jane-doe-1959/`; relay log will show error |
| Add Note button missing | Encounter not yet decrypted | Wait for patient approval + Face ID; button appears post-decrypt |
| Multiple "evo" icons on home screen | Patient + clinician apps both installed | This is expected; they're separate bundle ids. Long-press an icon to identify by bundle. |

---

## What the paper figure captures

The screenshot for **LNCS §7.4 — Dual-device clinical demonstration**
should be a composite of:

1. Demo 1 still 1 (patient iPhone, Face ID prompt mid-encounter)
2. Demo 1 still 2 (clinician iPad, records rendered with countdown)
3. Demo 3 paper moment (clinician iPad, EBR Alert sheet with Sources
   expanded showing the warfarin → apixaban amendment chain)

Composite layout: 3 panels horizontally. Caption ~120 words explaining:
- The cryptographic property (operator-bound SE key, never exfiltrated)
- The consent property (Face ID gates release of wrapped key)
- The accretive property (amendment-supersedes-original; citation card
  surfaces the chain at point of action; current EHRs cannot do this)
