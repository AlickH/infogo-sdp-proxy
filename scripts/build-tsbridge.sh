#!/bin/bash
# 用 gomobile 把 tsbridge/ 里的 Tailscale Go 桥接包编译成 macOS xcframework。
#
# 产物内含 tailscale.com/tsnet 的控制面 + userspace 数据面，导出
# TsbridgeStart / Stop / Status / Logout / LoginInteractive / Version。
# 前置：go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TSBRIDGE_XCFWK:-/tmp/Tsbridge.xcframework}"
TARGET="${TARGET:-macos}"
GOBIN_DIR="$(go env GOPATH)/bin"

# 相对路径转成基于项目根目录的绝对路径（后面会 cd 到 tsbridge/）
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

cd tsbridge
if ! grep -q "cmd/gobind" go.mod; then
    go get -tool golang.org/x/mobile/cmd/gobind
fi
go mod tidy

# 让 Go/CGO 产物与 App 的部署目标一致，避免链接时出现
# "built for newer macOS version (27.2) than being linked (13.0)" 警告
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

rm -rf "$OUT"
echo "编译 Tsbridge: target=$TARGET deployment=$MACOSX_DEPLOYMENT_TARGET"
gomobile bind -target="$TARGET" -o "$OUT" tsbridge

echo "已生成: $OUT"
du -sh "$OUT"
echo "Swift 模块名: Tsbridge（头文件见 \$OUT/macos-arm64_x86_64/Tsbridge.framework/Headers/Tsbridge.objc.h）"
