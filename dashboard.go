package main

// 本地 Web 管理界面：状态 / 扫码登录 / 资源 / 日志

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

//go:embed ui/index.html
var indexHTML []byte

//go:embed assets/favicon.ico
var faviconICO []byte

// ---------- 日志环形缓冲 ----------

type logRing struct {
	mu    sync.Mutex
	lines []string
	max   int
}

func newLogRing(max int) *logRing { return &logRing{max: max} }

func (r *logRing) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	// 按行拆分（简单处理：追加后再截断）
	for _, ln := range splitLines(string(p)) {
		r.lines = append(r.lines, ln)
	}
	if len(r.lines) > r.max {
		r.lines = r.lines[len(r.lines)-r.max:]
	}
	return len(p), nil
}

func (r *logRing) Lines() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, len(r.lines))
	copy(out, r.lines)
	return out
}

func splitLines(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			line := s[start:i]
			if line != "" {
				out = append(out, line)
			}
			start = i + 1
		}
	}
	if start < len(s) {
		out = append(out, s[start:])
	}
	return out
}

// ---------- 登录状态机 ----------

type loginManager struct {
	mu         sync.Mutex
	state      string // idle | waiting | scanned | success | error
	url        string // 登录页地址（界面内嵌 iframe）
	ts         int64
	username   string
	errMsg     string
	running    bool
	canceled   bool
	ctx        *loginCtx
	qrPNG      []byte
	notifiedAt int64
}

func (m *loginManager) snapshot() map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	return map[string]any{
		"state":    m.state,
		"url":      m.url,
		"ts":       m.ts,
		"qr_ready": len(m.qrPNG) > 0,
		"username": m.username,
		"error":    m.errMsg,
	}
}

func (m *loginManager) update(state, url string, ts int64, username, errMsg string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.state = state
	if url != "" {
		m.url, m.ts = url, ts
	}
	if username != "" {
		m.username = username
	}
	m.errMsg = errMsg
	if state == "success" || state == "error" {
		m.running = false
	}
}

// ---------- HTTP 服务 ----------

type dashboard struct {
	cfg       *Config
	st        *State
	api       *apiClient
	deviceID  string
	cfgPath   string
	lm        *loginManager
	ring      *logRing
	autoLogin bool
	uiHits    int64
	recentMu  sync.Mutex
	recent    []string
}

func startDashboard(cfg *Config, st *State, api *apiClient, deviceID, cfgPath string, ring *logRing) {
	d := &dashboard{
		cfg: cfg, st: st, api: api, deviceID: deviceID,
		cfgPath: cfgPath, lm: &loginManager{state: "idle"}, ring: ring,
		autoLogin: true,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(indexHTML)
	})
	apiCount := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			atomic.AddInt64(&d.uiHits, 1)
			d.recentMu.Lock()
			d.recent = append(d.recent, r.URL.Path)
			if len(d.recent) > 12 {
				d.recent = d.recent[len(d.recent)-12:]
			}
			d.recentMu.Unlock()
			h(w, r)
		}
	}
	mux.HandleFunc("/api/status", apiCount(d.handleStatus))
	mux.HandleFunc("/api/login", apiCount(d.handleLogin))
	mux.HandleFunc("/api/login/refresh", apiCount(d.handleLoginRefresh))
	mux.HandleFunc("/api/login/qr", apiCount(d.handleLoginQR))
	mux.HandleFunc("/api/logout", apiCount(d.handleLogout))
	mux.HandleFunc("/api/relogin", apiCount(d.handleRelogin))
	mux.HandleFunc("/api/debug/probe", apiCount(d.handleProbe))
	mux.HandleFunc("/api/debug/reslist", apiCount(d.handleResList))
	mux.HandleFunc("/api/debug/raw", apiCount(d.handleRaw))
	mux.HandleFunc("/api/debug/discover", apiCount(d.handleDiscover))
	mux.HandleFunc("/api/debug/rawtext", apiCount(d.handleRawText))
	mux.HandleFunc("/api/login/notify", apiCount(d.handleLoginNotify))
	mux.HandleFunc("/api/login/page", apiCount(d.handleLoginPage))
	mux.HandleFunc("/api/resources", apiCount(d.handleResources))
	mux.HandleFunc("/api/logs", apiCount(d.handleLogs))
	mux.HandleFunc("/favicon.ico", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/x-icon")
		w.Header().Set("Cache-Control", "max-age=86400")
		_, _ = w.Write(faviconICO)
	})
	mux.HandleFunc("/proxy.pac", d.handlePAC)
	mux.HandleFunc("/api/sysproxy", apiCount(d.handleSysProxy))
	mux.HandleFunc("/surge.list", apiCount(d.handleRuleList))
	mux.HandleFunc("/clash.list", apiCount(d.handleRuleList))

	addr := cfg.UIListen
	if addr == "" {
		addr = "127.0.0.1:28181"
	}
	// 启动后自动进入扫码（扫码是唯一登录方式）
	go func() {
		for i := 0; i < 30; i++ {
			time.Sleep(500 * time.Millisecond)
			if d.autoLogin && st.State() == "login_required" {
				d.autoLogin = false
				log.Printf("[界面] 自动进入扫码登录")
				d.startLogin()
				return
			}
			if st.State() == "connected" {
				d.autoLogin = false
				return
			}
		}
	}()
	go func() {
		log.Printf("[界面] 管理界面: http://%s", addr)
		if err := http.ListenAndServe(addr, mux); err != nil {
			log.Printf("[界面] 启动失败: %v", err)
		}
	}()
}

