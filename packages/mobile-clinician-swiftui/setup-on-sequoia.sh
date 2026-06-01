#!/bin/bash
# setup-on-sequoia.sh — Phase 3c-v clinician SwiftUI app.
# Mirrors mobile-patient-swiftui/setup-on-sequoia.sh; differences:
#   - bundle id ai.memoryoracle.clinician (vs .patient)
#   - adds NSCameraUsageDescription (clinician scans QR; patient doesn't)
#   - dest: ~/Desktop/memoryOracleClinician (vs memoryOraclePatient)
#
# Idempotent: safe to re-run.
#
# Usage (in tmux on Sequoia):
#   cd ~/.remote/github.com/@ramene/memory-oracle
#   git pull
#   bash packages/mobile-clinician-swiftui/setup-on-sequoia.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWIFTUI_SRC="$REPO_ROOT/packages/mobile-clinician-swiftui/src"
SE_AGE_SRC="$REPO_ROOT/packages/mobile-patient/modules/se-age/ios"
SKELETON=~/Desktop/seAgeTest
DEST=~/Desktop/memoryOracleClinician

[ -d "$SKELETON" ] || { echo "✗ skeleton missing: $SKELETON"; exit 1; }
[ -d "$SWIFTUI_SRC" ] || { echo "✗ swift sources missing: $SWIFTUI_SRC"; exit 1; }
[ -d "$SE_AGE_SRC" ] || { echo "✗ se-age sources missing: $SE_AGE_SRC"; exit 1; }

# ── 1. Clone skeleton ────────────────────────────────────────────────────
echo "── [1] clone seAgeTest → memoryOracleClinician ──"
rm -rf "$DEST"
cp -R "$SKELETON" "$DEST"
find "$DEST" -name '.DS_Store' -delete
rm -rf "$DEST/evo/.git"

PROJ_DIR="$DEST/evo/evo"
PBXPROJ="$DEST/evo/evo.xcodeproj/project.pbxproj"

# Remove the seAgeTest test-harness ContentView.
rm -f "$PROJ_DIR/ContentView.swift"

# ── 2. Drop in 6 reused Swift libs ───────────────────────────────────────
echo "── [2] drop 6 reused libs ──"
for f in SeAgeService.swift AgeRecipient.swift Bech32.swift AgeEncryptor.swift AgeCrypto.swift AgeFile.swift; do
  cp "$SE_AGE_SRC/$f" "$PROJ_DIR/$f"
  echo "    ✓ $f"
done

# ── 3. Drop in 9 new SwiftUI files ───────────────────────────────────────
echo "── [3] drop 9 new SwiftUI files ──"
for f in ContentView.swift HomeView.swift ScannerView.swift EncounterRequestView.swift \
         ActiveEncounterView.swift AuditView.swift RelayClient.swift \
         DecryptHandler.swift MockRecords.swift AuditStore.swift; do
  cp "$SWIFTUI_SRC/$f" "$PROJ_DIR/$f"
  echo "    ✓ $f"
done

# ── 4. Patch pbxproj: bundle id + Face ID + Camera usage strings ─────────
echo "── [4] patch pbxproj ──"
sed -i '' 's|PRODUCT_BUNDLE_IDENTIFIER = haus\.noodles\.seAgeTest;|PRODUCT_BUNDLE_IDENTIFIER = ai.memoryoracle.clinician;|g' "$PBXPROJ"
PBXPROJ_PATH="$PBXPROJ" python3 <<'PYEOF'
import os, re
path = os.environ['PBXPROJ_PATH']
with open(path) as f:
    content = f.read()
old_pattern = r'INFOPLIST_KEY_NSFaceIDUsageDescription = "[^"]*";'
new_value = '''INFOPLIST_KEY_NSFaceIDUsageDescription = "Face ID confirms you are the clinician and unlocks the encrypted session keys the patient released for this encounter.";'''
content = re.sub(old_pattern, new_value, content)
with open(path, 'w') as f:
    f.write(content)
print("    ✓ Face ID usage description updated")
PYEOF

# ── 5. Write complete Info.plist (Camera + Face ID + ATS + Local Network) ──
echo "── [5] write complete Info.plist ──"
INFOPLIST="$DEST/evo/Info.plist"
cat > "$INFOPLIST" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key>
		<true/>
	</dict>
	<key>UIApplicationSupportsIndirectInputEvents</key>
	<true/>
	<key>UILaunchScreen</key>
	<dict/>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>UISupportedInterfaceOrientations~ipad</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationPortraitUpsideDown</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>NSCameraUsageDescription</key>
	<string>Scan a patient's QR to begin an encrypted, time-limited encounter. The camera is not used for any other purpose, and no images are stored.</string>
	<key>NSFaceIDUsageDescription</key>
	<string>Face ID confirms you are the clinician and unlocks the encrypted session keys the patient released for this encounter.</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
	<key>NSBonjourServices</key>
	<array>
		<string>_http._tcp</string>
		<string>_https._tcp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Reach the encounter relay on your local network to coordinate a consent encounter with the patient's iPhone. The relay only forwards opaque encrypted blobs.</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>
PLISTEOF
echo "    ✓ Info.plist written ($(wc -l < "$INFOPLIST" | tr -d ' ') lines)"

# ── 6. Disable GENERATE_INFOPLIST_FILE + add INFOPLIST_FILE ──────────────
echo "── [6] disable GENERATE_INFOPLIST_FILE + add INFOPLIST_FILE ──"
sed -i '' 's|GENERATE_INFOPLIST_FILE = YES;|GENERATE_INFOPLIST_FILE = NO;|g' "$PBXPROJ"
PBXPROJ_PATH="$PBXPROJ" python3 <<'PYEOF'
import os, re
path = os.environ['PBXPROJ_PATH']
with open(path) as f:
    content = f.read()
new_content, n = re.subn(
    r'(GENERATE_INFOPLIST_FILE = NO;)\n(\s*)(?!INFOPLIST_FILE)',
    r'\1\n\2INFOPLIST_FILE = "Info.plist";\n\2',
    content
)
with open(path, 'w') as f:
    f.write(new_content)
print(f"    ✓ added INFOPLIST_FILE to {n} build config block(s)")
PYEOF
grep -E 'GENERATE_INFOPLIST_FILE|INFOPLIST_FILE|PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM' "$PBXPROJ" | sort -u | sed 's/^/    /'

# ── 7. Done ──────────────────────────────────────────────────────────────
cat <<EOF

═════════════════════════════════════════════════════════════════════
✓ memoryOracleClinician assembled at: $DEST
═════════════════════════════════════════════════════════════════════

Open in Xcode:
  open ~/Desktop/memoryOracleClinician/evo/evo.xcodeproj

In Xcode:
  1. ⇧⌘K  (Clean Build Folder)
  2. Top device picker → "Ramene's iPhone" (or iPad if you have one)
  3. ⌘R

On first launch:
  - Local Network permission prompt → Allow
  - Camera permission prompt (when you tap "Scan patient QR") → Allow
  - Face ID permission prompt (on first decrypt) → Allow

End-to-end demo flow:
  1. Patient iPhone: app open, QR visible
  2. Clinician iPhone/iPad: tap "Scan patient QR" → scan
  3. Configure encounter: pick scopes + TTL → tap Send
  4. Patient iPhone: pending request appears → tap → consent → Face ID → Approve
  5. Clinician device: polls every 3s → on approval, Face ID fires → records render with countdown
  6. TTL expires OR clinician taps "End encounter & shred" → memory cleared

EOF
