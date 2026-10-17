#!/usr/bin/env bash
#
# Builds app/macos/build/Cmm.app: the SwiftUI app with the cmm engine inside it.
#
#   1. builds the Go engine from this repository (the folder two levels up) into Contents/Resources/cmm,
#   2. builds the app with `swift build -c release`,
#   3. builds the app icon (Icon/AppIcon.icon, an Icon Composer document) with actool,
#   4. assembles the bundle (Info.plist: com.davidsaint.cmm, "cmm", macOS 14 or later),
#   5. signs it ad hoc (no developer account needed; the app runs on the Mac that built it) and checks the result.
#
# Safe to run again: the bundle is rebuilt from scratch each time and only its own output folder is touched.
# Nothing is installed anywhere (no `go install`), and nothing is deleted outside app/macos/build/Cmm.app.
#
# Needs Go and the Swift toolchain (Xcode or its command line tools) on PATH.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # app/macos
REPO_ROOT="$(cd "$HERE/../.." && pwd)"                  # the repository root, where go.mod is
APP="$HERE/build/Cmm.app"

die() {
    echo "build-app.sh: $*" >&2
    exit 1
}

# --- what is needed -------------------------------------------------------------------------------------------

command -v go >/dev/null 2>&1 ||
    die "Go was not found on PATH, so the cmm engine cannot be built. The app carries its own copy of cmm, built from
this repository with Go. Install Go (https://go.dev/doc/install), open a new terminal and run this script again."
command -v swift >/dev/null 2>&1 ||
    die "swift was not found on PATH. Install Xcode (or run 'xcode-select --install') and run this script again."
command -v codesign >/dev/null 2>&1 || die "codesign was not found (it ships with macOS)."
command -v plutil >/dev/null 2>&1 || die "plutil was not found (it ships with macOS)."
[ -f "$REPO_ROOT/go.mod" ] || die "expected the cmm repository at $REPO_ROOT (no go.mod there)."

# --- a fresh bundle -------------------------------------------------------------------------------------------

# The only thing this script ever removes is its own previous output.
[ "$APP" = "$HERE/build/Cmm.app" ] || die "refusing to clean an unexpected path: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- the engine -----------------------------------------------------------------------------------------------

echo "==> Building the cmm engine (Go) from $REPO_ROOT"
(cd "$REPO_ROOT" && go build -trimpath -o "$APP/Contents/Resources/cmm" .) ||
    die "the Go build failed (see the messages above)."

# --- the app --------------------------------------------------------------------------------------------------

echo "==> Building the app (swift build -c release)"
swift build -c release --package-path "$HERE" --product Cmm ||
    die "the Swift build failed (see the messages above)."
BIN_DIR="$(swift build -c release --package-path "$HERE" --show-bin-path)"
[ -x "$BIN_DIR/Cmm" ] || die "swift build did not produce $BIN_DIR/Cmm."
cp "$BIN_DIR/Cmm" "$APP/Contents/MacOS/Cmm"

# --- the icon -------------------------------------------------------------------------------------------------

# Icon/AppIcon.icon is an Icon Composer document with a light, a dark and a tinted look. actool turns it into the
# asset catalog the system draws the icon from on macOS 26 and later (Assets.car) and an AppIcon.icns for older
# systems; both go into the bundle's Resources, and Info.plist below names the icon.
ICON_SRC="$HERE/Icon/AppIcon.icon"
[ -d "$ICON_SRC" ] || die "the app icon is missing: $ICON_SRC"
xcrun --find actool >/dev/null 2>&1 || die "actool was not found (it ships with Xcode), so the app icon cannot be built."
echo "==> Building the app icon (actool)"
ICON_LOG="$(xcrun actool "$ICON_SRC" --compile "$APP/Contents/Resources" --platform macosx --target-device mac \
    --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$HERE/build/icon-info.plist" \
    --output-format human-readable-text --notices --warnings --errors 2>&1)" || {
    echo "$ICON_LOG" >&2
    die "actool could not build the app icon (see the messages above)."
}
[ -f "$APP/Contents/Resources/Assets.car" ] && [ -f "$APP/Contents/Resources/AppIcon.icns" ] ||
    die "actool did not produce the icon files in $APP/Contents/Resources."

# --- the bundle -----------------------------------------------------------------------------------------------

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Cmm</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.davidsaint.cmm</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>cmm</string>
    <key>CFBundleDisplayName</key>
    <string>cmm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "the generated Info.plist is not valid."

# --- signing --------------------------------------------------------------------------------------------------

# Ad hoc (identity "-"). The embedded engine is signed first and explicitly: --deep does not reliably treat a
# plain executable in Resources as nested code, and an unsigned one would make the whole bundle fail to verify.
echo "==> Signing (ad hoc)"
codesign --force --sign - "$APP/Contents/Resources/cmm"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" ||
    die "the bundle does not verify after signing."

# --- a last look ----------------------------------------------------------------------------------------------

# The embedded engine must run from inside the bundle (this only prints its version).
ENGINE_VERSION="$("$APP/Contents/Resources/cmm" --version)" ||
    die "the cmm inside the bundle does not run."

echo
echo "Built:   $APP"
echo "Engine:  $ENGINE_VERSION (Contents/Resources/cmm)"
echo "Open it: open \"$APP\""
echo "While developing, CMM_BIN=/path/to/cmm makes the app use another cmm (see app/macos/README.md)."