func writeJSONResp(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func (d *dashboard) recentPaths() []string {
	d.recentMu.Lock()
	defer d.recentMu.Unlock()
	out := make([]string, len(d.recent))
	copy(out, d.recent)
	return out
}

func (d *dashboard) handleStatus(w http.ResponseWriter, r *http.Request) {
	d.st.mu.RLock()
	resourceCount := len(d.st.resources)
	sessionOK := d.st.sessionOK
	state := d.st.state
	username := d.st.username
	d.st.mu.RUnlock()
	writeJSONResp(w, map[string]any{
		"proxy_running":  true,
		"session_ok":     sessionOK,
		"state":          state,
		"username":       username,
		"listen":         d.cfg.Listen,
		"http_listen":    d.cfg.HTTPListen,
		"resource_count": resourceCount,
		"gateway":        d.cfg.Gateway,
		"ui_hits":        atomic.LoadInt64(&d.uiHits),
	})
}

func (d *dashboard) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		st := d.st.State()
		if st == "login_required" || st == "offline" || st == "connected" {
			d.startLogin()
		}
	}
	writeJSONResp(w, d.lm.snapshot())
}

func (d *dashboard) handleResources(w http.ResponseWriter, r *http.Request) {
	d.st.mu.RLock()
	defer d.st.mu.RUnlock()
	writeJSONResp(w, map[string]any{"resources": d.st.resources})
}

func (d *dashboard) handleLogs(w http.ResponseWriter, r *http.Request) {
	writeJSONResp(w, map[string]any{"lines": d.ring.Lines()})
}

