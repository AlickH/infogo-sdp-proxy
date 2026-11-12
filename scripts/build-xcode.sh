#!/usr/bin/env bash
# 用 Xcode 工程构建并打包 SDP.app（Release + Developer ID 签名）
#
# 前置：
#   - Xcode 26+、xcodegen
#   - Developer ID Application 证书（team KLU8GF65GP）
#   - build/profiles/{app,ne,wg,ts}.provisionprofile，并已安装到
#     ~/Library/MobileDevice/Provisioning Profiles/（否则 xcodebuild 找不到 profile）
#
# 产物：dist/SDP.app（含 3 个内嵌系统扩展，已签名，未公证）
set -euo pipefail
cd "$(dirname "$0")/.."

DD="${DERIVED_DATA:-build/DerivedData}"
OUT="${OUT:-dist/SDP.app}"

command -v xcodegen >/dev/null 2>&1 || { echo "缺少 xcodegen：brew install xcodegen" >&2; exit 1; }

echo "==> 生成 SDP.xcodeproj"
xcodegen generate

echo "==> 构建 Release（4 个 target）"
xcodebuild build \
  -project SDP.xcodeproj \
  -scheme SDP \
  -configuration Release \
  -derivedDataPath "$DD" \
  | tail -5

APP="$DD/Build/Products/Release/SDP.app"
[ -d "$APP" ] || { echo "构建产物不存在: $APP" >&2; exit 1; }

echo "==> 打包到 $OUT"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$APP" "$OUT"
xattr -cr "$OUT" 2>/dev/null || true

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=2 "$OUT"
codesign -dv --verbose=2 "$OUT" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" | sed 's/^/    /'

echo
echo "已生成: $OUT"
echo "提示：系统扩展需从 /Applications 安装；首次启用会弹出系统扩展授权。"
