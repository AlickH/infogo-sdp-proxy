#!/bin/bash
# dist/SDP.app → ZIP → Apple 公证（asc）→ staple → 校验
#
# 前置：
#   - 已用 scripts/build-xcode.sh 产出并签名 dist/SDP.app
#   - 钥匙串里有 Developer ID Application 证书
#   - asc 已登录（asc auth doctor）
#
# 合并后只有一个系统扩展（com.alick.sdp-proxy.ne），App 与扩展都由
# xcodebuild 用同一个 Developer ID 证书签好，这里不再重复签名，
# 只做「打包 → 公证 → 附票 → 验证」。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-dist/SDP.app}"
ZIP="${ZIP:-${APP%.app}.zip}"

echo "== 前置检查 =="
command -v asc >/dev/null 2>&1 || { echo "asc 未安装"; exit 1; }
asc auth status >/dev/null 2>&1 || { echo "asc 未认证，请先 asc auth login"; exit 1; }
[ -d "$APP" ] || { echo "产物不存在: ${APP}（先跑 scripts/build-xcode.sh）" >&2; exit 1; }
# 两种载体都接受：旧的系统扩展（Contents/Library/SystemExtensions/*.systemextension）
# 或新的 app extension（Contents/PlugIns/*.appex）。两者缺一则说明构建形态不对。
has_sysext=$(find "$APP/Contents/Library/SystemExtensions" -name "*.systemextension" 2>/dev/null | head -1)
has_appex=$(find "$APP/Contents/PlugIns" -name "*.appex" 2>/dev/null | head -1)
if [ -z "$has_sysext" ] && [ -z "$has_appex" ]; then
  echo "既无系统扩展也无 app extension：构建形态不对" >&2
  exit 1
fi
echo "   扩展载体：$( [ -n "$has_appex" ] && echo "app extension ($(basename "$has_appex"))" || echo "system extension ($(basename "$has_sysext"))" )"

echo "== 签名校验（公证要求 hardened runtime + 安全时间戳） =="
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|flags" | sed 's/^/    /'

echo "== 打包 =="
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
ls -lh "$ZIP"

echo "== 公证（--wait） =="
# 上传走代理时即使只有 11MB 也可能被掐断（S3 Put broken pipe / context deadline
# exceeded），asc 默认上传超时偏短，这里放宽到 30 分钟并允许重试三次。
export ASC_UPLOAD_TIMEOUT="${ASC_UPLOAD_TIMEOUT:-30m}"
attempt=1
until asc notarization submit --file "$ZIP" --wait; do
    if [ "$attempt" -ge 3 ]; then
        echo "公证提交连续 3 次失败：检查网络 / 代理（HTTPS_PROXY）后重跑本脚本" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    echo "提交失败，10 秒后重试（第 $attempt/3 次，上传超时 ${ASC_UPLOAD_TIMEOUT}）…" >&2
    sleep 10
done

echo "== staple（把票据附到 App 上，离线也能通过 Gatekeeper） =="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "== Gatekeeper 校验 =="
spctl -a -vv -t install "$APP" 2>&1 || true

echo "完成: ${APP}（已公证 + 已 staple）"
echo "安装：rsync -a --delete $APP/ /Applications/SDP.app/（保留顶层 inode，避免 sysextd 认为 App 被替换）"