// startLogin 启动扫码登录流程（异步）
func (d *dashboard) startLogin() {
	d.lm.mu.Lock()
	if d.lm.running {
		d.lm.mu.Unlock()
		return
	}
	d.lm.running = true
	d.lm.canceled = false
	d.lm.state = "waiting"
	d.lm.errMsg = ""
	d.lm.url = ""
	d.lm.ts = 0
	d.lm.mu.Unlock()
	prevState := d.st.State()
	d.st.SetState("scanning")

	base := d.cfg.ServerBase
	if base == "" {
		base = "https://" + d.cfg.ServerName
	}
	go func() {
		restore := func() {
			if d.st.Token() != "" {
				d.st.SetState("connected")
			} else {
				d.st.SetState("login_required")
			}
		}
		ctx, err := prepareLogin(base, d.deviceID)
		if err != nil {
			d.lm.update("error", "", 0, "", err.Error())
			restore()
			return
		}
		d.lm.mu.Lock()
		d.lm.ctx = ctx
		u, ts := ctx.qrURL()
		d.lm.url, d.lm.ts = u, ts
		d.lm.mu.Unlock()
		d.loadQRImage(u)
		log.Printf("[界面] 登录二维码已生成 (ts=%d)", ts)
		_ = prevState

		for {
			d.lm.mu.Lock()
			if d.lm.canceled {
				d.lm.running = false
				d.lm.state = "idle"
				d.lm.canceled = false
				d.lm.mu.Unlock()
				if d.st.Token() != "" {
					d.st.SetState("connected")
				} else {
					d.st.SetState("login_required")
				}
				return
			}
			// 二维码 2 分钟过期自动换新
			if time.Now().UnixMilli()-d.lm.ts > 2*60*1000 {
				nu, nts := d.lm.ctx.qrURL()
				d.lm.url, d.lm.ts = nu, nts
				d.lm.mu.Unlock()
				d.loadQRImage(nu)
				log.Printf("[界面] 二维码已自动刷新")
				time.Sleep(500 * time.Millisecond)
				continue
			}
			ts := d.lm.ts
			notifiedAt := d.lm.notifiedAt
			d.lm.mu.Unlock()

			if notifiedAt > 0 && time.Now().UnixMilli()-notifiedAt > 20*1000 {
				d.lm.mu.Lock()
				nu, nts := d.lm.ctx.qrURL()
				d.lm.url, d.lm.ts = nu, nts
				d.lm.notifiedAt = 0
				d.lm.qrPNG = nil
				d.lm.mu.Unlock()
				d.loadQRImage(nu)
				log.Printf("[扫码] 已收到页面回传但轮询未成功，已刷新二维码 (ts=%d)", nts)
				time.Sleep(500 * time.Millisecond)
				continue
			}

			if tok, user, done := ctx.pollScan(ts); done {
				d.lm.update("scanned", "", 0, user, "")
				d.st.SetState("checking")
				res, err := ctx.finish(tok, user)
				if err != nil {
					d.lm.update("error", "", 0, "", err.Error())
					restore()
					return
				}
				d.st.setToken(res.Token, parseTS(res.Timestamp))
				d.api.token = res.Token
				d.st.sessionOK = true
				if err := saveTokenString(d.cfgPath, res.Token); err != nil {
					log.Printf("[界面] 保存 token 失败: %v", err)
				}
				pol, _ := fetchPolicyResources(d.api, d.deviceID)
				rs, _ := fetchResources(d.api, d.deviceID)
				if len(pol) > 0 {
					extra := append([]Resource{}, rs...)
					extra = append(extra, d.cfg.Resources...)
					d.st.setResources(mergeResources(pol, extra))
					log.Printf("[资源] 策略表 %d 条", len(pol))
				} else if len(rs) > 0 {
					d.st.setResources(mergeResources(rs, d.cfg.Resources))
				}
				d.st.setUsername(res.UserName)
				// Windows：登录成功后若系统代理未开启且无其他代理，则启用
				if runtime.GOOS == "windows" && (d.cfg.AutoSystemProxy == nil || *d.cfg.AutoSystemProxy) {
					if !systemProxyEnabled() && !otherSystemProxyPresent() {
						if err := setSystemProxy(true); err == nil {
							log.Printf("[系统代理] 登录成功后已开启")
						}
					}
				}
				d.lm.update("success", "", 0, res.UserName, "")
				log.Printf("[界面] 扫码登录成功: %s", res.UserName)
				d.st.SetState("connected")
				return
			}
			time.Sleep(2 * time.Second)
		}
	}()
}

// handleLoginRefresh 手动刷新二维码
func (d *dashboard) handleLoginRefresh(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResp(w, map[string]any{"ok": false, "error": "method not allowed"})
		return
	}
	d.lm.mu.Lock()
	if !d.lm.running || d.lm.ctx == nil || d.lm.state != "waiting" {
		d.lm.mu.Unlock()
		writeJSONResp(w, map[string]any{"ok": false, "error": "当前不在扫码状态"})
		return
	}
	u, ts := d.lm.ctx.qrURL()
	d.lm.url, d.lm.ts = u, ts
	d.lm.qrPNG = nil
	d.lm.mu.Unlock()
	d.loadQRImage(u)
	d.lm.mu.Lock()
	ok := len(d.lm.qrPNG) > 0
	d.lm.mu.Unlock()
	log.Printf("[界面] 二维码已手动刷新")
	writeJSONResp(w, map[string]any{"ok": ok, "url": u, "ts": ts})
}

func parseTS(s string) int64 {
	var v int64
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0
		}
		v = v*10 + int64(c-'0')
	}
	return v
}

var _ = fmt.Sprintf

