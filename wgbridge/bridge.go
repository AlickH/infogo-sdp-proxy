package wgbridge

// 导出给 Swift 的入口。对标 tsbridge/bridge.go 的设计：
// 只暴露 gobind 能绑定的类型（string / []byte / error）。

import (
	"fmt"
	"log"
	"sync"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

var (
	mu      sync.Mutex
	dev     *device.Device
	version = "0.0.1"
)

// Start 用 UAPI 配置启动 WireGuard 设备。
//
// uapi 格式（与 wgTurnOn 的 settings 完全一致）。
// 注意：密钥是 **hex** 编码，不是 wg-quick 里的 base64。
//
//	private_key=<hex>
//	listen_port=0
//	public_key=<hex>
//	allowed_ip=10.0.0.0/24
//	endpoint=host:port
//	persistent_keepalive_interval=25
func Start(uapi string) error {
	mu.Lock()
	defer mu.Unlock()

	if dev != nil {
		dev.Close()
		dev = nil
	}
	resetDevice()

	d := getDevice()
	logger := &device.Logger{
		Verbosef: func(format string, args ...any) {
			logf("[wg] "+format, args...)
		},
		Errorf: func(format string, args ...any) {
			logf("[wg] ERROR "+format, args...)
		},
	}

	dev = device.NewDevice(d, conn.NewStdNetBind(), logger)
	if err := dev.IpcSet(uapi); err != nil {
		dev.Close()
		dev = nil
		return fmt.Errorf("wgbridge: IpcSet 失败: %w", err)
	}
	dev.Up()
	logf("[wg] 设备已启动")
	return nil
}

// Stop 关闭设备并丢弃内存队列。
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if dev != nil {
		dev.Close()
		dev = nil
	}
	resetDevice()
	logf("[wg] 设备已停止")
	return nil
}

// Status 返回 wireguard-go 的运行时配置（UAPI 格式）。
// 其中 last_handshake_time_sec / rx_bytes / tx_bytes 可用于判断连通性。
func Status() string {
	mu.Lock()
	d := dev
	mu.Unlock()
	if d == nil {
		return ""
	}
	s, err := d.IpcGet()
	if err != nil {
		return ""
	}
	return s
}

// Version 返回桥接层版本，用于启动时打日志确认链接成功。
func Version() string {
	return version
}

// 日志走标准 log（写到 stderr）。gobind 无法绑定 func 参数，
// 所以不做 Swift 侧注入；需要更细的日志时由 Swift 层自己记录。
func logf(format string, args ...any) {
	log.Printf("[wgbridge] "+format, args...)
}
