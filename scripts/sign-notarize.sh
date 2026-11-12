#!/bin/bash
# 组装 SDP.app → Developer ID 签名 → asc 公证 → staple → Gatekeeper 校验
#
# 前置：
#   - 钥匙串里有 Developer ID Application 证书
#   - asc 已登录（asc auth doctor）
#   - build/profiles/{app,ne,wg,ts}.provisionprofile
#   - dist/SDP.app/Contents/Info.plist（Assets.car 可选）
#   - APP_BIN / SDPNE_BIN / WGNE_BIN / TSNE_BIN 四个 Mach-O
# 缺失的 NE 二进制会被跳过并明确警告，不会伪造占位文件。
set -euo pipefail
cd "$(dirname "$0")/.."

ID="${SIGN_IDENTITY:-Developer ID Application: Ning Huang (KLU8GF65GP)}"
APP_BIN="${APP_BIN:-/tmp/sdp-app-bin}"
SDPNE_BIN="${SDPNE_BIN:-/tmp/ne-build/SDPNE}"
WGNE_BIN="${WGNE_BIN:-/tmp/ne-build/WGNE}"
TSNE_BIN="${TSNE_BIN:-/tmp/ne-build/TSNE-full}"
OUT="${OUT:-/tmp/ne-app/SDP.app}"
ZIP="${ZIP:-/tmp/ne-app/SDP.zip}"

echo "== 前置检查 =="
command -v asc >/dev/null 2>&1 || { echo "asc 未安装"; exit 1; }
asc auth status >/dev/null 2>&1 || { echo "asc 未认证，请先 asc auth login"; exit 1; }
security find-identity -v -p codesigning | grep -Fq "$ID" || { echo "钥匙串里找不到签名证书: $ID"; exit 1; }
for p in app ne wg ts; do
    [ -f "build/profiles/$p.provisionprofile" ] || { echo "缺签名描述文件: build/profiles/$p.provisionprofile"; exit 1; }
done
[ -x "$APP_BIN" ] || { echo "缺 App 主二进制: $APP_BIN"; exit 1; }
[ -x "$TSNE_BIN" ] || { echo "缺 Tailscale 扩展二进制: $TSNE_BIN"; exit 1; }
INFO_PLIST="${INFO_PLIST:-dist/SDP.app/Contents/Info.plist}"
[ -f "$INFO_PLIST" ] || INFO_PLIST=assets/SDP-Info.plist
[ -f "$INFO_PLIST" ] || { echo "缺 App Info.plist（可用 INFO_PLIST 指定）"; exit 1; }
echo "  证书 / asc / 4 个 profile / 主二进制 OK (Info.plist: ${INFO_PLIST})"

echo "== 组装 =="
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" \
         "$OUT/Contents/Library/SystemExtensions"
cp "$INFO_PLIST" "$OUT/Contents/Info.plist"
cp "$APP_BIN" "$OUT/Contents/MacOS/SDP"
cp build/profiles/app.provisionprofile "$OUT/Contents/embedded.provisionprofile"
# App 图标：直接把 Icon Composer 的 assets/AppIcon.icon 交给 actool 编译。
# .icon 本身就是一个「抽象 asset catalog」，actool 吃目录本身即可产出
# 带 Aqua / DarkAqua / Tintable 三套外观的 IconImageStack + 兼容用 AppIcon.icns。
ICON_SRC=assets/AppIcon.icon
if [ -d "$ICON_SRC" ]; then
    xcrun actool "$ICON_SRC" \
        --compile "$OUT/Contents/Resources" \
        --output-format human-readable-text --notices --warnings \
        --app-icon AppIcon \
        --target-device mac --minimum-deployment-target 13.0 --platform macosx \
        --bundle-identifier com.alick.sdp-proxy \
        --output-partial-info-plist "$OUT/Contents/Resources/icon-partial.plist" >/dev/null
    # 把 CFBundleIconName / CFBundleIconFile 合并进 Info.plist
    /usr/libexec/PlistBuddy -c "Merge $OUT/Contents/Resources/icon-partial.plist" "$OUT/Contents/Info.plist" 2>/dev/null || true
    rm -f "$OUT/Contents/Resources/icon-partial.plist"
    echo "  已编译图标: $ICON_SRC -> Assets.car + AppIcon.icns"
else
    echo "  [警告] $ICON_SRC 缺失，App 将无图标" >&2
fi

add_ext() {
    local key="$1" plist="$2" bin="$3" execname="$4" entitle="$5" ident="$6" profile="$7"
    local dir="$OUT/Contents/Library/SystemExtensions/$key.systemextension"
    mkdir -p "$dir/Contents/MacOS"
    cp "$plist" "$dir/Contents/Info.plist"
    cp "$bin" "$dir/Contents/MacOS/$execname"
    cp "$profile" "$dir/Contents/embedded.provisionprofile"
    echo "  签名扩展 $ident"
    codesign --force --options runtime --timestamp \
        --entitlements "$entitle" --identifier "$ident" --sign "$ID" "$dir"
}

included=0
if [ -x "$SDPNE_BIN" ]; then
    add_ext "com.alick.sdp-proxy.ne" ne/Info.plist "$SDPNE_BIN" "SDPNE" \
        ne/SDPNE.entitlements "com.alick.sdp-proxy.ne" build/profiles/ne.provisionprofile
    included=$((included + 1))
else
    echo "  [跳过] SDPNE 未提供（需 macapp/Core 与 hev 静态库完整构建）" >&2
fi
if [ -x "$WGNE_BIN" ]; then
    add_ext "com.alick.sdp-proxy.wg" ne/Info-WG.plist "$WGNE_BIN" "WGNE" \
        ne/WGNE.entitlements "com.alick.sdp-proxy.wg" build/profiles/wg.provisionprofile
    included=$((included + 1))
else
    echo "  [跳过] WGNE 未提供（需 WireGuardKit）" >&2
fi
add_ext "com.alick.sdp-proxy.ts" ne/Info-TS.plist "$TSNE_BIN" "TSNE" \
    ne/TSNE.entitlements "com.alick.sdp-proxy.ts" build/profiles/ts.provisionprofile
included=$((included + 1))
echo "  已纳入 $included 个系统扩展"

echo "== 签名 App =="
codesign --force --options runtime --timestamp \
    --entitlements macapp/SDP.entitlements --sign "$ID" "$OUT"
codesign --verify --deep --strict --verbose=2 "$OUT" 2>&1 | tail -8

echo "== 打包 =="
mkdir -p "$(dirname "$ZIP")"
rm -f "$ZIP"
ditto -c -k --keepParent "$OUT" "$ZIP"
ls -lh "$ZIP"

echo "== asc 公证（--wait） =="
asc notarization submit --file "$ZIP" --wait

echo "== staple =="
xcrun stapler staple "$OUT"

echo "== Gatekeeper 校验 =="
spctl -a -vv -t install "$OUT" 2>&1 || true
echo "完成: $OUT"
