#!/bin/bash
# Voca build script — Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
# SPDX-License-Identifier: AGPL-3.0-or-later
# Voca 一键构建：编译 release 版本并组装 Voca.app
# 用法：./build.sh   （产物在 build/Voca.app）
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

APP="build/Voca.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/Voca "$APP/Contents/MacOS/Voca"

# 关键：拷贝依赖库的资源 bundle（KeyboardShortcuts 的本地化等），
# 缺失会导致点开菜单栏面板时 Bundle.module 断言崩溃
for bundle in .build/release/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Voca</string>
    <key>CFBundleDisplayName</key>
    <string>Voca</string>
    <key>CFBundleIdentifier</key>
    <string>local.voca.Voca</string>
    <key>CFBundleExecutable</key>
    <string>Voca</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Personal use</string>
</dict>
</plist>
EOF

echo "✅ 构建完成：$APP"
echo "   启动：open $APP"
