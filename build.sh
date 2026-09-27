#!/bin/bash
# Voca build script — Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
# SPDX-License-Identifier: AGPL-3.0-or-later
# Voca 一键构建：编译 release 版本并组装 Voca.app
# 用法：./build.sh   （产物在 build/Voca.app）
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

# 版本单一来源：最近的 git tag（发布时推 x.y.z tag）；无 tag 时回退 0.1.0。
# 构建号用提交数，保证同版本内每次构建递增。
VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)"
BUILD="$(git rev-list HEAD --count 2>/dev/null || echo 1)"
echo "==> 版本 $VERSION (build $BUILD)"

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

# SwiftUI resolves unqualified Text/Label keys in the app bundle, not the SPM resource bundle.
# Keep the app's localizations beside the packaged dependency bundles.
for language in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$language.lproj"
    cp "Sources/Voca/Resources/$language.lproj/Localizable.strings" \
        "$APP/Contents/Resources/$language.lproj/Localizable.strings"
    cp "Sources/Voca/Resources/$language.lproj/InfoPlist.strings" \
        "$APP/Contents/Resources/$language.lproj/InfoPlist.strings"
    cp "Sources/Voca/Resources/$language.lproj/ServicesMenu.strings" \
        "$APP/Contents/Resources/$language.lproj/ServicesMenu.strings"
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

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hans</string></array>
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Voca reads the current browser tab URL to record the source of selected text you save.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Voca reads the screen only while the galaxy is open to render live refraction. Frames are processed in memory, not saved.</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Look Up with Voca</string>
            </dict>
            <key>NSMessage</key>
            <string>lookupWordService</string>
            <key>NSPortName</key>
            <string>local.voca.Voca</string>
            <key>NSSendTypes</key>
            <array>
                <string>NSStringPboardType</string>
            </array>
            <key>NSUserData</key>
            <string>lookup</string>
            <key>NSServiceDescription</key>
            <string>Look up selected text with Voca near the cursor</string>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 UNLINEARITY — AGPL-3.0-or-later</string>
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

# 刷新系统服务登记，让右键「服务」菜单尽快出现「用 Voca 查词」
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo "✅ 构建完成：$APP"
echo "   启动：open $APP"
