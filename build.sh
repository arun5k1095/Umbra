#!/bin/bash
# Builds build/Umbra.app. Needs macOS 15+ (Apple Silicon) and Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
BUILD_NUMBER=${BUILD_NUMBER:-1}
APP=build/Umbra.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/lists"

echo "• Compiling"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
    -o "$APP/Contents/MacOS/Umbra" $(find Sources -name '*.swift' | sort)

echo "• Resources"
cp Resources/public_suffix_list.dat "$APP/Contents/Resources/"
cp Resources/lists/host-rules.txt "$APP/Contents/Resources/"
cp Resources/lists/rules-*.json "$APP/Contents/Resources/lists/"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Umbra</string>
    <key>CFBundleDisplayName</key><string>Umbra</string>
    <key>CFBundleIdentifier</key><string>local.umbra.browser</string>
    <key>CFBundleExecutable</key><string>Umbra</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>NSCameraUsageDescription</key><string>A website you're visiting asked to use your camera.</string>
    <key>NSMicrophoneUsageDescription</key><string>A website you're visiting asked to use your microphone.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>Web site URL</string>
            <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>HTML document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key><array><string>public.html</string><string>public.xhtml</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "• Tor"
[ -x vendor/tor/tor ] || scripts/fetch-tor.sh
mkdir -p "$APP/Contents/Helpers"
cp vendor/tor/tor vendor/tor/libevent-2.1.7.dylib "$APP/Contents/Helpers/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp vendor/tor/LICENSE-*.txt "$APP/Contents/Resources/Licenses/"

echo "• Signing (ad-hoc)"
# The Expert Bundle's own signature is broken by its packaging, so sign the helpers here.
codesign --force --sign - "$APP/Contents/Helpers/libevent-2.1.7.dylib"
codesign --force --sign - "$APP/Contents/Helpers/tor"
codesign --force --sign - "$APP"
echo "✓ Built $APP (version $VERSION)"
