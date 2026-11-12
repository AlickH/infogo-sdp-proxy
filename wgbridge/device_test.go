package wgbridge

// 只测「内存 tun 设备 + 桥接入口」的契约，不依赖真实网络与对端。
// 目的是保证：wireguard-go 能挂上我们的设备，且裸 IP 包能双向流动。

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"strings"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/tun"
)

func ipv4Packet(payload byte) []byte {
	// 最小可辨识的 IPv4 包：版本/首部长度 + 一个载荷字节
	pkt := make([]byte, 20)
	pkt[0] = 0x45
	pkt[2], pkt[3] = 0x00, 0x14
	pkt[9] = 17
	pkt[19] = payload
	return pkt
}

func TestDeviceContract(t *testing.T) {
	var _ tun.Device = (*packetDevice)(nil)
}

func TestInboundDeliverAndRead(t *testing.T) {
	resetDevice()
	pkt := ipv4Packet(0x11)
	if err := DeliverInboundPacket(pkt); err != nil {
		t.Fatalf("DeliverInboundPacket 失败: %v", err)
	}

	buf := make([]byte, 1500)
	const offset = 16
	n, err := getDevice().Read(buf, offset)
	if err != nil {
		t.Fatalf("Read 失败: %v", err)
	}
	if n != len(pkt) {
		t.Fatalf("长度不符: got %d want %d", n, len(pkt))
	}
	if !bytes.Equal(buf[offset:offset+n], pkt) {
		t.Fatalf("内容不符")
	}
}

func TestOutboundWriteAndRead(t *testing.T) {
	resetDevice()
	pkt := ipv4Packet(0x22)
	if _, err := getDevice().Write(pkt, 0); err != nil {
		t.Fatalf("Write 失败: %v", err)
	}
	got := ReadOutboundPacket()
	if !bytes.Equal(got, pkt) {
		t.Fatalf("内容不符: got %v", got)
	}
}

func TestCloseUnblocks(t *testing.T) {
	resetDevice()
	d := getDevice()
	done := make(chan struct{})
	go func() {
		_, _ = d.Read(make([]byte, 1500), 0)
		close(done)
	}()
	time.Sleep(50 * time.Millisecond)
	_ = d.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Close 后 Read 没有返回")
	}
}

// UAPI 里的密钥是 **hex** 编码（不是 base64），这点和 wg-quick 配置不同
func randomKey() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func TestStartStopWithUAPI(t *testing.T) {
	uapi := "private_key=" + randomKey() + "\n" +
		"listen_port=0\n" +
		// 注意：不能插空行，IpcSetOperation 遇到空行就结束解析
		"public_key=" + randomKey() + "\n" +
		"allowed_ip=10.0.0.0/24\n" +
		"endpoint=127.0.0.1:51820\n"

	if err := Start(uapi); err != nil {
		t.Fatalf("Start 失败: %v", err)
	}
	gotStatus := Status()
	if gotStatus == "" {
		t.Fatal("Status 为空，设备可能没真正起来")
	}
	if !bytes.Contains([]byte(gotStatus), []byte("public_key=")) {
		t.Fatalf("peer 没被创建（UAPI 里可能混入了空行）:\n%s", gotStatus)
	}
	if err := Stop(); err != nil {
		t.Fatalf("Stop 失败: %v", err)
	}
	if got := Status(); got != "" {
		t.Fatal("Stop 后 Status 应为空")
	}
}

func TestResolveEndpoints(t *testing.T) {
	in := "private_key=abc\nendpoint=1.2.3.4:51820\nallowed_ip=10.0.0.0/24\n"
	got, err := resolveEndpoints(in)
	if err != nil {
		t.Fatalf("字面量 IP 不该报错: %v", err)
	}
	if got != in {
		t.Fatalf("字面量 IP 被改写了:\n%s", got)
	}

	got2, err := resolveEndpoints("endpoint=localhost:51820\n")
	if err != nil {
		t.Fatalf("localhost 解析失败: %v", err)
	}
	if !strings.Contains(got2, "endpoint=127.0.0.1:51820") &&
		!strings.Contains(got2, "endpoint=[::1]:51820") {
		t.Fatalf("localhost 没有被解析成 IP: %q", got2)
	}
}
