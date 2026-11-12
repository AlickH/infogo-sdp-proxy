package tsbridge

// WireGuard 引擎的导出入口。与 tailscale 引擎同包，
// 由同一个 gomobile bind 产出一个 framework —— 否则两个 framework
// 各自的 cgo 运行时会产生 __cgo_topofstack / crosscall2 等重复符号。
//
// 只暴露 gobind 能绑定的类型（string / []byte / error）。

import (
	"fmt"
	"log"
	"net"
	"strings"
	"sync"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

var (
	wgMu      sync.Mutex
	wgDev     *device.Device
	wgVersion = "0.0.2"
)

// WgStart 用 UAPI 配置启动 WireGuard 设备。
//
// 注意：密钥是 **hex** 编码，不是 wg-quick 里的 base64。
//
//	private_key=<hex>
//	listen_port=0
//	public_key=<hex>
//	allowed_ip=10.0.0.0/24
//	endpoint=host:port
//	persistent_keepalive_interval=25
func WgStart(uapi string) error {
	wgMu.Lock()
	defer wgMu.Unlock()

	if wgDev != nil {
		wgDev.Close()
		wgDev = nil
	}
	wgResetDevice()

	d := wgGetDevice()
	logger := &device.Logger{
		Verbosef: func(format string, args ...any) { wgLogf("[wg] "+format, args...) },
		Errorf:   func(format string, args ...any) { wgLogf("[wg] ERROR "+format, args...) },
	}

	resolved, err := wgResolveEndpoints(uapi)
	if err != nil {
		return err
	}
	wgDev = device.NewDevice(d, conn.NewStdNetBind(), logger)
	if err := wgDev.IpcSet(resolved); err != nil {
		wgDev.Close()
		wgDev = nil
		return fmt.Errorf("tsbridge/wg: IpcSet 失败: %w", err)
	}
	wgDev.Up()
	wgLogf("[wg] 设备已启动")
	return nil
}

// WgStop 关闭设备并丢弃内存队列。
func WgStop() error {
	wgMu.Lock()
	defer wgMu.Unlock()
	if wgDev != nil {
		wgDev.Close()
		wgDev = nil
	}
	wgResetDevice()
	wgLogf("[wg] 设备已停止")
	return nil
}

// WgStatus 返回 wireguard-go 的运行时配置（UAPI 格式）。
// 其中 last_handshake_time_sec / rx_bytes / tx_bytes 可用于判断连通性。
func WgStatus() string {
	wgMu.Lock()
	d := wgDev
	wgMu.Unlock()
	if d == nil {
		return ""
	}
	s, err := d.IpcGet()
	if err != nil {
		return ""
	}
	return s
}

func WgVersion() string { return wgVersion }

// wgResolveEndpoints 把 UAPI 里 `endpoint=域名:端口` 的域名预先解析成 IP。
//
// wireguard-go 的 StdNetBind.ParseEndpoint 内部是 netip.ParseAddrPort，
// **只接受 IP 字面量**，传域名会报
// `ParseAddr("663407.xyz"): IPv4 field has value >255`。
// WireGuardKit 原本在 Swift 侧用 getaddrinfo 做了这件事，换到内存桥接后要补上。
func wgResolveEndpoints(uapi string) (string, error) {
	lines := strings.Split(uapi, "\n")
	for i, line := range lines {
		if !strings.HasPrefix(line, "endpoint=") {
			continue
		}
		hostPort := strings.TrimPrefix(line, "endpoint=")
		host, port, err := net.SplitHostPort(hostPort)
		if err != nil || net.ParseIP(host) != nil {
			continue
		}
		ips, err := net.LookupIP(host)
		if err != nil {
			return "", fmt.Errorf("tsbridge/wg: 解析 endpoint %q 失败: %w", host, err)
		}
		var chosen net.IP
		for _, ip := range ips {
			if ip.To4() != nil {
				chosen = ip
				break
			}
		}
		if chosen == nil && len(ips) > 0 {
			chosen = ips[0]
		}
		if chosen == nil {
			return "", fmt.Errorf("tsbridge/wg: endpoint %q 没有解析结果", host)
		}
		lines[i] = "endpoint=" + net.JoinHostPort(chosen.String(), port)
		wgLogf("[wg] endpoint %s → %s", hostPort, lines[i])
	}
	return strings.Join(lines, "\n"), nil
}

// WireGuard 的日志缓冲区。
//
// gobind 无法绑定 func 参数，而 stderr 在 NetworkExtension 里完全不可见
// （扩展进程的 stderr 没有任何接收方）。把日志留在内存里，由 Swift 侧
// 定期取走写进诊断文件，否则 WireGuard 握手失败的真正原因永远看不到。
var (
	wgLogMu    sync.Mutex
	wgLogLines []string
)

const wgLogLimit = 400

// gobind 无法绑定 func 参数，日志写 stderr 的同时进内存缓冲。
func wgLogf(format string, args ...any) {
	line := fmt.Sprintf("[tsbridge/wg] "+format, args...)
	log.Print(line)

	wgLogMu.Lock()
	defer wgLogMu.Unlock()
	wgLogLines = append(wgLogLines, line)
	if len(wgLogLines) > wgLogLimit {
		wgLogLines = wgLogLines[len(wgLogLines)-wgLogLimit:]
	}
}

// WgDrainLog 取出自上次调用以来累积的日志（取走即清空）。
func WgDrainLog() string {
	wgLogMu.Lock()
	defer wgLogMu.Unlock()
	if len(wgLogLines) == 0 {
		return ""
	}
	out := strings.Join(wgLogLines, "\n")
	wgLogLines = wgLogLines[:0]
	return out
}
