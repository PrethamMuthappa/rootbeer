#!/bin/bash
# Builds RootBeer in release mode and assembles an ad-hoc signed build/RootBeer.app.
# Needs only the Command Line Tools. Writes only inside this project folder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/RootBeer.app"
VERSION="${ROOTBEER_VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "RootBeer: building release binary…"
swift build -c release --product RootBeer
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "RootBeer: assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RootBeer" "$APP/Contents/MacOS/RootBeer"

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
    <key>CFBundleIdentifier</key>
    <string>com.local.rootbeer</string>
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
codesign --force --sign - --options runtime --identifier com.local.rootbeer "$APP"
codesign --verify --strict "$APP"

echo "RootBeer: built $APP"
echo "Launch with: open \"$APP\""
