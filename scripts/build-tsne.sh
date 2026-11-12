#!/bin/bash
# 编译 TSNE（Tailscale Packet Tunnel 系统扩展）可执行体。
#
# 宿主层源码在本仓库（ne/main.swift + ne/TSProvider.swift）；引擎适配层由
# TS_BRIDGE_SRC 指定，需构建方自行实现 TailscaleRuntime（见 README「构建依赖」）。
# 未提供 TS_BRIDGE_SRC 时仍会编译出只含宿主层的 TSNE，可用于自检，
# 但运行时会明确报 engineNotEmbedded，不会伪装成已连接。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TSNE_BIN:-/tmp/ne-build/TSNE}"
TARGET="${TARGET:-arm64-apple-macosx13.0}"
BRIDGE="${TS_BRIDGE_SRC:-}"
FWK="${TS_BRIDGE_FWK:-}"

SRCS=(ne/main.swift ne/TSProvider.swift)
# 用普通字符串而不是数组，兼容 macOS 自带 bash 3.2 + set -u 的空数组行为
DEFS=""
if [ -n "$BRIDGE" ]; then
    if [ ! -f "$BRIDGE" ]; then
        echo "TS_BRIDGE_SRC 指定的文件不存在: $BRIDGE" >&2
        exit 1
    fi
    SRCS+=("$BRIDGE")
    DEFS="-D TS_HAS_BRIDGE"
fi

# 可选：链接 scripts/build-tsbridge.sh 产出的 Tsbridge.xcframework。
# 提供 framework 时必须同时提供调用它的 Swift 适配层（TS_BRIDGE_SRC）。
FWK_FLAGS=""
if [ -n "$FWK" ]; then
    if [ -z "$BRIDGE" ]; then
        echo "提供 TS_BRIDGE_FWK 时也必须指定 TS_BRIDGE_SRC（例如 Tools/TSBridgeRuntime.swift）" >&2
        exit 1
    fi
    SLICE="$FWK/macos-arm64_x86_64"
    if [ ! -d "$SLICE" ]; then
        echo "TS_BRIDGE_FWK 缺少 macos-arm64_x86_64 切片: $FWK" >&2
        exit 1
    fi
    FWK_FLAGS="-F $SLICE -framework Tsbridge"
fi

mkdir -p "$(dirname "$OUT")"
echo "编译 TSNE: target=$TARGET"
echo "  源码: ${SRCS[*]}"
if [ -z "$BRIDGE" ]; then
    echo "  警告: 未提供 TS_BRIDGE_SRC，产物只含宿主层，运行时会报 engineNotEmbedded" >&2
fi

swiftc -target "$TARGET" $DEFS $FWK_FLAGS \
    -framework NetworkExtension -framework Network \
    "${SRCS[@]}" -o "$OUT"

echo "已生成: $OUT"
echo "下一步: 准备 build/profiles/*.provisionprofile 后运行 scripts/build-mac-app.sh"
