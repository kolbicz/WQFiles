#!/usr/bin/env bash
# An explicitly selected disposable simulator, driven without opening Simulator.app.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${WQ_SIMULATOR_UDID:?Set WQ_SIMULATOR_UDID to a disposable booted iOS simulator}"
OUT=$(mktemp -d "$ROOT/.work/tests/ui.XXXXXX")
APP="$OUT/WQScanUITests.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-fobjc-arc -fmodules "-fmodules-cache-path=$OUT/modules" -target arm64-apple-ios26.0-simulator -isysroot "$SDK" -Wall -Wextra -Werror -O1)
xcrun --sdk iphonesimulator clang "${FLAGS[@]}" -Dmain=WQProductionMain -c main.m -o "$OUT/main.o"
xcrun --sdk iphonesimulator clang "${FLAGS[@]}" -framework UIKit -framework Foundation -framework Security -framework UniformTypeIdentifiers -framework JavaScriptCore -lsqlite3 -lz \
    WQCore.m WQAccess.m WQScanTask.m WQLocalization.m WQLaunchServices.m WQUI.m WQSharing.m WQApps.m WQCache.m WQPlistEditor.m WQHexViewer.m WQSQLiteViewer.m WQSQLiteSave.m WQHealth.m WQTrash.m WQArchive.m WQSyntax.m WQMediaStream.m WQWebServer.m WQTheme.m WQInspector.m tests/WQScanUITests.m "$OUT/main.o" -o "$APP/WQScanUITests"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cz.kolbi.wqfiles.scan-tests</string><key>CFBundleExecutable</key><string>WQScanUITests</string><key>CFBundleName</key><string>WQ Scan Tests</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>MinimumOSVersion</key><string>26.0</string><key>LSRequiresIPhoneOS</key><true/><key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict><key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
BUNDLE=cz.kolbi.wqfiles.scan-tests
xcrun simctl terminate "$WQ_SIMULATOR_UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl uninstall "$WQ_SIMULATOR_UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$WQ_SIMULATOR_UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$WQ_SIMULATOR_UDID" "$BUNDLE" data)
wait_marker() {
    for ((attempt=0; attempt<60; attempt++)); do
        if [[ -f "$DATA/Documents/$1" ]]; then return 0; fi
        if compgen -G "$DATA/Documents/FAIL-*" >/dev/null; then ls "$DATA/Documents/FAIL-"*; return 1; fi
        sleep 1
    done
    echo "Timed out waiting for $1; app data: $DATA" >&2
    return 1
}
xcrun simctl launch "$WQ_SIMULATOR_UDID" "$BUNDLE"
wait_marker ready-for-background
xcrun simctl launch "$WQ_SIMULATOR_UDID" com.apple.Preferences
wait_marker background-paused
xcrun simctl launch "$WQ_SIMULATOR_UDID" "$BUNDLE"
wait_marker ready-to-terminate
xcrun simctl terminate "$WQ_SIMULATOR_UDID" "$BUNDLE"
xcrun simctl launch "$WQ_SIMULATOR_UDID" "$BUNDLE" recover
wait_marker recovery-passed
xcrun simctl io "$WQ_SIMULATOR_UDID" screenshot "$OUT/recovered-screen.png"
xcrun simctl terminate "$WQ_SIMULATOR_UDID" "$BUNDLE"
printf 'UIKit navigation, reconstruction, background/foreground and relaunch checks: PASS\nArtifacts: %s\n' "$OUT"
