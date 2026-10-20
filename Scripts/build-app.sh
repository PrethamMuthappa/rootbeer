#!/bin/bash
# Builds RootBeer in release mode and assembles an ad-hoc signed build/RootBeer.app.
# Needs only the Command Line Tools. Writes only inside this project folder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/RootBeer.app"
BUNDLE_ID="io.github.prethammuthappa.rootbeer"
VERSION="${ROOTBEER_VERSION:-0.1.0}"
# A source tarball (e.g. when Homebrew builds RootBeer) has no git history; fall back to 1.
BUILD_NUMBER="${ROOTBEER_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# Extra `swift build` flags, e.g. --disable-sandbox: Homebrew builds inside its own sandbox and
# SwiftPM can't nest another one. (The odd expansion below keeps bash 3.2 happy with an empty array.)
read -r -a SWIFT_FLAGS <<< "${ROOTBEER_SWIFT_FLAGS:-}"

echo "RootBeer: building release binary…"
swift build -c release --product RootBeer ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})"

echo "RootBeer: assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RootBeer" "$APP/Contents/MacOS/RootBeer"

# App icon: Resources/AppIcon.png (1024×1024 or larger, transparent outside the rounded square)
# becomes AppIcon.icns with every size macOS uses. sips and iconutil ship with macOS.
ICON_SRC="$ROOT/Resources/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
    echo "RootBeer: making AppIcon.icns from Resources/AppIcon.png"
    ICONSET="$ROOT/build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -s format png -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -s format png -z "$((size * 2))" "$((size * 2))" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
else
    echo "RootBeer: no Resources/AppIcon.png; the app will use the generic icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>RootBeer</string>
    <key>CFBundleDisplayName</key>
    <string>RootBeer</string>
    <key>CFBundleExecutable</key>
    <string>RootBeer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# RootBeer links its Swift libraries by absolute path (/usr/lib/swift), so the toolchain's rpaths are
# never used; drop them so the loader has nowhere else to look.
otool -l "$APP/Contents/MacOS/RootBeer" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | while read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/RootBeer" 2>/dev/null
done
if otool -L "$APP/Contents/MacOS/RootBeer" | grep -q "@rpath"; then
    echo "RootBeer: binary links @rpath libraries; rpaths are needed after all" >&2
    exit 1
fi

# Hardened runtime: blocks DYLD_* injection and unsigned libraries. Required for notarization too.
echo "RootBeer: ad-hoc signing (hardened runtime)…"
codesign --force --sign - --options runtime --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

echo "RootBeer: built $APP"
echo "Launch with: open \"$APP\""
