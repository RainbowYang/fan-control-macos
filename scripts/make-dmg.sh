#!/bin/bash
# 把 FanControl 打包成可分发的 .dmg
# 用法：./scripts/make-dmg.sh
set -euo pipefail

APP_NAME="FanControl"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/Build/Products/Release"
DMG_DIR="$ROOT/dist"
STAGE="$DMG_DIR/stage"

echo "== 构建 Release =="
xcodebuild -project "$ROOT/FanControl.xcodeproj" \
  -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$ROOT/.build" build >/dev/null

APP="$BUILD_DIR/$APP_NAME.app"
[ -d "$APP" ] || { echo "错误: 构建产物不存在 $APP"; exit 1; }

echo "== 打包二进制进 bundle =="
# smctl daemon install 要求 smctld 与 smctl 同目录，必须一起拷
\cp -f "$ROOT/vendor/smctl/smctl" "$ROOT/vendor/smctl/smctld" \
  "$APP/Contents/MacOS/"

echo "== 制作 dmg =="
mkdir -p "$DMG_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# symlink /Applications 方便拖拽安装
ln -s /Applications "$STAGE/Applications"
\cp -R "$APP" "$STAGE/$APP_NAME.app"

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
DMG="$DMG_DIR/$APP_NAME-$VERSION-arm64.dmg"
rm -f "$DMG"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✅ 打包完成: $DMG"
echo "   （未签名/公证，分发后用户需「右键→打开」绕过 Gatekeeper）"
