#!/bin/bash
# setup-on-sequoia.sh — orchestrates the Sequoia-side Xcode project setup
# for the memoryOraclePatient SwiftUI app.
#
# Reuses the existing ~/Desktop/seAgeTest skeleton (Xcode 26+ FilesystemSynchronizedRootGroup
# pattern, signing team 27TUX5PYAU already configured, deploys to "Ramene's iPhone" via
# CoreDevice). Same 30-min-to-iPhone pattern that shipped Phase 3b-i.
#
# Idempotent: safe to re-run (cleans + rebuilds the destination dir).
#
# Usage (in tmux on Sequoia):
#   cd ~/.remote/github.com/@ramene/memory-oracle
#   git pull
#   bash packages/mobile-patient-swiftui/setup-on-sequoia.sh
#
# Output: ~/Desktop/memoryOraclePatient/evo.xcodeproj ready to open

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWIFTUI_SRC="$REPO_ROOT/packages/mobile-patient-swiftui/src"
SE_AGE_SRC="$REPO_ROOT/packages/mobile-patient/modules/se-age/ios"
SKELETON=~/Desktop/seAgeTest
DEST=~/Desktop/memoryOraclePatient

# ── Preflight ──────────────────────────────────────────────────────────────
[ -d "$SKELETON" ] || { echo "✗ skeleton missing: $SKELETON (expected from 3b-i)"; exit 1; }
[ -d "$SWIFTUI_SRC" ] || { echo "✗ swift sources missing: $SWIFTUI_SRC (git pull?)"; exit 1; }
[ -d "$SE_AGE_SRC" ] || { echo "✗ se-age sources missing: $SE_AGE_SRC"; exit 1; }

# ── 1. Clone skeleton (idempotent) ────────────────────────────────────────
echo "── [1] clone seAgeTest → memoryOraclePatient ──"
rm -rf "$DEST"
cp -R "$SKELETON" "$DEST"
find "$DEST" -name '.DS_Store' -delete

PROJ_DIR="$DEST/evo/evo"
PBXPROJ="$DEST/evo/evo.xcodeproj/project.pbxproj"

# Remove the seAgeTest test-harness ContentView (we replace with our routing ContentView).
rm -f "$PROJ_DIR/ContentView.swift"

# Remove any leftover .git from the seAgeTest skeleton (it'll have evoTest's git).
rm -rf "$DEST/evo/.git"

# ── 2. Drop in the 4 reused Swift libs (from se-age module) ──────────────
echo "── [2] drop 4 reused libs ──"
for f in SeAgeService.swift AgeRecipient.swift Bech32.swift AgeEncryptor.swift; do
  cp "$SE_AGE_SRC/$f" "$PROJ_DIR/$f"
  echo "    ✓ $f"
done

# ── 3. Drop in the 8 new SwiftUI files ────────────────────────────────────
echo "── [3] drop 8 new SwiftUI files ──"
for f in ContentView.swift HomeView.swift ConsentView.swift AuditView.swift \
         RelayClient.swift ApproveHandler.swift DebugSimulator.swift AuditStore.swift; do
  cp "$SWIFTUI_SRC/$f" "$PROJ_DIR/$f"
  echo "    ✓ $f"
done

echo "── post-drop source tree ──"
ls -la "$PROJ_DIR"/*.swift | awk '{print "    "$NF, $5"B"}'

# ── 4. Patch pbxproj: bundle id + Face ID usage string ──────────────────
echo "── [4] patch pbxproj ──"
sed -i '' 's|PRODUCT_BUNDLE_IDENTIFIER = haus\.noodles\.seAgeTest;|PRODUCT_BUNDLE_IDENTIFIER = ai.memoryoracle.patient;|g' "$PBXPROJ"

# Replace the 3b-i Face ID usage description with our patient-app version.
# Pass the pbxproj path via env var, NOT via positional arg: `python3 <<EOF "$VAR"`
# makes Python treat $VAR as SCRIPT_PATH and try to execute it as Python (which
# fails on the pbxproj's "DEVELOPMENT_TEAM = 27TUX5PYAU;" — leading digit
# triggers "invalid decimal literal"). Env-var pattern avoids that footgun.
PBXPROJ_PATH="$PBXPROJ" python3 <<'PYEOF'
import re, os
path = os.environ['PBXPROJ_PATH']
with open(path) as f:
    content = f.read()
old_pattern = r'INFOPLIST_KEY_NSFaceIDUsageDescription = "[^"]*";'
new_value = '''INFOPLIST_KEY_NSFaceIDUsageDescription = "Face ID approves a clinician request to access your memory namespace for a single encounter. Your private key never leaves this device's Secure Enclave; Face ID only releases a time-limited wrapped key to the clinician.";'''
content = re.sub(old_pattern, new_value, content)
with open(path, 'w') as f:
    f.write(content)
print("    ✓ Face ID usage description updated")
PYEOF

echo "── pbxproj state after patch ──"
grep -E 'PRODUCT_BUNDLE_IDENTIFIER|INFOPLIST_KEY_NSFaceIDUsageDescription|DEVELOPMENT_TEAM' "$PBXPROJ" | sort -u | sed 's/^/    /'

# ── 5. Done — give the operator the next step ────────────────────────────
cat <<EOF

═════════════════════════════════════════════════════════════════════
✓ memoryOraclePatient assembled at: $DEST
═════════════════════════════════════════════════════════════════════

Open in Xcode:
  open ~/Desktop/memoryOraclePatient/evo/evo.xcodeproj

In Xcode (2 GUI clicks):
  1. Target "evo" → Info tab → click + to add row:
     - "Application Transport Security Settings"  (this is the friendly
        name for NSAppTransportSecurity; Xcode auto-completes)
     - Set type: Dictionary
     - Inside it, click + to add child:
        - "Allow Arbitrary Loads" → Boolean → YES
        (This permits HTTP to http://192.168.100.5:8080 for the demo.
         Remove + delete this row entirely when moving to verum.sh HTTPS.)

  2. Top device picker → "Ramene's iPhone"
  3. ⌘R

Expected on iPhone:
  - "memory-oracle Patient" title; "Phase 3c-iv · SwiftUI native"
  - QR code rendered with your patient recipient + relay URL
  - "Pending requests (0)" — empty until you tap simulate
  - Bottom dashed-border purple box: "🧪 Reviewer / demo mode"
  - Tap "Simulate clinician request" → relay POST → request appears in ~5s
  - Tap the request → consent screen → Approve → Face ID → wrapped keys POSTed

Relay must be running on Sequoia (separate terminal in tmux):
  cd $REPO_ROOT/packages/encounter-relay && PORT=8080 npm start

EOF
