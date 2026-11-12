package tsbridge

import (
	"errors"
	"io"
	"os"
	"sync"

	"github.com/tailscale/wireguard-go/tun"
)

// 本文件实现「NEPacketTunnelFlow ↔ Tailscale 引擎」的数据面桥接。
//
// 依据（tailscale.com v1.104.5 源码）：
//   - tsnet.Server.Tun tun.Device          tsnet/tsnet.go:332-335（官方注入点，Start 前设置）
//   - tun.Device 接口                      wireguard-go/tun/tun.go:63-90（8 个方法）
//   - chanTUN 参考实现                     tsnet/tsnet_test.go:2662-2739
//   - Wrapper 出站/入站数据流               net/tstun/wrap.go:879 / 1261
//
// 注意：
//   - NEPacketTunnelFlow 交付的是**裸 IP 包**，不带 utun 的 4 字节 AF 头；
//     tun_darwin.go:224-259 才处理那 4 字节，这里不能加。
//   - Write 由 wireguard-go 每 peer 的接收协程调用，必须线程安全。
//   - 绝不能实现 IsFakeTun() bool，否则 tsd.go:148-155 会判定 onlyNetstack，
//     导致包不经过我们的 Device。

const (
	packetQueueDepth = 512
	tunnelMTU        = 1280 // tstun.DefaultTUNMTU()，与 Swift 侧 NEPacketTunnelNetworkSettings.mtu 一致
)

// packetTunnelDevice 实现 tun.Device，把 IP 包读写桥接到 Swift 侧 packetFlow。
// 它是非导出类型：tun.Device.Read 含 []tun.ReadPacket、Events() 返回 channel，
// 这些都无法被 gobind 绑定，所以只通过下面的顶层函数暴露给 Swift。
type packetTunnelDevice struct {
	in     chan []byte // Swift → Go：packetFlow.readPackets 的包，供 Read 消费
	out    chan []byte // Go → Swift：Write 产出的包，供 ReadOutboundPacket 取出
	closed chan struct{}
	events chan tun.Event
	wmu    sync.Mutex // Write 必须线程安全
	once   sync.Once
}

var (
	deviceMu  sync.Mutex
	globalDev *packetTunnelDevice
)

func getDevice() *packetTunnelDevice {
	deviceMu.Lock()
	defer deviceMu.Unlock()
	if globalDev == nil {
		globalDev = newPacketTunnelDevice()
	}
	return globalDev
}

// resetDevice 在 Stop 后丢弃已关闭的设备，保证下次 Start 拿到全新的 channel。
func resetDevice() {
	deviceMu.Lock()
	defer deviceMu.Unlock()
	globalDev = nil
}

func newPacketTunnelDevice() *packetTunnelDevice {
	d := &packetTunnelDevice{
		in:     make(chan []byte, packetQueueDepth),
		out:    make(chan []byte, packetQueueDepth),
		closed: make(chan struct{}),
		events: make(chan tun.Event, 1),
	}
	// Wrapper 要求设备上线事件，否则 Read 一直 corked（wrap.go:864-876）
	d.events <- tun.EventUp
	return d
}

// Read 阻塞等待 Swift 投递的一个裸 IP 包。
// slab 前后各需保留 tun.ReadPacketSpacing(64) 字节（wireguard-go/tun/tun.go:39-46）。
func (d *packetTunnelDevice) Read(slab []byte, packets []tun.ReadPacket) (int, error) {
	// 先做一次非阻塞检查：Close 后 in 可能仍可写，select 会随机选到写入分支
	select {
	case <-d.closed:
		return 0, io.EOF
	default:
	}
	select {
	case <-d.closed:
		return 0, io.EOF
	case pkt := <-d.in:
		if len(packets) == 0 {
			return 0, nil
		}
		off := tun.ReadPacketSpacing
		if len(slab) < off*2 {
			return 0, io.ErrShortBuffer
		}
		n := copy(slab[off:len(slab)-off], pkt)
		packets[0].Offset = off
		packets[0].Size = n
		return 1, nil
	}
}

// Write 接收引擎要发给 OS 的包。bufs[i][offset:] 是裸 IP 包
// （offset >= tstun.WritePacketStartOffset = 16）。
func (d *packetTunnelDevice) Write(bufs [][]byte, offset int) (int, error) {
	d.wmu.Lock()
	defer d.wmu.Unlock()
	select {
	case <-d.closed:
		return 0, io.EOF
	default:
	}
	for _, b := range bufs {
		if offset > len(b) {
			continue
		}
		pkt := b[offset:]
		if len(pkt) == 0 {
			continue
		}
		cp := append([]byte(nil), pkt...)
		select {
		case d.out <- cp:
		default:
			// 队列满时丢包，绝不阻塞 wireguard-go 的接收协程
		}
	}
	return len(bufs), nil
}

func (d *packetTunnelDevice) File() *os.File               { return nil }
func (d *packetTunnelDevice) MTU() (int, error)               { return tunnelMTU, nil }
func (d *packetTunnelDevice) Name() (string, error)         { return "sdp-tailscale", nil }
func (d *packetTunnelDevice) Events() <-chan tun.Event        { return d.events }
func (d *packetTunnelDevice) BatchSize() int                  { return 1 }
func (d *packetTunnelDevice) Close() error {
	d.once.Do(func() { close(d.closed) })
	return nil
}

// 编译期断言：确保实现完整（缺失方法会直接编译失败）。
var _ tun.Device = (*packetTunnelDevice)(nil)

func (d *packetTunnelDevice) deliverInbound(pkt []byte) error {
	select {
	case <-d.closed:
		return errors.New("tsbridge: device closed")
	default:
	}
	select {
	case <-d.closed:
		return errors.New("tsbridge: device closed")
	case d.in <- append([]byte(nil), pkt...):
		return nil
	default:
		return errors.New("tsbridge: inbound queue full")
	}
}

func (d *packetTunnelDevice) readOutbound() []byte {
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

// ---- 导出的 gomobile API ----

// DeliverInboundPacket 把 Swift packetFlow.readPackets 得到的裸 IP 包交给引擎
// （OS → Tailscale，出站方向）。返回 error 只表示队列状态。
func DeliverInboundPacket(pkt []byte) error {
	return getDevice().deliverInbound(pkt)
}

// ReadOutboundPacket 阻塞取出一个引擎要写给 OS 的裸 IP 包；设备关闭后返回 nil，
// Swift 侧据此退出写包循环。
func ReadOutboundPacket() []byte {
	return getDevice().readOutbound()
}
