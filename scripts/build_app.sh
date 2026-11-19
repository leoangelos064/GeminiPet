#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$BASE_DIR/GeminiPet.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$RESOURCES/sprites"
mkdir -p "$MACOS" "$RESOURCES/sprites"

cp -f "$BASE_DIR/sprites/"*.png "$RESOURCES/sprites/"
cp -f "$BASE_DIR/scripts/pet_ai_bridge.py" "$RESOURCES/pet_ai_bridge.py"
chmod +x "$RESOURCES/pet_ai_bridge.py"

cat > "$CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>GeminiPet</string>
    <key>CFBundleIdentifier</key>
    <string>com.antigravity.geminipet</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>哈基米桌宠</string>
    <key>CFBundleDisplayName</key>
    <string>哈基米桌宠</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>哈基米桌宠需要使用麦克风来开启语音对话模式。</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>哈基米桌宠需要使用屏幕录制权限以实现“看屏幕提问”功能。</string>
</dict>
</plist>
EOF

if [ -f "$BASE_DIR/sprites/idle.png" ]; then
    ICONSET="$BASE_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256; do
        sips -z $sz $sz "$BASE_DIR/sprites/idle.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
        sz2=$((sz * 2))
        sips -z $sz2 $sz2 "$BASE_DIR/sprites/idle.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns" >/dev/null 2>&1 || true
    rm -rf "$ICONSET"
fi

echo "Compiling GeminiPet.app with swiftc..."
swiftc -O \
    -parse-as-library \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework AVFoundation \
    -framework Carbon \
    "$BASE_DIR/src/GeminiPetApp.swift" \
    -o "$MACOS/GeminiPet"

chmod +x "$MACOS/GeminiPet"
echo "✅ Built $APP_DIR successfully!"
