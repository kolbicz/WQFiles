#!/usr/bin/env bash
# Builds WQFiles.ipa (arm64, ad-hoc signed with the App Group entitlement;
# re-sign with your sideloading tool, keeping an App Group).
# The app policy is iOS 26.0 or later; the SDK version is intentionally not the
# deployment target. Set WQFILES_FINAL_IPA to override the publication path.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
MINIMUM_IOS_VERSION=26.0
FINAL_IPA=${WQFILES_FINAL_IPA:-WQFiles.ipa}

# Publish only after the host regression suite passes. The packaged artifact
# still needs device validation, but this prevents a known-broken source tree
# from replacing the release IPA. The runner is required: a missing runner
# fails the build. WQ_SKIP_PREFLIGHT=1 is the only bypass and says so loudly.
PREFLIGHT_RUNNER="$ROOT/tests/run_all_tests.sh"
if [[ "${WQ_SKIP_PREFLIGHT:-0}" == 1 ]]; then
    {
        echo "************************************************************"
        echo "WARNING: host regression preflight SKIPPED (WQ_SKIP_PREFLIGHT=1)."
        echo "This IPA has not passed tests/run_all_tests.sh."
        echo "************************************************************"
    } >&2
else
    if [[ ! -f "$PREFLIGHT_RUNNER" ]]; then
        echo "preflight runner missing: $PREFLIGHT_RUNNER" >&2
        echo "restore it, or set WQ_SKIP_PREFLIGHT=1 to build without the regression gate" >&2
        exit 1
    fi
    # Through bash, so a lost executable bit cannot silently skip the gate.
    bash "$PREFLIGHT_RUNNER" || {
        echo "preflight failed: $PREFLIGHT_RUNNER (no IPA written)" >&2
        exit 1
    }
