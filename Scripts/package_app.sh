#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "==> Building Vortex in release mode for Apple Silicon / arm64..."
swift build -c release --arch arm64

BIN_PATH="$DIR/.build/arm64-apple-macosx/release/Vortex"
APP_DIR="$DIR/Vortex.app"

echo "==> Packaging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Vortex"
chmod +x "$APP_DIR/Contents/MacOS/Vortex"

if [ -f "/opt/homebrew/bin/aria2c" ]; then
    cp "/opt/homebrew/bin/aria2c" "$APP_DIR/Contents/MacOS/aria2c"
    chmod +x "$APP_DIR/Contents/MacOS/aria2c"
fi

cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Vortex</string>
    <key>CFBundleIdentifier</key>
    <string>com.vortex.downloadmanager</string>
    <key>CFBundleName</key>
    <string>Vortex</string>
    <key>CFBundleDisplayName</key>
    <string>Vortex Download Manager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Vortex Download</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>vortex</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing Vortex.app..."
codesign --force --deep --sign - "$APP_DIR"

if [ -d "$DIR/../Vortex.app" ]; then
    echo "==> Syncing build to $DIR/../Vortex.app..."
    rm -rf "$DIR/../Vortex.app"
    cp -R "$APP_DIR" "$DIR/../Vortex.app"
fi

echo "==> Successfully created $APP_DIR!"
echo "You can now run 'open Vortex.app' or drag it to /Applications."
