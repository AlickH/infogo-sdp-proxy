#!/bin/bash
# 组装并签名 macOS App（含 NE 透明代理 + WireGuard + Tailscale 三个系统扩展）
# 依赖：swiftc 编译产物、/tmp/ne-build 下的三个 NE 二进制、build/profiles/*.provisionprofile
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BIN="${APP_BIN:-/tmp/SDP-app-bin}"
SDPNE_BIN="${SDPNE_BIN:-/tmp/ne-build/SDPNE}"
WGNE_BIN="${WGNE_BIN:-/tmp/ne-build/WGNE}"
TSNE_BIN="${TSNE_BIN:-/tmp/ne-build/TSNE}"
OUT="${OUT:-/tmp/ne-app/SDP.app}"
ID="Developer ID Application: Ning Huang (KLU8GF65GP)"

# 输入预检：缺任何一个都先列清单退出，避免后续 cp / codesign 连锁报错
missing=0
for f in "$APP_BIN" "$SDPNE_BIN" "$WGNE_BIN" "$TSNE_BIN" \
         assets/Assets.car \
         build/profiles/ne.provisionprofile \
         build/profiles/wg.provisionprofile \
         build/profiles/ts.provisionprofile \
         build/profiles/app.provisionprofile \
         ne/Info.plist ne/Info-WG.plist ne/Info-TS.plist \
         ne/SDPNE.entitlements ne/WGNE.entitlements ne/TSNE.entitlements \
         macapp/SDP.entitlements; do
    if [ ! -f "$f" ]; then
        echo "缺少构建输入: $f" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    cat >&2 <<'EOF'

以上文件需要在构建机上准备：
  - APP_BIN / SDPNE_BIN / WGNE_BIN / TSNE_BIN：四个编译产物
    （TSNE 可用 scripts/build-tsne.sh 编译）
  - dist/SDP.app/Contents/{Info.plist,Resources/Assets.car}：App 资源
  - build/profiles/*.provisionprofile：四个签名 profile（Developer ID 申请）
  - Info*.plist / *.entitlements：仓库内已提供
可用环境变量 APP_BIN / SDPNE_BIN / WGNE_BIN / TSNE_BIN / OUT 覆盖路径。
EOF
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
mkdir -p "$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.ne.systemextension/Contents/MacOS"
mkdir -p "$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.wg.systemextension/Contents/MacOS"
mkdir -p "$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.ts.systemextension/Contents/MacOS"

cp assets/SDP-Info.plist "$OUT/Contents/Info.plist"
cp assets/Assets.car "$OUT/Contents/Resources/Assets.car"
cp "$APP_BIN" "$OUT/Contents/MacOS/SDP"

NE="$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.ne.systemextension"
cp ne/Info.plist "$NE/Contents/Info.plist"
cp "$SDPNE_BIN" "$NE/Contents/MacOS/SDPNE"
cp build/profiles/ne.provisionprofile "$NE/Contents/embedded.provisionprofile"

WG="$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.wg.systemextension"
cp ne/Info-WG.plist "$WG/Contents/Info.plist"
cp "$WGNE_BIN" "$WG/Contents/MacOS/WGNE"
cp build/profiles/wg.provisionprofile "$WG/Contents/embedded.provisionprofile"

TS="$OUT/Contents/Library/SystemExtensions/com.alick.sdp-proxy.ts.systemextension"
cp ne/Info-TS.plist "$TS/Contents/Info.plist"
cp "$TSNE_BIN" "$TS/Contents/MacOS/TSNE"
cp build/profiles/ts.provisionprofile "$TS/Contents/embedded.provisionprofile"

cp build/profiles/app.provisionprofile "$OUT/Contents/embedded.provisionprofile"

xattr -cr "$OUT" 2>/dev/null || true
find "$OUT" -exec xattr -c {} \; 2>/dev/null || true
codesign --force --options runtime --timestamp --entitlements ne/SDPNE.entitlements --identifier com.alick.sdp-proxy.ne --sign "$ID" "$NE"
codesign --force --options runtime --timestamp --entitlements ne/WGNE.entitlements --identifier com.alick.sdp-proxy.wg --sign "$ID" "$WG"
codesign --force --options runtime --timestamp --entitlements ne/TSNE.entitlements --identifier com.alick.sdp-proxy.ts --sign "$ID" "$TS"
codesign --force --options runtime --timestamp --entitlements macapp/SDP.entitlements --sign "$ID" "$OUT"
echo "已生成并签名: $OUT"