fi
if [[ "$FINAL_IPA" != /* ]]; then
    FINAL_IPA="$ROOT/$FINAL_IPA"
fi
FINAL_DIR=$(dirname -- "$FINAL_IPA")
if [[ ! -d "$FINAL_DIR" ]]; then
    echo "final IPA directory does not exist: $FINAL_DIR" >&2
    exit 1
fi

plist_value() {
    plutil -extract "$1" raw -o - "$2"
}

fail() {
    echo "build validation failed: $*" >&2
    exit 1
}

# Every action WQShortcuts.swift declares has to be in the metadata: a file
# that is there but lists nothing gives an app without actions.
check_shortcut_actions() {
    local metadata="$1/Metadata.appintents/extract.actionsdata" intent count=0
    for intent in $(sed -n 's/^struct \([A-Za-z0-9_]*\): AppIntent.*/\1/p' "$ROOT/WQShortcuts.swift"); do
        grep -q "\"$intent\"" "$metadata" || fail "the Shortcuts metadata does not list $intent"
        count=$((count + 1))
    done
    [[ "$count" -gt 0 ]] || fail "WQShortcuts.swift declares no Shortcuts actions"
}

EXPECTED_BUNDLE_ID=$(plist_value CFBundleIdentifier Info.plist)
EXPECTED_VERSION=$(plist_value CFBundleShortVersionString Info.plist)
EXPECTED_BUILD=$(plist_value CFBundleVersion Info.plist)
EXPECTED_MINIMUM_OS=$(plist_value MinimumOSVersion Info.plist)
APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' entitlements.plist)
[[ -n "$APP_GROUP" ]] || fail "entitlements.plist has no App Group"
# WQ Files' folder (Backups, AppBackups) shows in the Files app only with both
# keys on; 0.9.12 and 0.9.13 shipped without it.
for key in UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace; do
    [[ "$(plist_value "$key" Info.plist)" == "true" ]] || \
        fail "Info.plist $key must be true (WQ Files' folder in the Files app)"
done
[[ "$EXPECTED_MINIMUM_OS" == "$MINIMUM_IOS_VERSION" ]] || \
    fail "Info.plist minimum OS $EXPECTED_MINIMUM_OS does not match build policy $MINIMUM_IOS_VERSION"

OUT=$(mktemp -d "$FINAL_DIR/.WQFiles-build.XXXXXX")
IPA_TMP=$(mktemp "$FINAL_DIR/.WQFiles.ipa.XXXXXX")
rm -f -- "$IPA_TMP"
CHECK_DIR=""
cleanup() {
    if [[ -n "${OUT:-}" && -d "$OUT" ]]; then rm -rf -- "$OUT"; fi
    if [[ -n "${IPA_TMP:-}" && -e "$IPA_TMP" ]]; then rm -f -- "$IPA_TMP"; fi
    if [[ -n "${CHECK_DIR:-}" && -d "$CHECK_DIR" ]]; then rm -rf -- "$CHECK_DIR"; fi
}
trap cleanup EXIT

APP="$OUT/Payload/WQFiles.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
# Shortcuts actions: App Intents exist in Swift only, so the one Swift file is
# compiled here and linked with the Objective-C sources. The compiler also
# writes what the actions declare (titles, parameters) for the metadata step
# further down.
SWIFT_TARGET="arm64-apple-ios$MINIMUM_IOS_VERSION"
SWIFT_OBJECT="$OUT/WQShortcutsIntents.o"
cat > "$OUT/appintents-protocols.json" <<'JSON'
["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]
JSON
xcrun --sdk iphoneos swiftc -target "$SWIFT_TARGET" -sdk "$SDK" -module-name WQFiles -parse-as-library -O \
    -swift-version 5 -warnings-as-errors -module-cache-path "$OUT/ModuleCache" -import-objc-header WQShortcuts.h \
    -emit-const-values-path "$OUT/WQShortcutsIntents.swiftconstvalues" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$OUT/appintents-protocols.json" \
    -c WQShortcuts.swift -o "$SWIFT_OBJECT"
[[ -f "$SWIFT_OBJECT" && -f "$OUT/WQShortcutsIntents.swiftconstvalues" ]] || fail "swiftc wrote no Shortcuts object or constant values"
xcrun --sdk iphoneos clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -arch arm64 \
    -miphoneos-version-min="$MINIMUM_IOS_VERSION" \
    -isysroot "$SDK" -Wall -Wextra -Werror -O2 ${WQ_EXTRA_CFLAGS:-} \
    -framework UIKit -framework Foundation -framework Security -framework UniformTypeIdentifiers -framework JavaScriptCore \
    WQCore.m WQAccess.m WQScanTask.m WQLocalization.m WQLaunchServices.m WQUI.m WQSharing.m WQApps.m WQCache.m WQPlistEditor.m WQHexViewer.m WQSQLiteViewer.m WQSQLiteSave.m WQHealth.m WQTrash.m WQArchive.m WQSyntax.m WQMediaStream.m WQWebServer.m WQTheme.m WQInspector.m WQShortcuts.m main.m "$SWIFT_OBJECT" \
    -L "$SDK/usr/lib/swift" -Xlinker -rpath -Xlinker /usr/lib/swift -lsqlite3 -lz -o "$APP/WQFiles"
cp Info.plist "$APP/Info.plist"
# What the Shortcuts app reads to list the actions: without this folder in the
# app, the Swift code is there but no action shows up.
SWIFT_TOOLCHAIN=$(dirname "$(dirname "$(dirname "$(xcrun --sdk iphoneos --find swiftc)")")")
XCODE_BUILD=$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }') || true
printf '%s\n' "$ROOT/WQShortcuts.swift" > "$OUT/appintents-sources.txt"
printf '%s\n' "$OUT/WQShortcutsIntents.swiftconstvalues" > "$OUT/appintents-constvalues.txt"
xcrun appintentsmetadataprocessor --output "$APP" --toolchain-dir "$SWIFT_TOOLCHAIN" --module-name WQFiles \
    --sdk-root "$SDK" --xcode-version "${XCODE_BUILD:-unknown}" --platform-family iOS \
    --deployment-target "$MINIMUM_IOS_VERSION" --target-triple "$SWIFT_TARGET" \
    --source-file-list "$OUT/appintents-sources.txt" --swift-const-vals-list "$OUT/appintents-constvalues.txt" \
    --force >"$OUT/appintents.log" 2>&1 || { cat "$OUT/appintents.log" >&2; fail "the Shortcuts metadata could not be written"; }
[[ -f "$APP/Metadata.appintents/extract.actionsdata" ]] || fail "the app has no Shortcuts metadata (Metadata.appintents)"
check_shortcut_actions "$APP"
# App icon with the iOS 18+ dark and tinted variants (issue #47): a catalog
# built from icons/ and compiled by actool into Assets.car plus the classic
# PNGs; its CFBundleIcons replace the plain PNG list in Info.plist.
ICON_CATALOG="$OUT/Icons.xcassets"
mkdir -p "$ICON_CATALOG/AppIcon.appiconset"
cp icons/AppIcon1024.png icons/AppIcon1024-dark.png icons/AppIcon1024-tinted.png "$ICON_CATALOG/AppIcon.appiconset/"
cat > "$ICON_CATALOG/Contents.json" <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
cat > "$ICON_CATALOG/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "AppIcon1024-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
      "filename" : "AppIcon1024-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
xcrun actool "$ICON_CATALOG" --compile "$APP" --platform iphoneos \
    --minimum-deployment-target "$MINIMUM_IOS_VERSION" --target-device iphone --target-device ipad \
    --app-icon AppIcon --output-partial-info-plist "$OUT/icon-info.plist" \
    --errors --warnings --output-format human-readable-text >/dev/null || fail "actool could not compile the app icon"
[[ -f "$APP/Assets.car" ]] || fail "actool wrote no Assets.car"
for key in CFBundleIcons 'CFBundleIcons~ipad'; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Info.plist" >/dev/null 2>&1 || true
done
/usr/libexec/PlistBuddy -c "Merge $OUT/icon-info.plist" "$APP/Info.plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$APP/Info.plist")" == AppIcon ]] || \
    fail "Info.plist has no catalog app icon"
