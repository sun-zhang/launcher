#!/bin/bash
# 构建 LauncherZ.app（debug 版本供开发自测；Beta 分发需 Developer ID 固定签名，见 docs R5 教训）
# 用法: scripts/build-app.sh [--release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="debug"
[[ "${1:-}" == "--release" ]] && CONFIG="release"

echo "▸ swift build ($CONFIG)"
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release
    BIN=".build/release/LauncherZApp"
else
    swift build
    BIN=".build/debug/LauncherZApp"
fi

APP="build/LauncherZ.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "▸ 组装 bundle"
cp "$BIN" "$APP/Contents/MacOS/LauncherZ"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>LauncherZ</string>
    <key>CFBundleDisplayName</key>         <string>LauncherZ</string>
    <key>CFBundleExecutable</key>          <string>LauncherZ</string>
    <key>CFBundleIdentifier</key>          <string>com.launcherz.app</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>0.1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>26.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

echo "▸ ad-hoc 签名（TCC 相关的手势测试需固定签名身份，见 docs/技术预研报告 §1.1）"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  （codesign 跳过：$(codesign --version >/dev/null 2>&1 || echo 未安装)）"

echo "✅ $APP"
