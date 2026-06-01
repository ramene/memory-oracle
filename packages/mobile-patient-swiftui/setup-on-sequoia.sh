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

# ── 2. Drop in the 6 reused Swift libs (from se-age module) ──────────────
# Patient app only ENCRYPTS, but AgeEncryptor's symbols depend on helpers
# living in AgeCrypto.swift (pivP256WrapKey, payloadKey) and AgeFile.swift
# (base64EncodeUnpadded). Without those two, the build fails with "Cannot
# find 'AgeCrypto' in scope" + "Cannot find 'base64EncodeUnpadded' in scope".
# Including all 6 — AgeCrypto + AgeFile are dead code on the patient side
# but resolve AgeEncryptor's link dependencies.
echo "── [2] drop 6 reused libs ──"
for f in SeAgeService.swift AgeRecipient.swift Bech32.swift AgeEncryptor.swift AgeCrypto.swift AgeFile.swift; do
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

# ── 5. Write a complete Info.plist with our ATS dict + disable synthesis ──
# Xcode 14+ behavior: when GENERATE_INFOPLIST_FILE = YES, Xcode IGNORES the
# INFOPLIST_FILE path and synthesizes from INFOPLIST_KEY_* build settings
# instead. Synthesis can't express complex dict values (NSAppTransportSecurity
# is a dict, not a string), so we must turn synthesis OFF and provide a
# complete Info.plist that reproduces the keys synthesis was supplying.
#
# CRITICAL placement: Info.plist must live OUTSIDE the FilesystemSynchronized-
# RootGroup source dir (evo/evo/). If placed inside, Xcode 16+ auto-adds it
# to Copy Bundle Resources, AND the dedicated Process Info.plist step runs
# too — both target the same output path → "Multiple commands produce
# .../Info.plist" build error. Putting it as a sibling of evo.xcodeproj
# keeps it out of the auto-sync dir.
echo "── [5] write complete Info.plist (includes ATS for the LAN-IP demo) ──"
INFOPLIST="$DEST/evo/Info.plist"   # ← parent of $PROJ_DIR; sibling of evo.xcodeproj
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
	<key>NSFaceIDUsageDescription</key>
	<string>Face ID approves a clinician request to access your memory namespace for a single encounter. Your private key never leaves this device's Secure Enclave; Face ID only releases a time-limited wrapped key to the clinician.</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
</dict>
</plist>
PLISTEOF
echo "    ✓ Info.plist written ($(wc -l < "$INFOPLIST" | tr -d ' ') lines)"

# ── 6. Turn off GENERATE_INFOPLIST_FILE + add INFOPLIST_FILE in pbxproj ──
# Both settings must change together. Setting GENERATE_INFOPLIST_FILE = NO
# without INFOPLIST_FILE leaves Xcode with no Info.plist location → build
# fails with "missing Info.plist". seAgeTest skeleton doesn't have
# INFOPLIST_FILE in pbxproj (it relied on synthesis), so we add it.
echo "── [6] disable GENERATE_INFOPLIST_FILE + add INFOPLIST_FILE in pbxproj ──"
sed -i '' 's|GENERATE_INFOPLIST_FILE = YES;|GENERATE_INFOPLIST_FILE = NO;|g' "$PBXPROJ"
# Python for safe multi-line insertion with idempotency (negative lookahead
# prevents double-insertion if INFOPLIST_FILE already follows).
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
grep -E 'GENERATE_INFOPLIST_FILE|INFOPLIST_FILE' "$PBXPROJ" | sort -u | sed 's/^/    /'

# ── 7. Done — give the operator the next step ────────────────────────────
cat <<EOF

═════════════════════════════════════════════════════════════════════
✓ memoryOraclePatient assembled at: $DEST
═════════════════════════════════════════════════════════════════════

Open in Xcode:
  open ~/Desktop/memoryOraclePatient/evo/evo.xcodeproj

In Xcode (zero GUI clicks for ATS — it's now baked into Info.plist):
  1. ⇧⌘K  (Clean Build Folder — important, the prior build has stale Info.plist)
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