for lproj in "$ROOT"/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP/"
done
# The example themes ship in the app (Settings → Theme shows them built in).
if compgen -G "$ROOT/themes/*.wqtheme" >/dev/null; then
    mkdir -p "$APP/Themes"
    cp "$ROOT"/themes/*.wqtheme "$APP/Themes/"
fi
plutil -convert binary1 "$APP/Info.plist"
codesign -f -s - --entitlements entitlements.plist "$APP"

validate_app() {
    local app_path=$1
    [[ -x "$app_path/WQFiles" ]] || fail "missing executable in $app_path"
    [[ -f "$app_path/Info.plist" ]] || fail "missing Info.plist in $app_path"
    [[ -f "$app_path/Metadata.appintents/extract.actionsdata" ]] || fail "missing Shortcuts metadata in $app_path"
    check_shortcut_actions "$app_path"
    [[ "$(plist_value CFBundleIdentifier "$app_path/Info.plist")" == "$EXPECTED_BUNDLE_ID" ]] || \
        fail "bundle identifier does not match source metadata"
    [[ "$(plist_value CFBundleShortVersionString "$app_path/Info.plist")" == "$EXPECTED_VERSION" ]] || \
        fail "short version does not match source metadata"
    [[ "$(plist_value CFBundleVersion "$app_path/Info.plist")" == "$EXPECTED_BUILD" ]] || \
        fail "build version does not match source metadata"
    [[ "$(plist_value MinimumOSVersion "$app_path/Info.plist")" == "$EXPECTED_MINIMUM_OS" ]] || \
        fail "minimum OS does not match source metadata"
    codesign --verify --deep --strict "$app_path"
    local signed_entitlements
    signed_entitlements=$(codesign -d --entitlements :- "$app_path" 2>&1) || \
        fail "unable to inspect signed entitlements"
    [[ "$signed_entitlements" == *"$APP_GROUP"* ]] || \
        fail "signed app is missing required App Group $APP_GROUP"
}

# Package to a same-directory temporary sibling, then validate the actual ZIP
# contents and signature. The final path is untouched until all checks pass.
(cd "$OUT" && zip -qry "$IPA_TMP" Payload)
unzip -tqq "$IPA_TMP"
CHECK_DIR=$(mktemp -d "$OUT/ipa-check.XXXXXX")
unzip -q "$IPA_TMP" -d "$CHECK_DIR"
validate_app "$CHECK_DIR/Payload/WQFiles.app"
mv -f -- "$IPA_TMP" "$FINAL_IPA"
IPA_TMP=""
echo "wrote $FINAL_IPA"
