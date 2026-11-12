#!/bin/bash
# 用 gomobile 把 wgbridge/ 里的 WireGuard Go 桥接包编译成 macOS xcframework。
#
# 产物导出 Start / Stop / Status / DeliverInboundPacket / ReadOutboundPacket / Version，
# 让 wireguard-go 可以挂在一个**内存 tun 设备**上，不再依赖真实 utun fd。
# 这是「三个隧道合并成一个系统扩展」的前置条件。
#
# 前置：go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${WGBRIDGE_XCFWK:-Vendor/Wgbridge.xcframework}"
TARGET="${TARGET:-macos}"
GOBIN_DIR="$(go env GOPATH)/bin"

case "$OUT" in
    /*) ;;
    *) OUT="$PWD/$OUT" ;;
esac

if ! command -v gomobile >/dev/null 2>&1 && [ ! -x "$GOBIN_DIR/gomobile" ]; then
    cat >&2 <<'EOF'
未找到 gomobile，请先执行：
  go install golang.org/x/mobile/cmd/gomobile@latest
  export PATH="$(go env GOPATH)/bin:$PATH"
  gomobile init
EOF
    exit 1
fi
export PATH="$GOBIN_DIR:$PATH"

cd wgbridge
if ! grep -q "cmd/gobind" go.mod; then
    go get -tool golang.org/x/mobile/cmd/gobind
fi
go mod tidy

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

rm -rf "$OUT"
echo "编译 Wgbridge: target=$TARGET deployment=$MACOSX_DEPLOYMENT_TARGET"
gomobile bind -target="$TARGET" -o "$OUT" wgbridge

echo "已生成: $OUT"
du -sh "$OUT"
echo "Swift 模块名: Wgbridge"