// handlePAC 输出 PAC 自动代理配置：内网域名/IP/CIDR 走隧道，其余直连
func (d *dashboard) handlePAC(w http.ResponseWriter, r *http.Request) {
	host, port, err := net.SplitHostPort(d.cfg.Listen)
	if err != nil {
		host, port = "127.0.0.1", "11095"
	}
	httpPort := ""
	if _, hp, err := net.SplitHostPort(d.cfg.HTTPListen); err == nil {
		httpPort = hp
	}
	proxy := "PROXY " + host + ":" + httpPort
	if httpPort == "" {
		proxy = "SOCKS5 " + host + ":" + port
	}

	d.st.mu.RLock()
	var domains, exactIPs []string
	type cidrEntry struct{ net, mask string }
	var cidrs []cidrEntry
	seen := map[string]bool{}
	for _, res := range d.st.resources {
		p := strings.TrimSpace(strings.ToLower(res.Pattern))
		if p == "" {
			continue
		}
		key := p + "|" + res.ResID
		if seen[key] {
			continue
		}
		seen[key] = true
		if strings.Contains(p, "/") {
			ip, ipnet, err := net.ParseCIDR(p)
			if err != nil || ip.To4() == nil {
				continue
			}
			ones, _ := ipnet.Mask.Size()
			cidrs = append(cidrs, cidrEntry{net: ip.To4().String(), mask: cidrMask(ones)})
			continue
		}
		if net.ParseIP(p) != nil {
			exactIPs = append(exactIPs, p)
			continue
		}
		if strings.Contains(p, "-") && strings.Count(p, ".") == 6 {
			segs := strings.SplitN(p, "-", 2)
			for _, c := range ipRangeToCIDRs(segs[0], segs[1]) {
				ip, ipnet, err := net.ParseCIDR(c)
				if err != nil || ip.To4() == nil {
					continue
				}
				ones, _ := ipnet.Mask.Size()
				cidrs = append(cidrs, cidrEntry{net: ip.To4().String(), mask: cidrMask(ones)})
			}
			continue
		}
		if strings.Contains(p, ".") {
			domains = append(domains, strings.TrimPrefix(p, "."))
		}
	}
	d.st.mu.RUnlock()

	var js strings.Builder
	js.WriteString("var DOMAINS = [" + joinQuoted(domains) + "];\n")
	js.WriteString("var IPS = [" + joinQuoted(exactIPs) + "];\n")
	var cidrPairs []string
	for _, c := range cidrs {
		cidrPairs = append(cidrPairs, "["+strconvQuote(c.net)+","+strconvQuote(c.mask)+"]")
	}
	js.WriteString("var CIDRS = [" + strings.Join(cidrPairs, ",") + "];\n\n")
	js.WriteString(`function isIPv4(h) { return /^(\d{1,3}\.){3}\d{1,3}$/.test(h); }

function FindProxyForURL(url, host) {
  host = host.toLowerCase();
  // 本机与 SDP 控制通道必须直连，避免代理回环
  if (host === "localhost" || host === "127.0.0.1") return "DIRECT";
  if (isInNet(host, "127.0.0.0", "255.0.0.0")) return "DIRECT";
  if (host === "sdp.cscec5b.com.cn") return "DIRECT";
  if (host === "app.cscec5b.com.cn") return "DIRECT";
  for (var i = 0; i < DOMAINS.length; i++) {
    var d = DOMAINS[i];
    if (host === d || (host.length > d.length && host.slice(-(d.length + 1)) === '.' + d)) {
      return "` + proxy + `";
    }
  }
  if (isIPv4(host)) {
    for (var j = 0; j < IPS.length; j++) {
      if (host === IPS[j]) return "` + proxy + `";
    }
    for (var k = 0; k < CIDRS.length; k++) {
      if (isInNet(host, CIDRS[k][0], CIDRS[k][1])) return "` + proxy + `";
    }
  }
  return "DIRECT";
}
`)
	w.Header().Set("Content-Type", "application/x-ns-proxy-autoconfig")
	_, _ = w.Write([]byte(js.String()))
}

func cidrMask(ones int) string {
	m := uint32(0)
	if ones > 0 {
		m = ^uint32(0) << (32 - ones)
	}
	return net.IPv4(byte(m>>24), byte(m>>16), byte(m>>8), byte(m)).String()
}

func joinQuoted(list []string) string {
	quoted := make([]string, 0, len(list))
	for _, s := range list {
		quoted = append(quoted, strconvQuote(s))
	}
	return strings.Join(quoted, ",")
}

func strconvQuote(s string) string { return "\"" + s + "\"" }

