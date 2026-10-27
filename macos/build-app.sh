#!/bin/zsh
# 构建 ZCode Remote（macOS 遥控壳）：swift build → 组装 .app → ad-hoc 签名 → 打 zip
# 应用名刻意与官方 ZCode.app 区分，避免安装到同一台机器时冲突
# 产物统一输出到 build/bin/
set -e
cd "$(dirname "$0")"
VERSION="1.0.1"
APP_NAME="ZCode Remote"

mkdir -p build/bin

python3 tools/make_icon.py

# 通用二进制：Apple 芯片 + Intel 的 Mac 都能跑
swift build -c release --arch arm64 --arch x86_64

APP="build/bin/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/out/Products/Release/ZCodeShell "$APP/Contents/MacOS/${APP_NAME}"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>dev.straiway.zcodeshell.mac</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>10</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
ZIP="build/bin/ZCode-Remote-macOS-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "done: $APP + $ZIP"
