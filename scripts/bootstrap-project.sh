#!/bin/bash
# 生成 Xcode 工程并修正 objectVersion。
#
# XcodeGen 2.45 目前仍生成 objectVersion = 77（Xcode 16 格式），
# 会导致 GitHub Actions 默认的 Xcode 15.4 无法打开工程
# （参见 https://github.com/yonaskolb/XcodeGen/issues/1578）。
# 生成后统一把 objectVersion 降为 60，Xcode 15/16/26 均可打开。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBX="$ROOT/FanControl.xcodeproj/project.pbxproj"

xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"

if grep -q 'objectVersion = 77;' "$PBX"; then
  sed -i '' 's/objectVersion = 77;/objectVersion = 60;/' "$PBX"
  echo "Patched objectVersion 77 -> 60 in $PBX"
fi
