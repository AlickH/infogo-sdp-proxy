// sdp-proxy: 盈高零信任 SDP 纯 SOCKS5 代理客户端
//
// 协议（逆向所得）：
//
//	TLS 连接网关 → SOCKS5 协商 05 01 80 → 认证 80|len|token|len|resid
//	→ CONNECT 05 01 00 <addr> <00><len><base64(JSON)> → 裸字节流
package main

import (
	"crypto/tls"
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed default_config.json
var defaultConfigJSON []byte

type Resource struct {
	Pattern string `json:"domain"`          // 域名后缀 / IP / CIDR
	ResID   string `json:"resid"`           // 资源 ID
	Ports   string `json:"ports,omitempty"` // 端口限制（如 "443" / "80/24-3300"），空表示不限
}

type Config struct {
	Gateway    string `json:"gateway"`     // 网关地址（逗号分隔多个）
	ServerName string `json:"server_name"` // TLS SNI
	ServerBase string `json:"server_base"` // 服务端地址, 如 https://sdp.cscec5b.com.cn:17441
	DeviceID   string `json:"device_id"`   // 设备 ID（登录用）
	Token      string `json:"token"`       // 登录 token
	TokenFile  string `json:"token_file"`  // 从文件读取 token（可选）
	Listen     string `json:"listen"`      // 本地监听
	UIListen   string `json:"ui_listen"`   // 管理界面监听
	HTTPListen string `json:"http_listen"` // HTTP 代理监听（系统代理用）
	// FallbackDirect 为 true（默认）时，未匹配资源的域名直接连接
	FallbackDirect *bool `json:"fallback_direct"`
	// AutoSystemProxy 为 true（默认）时，无其他系统代理则自动开启（仅 Windows）
	AutoSystemProxy *bool      `json:"auto_system_proxy"`
	Resources       []Resource `json:"resources"`
	// LearnedResources 自动发现的域名→资源 ID 映射
	LearnedResources map[string]string `json:"learned_resources,omitempty"`
	// DirectDomains 不需要走隧道、直接连公网入口的域名（后缀匹配）
	DirectDomains []string `json:"direct_domains,omitempty"`
}

// openAppWindow 打开管理界面：Windows 用 Edge 应用模式（无地址栏），其他平台用默认浏览器
func openAppWindow(u string) {
	switch runtime.GOOS {
	case "windows":
		// 直接定位 Edge，避免 cmd.exe 弹控制台窗口
		paths := []string{
			`C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe`,
			`C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe`,
		}
		for _, p := range paths {
			if _, err := os.Stat(p); err == nil {
				cmd := exec.Command(p, "--app="+u)
				hideWindow(cmd)
				if cmd.Start() == nil {
					return
				}
			}
		}
		// 退回默认浏览器（rundll32 是 GUI 程序，不会闪控制台）
		cmd := exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
		hideWindow(cmd)
		_ = cmd.Start()
	case "darwin":
		_ = exec.Command("open", u).Start()
	default:
		_ = exec.Command("xdg-open", u).Start()
	}
}

// alreadyRunning 检测管理界面是否已在运行（单实例）
func alreadyRunning(addr string) bool {
	conn, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// safeGo 运行 goroutine 并捕获 panic（GUI 模式否则静默崩溃）
func safeGo(name string, fn func()) {
	go func() {
		defer func() {
			if r := recover(); r != nil {
				msg := name + " 崩溃: " + fmt.Sprint(r)
				log.Printf("%s\n%s", msg, debug.Stack())
				fatalBox(msg + "\n详情见日志: app.log")
			}
		}()
		fn()
	}()
}

func main() {
	cfgPath := flag.String("config", "", "配置文件路径（默认用户配置目录）")
	openUI := flag.Bool("open-ui", true, "启动后打开管理界面")
	loginFlag := flag.Bool("login", false, "先执行二维码登录")
	noBrowser := flag.Bool("no-browser", false, "不自动打开浏览器")
	flag.Parse()

	// 配置文件路径：未指定时用用户配置目录
	path := *cfgPath
	if path == "" {
		dir, err := os.UserConfigDir()
		if err != nil {
			dir = "."
		}
		dir = filepath.Join(dir, "sdp-proxy")
		_ = os.MkdirAll(dir, 0700)
		path = filepath.Join(dir, "config.json")
	}
	*cfgPath = path
	activeCfgPath = path

	raw, err := os.ReadFile(path)
	if err != nil {
		// 首次运行：写入内置默认配置
		if werr := os.WriteFile(path, defaultConfigJSON, 0600); werr != nil {
			msg := "创建配置失败: " + werr.Error()
			log.Printf("%s", msg)
			fatalBox(msg)
			return
		}
		raw = defaultConfigJSON
		log.Printf("已创建默认配置: %s", path)
	}
	var cfg Config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		msg := "解析配置失败: " + err.Error()
		log.Printf("%s", msg)
		fatalBox(msg)
		return
	}
	if cfg.Listen == "" {
		cfg.Listen = "127.0.0.1:11081"
	}
	if cfg.UIListen == "" {
		cfg.UIListen = "127.0.0.1:28181"
	}
	if cfg.HTTPListen == "" {
		cfg.HTTPListen = "127.0.0.1:11096"
	}
	if cfg.FallbackDirect == nil {
		t := true
		cfg.FallbackDirect = &t
	}
	if cfg.ServerName == "" {
		cfg.ServerName = "sdp.cscec5b.com.cn"
	}
	// 登录模式
	if *loginFlag {
		deviceID := cfg.DeviceID
		if deviceID == "" {
			deviceID = "888499"
		}
		base := cfg.ServerBase
		if base == "" {
			base = "https://" + cfg.ServerName
		}
		res, err := doLogin(base, deviceID, !*noBrowser)
		if err != nil {
			msg := "登录失败: " + err.Error()
			log.Printf("%s", msg)
			fatalBox(msg)
			return
		}
		if err := saveTokenToConfig(*cfgPath, res); err != nil {
			msg := "保存配置失败: " + err.Error()
			log.Printf("%s", msg)
			fatalBox(msg)
			return
		}
		cfg.Token = res.Token
		if cfg.Gateway == "" {
			log.Fatal("登录成功，但配置缺少 gateway，无法启动代理")
		}
	}

	if cfg.Gateway == "" {
		log.Printf("配置缺少 gateway")
		fatalBox("配置缺少 gateway: " + path)
		return
	}
	if cfg.Token == "" && cfg.TokenFile == "" {
		log.Printf("尚未登录，请打开界面扫码登录")
	}

	// 初始化运行时状态
	token, err := cfg.currentToken()
	if err != nil {
		log.Printf("暂无有效 token: %v", err)
		token = ""
	}
	st := &State{token: token, resources: cfg.Resources, sessionOK: token != ""}
	if token == "" {
		st.SetState("login_required")
	}

	deviceID := cfg.DeviceID
	if deviceID == "" {
		deviceID = "888499"
	}
	base := cfg.ServerBase
	if base == "" {
		base = "https://" + cfg.ServerName
	}
	api := newAPIClient(base)
	api.token = token
	if token == "" {
		st.SetState("login_required")
	} else {
		st.SetState("connecting")
		go func() {
			ok, err := checkSession(api, st, deviceID, *cfgPath)
			if err != nil || !ok {
				st.mu.Lock()
				st.sessionOK = false
				st.mu.Unlock()
				st.SetState("login_required")
				if err != nil {
					log.Printf("[会话] 初始检查失败: %v", err)
				} else {
					log.Printf("[会话] 已过期，需要重新登录")
				}
				return
			}
			st.mu.Lock()
			st.sessionOK = true
			st.mu.Unlock()
			st.SetState("connected")
		}()
	}
	for dom, rid := range cfg.LearnedResources {
		builtinResources = append(builtinResources, Resource{Pattern: dom, ResID: rid})
	}
	startRefreshers(api, st, deviceID, *cfgPath, cfg.Resources)

	ring := newLogRing(300)
	// Windows GUI 程序没有有效的 stderr，MultiWriter 会在首个错误处停止，
	// 因此把文件/内存放前面，stderr 放最后
	writers := []io.Writer{ring}
	logFile, logErr := os.OpenFile(filepath.Join(filepath.Dir(path), "app.log"),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if logErr == nil && logFile != nil {
		writers = append(writers, logFile)
	}
	writers = append(writers, os.Stderr)
	log.SetOutput(io.MultiWriter(writers...))

	// Windows：单实例 + WebView2 原生窗口（窗口属于本进程，图标/关闭行为都是原生的）
	if runtime.GOOS == "windows" {
		enableDPIAwareness()
	}
	if runtime.GOOS == "windows" && *openUI {
		if alreadyRunning(cfg.UIListen) {
			log.Printf("程序已在运行，尝试激活现有窗口")
			activateExistingWindow()
			return
		}
		ready := make(chan struct{})
		go serve(&cfg, st, api, deviceID, *cfgPath, ring, ready)
		select {
		case <-ready:
		case <-time.After(15 * time.Second):
			log.Printf("[界面] 服务启动超时")
		}
		uiURL := "http://" + cfg.UIListen + "/"
		if runNativeWindow(uiURL, filepath.Dir(path)) {
			// 窗口关闭 → 退出应用（恢复系统代理）
			cleanupAndExit()
		}
		log.Printf("[界面] WebView2 不可用，退回浏览器窗口并保持后台运行")
		openAppWindow(uiURL)
		select {}
	}

	serve(&cfg, st, api, deviceID, *cfgPath, ring, nil)
}

// serve 启动代理与界面（ready 非空时在就绪后关闭）
func serve(cfg *Config, st *State, api *apiClient, deviceID, cfgPath string, ring *logRing, ready chan<- struct{}) {
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		msg := "启动失败: " + err.Error()
		log.Printf("%s", msg)
		fatalBox(msg)
		return
	}
	log.Printf("SOCKS5 代理已启动: %s -> %s", cfg.Listen, cfg.Gateway)
	go startHTTPProxy(cfg, st)
	startTray(func() {
		if !activateExistingWindow() {
			openAppWindow("http://" + cfg.UIListen + "/")
		}
	})
	startDashboard(cfg, st, api, deviceID, cfgPath, ring)

	// Windows：没有其他系统代理时，默认自动开启
	if runtime.GOOS == "windows" && (cfg.AutoSystemProxy == nil || *cfg.AutoSystemProxy) {
		if systemProxyEnabled() {
			log.Printf("[系统代理] 已是本程序，保持开启")
		} else if otherSystemProxyPresent() {
			log.Printf("[系统代理] 检测到其他代理软件的系统代理，不自动开启")
		} else if err := setSystemProxy(true); err != nil {
			log.Printf("[系统代理] 自动开启失败: %v", err)
		} else {
			log.Printf("[系统代理] 未检测到其他系统代理，已自动开启")
		}
	}

	if ready != nil {
		close(ready)
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go handle(conn, cfg, st)
	}
}

// ---------- SOCKS5 服务端 ----------

func handle(conn net.Conn, cfg *Config, st *State) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))

	// 1) 握手：05 nmethods methods
	hdr := make([]byte, 2)
	if _, err := io.ReadFull(conn, hdr); err != nil || hdr[0] != 0x05 {
		return
	}
	methods := make([]byte, hdr[1])
	if _, err := io.ReadFull(conn, methods); err != nil {
		return
	}
	if _, err := conn.Write([]byte{0x05, 0x00}); err != nil { // 无需认证
		return
	}

	// 2) 请求：VER CMD RSV ATYP ADDR PORT
	req := make([]byte, 4)
	if _, err := io.ReadFull(conn, req); err != nil || req[0] != 0x05 {
		return
	}
	if req[1] != 0x01 { // 仅支持 CONNECT
		_, _ = conn.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	var host string
	switch req[3] {
	case 0x01:
		b := make([]byte, 4)
		if _, err := io.ReadFull(conn, b); err != nil {
			return
		}
		host = net.IP(b).String()
	case 0x03:
		l := make([]byte, 1)
		if _, err := io.ReadFull(conn, l); err != nil {
			return
		}
		b := make([]byte, l[0])
		if _, err := io.ReadFull(conn, b); err != nil {
			return
		}
		host = string(b)
	case 0x04:
		b := make([]byte, 16)
		if _, err := io.ReadFull(conn, b); err != nil {
			return
		}
		host = net.IP(b).String()
	default:
		return
	}
	pb := make([]byte, 2)
	if _, err := io.ReadFull(conn, pb); err != nil {
		return
	}
	port := binary.BigEndian.Uint16(pb)

	token := st.Token()
	if token == "" {
		log.Printf("[拒绝] %s:%d 无法获取 token", host, port)
		_, _ = conn.Write([]byte{0x05, 0x02, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	if isDirectDomain(cfg, host) {
		up, err := dialDirect(host, port)
		if err != nil {
			log.Printf("[直连失败] %s:%d: %v", host, port, err)
			return
		}
		log.Printf("[直连] %s:%d (公网入口)", host, port)
		relay(conn, up)
		return
	}
	resid := st.ResIDPort(host, port)
	if resid == "" {
		if cfg.FallbackDirect != nil && *cfg.FallbackDirect {
			directHandle(conn, host, port)
			return
		}
		log.Printf("[拒绝] %s:%d 没有匹配的资源 ID", host, port)
		_, _ = conn.Write([]byte{0x05, 0x02, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	up, err := dialGateway(cfg, token, host, port, resid)
	if err != nil && needDiscover(err) && !st.HostKnown(host) {
		if newResid := discoverResID(cfg, st, host, port); newResid != "" {
			log.Printf("[资源] %s 发现可用资源 resid=%s（已缓存）", host, newResid)
			learnResource(cfg, st, host, newResid)
			up, err = dialGateway(cfg, token, host, port, newResid)
			if err == nil {
				resid = newResid
			}
		}
	}
	if err != nil {
		log.Printf("[失败] %s:%d resid=%s: %v", host, port, resid, err)
		_, _ = conn.Write([]byte{0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer up.Close()

	// 回复成功
	if _, err := conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}
	_ = conn.SetDeadline(time.Time{})
	log.Printf("[连接] %s:%d (resid=%s)", host, port, resid)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(up, conn)
		if c, ok := up.(interface{ CloseWrite() error }); ok {
			_ = c.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(conn, up)
		if c, ok := conn.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	wg.Wait()
}

// ---------- 网关隧道 ----------

func (c *Config) currentToken() (string, error) {
	if c.TokenFile == "" {
		if c.Token == "" {
			return "", fmt.Errorf("配置中没有 token")
		}
		return c.Token, nil
	}
	raw, err := os.ReadFile(c.TokenFile)
	if err != nil {
		return "", err
	}
	re := regexp.MustCompile(`Token=([0-9a-fA-F]{16,})`)
	m := re.FindSubmatch(raw)
	if m == nil {
		return "", fmt.Errorf("文件中未找到 Token")
	}
	return string(m[1]), nil
}

func dialGateway(cfg *Config, token, host string, port uint16, resid string) (net.Conn, error) {
	var lastErr error
	for _, gw := range strings.Split(cfg.Gateway, ",") {
		gw = strings.TrimSpace(gw)
		if gw == "" {
			continue
		}
		conn, err := dialOneGateway(gw, cfg.ServerName, token, host, port, resid)
		if err == nil {
			return conn, nil
		}
		lastErr = err
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("没有可用网关")
	}
	return nil, lastErr
}

func dialOneGateway(gwAddr, serverName, token, host string, port uint16, resid string) (net.Conn, error) {
	return dialOneGatewayEx(gwAddr, serverName, token, host, port, resid, false)
}

// dialOneGatewayEx useIP=true 时用 IPv4 地址发起 CONNECT（资源按 IP 段授权的情况）
func dialOneGatewayEx(gwAddr, serverName, token, host string, port uint16, resid string, useIP bool) (net.Conn, error) {
	raw, err := net.DialTimeout("tcp", gwAddr, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("连接网关失败: %w", err)
	}
	tlsConn := tls.Client(raw, &tls.Config{
		InsecureSkipVerify: true,
		ServerName:         serverName,
		MinVersion:         tls.VersionTLS12,
	})
	_ = tlsConn.SetDeadline(time.Now().Add(15 * time.Second))
	if err := tlsConn.Handshake(); err != nil {
		raw.Close()
		return nil, fmt.Errorf("TLS 握手失败: %w", err)
	}

	// 1) greeting
	if _, err := tlsConn.Write([]byte{0x05, 0x01, 0x80}); err != nil {
		tlsConn.Close()
		return nil, err
	}
	buf := make([]byte, 2)
	if _, err := io.ReadFull(tlsConn, buf); err != nil || buf[0] != 0x05 || buf[1] != 0x80 {
		tlsConn.Close()
		return nil, fmt.Errorf("greeting 失败: %x", buf)
	}

	// 2) auth: 80 | len(token) | token | len(resid) | resid
	tokenB := []byte(token)
	residB := []byte(resid)
	auth := make([]byte, 0, 2+len(tokenB)+1+len(residB))
	auth = append(auth, 0x80, byte(len(tokenB)))
	auth = append(auth, tokenB...)
	auth = append(auth, byte(len(residB)))
	auth = append(auth, residB...)
	if _, err := tlsConn.Write(auth); err != nil {
		tlsConn.Close()
		return nil, err
	}
	if _, err := io.ReadFull(tlsConn, buf); err != nil || buf[0] != 0x80 {
		tlsConn.Close()
		return nil, fmt.Errorf("认证失败: %x", buf)
	}

	// 3) CONNECT：域名 + info 块
	infoJSON, _ := json.Marshal(map[string]any{
		"version": 1,
		"data": map[string]string{
			"client_ip":    localIP(),
			"process_name": "isaproxy",
			"os":           "linux",
		},
	})
	info := base64.StdEncoding.EncodeToString(infoJSON)

	req := make([]byte, 0, 16+len(host)+len(info))
	if useIP {
		ip := net.ParseIP(host).To4()
		if ip == nil {
			tlsConn.Close()
			return nil, fmt.Errorf("非 IPv4 地址: %s", host)
		}
		req = append(req, 0x05, 0x01, 0x00, 0x01)
		req = append(req, ip...)
	} else {
		req = append(req, 0x05, 0x01, 0x00, 0x03, byte(len(host)))
		req = append(req, []byte(host)...)
	}
	req = append(req, byte(port>>8), byte(port))
	req = append(req, 0x00, byte(len(info)))
	req = append(req, []byte(info)...)
	if _, err := tlsConn.Write(req); err != nil {
		tlsConn.Close()
		return nil, err
	}
	rep := make([]byte, 4)
	if _, err := io.ReadFull(tlsConn, rep); err != nil {
		tlsConn.Close()
		return nil, fmt.Errorf("CONNECT 响应读取失败: %w", err)
	}
	if rep[1] != 0x00 {
		tlsConn.Close()
		return nil, fmt.Errorf("CONNECT 被拒绝: %x", rep)
	}
	// 读掉地址与端口
	switch rep[3] {
	case 0x01:
		io.ReadFull(tlsConn, make([]byte, 4))
	case 0x03:
		l := make([]byte, 1)
		io.ReadFull(tlsConn, l)
		io.ReadFull(tlsConn, make([]byte, l[0]))
	case 0x04:
		io.ReadFull(tlsConn, make([]byte, 16))
	}
	io.ReadFull(tlsConn, make([]byte, 2))

	_ = tlsConn.SetDeadline(time.Time{})
	return tlsConn, nil
}

func localIP() string {
	// 取到网关路由的本机 IP（网关记录 client_ip）
	conn, err := net.Dial("udp", "122.191.10.77:80")
	if err != nil {
		return "0.0.0.0"
	}
	defer conn.Close()
	if a, ok := conn.LocalAddr().(*net.UDPAddr); ok {
		return a.IP.String()
	}
	return "0.0.0.0"
}

// directHandle 未匹配资源的域名：直接连接（配合 PAC 实现"内网走隧道、其余直连"）
func directHandle(conn net.Conn, host string, port uint16) {
	addr := net.JoinHostPort(host, strconv.Itoa(int(port)))
	up, err := net.DialTimeout("tcp", addr, 10*time.Second)
	if err != nil {
		log.Printf("[直连失败] %s: %v", addr, err)
		_, _ = conn.Write([]byte{0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer up.Close()
	if _, err := conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}
	_ = conn.SetDeadline(time.Time{})
	log.Printf("[直连] %s", addr)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(up, conn)
		if c, ok := up.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(conn, up)
		if c, ok := conn.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	wg.Wait()
}