// handleRuleList 输出 Surge / Clash 规则订阅（由 App 资源列表自动生成）
func (d *dashboard) handleRuleList(w http.ResponseWriter, r *http.Request) {
	d.st.mu.RLock()
	var lines []string
	seen := map[string]bool{}
	for _, res := range d.st.resources {
		p := strings.TrimSpace(strings.ToLower(res.Pattern))
		if p == "" || seen[p] {
			continue
		}
		seen[p] = true
		if isExplicitDirectDomain(d.cfg, p) {
			continue // 公网入口，走直连，不进隧道规则集
		}
		switch {
		case strings.Contains(p, "/"):
			lines = append(lines, "IP-CIDR,"+p+",no-resolve")
		case strings.Contains(p, "-") && strings.Count(p, ".") == 6:
			segs := strings.SplitN(p, "-", 2)
			for _, c := range ipRangeToCIDRs(segs[0], segs[1]) {
				lines = append(lines, "IP-CIDR,"+c+",no-resolve")
			}
		case net.ParseIP(p) != nil:
			lines = append(lines, "IP-CIDR,"+p+"/32,no-resolve")
		default:
			if strings.Contains(p, ".") {
				lines = append(lines, "DOMAIN-SUFFIX,"+strings.TrimPrefix(p, "."))
			}
		}
	}
	d.st.mu.RUnlock()

	header := "# 由 SDP 代理自动生成（资源列表实时同步）\n" +
		"# Surge:  RULE-SET,http://127.0.0.1:28181/surge.list,CSCEC,no-resolve\n" +
		"# Clash:  rule-provider 指向 http://127.0.0.1:28181/clash.list (behavior: classical)\n" +
		"# 注意: sdp.cscec5b.com.cn 为控制通道, 需在规则集之前 DIRECT\n"
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(header + strings.Join(lines, "\n") + "\n"))
}

// handleSysProxy 查询/切换系统代理
func (d *dashboard) handleSysProxy(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		var body struct {
			Enable bool `json:"enable"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if err := setSystemProxy(body.Enable); err != nil {
			writeJSONResp(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSONResp(w, map[string]any{"ok": true, "enabled": systemProxyEnabled()})
		return
	}
	writeJSONResp(w, map[string]any{"enabled": systemProxyEnabled()})
}

// loadQRImage 抓取登录页二维码图片
func (d *dashboard) loadQRImage(pageURL string) {
	png, err := fetchLoginQR(pageURL)
	d.lm.mu.Lock()
	defer d.lm.mu.Unlock()
	if err != nil {
		d.lm.qrPNG = nil
		d.lm.errMsg = "二维码获取失败: " + err.Error()
		log.Printf("[界面] 二维码获取失败: %v", err)
		return
	}
	d.lm.qrPNG = png
	d.lm.errMsg = ""
}

// handleLoginQR 返回二维码 PNG
func (d *dashboard) handleLoginQR(w http.ResponseWriter, r *http.Request) {
	d.lm.mu.Lock()
	png := d.lm.qrPNG
	d.lm.mu.Unlock()
	if len(png) == 0 {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(png)
}

// handleRelogin 退出并重新扫码：清 token → 关系统代理 → 立刻出新二维码
func (d *dashboard) handleRelogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResp(w, map[string]any{"ok": false, "error": "method not allowed"})
		return
	}
	// 1) 取消当前扫码流程
	d.lm.mu.Lock()
	d.lm.canceled = true
	d.lm.running = false
	d.lm.state = "idle"
	d.lm.url = ""
	d.lm.ts = 0
	d.lm.qrPNG = nil
	d.lm.username = ""
	d.lm.notifiedAt = 0
	d.lm.mu.Unlock()
	// 2) 关闭系统代理
	if systemProxyEnabled() {
		_ = setSystemProxy(false)
	}
	// 3) 清 token
	d.st.setToken("", 0)
	d.st.mu.Lock()
	d.st.sessionOK = false
	d.st.mu.Unlock()
	_ = saveTokenString(d.cfgPath, "")
	d.api.token = ""
	d.st.SetState("login_required")
	log.Printf("[退出] 已断开连接，准备重新扫码")
	// 4) 立刻开始新的扫码
	d.startLogin()
	writeJSONResp(w, map[string]any{"ok": true})
}

// handleLogout 断开连接（清 token、关系统代理、回到未登录）
func (d *dashboard) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResp(w, map[string]any{"ok": false, "error": "method not allowed"})
		return
	}
	// 1) 取消进行中的登录
	d.lm.mu.Lock()
	d.lm.canceled = true
	d.lm.running = false
	d.lm.state = "idle"
	d.lm.url = ""
	d.lm.ts = 0
	d.lm.qrPNG = nil
	d.lm.username = ""
	d.lm.mu.Unlock()

	// 2) 关闭系统代理（避免断网）
	if systemProxyEnabled() {
		if err := setSystemProxy(false); err != nil {
			log.Printf("[退出] 关闭系统代理失败: %v", err)
		}
	}

	// 3) 清空 token
	d.st.setToken("", 0)
	d.st.mu.Lock()
	d.st.sessionOK = false
	d.st.mu.Unlock()
	if err := saveTokenString(d.cfgPath, ""); err != nil {
		log.Printf("[退出] 清除 token 失败: %v", err)
	}
	d.api.token = ""
	d.st.SetState("login_required")
	log.Printf("[退出] 已断开连接")
	writeJSONResp(w, map[string]any{"ok": true})
}
