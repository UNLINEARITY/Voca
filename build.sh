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

# 从设计源图生成 macOS 所需的多尺寸图标。
ICON_SOURCE="Assets/AppIcon.png"
ICONSET="$APP/Contents/Resources/Voca.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Voca.icns"
rm -r "$ICONSET"

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
    <key>CFBundleIconFile</key>
    <string>Voca.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Voca 在保存来自浏览器的选中文字时，读取当前标签页网址作为来源记录。</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Voca 仅在打开星图时读取当前屏幕，以实时呈现玻璃球的透镜折射；画面只在内存中处理，不会保存。</string>
    <key>NSHumanReadableCopyright</key>
    <string>Personal use</string>
</dict>
</plist>
EOF

# 代码签名必须在全部 bundle 内容写入后执行，否则后写入的 Info.plist 会破坏签名。
# 优先使用本地开发证书（稳定身份，重编译不掉隐私权限），否则 ad-hoc 兜底。
IDENTITY="Voca Development"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "==> codesign with $IDENTITY"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "==> codesign ad-hoc（未找到本地开发证书，隐私权限将在重编译后失效）"
    codesign --force --sign - "$APP"
fi
codesign --verify --verbose "$APP" 2>&1 | tail -1

echo "✅ 构建完成：$APP"
echo "   启动：open $APP"
