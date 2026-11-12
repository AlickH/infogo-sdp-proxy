#!/bin/bash
# 部署构建产物到 /Applications 并启动。
#
# 关于签名绑定：NETunnelProviderManager 保存配置时会记录当时 appex 的签名，
# 之后重新签名（CDHash 变化）可能导致校验失败。但**不要**用「禁用再启用」的方式
# 去刷新它——NEProviderStopReason 文档里 reason=1 是 UserInitiated（用户主动停止），
# 而 disableAndRemoveConfig() 会把 isEnabled 置 false，若此时进程被中断，
# 配置就停在「已禁用」状态，后续任何连接请求都会被立刻停掉。
#
# 正确做法：只改 wanted 标记，让 App 自己的 reload() 重新 saveToPreferences
# （它会设 isEnabled = true），并且等它写完再继续。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${SRC:-build/DerivedData/Build/Products/Release/SDP.app}"
DST="${DST:-/Applications/SDP.app}"

[ -d "$SRC" ] || { echo "构建产物不存在: $SRC" >&2; exit 1; }

echo "==> 停掉正在运行的 SDP"
pkill -f "$DST/Contents/MacOS/SDP" 2>/dev/null || true
sleep 1

echo "==> 安装到 $DST"
rm -rf "$DST"
cp -R "$SRC" "$DST"
xattr -cr "$DST"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DST" 2>/dev/null || true

echo "==> 以「总开关=开」启动（App 的 reload() 会重新保存配置并置 isEnabled=true）"
defaults write com.alick.sdp-proxy "sdp.merged.vpnWanted" -bool true
rm -f /tmp/sdpvpn.log
open -a "$DST"

echo "==> 等待隧道建立"
for i in $(seq 1 20); do
    if scutil --nc list 2>/dev/null | grep -q "com.alick.sdp-proxy.*Connected"; then
        echo "    已连接（第 ${i} 次检查）"
        break
    fi
    sleep 1
done

echo "==> 状态"
scutil --nc list | grep -i "com.alick.sdp-proxy" || echo "(无配置)"
pgrep -lf "SDPNE" | head -3 || echo "(扩展未运行)"
