#!/bin/bash
# 编译 WGNE（WireGuard Packet Tunnel 系统扩展）可执行体。
#
# 组件：
#   - 宿主层源码在本仓库：ne/main.swift + ne/WGProvider.swift
#   - WireGuardKit（Swift）：wireguard-apple 的 Sources/WireGuardKit/*.swift
#   - WireGuardKitC（C）：key.c / x25519.c 与 key.h / x25519.h
#   - WireGuardKitGo（Go c-archive）：libwg-go.a + wireguard.h
#
# 引擎数据面来自上游 wireguard-apple（MIT），通过 bridging header 暴露 C 符号，
# 不依赖 Swift Package Manager 的 module 机制（WGNE 走内嵌 NE 路线，禁止 CLI 方案）。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${WGNE_BIN:-/tmp/ne-build/WGNE}"
WGAPPLE="${WIREGUARD_APPLE:-/tmp/wireguard-apple}"
LIBWG="${LIBWG_GO:-/tmp/ne-build/wg/libwg-go.a}"
TARGET="${TARGET:-arm64-apple-macosx13.0}"
STAGE="/tmp/ne-build/wg-src"

# 1) 准备 wireguard-apple 源码（缺失则克隆）
if [ ! -d "$WGAPPLE/Sources/WireGuardKit" ]; then
    echo "克隆 wireguard-apple -> $WGAPPLE"
    rm -rf "$WGAPPLE"
    git clone --depth 1 https://github.com/WireGuard/wireguard-apple.git "$WGAPPLE"
fi

# 2) 准备 libwg-go.a（缺失则通过上游 Makefile 构建）
if [ ! -f "$LIBWG" ]; then
    echo "构建 libwg-go.a -> $LIBWG"
    ( cd "$WGAPPLE/Sources/WireGuardKitGo" && \
      make ARCHS=arm64 PLATFORM_NAME=macosx CONFIGURATION_BUILD_DIR="$(dirname "$LIBWG")" build version-header )
fi

# 3) 暂存需要直接编译的 C 源与头文件
#    WireGuardKitC.h 自定义了 ctl_info / sockaddr_ctl / CTLIOCGINFO（系统头在
#    新版 SDK 上标记为 unavailable），并 include 了 key.h / x25519.h，因此 Swift
#    侧所需的控制通道符号与密钥函数都从这里暴露。
mkdir -p "$STAGE"
cp "$WGAPPLE/Sources/WireGuardKitC/key.c"          "$STAGE/key.c"
cp "$WGAPPLE/Sources/WireGuardKitC/x25519.c"       "$STAGE/x25519.c"
cp "$WGAPPLE/Sources/WireGuardKitC/key.h"          "$STAGE/key.h"
cp "$WGAPPLE/Sources/WireGuardKitC/x25519.h"       "$STAGE/x25519.h"
cp "$WGAPPLE/Sources/WireGuardKitC/WireGuardKitC.h" "$STAGE/WireGuardKitC.h"
cp "$WGAPPLE/Sources/WireGuardKitGo/wireguard.h"   "$STAGE/wireguard.h"

# 4) bridging header：声明 WireGuardKitGo(wg*函数) 与 WireGuardKitC(控制通道/密钥函数)
#    <sys/types.h> 必须在 WireGuardKitC.h 之前，因为其中用到了 u_int32_t / u_char。
cat > "$STAGE/wg_bridge.h" <<'EOF'
#ifndef WG_BRIDGE_H
#define WG_BRIDGE_H
#include <sys/types.h>
#include <stdint.h>
#include <stdbool.h>
#include "wireguard.h"
#include "WireGuardKitC.h"
#endif
EOF

# 5) 收集 WireGuardKit Swift 源（去掉 Package.swift 专用入口，仅编译本仓库/扩展需要的类型）
WGKIT_SWIFT=(
    "$WGAPPLE/Sources/WireGuardKit/Array+ConcurrentMap.swift"
    "$WGAPPLE/Sources/WireGuardKit/DNSResolver.swift"
    "$WGAPPLE/Sources/WireGuardKit/DNSServer.swift"
    "$WGAPPLE/Sources/WireGuardKit/Endpoint.swift"
    "$WGAPPLE/Sources/WireGuardKit/IPAddress+AddrInfo.swift"
    "$WGAPPLE/Sources/WireGuardKit/IPAddressRange.swift"
    "$WGAPPLE/Sources/WireGuardKit/InterfaceConfiguration.swift"
    "$WGAPPLE/Sources/WireGuardKit/PacketTunnelSettingsGenerator.swift"
    "$WGAPPLE/Sources/WireGuardKit/PeerConfiguration.swift"
    "$WGAPPLE/Sources/WireGuardKit/PrivateKey.swift"
    "$WGAPPLE/Sources/WireGuardKit/TunnelConfiguration.swift"
    "$WGAPPLE/Sources/WireGuardKit/WireGuardAdapter.swift"
)

mkdir -p "$(dirname "$OUT")"
echo "编译 WGNE: target=$TARGET"

swiftc -target "$TARGET" \
    -framework NetworkExtension -framework Network -framework Foundation -framework Security \
    -import-objc-header "$STAGE/wg_bridge.h" \
    -I "$STAGE" \
    "$STAGE/key.c" "$STAGE/x25519.c" \
    "${WGKIT_SWIFT[@]}" \
    ne/main.swift ne/WGProvider.swift \
    "$LIBWG" \
    -o "$OUT"

echo "已生成: $OUT"
echo "下一步: 准备 build/profiles/*.provisionprofile 后运行 scripts/build-mac-app.sh"
