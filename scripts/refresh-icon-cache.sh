#!/bin/bash
# 重装同路径 App 后，LaunchServices 可能仍缓存旧图标（显示为通用占位图）。
# 运行本脚本刷新图标缓存。
set -e
APP="${1:-$HOME/Applications/SDP.app}"
if [ ! -d "$APP" ]; then
  echo "找不到 $APP"
  exit 1
fi
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP" 2>/dev/null || true
touch "$APP"
killall Finder 2>/dev/null || true
sleep 1
"$LSREGISTER" -f "$APP" 2>/dev/null || true
echo "图标缓存已刷新：$APP"
