package wgbridge

// 本文件实现「内存 tun 设备」：让 wireguard-go 不依赖真实 utun 文件描述符。
//
// 为什么需要它：
//   - wireguard-go 官方入口 `wgTurnOn(settings, tun_fd)` 只接受**真实 utun fd**，
//     WireGuardAdapter 甚至是靠扫描 fd 0~1024 找 com.apple.net.utun_control 来定位的。
//   - 想把 WireGuard 并进「一个系统扩展 + 一个 packet flow + 内部分类器」的架构，
//     就必须能像 hev / tsnet 那样，用内存队列把裸 IP 包喂给引擎。
//
// 参考：同仓库 tsbridge/packetdevice.go（tsnet 版本，接口是 Tailscale 的 fork），
// 这里用的是上游 golang.zx2c4.com/wireguard，tun.Device 的 Read 签名不同。

import (
	"errors"
	"io"
	"os"
	"sync"

	"golang.zx2c4.com/wireguard/tun"
)

const (
	packetQueueDepth = 512
	// 与 Swift 侧 NEPacketTunnelNetworkSettings.mtu 保持一致
	tunnelMTU = 1420
)

// packetDevice 实现 tun.Device，把 IP 包读写桥接到 Swift 侧的分类器。
// 非导出：tun.Device 的 Read 含切片参数、Events 返回 channel，gobind 无法绑定，
// 因此只通过 bridge.go 里的顶层函数暴露给 Swift。
type packetDevice struct {
	in     chan []byte // Swift → Go：待加密发送的包，供 Read 消费
	out    chan []byte // Go → Swift：已解密的包，供 ReadOutboundPacket 取出
	closed chan struct{}
	events chan tun.Event
	wmu    sync.Mutex
	once   sync.Once
}

var (
	deviceMu  sync.Mutex
	globalDev *packetDevice
)

func getDevice() *packetDevice {
	deviceMu.Lock()
	defer deviceMu.Unlock()
	if globalDev == nil {
		globalDev = newPacketDevice()
	}
	return globalDev
}

func resetDevice() {
	deviceMu.Lock()
	defer deviceMu.Unlock()
	globalDev = nil
}

func newPacketDevice() *packetDevice {
	d := &packetDevice{
		in:     make(chan []byte, packetQueueDepth),
		out:    make(chan []byte, packetQueueDepth),
		closed: make(chan struct{}),
		events: make(chan tun.Event, 1),
	}
	// wireguard-go 会等设备上线事件，否则不会开始收发
	d.events <- tun.EventUp
	return d
}

// Read 阻塞等待 Swift 投递的一个裸 IP 包（待加密）。
// 注意：该版本 wireguard-go 的 tun.Device 是单包接口（Read([]byte, int)）。
func (d *packetDevice) Read(buf []byte, offset int) (int, error) {
	// 先做一次非阻塞检查：Close 后 in 可能仍可写，select 会随机选中写入分支
	select {
	case <-d.closed:
		return 0, io.EOF
	default:
	}
	var pkt []byte
	select {
	case <-d.closed:
		return 0, io.EOF
	case pkt = <-d.in:
	}
	n := copy(buf[offset:], pkt)
	if n < len(pkt) {
		return 0, errors.New("wgbridge: read buffer too small")
	}
	return n, nil
}

// Write 由 wireguard-go 的接收协程调用，必须线程安全。
func (d *packetDevice) Write(buf []byte, offset int) (int, error) {
	d.wmu.Lock()
	defer d.wmu.Unlock()
	select {
	case <-d.closed:
		return 0, io.EOF
	default:
	}
	pkt := append([]byte(nil), buf[offset:]...)
	if len(pkt) == 0 {
		return 0, nil
	}
	select {
	case d.out <- pkt:
		return len(pkt), nil
	default:
		// 队列满：丢弃单包，不阻塞 wireguard-go 的接收协程
		return 0, nil
	}
}

func (d *packetDevice) File() *os.File             { return nil }
func (d *packetDevice) MTU() (int, error)          { return tunnelMTU, nil }
func (d *packetDevice) Name() (string, error)      { return "sdp-wireguard", nil }
func (d *packetDevice) Events() <-chan tun.Event   { return d.events }
// Flush 在批量写之后被调用；内存队列是即写即入，无需额外动作。
func (d *packetDevice) Flush() error               { return nil }

func (d *packetDevice) Close() error {
	d.once.Do(func() {
		close(d.closed)
		close(d.events)
	})
	return nil
}

// ---- 导出的数据面 API ----

// DeliverInboundPacket 把分类器交过来的裸 IP 包放进「待加密」队列。
func DeliverInboundPacket(pkt []byte) error {
	d := getDevice()
	select {
	case <-d.closed:
		return errors.New("wgbridge: device closed")
	default:
	}
	select {
	case d.in <- append([]byte(nil), pkt...):
		return nil
	case <-d.closed:
		return errors.New("wgbridge: device closed")
	default:
		return errors.New("wgbridge: inbound queue full")
	}
}

// ReadOutboundPacket 阻塞取出一个已解密的裸 IP 包；设备关闭后返回 nil。
func ReadOutboundPacket() []byte {
	d := getDevice()
	select {
	case <-d.closed:
		return nil
	default:
	}
	select {
	case <-d.closed:
		return nil
	case pkt := <-d.out:
		return pkt
	}
}
