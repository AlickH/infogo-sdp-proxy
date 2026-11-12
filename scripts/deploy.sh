#!/bin/bash
# 部署刚构建好的 dist/DerivedData 产物到 /Applications，并把 VPN 配置重新绑定到新签名。
#
# 为什么需要这一步：NETunnelProviderManager 在保存配置时会记录当时 extension 的
# 20 字节 code signature。之后每一次重新签名（CDHash 变化），系统都会按「旧签名」
# 校验新扩展，失败时报：
#   Signature check failed: code failed to satisfy specified code requirement(s)
# 表现为隧道状态 Connected 但扩展进程立刻退出，日志里一行都不写。
#
# 只有宿主 App 自己能改写这条配置（neagent 只接受有权保存 NE 配置的进程），
# 所以用 SDP_NE_OFF=1 启动一次让 App 重新 saveToPreferences，再用正常模式启动。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${SRC:-build/DerivedData/Build/Products/Release/SDP.app}"
DST="${DST:-/Applications/SDP.app}"

[ -d "$SRC" ] || { echo "构建产物不存在: $SRC（先跑 scripts/build-xcode.sh）" >&2; exit 1; }

echo "==> 停掉正在运行的 SDP"
pkill -f "$DST/Contents/MacOS/SDP" 2>/dev/null || true
sleep 1

echo "==> 安装到 $DST"
rm -rf "$DST"
cp -R "$SRC" "$DST"
xattr -cr "$DST"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DST" 2>/dev/null || true

echo "==> 用当前签名重新绑定 VPN 配置（SDP_NE_OFF=1）"
defaults write com.alick.sdp-proxy "sdp.merged.vpnWanted" -bool false
SDP_NE_OFF=1 "$DST/Contents/MacOS/SDP" &>/tmp/sdp_rebind.log &
REBIND_PID=$!
sleep 6
kill "$REBIND_PID" 2>/dev/null || true
wait "$REBIND_PID" 2>/dev/null || true

echo "==> 恢复并启动"
defaults write com.alick.sdp-proxy "sdp.merged.vpnWanted" -bool true
open -a "$DST"
sleep 10

echo "==> 状态"
scutil --nc list | grep -i "com.alick.sdp-proxy" || echo "(无配置)"
pgrep -lf "SDPNE" | head -3 || echo "(扩展未运行)"
