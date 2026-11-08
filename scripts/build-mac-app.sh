#!/bin/bash
# 组装并签名 macOS App（含 NE 透明代理 + WireGuard 两个系统扩展）
# 依赖：swiftc 编译产物、build/profiles/*.provisionprofile
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BIN="${APP_BIN:-/tmp/SDP-app-bin}"
SDPNE_BIN="${SDPNE_BIN:-/tmp/ne-build/SDPNE}"
WGNE_BIN="${WGNE_BIN:-/tmp/ne-build/WGNE}"
OUT="${OUT:-/tmp/ne-app/SDP.app}"
ID="Developer ID Application: Ning Huang (KLU8GF65GP)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
mkdir -p "$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.ne.systemextension/Contents/MacOS"
mkdir -p "$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.wg.systemextension/Contents/MacOS"

cp dist/SDP.app/Contents/Info.plist "$OUT/Contents/Info.plist"
cp dist/SDP.app/Contents/Resources/Assets.car "$OUT/Contents/Resources/Assets.car"
cp "$APP_BIN" "$OUT/Contents/MacOS/SDP"

NE="$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.ne.systemextension"
cp ne/Info.plist "$NE/Contents/Info.plist"
cp "$SDPNE_BIN" "$NE/Contents/MacOS/SDPNE"
cp build/profiles/ne.provisionprofile "$NE/Contents/embedded.provisionprofile"

WG="$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.wg.systemextension"
cp ne/Info-WG.plist "$WG/Contents/Info.plist"
cp "$WGNE_BIN" "$WG/Contents/MacOS/WGNE"
cp build/profiles/wg.provisionprofile "$WG/Contents/embedded.provisionprofile"

cp build/profiles/app.provisionprofile "$OUT/Contents/embedded.provisionprofile"

xattr -cr "$OUT" 2>/dev/null || true
find "$OUT" -exec xattr -c {} \; 2>/dev/null || true
codesign --force --options runtime --timestamp --entitlements ne/SDPNE.entitlements --identifier com.alick.sdp-proxy.ne --sign "$ID" "$NE"
codesign --force --options runtime --timestamp --entitlements ne/WGNE.entitlements --identifier com.alick.sdp-proxy.wg --sign "$ID" "$WG"
codesign --force --options runtime --timestamp --entitlements macapp/SDP.entitlements --sign "$ID" "$OUT"
echo "已生成并签名: $OUT"
