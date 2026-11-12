package tsbridge

import (
	"bytes"
	"io"
	"sync"
	"testing"

	"github.com/tailscale/wireguard-go/tun"
)

// 一个最小裸 IPv4 包（NEPacketTunnelFlow 交付的格式，无 utun 4 字节 AF 头）
func ipv4Packet(payload byte) []byte {
	return []byte{
		0x45, 0x00, 0x00, 0x15, // version/IHL, TOS, total length
		0x00, 0x00, 0x40, 0x00, // id, flags/frag
		0x40, 0x11, 0x00, 0x00, // TTL, UDP, checksum
		100, 64, 0, 7, // src 100.64.0.7
		100, 64, 0, 8, // dst 100.64.0.8
		payload,
	}
}

func TestDeviceContract(t *testing.T) {
	d := newPacketTunnelDevice()
	defer d.Close()

	if mtu, _ := d.MTU(); mtu != 1280 {
		t.Fatalf("MTU = %d, want 1280", mtu)
	}
	if name, _ := d.Name(); name == "" {
		t.Fatal("Name() must not be empty")
	}
	if d.BatchSize() != 1 {
		t.Fatalf("BatchSize = %d, want 1", d.BatchSize())
	}
	if d.File() != nil {
		t.Fatal("File() must be nil for a packetFlow-backed device")
	}
	select {
	case ev := <-d.Events():
		if ev != tun.EventUp {
			t.Fatalf("first event = %v, want EventUp", ev)
		}
	default:
		t.Fatal("missing EventUp (Wrapper.Read would stay corked)")
	}
	// tsd.go:148-155 会把带 IsFakeTun() 的设备判定为 onlyNetstack
	if _, ok := any(d).(interface{ IsFakeTun() bool }); ok {
		t.Fatal("device must NOT implement IsFakeTun")
	}
}

func TestInboundDeliverAndRead(t *testing.T) {
	d := newPacketTunnelDevice()
	defer d.Close()

	pkt := ipv4Packet(0xAB)
	if err := d.deliverInbound(pkt); err != nil {
		t.Fatal(err)
	}
	slab := make([]byte, 2048)
	packets := make([]tun.ReadPacket, 1)
	n, err := d.Read(slab, packets)
	if err != nil || n != 1 {
		t.Fatalf("Read n=%d err=%v", n, err)
	}
	if packets[0].Offset != tun.ReadPacketSpacing {
		t.Fatalf("Offset = %d, want %d", packets[0].Offset, tun.ReadPacketSpacing)
	}
	if packets[0].Size != len(pkt) {
		t.Fatalf("Size = %d, want %d", packets[0].Size, len(pkt))
	}
	got := slab[packets[0].Offset : packets[0].Offset+packets[0].Size]
	if !bytes.Equal(got, pkt) {
		t.Fatal("inbound packet content mismatch")
	}
}

func TestOutboundWriteAndRead(t *testing.T) {
	d := newPacketTunnelDevice()
	defer d.Close()

	pkt := ipv4Packet(0xCD)
	const offset = 16 // tstun.WritePacketStartOffset
	buf := make([]byte, offset+len(pkt))
	copy(buf[offset:], pkt)
	n, err := d.Write([][]byte{buf}, offset)
	if err != nil || n != 1 {
		t.Fatalf("Write n=%d err=%v", n, err)
	}
	out := d.readOutbound()
	if !bytes.Equal(out, pkt) {
		t.Fatal("outbound packet mismatch (must be a bare IP packet)")
	}
}

func TestCloseUnblocks(t *testing.T) {
	d := newPacketTunnelDevice()
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	slab := make([]byte, 2048)
	packets := make([]tun.ReadPacket, 1)
	if _, err := d.Read(slab, packets); err != io.EOF {
		t.Fatalf("Read after Close = %v, want io.EOF", err)
	}
	if got := d.readOutbound(); got != nil {
		t.Fatalf("readOutbound after Close = %v, want nil", got)
	}
	if err := d.deliverInbound(ipv4Packet(1)); err == nil {
		t.Fatal("deliverInbound after Close should fail")
	}
}

// Write 会被 wireguard-go 的多个接收协程并发调用
func TestConcurrentWrite(t *testing.T) {
	d := newPacketTunnelDevice()
	defer d.Close()

	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			pkt := ipv4Packet(0x01)
			buf := make([]byte, 16+len(pkt))
			copy(buf[16:], pkt)
			_, _ = d.Write([][]byte{buf}, 16)
		}()
	}
	wg.Wait()
}
