// Package tsbridge 把 tailscale.com/tsnet 封装成 gomobile 可绑定的极简 API。
//
// gobind 只能绑定签名里含基本类型（string/bool/int，加可选 error）的函数，
// 直接 bind tailscale.com/tsnet 会因复杂类型（多返回值方法、map/interface 字段）
// 报错甚至 panic。所以这里所有辅助结构体都保持非导出，只导出
// 「string 进 / string 出」的函数；状态以 JSON 字符串传递，字段与
// macapp/TSManager.swift 的 TSRuntimeStatus / TSPeer 严格对齐。
//
// 数据面：packetdevice.go 实现 tun.Device 并注入 tsnet.Server.Tun，
// 由 Swift 侧 NEPacketTunnelFlow 通过 DeliverInboundPacket / ReadOutboundPacket
// 双向搬运裸 IP 包。
//
// 构建：scripts/build-tsbridge.sh（gomobile bind -target=macos）。
package tsbridge

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// config 是 Start 的入参（JSON）。保持非导出，避免 gobind 生成 ObjC 类型。
type config struct {
	Hostname   string `json:"hostname"`
	AuthKey    string `json:"authKey"`
	ControlURL string `json:"controlURL"`
	StateDir   string `json:"stateDir"`
	Ephemeral  bool   `json:"ephemeral"`
}

// runtimeStatus / peer 与 App 侧 TSRuntimeStatus / TSPeer 字段一一对应。
type runtimeStatus struct {
	BackendState string   `json:"backendState"`
	SelfIPs      []string `json:"selfIPs"`
	AuthURL      string   `json:"authURL"`
	Tailnet      string   `json:"tailnet"`
	Peers        []peer   `json:"peers"`
	RxBytes      int64    `json:"rxBytes"`
	TxBytes      int64    `json:"txBytes"`
	Error        string   `json:"error,omitempty"`
}

type peer struct {
	Name   string `json:"name"`
	IP     string `json:"ip"`
	Online bool   `json:"online"`
	Direct bool   `json:"direct"`
	OS     string `json:"os"`
	Relay  string `json:"relay"`
}

var (
	mu     sync.Mutex
	server *tsnet.Server
)

func emptyStatus() runtimeStatus {
	return runtimeStatus{
		BackendState: "Stopped",
		SelfIPs:      []string{},
		Peers:        []peer{},
	}
}

func encode(st runtimeStatus) string {
	b, err := json.Marshal(st)
	if err != nil {
		return `{"backendState":"Stopped","selfIPs":[],"authURL":"","tailnet":"","peers":[],"rxBytes":0,"txBytes":0,"error":"encode failed"}`
	}
	return string(b)
}

// Version 返回桥接层版本，便于 Swift 侧确认 framework 已链接。
func Version() string {
	return "tsbridge/0.1.0 (tailscale.com v1.104.5)"
}

// Start 启动 tsnet 节点。configJSON 是 config 的 JSON 编码，空串表示全部用默认值。
// 对应 TailscaleRuntime.start。
func Start(configJSON string) error {
	mu.Lock()
	defer mu.Unlock()
	if server != nil {
		return nil
	}
	var c config
	if configJSON != "" {
		if err := json.Unmarshal([]byte(configJSON), &c); err != nil {
			return fmt.Errorf("tsbridge: invalid config: %w", err)
		}
	}
	// Tun 必须在 Start 之前设置（tsnet.go:332-335）。设置后 tsnet 会改用
	// 真实 packet tunnel 数据面，而不是纯 userspace netstack；同时
	// CheckLocalTransportEndpoints=true（tsnet.go:930），路由/DNS 由 Swift
	// 的 NEPacketTunnelNetworkSettings 配置。
	s := &tsnet.Server{
		Hostname:   c.Hostname,
		AuthKey:    c.AuthKey,
		ControlURL: c.ControlURL,
		Dir:        c.StateDir,
		Ephemeral:  c.Ephemeral,
		Tun:        getDevice(),
	}
	if err := s.Start(); err != nil {
		return fmt.Errorf("tsbridge: tsnet start: %w", err)
	}
	server = s
	return nil
}

// Stop 关闭节点，对应 TailscaleRuntime.stop。
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return nil
	}
	err := server.Close()
	server = nil
	// 设备关闭后 channel 不可复用，下次 Start 需要一套新的
	resetDevice()
	return err
}

// Status 返回运行时状态 JSON，对应 TailscaleRuntime.statusJSON。
func Status() string {
	mu.Lock()
	s := server
	mu.Unlock()
	st := emptyStatus()
	if s == nil {
		return encode(st)
	}
	lc, err := s.LocalClient()
	if err != nil {
		st.Error = err.Error()
		return encode(st)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	raw, err := lc.Status(ctx)
	if err != nil {
		st.Error = err.Error()
		return encode(st)
	}
	return encode(convert(raw))
}

// Logout 清除登录态，对应 TSMessageRouter 的 "logout" 消息。
func Logout() error {
	lc, err := currentClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return lc.Logout(ctx)
}

// LoginInteractive 触发交互式登录，控制面随后会在 Status 里给出 authURL。
func LoginInteractive() error {
	lc, err := currentClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return lc.StartLoginInteractive(ctx)
}

func currentClient() (*local.Client, error) {
	mu.Lock()
	s := server
	mu.Unlock()
	if s == nil {
		return nil, fmt.Errorf("tsbridge: not started")
	}
	return s.LocalClient()
}

func convert(raw *ipnstate.Status) runtimeStatus {
	st := emptyStatus()
	if raw == nil {
		return st
	}
	st.BackendState = raw.BackendState
	st.AuthURL = raw.AuthURL
	st.Tailnet = raw.MagicDNSSuffix
	for _, ip := range raw.TailscaleIPs {
		st.SelfIPs = append(st.SelfIPs, ip.String())
	}
	for _, p := range raw.Peer {
		if p == nil {
			continue
		}
		ip := ""
		if len(p.TailscaleIPs) > 0 {
			ip = p.TailscaleIPs[0].String()
		}
		name := strings.TrimSuffix(p.DNSName, ".")
		if name == "" {
			name = p.HostName
		}
		st.Peers = append(st.Peers, peer{
			Name:   name,
			IP:     ip,
			Online: p.Online,
			Direct: p.CurAddr != "" && p.Relay == "",
			OS:     p.OS,
			Relay:  p.Relay,
		})
		st.RxBytes += p.RxBytes
		st.TxBytes += p.TxBytes
	}
	return st
}
