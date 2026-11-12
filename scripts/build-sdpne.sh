#!/bin/bash
# 编译 SDP 透明代理系统扩展 (SDPNE)
# 源码: ne/main.swift ne/Provider.swift + macapp/Core 中 Provider 用到的类型
#      + ne/bridge.h 桥接 hev 的 C 函数 + third_party/hev/lib 静态库
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${SDPNE_BIN:-/tmp/ne-build/SDPNE}"
HEV="third_party/hev/lib"

swiftc -target arm64-apple-macosx13.0 \
  -framework NetworkExtension -framework Network -framework Security \
  -I ne -I "$HEV" -import-objc-header ne/bridge.h \
  ne/main.swift ne/Provider.swift \
  macapp/Core/RuleStore.swift macapp/Core/RuleText.swift macapp/Core/Streams.swift \
  macapp/Core/SharedToken.swift macapp/Core/Gateway.swift macapp/Core/DNS.swift macapp/Core/Config.swift \
  "$HEV/libhev-socks5-tunnel.a" "$HEV/libhev-task-system.a" "$HEV/liblwip.a" "$HEV/libyaml.a" \
  -o "$OUT"
echo "已编译 SDPNE -> $OUT"
