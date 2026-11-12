package tsbridge

// 本文件实现 WireGuard 的「内存 tun 设备」（与 tsnet 的设备同包共存）：让 wireguard-go 不依赖真实 utun 文件描述符。
//
// 为什么需要它：
//   - wireguard-go 官方入口 `wgTurnOn(settings, tun_fd)` 只接受**真实 utun fd**，
//     WireGuardAdapter 甚至是靠扫描 fd 0~1024 找 com.apple.net.utun_control 来定位的。
//   - 想把 WireGuard 并进「一个系统扩展 + 一个 packet flow + 内部分类器」的架构，
//     就必须能像 hev / tsnet 那样，用内存队列把裸 IP 包喂给引擎。
//
// 参考：同仓库 tsbridge/packetdevice.go（tsnet 版本，接口是 Tailscale 的 fork），
// 这里用的是上游 golang.zx2c4.com/wireguard，wgTun.Device 的 Read 签名不同。

import (
	"errors"
	"io"
	"os"
	"sync"

	wgTun "golang.zx2c4.com/wireguard/tun"
)

const (
	wgQueueDepth = 512
	// 与 Swift 侧 NEPacketTunnelNetworkSettings.mtu 保持一致
	wgTunnelMTU = 1420
)

// wgPacketDevice 实现 wgTun.Device，把 IP 包读写桥接到 Swift 侧的分类器。
// 非导出：wgTun.Device 的 Read 含切片参数、Events 返回 channel，gobind 无法绑定，
// 因此只通过 bridge.go 里的顶层函数暴露给 Swift。
type wgPacketDevice struct {
	in     chan []byte // Swift → Go：待加密发送的包，供 Read 消费
	out    chan []byte // Go → Swift：已解密的包，供 WgReadOutboundPacket 取出
	closed chan struct{}
	events chan wgTun.Event
	wmu    sync.Mutex
	once   sync.Once
}

var (
	wgDeviceMu  sync.Mutex
	wgGlobalDev *wgPacketDevice
)

func wgGetDevice() *wgPacketDevice {
	wgDeviceMu.Lock()
	defer wgDeviceMu.Unlock()
	if wgGlobalDev == nil {
		wgGlobalDev = newWgPacketDevice()
	}
	return wgGlobalDev
}

func wgResetDevice() {
	wgDeviceMu.Lock()
	defer wgDeviceMu.Unlock()
	wgGlobalDev = nil
}

func newWgPacketDevice() *wgPacketDevice {
	d := &wgPacketDevice{
		in:     make(chan []byte, wgQueueDepth),
		out:    make(chan []byte, wgQueueDepth),
		closed: make(chan struct{}),
		events: make(chan wgTun.Event, 1),
	}
	// wireguard-go 会等设备上线事件，否则不会开始收发
	d.events <- wgTun.EventUp
	return d
}

// Read 阻塞等待 Swift 投递的一个裸 IP 包（待加密）。
// 当前 wireguard-go 的 tun.Device 是批量接口；BatchSize() 返回 1，
// 所以每次只会读写 bufs[0]。
func (d *wgPacketDevice) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
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
	if len(bufs) == 0 || len(sizes) == 0 {
		return 0, errors.New("sdbridge: empty read buffers")
	}
	n := copy(bufs[0][offset:], pkt)
	sizes[0] = n
	return 1, nil
}

// Write 由 wireguard-go 的接收协程调用，必须线程安全。
func (d *wgPacketDevice) Write(bufs [][]byte, offset int) (int, error) {
	d.wmu.Lock()
	defer d.wmu.Unlock()
	select {
	case <-d.closed:
		return 0, io.EOF
	default:
	}
	count := 0
	for _, buf := range bufs {
		pkt := append([]byte(nil), buf[offset:]...)
		if len(pkt) == 0 {
			continue
		}
		select {
		case d.out <- pkt:
			count++
		default:
			// 队列满：丢弃单包，不阻塞 wireguard-go 的接收协程
		}
	}
	return count, nil
}

func (d *wgPacketDevice) File() *os.File             { return nil }
func (d *wgPacketDevice) MTU() (int, error)          { return wgTunnelMTU, nil }
func (d *wgPacketDevice) Name() (string, error)      { return "sdp-wireguard", nil }
func (d *wgPacketDevice) Events() <-chan wgTun.Event { return d.events }
func (d *wgPacketDevice) BatchSize() int             { return 1 }

func (d *wgPacketDevice) Close() error {
	d.once.Do(func() {
		close(d.closed)
		close(d.events)
	})
	return nil
}

// ---- 导出的数据面 API ----

// WgDeliverInboundPacket 把分类器交过来的裸 IP 包放进「待加密」队列。
func WgDeliverInboundPacket(pkt []byte) error {
	d := wgGetDevice()
	select {
	case <-d.closed:
		return errors.New("sdbridge: device closed")
	default:
	}
	select {
	case d.in <- append([]byte(nil), pkt...):
		return nil
	case <-d.closed:
		return errors.New("sdbridge: device closed")
	default:
		return errors.New("sdbridge: inbound queue full")
	}
}

// WgReadOutboundPacket 阻塞取出一个已解密的裸 IP 包；设备关闭后返回 nil。
func WgReadOutboundPacket() []byte {
	d := wgGetDevice()
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
