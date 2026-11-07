package main

// 运行时状态：token 自动续期 + 资源列表自动刷新

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

type State struct {
	mu        sync.RWMutex
	token     string
	timestamp int64
	resources []Resource
	sessionOK bool
	state     string // login_required | scanning | checking | connected | offline
	username  string
	lastErr   string
}

// SetState 更新界面状态（渲染层状态机）
func (s *State) SetState(state string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state = state
}

// SetStateIfNotBusy 仅在非登录流程中时更新状态
func (s *State) SetStateIfNotBusy(state string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state == "scanning" || s.state == "checking" {
		return
	}
	s.state = state
}

func (s *State) State() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state
}

func (s *State) setUsername(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.username = name
}

func (s *State) Username() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.username
}

func (s *State) Token() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.token
}

func (s *State) setToken(token string, ts int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.token = token
	if ts > s.timestamp {
		s.timestamp = ts
	}
}

func (s *State) setResources(res []Resource) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.resources = res
}

// ResID 匹配：域名后缀 / 精确 IP / CIDR
func (s *State) ResIDPort(host string, port uint16) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	host = strings.ToLower(strings.TrimSpace(host))
	ip := net.ParseIP(host)
	best, bestLen := "", -1
	for _, r := range s.resources {
		p := strings.ToLower(r.Pattern)
		if p == "" {
			continue
		}
		if !portAllowed(r.Ports, port) {
			continue
		}
		if ip != nil && strings.Contains(p, "-") && !strings.Contains(p, "/") {
			// IP 段: a-b
			if segs := strings.SplitN(p, "-", 2); len(segs) == 2 {
				lo := net.ParseIP(strings.TrimSpace(segs[0])).To4()
				hi := net.ParseIP(strings.TrimSpace(segs[1])).To4()
				if lo != nil && hi != nil {
					ip4 := ip.To4()
					if ip4 != nil && bytes.Compare(ip4, lo) >= 0 && bytes.Compare(ip4, hi) <= 0 {
						return r.ResID
					}
				}
			}
			continue
		}
		if ip != nil && strings.Contains(p, "/") {
			if _, cidr, err := net.ParseCIDR(p); err == nil && cidr.Contains(ip) {
				return r.ResID
			}
			continue
		}
		if ip != nil && p == host {
			return r.ResID
		}
		if strings.HasPrefix(p, ".") {
			if strings.HasSuffix(host, p) && len(p) > bestLen {
				bestLen, best = len(p), r.ResID
			}
		} else if strings.Contains(p, ".") && (host == p || strings.HasSuffix(host, "."+p)) {
			if len(p) > bestLen {
				bestLen, best = len(p), r.ResID
			}
		}
	}
	return best
}

// HostKnown 域名是否在资源表中有精确条目（含后缀通配）
func (s *State) HostKnown(host string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	host = strings.ToLower(strings.TrimSpace(host))
	for _, r := range s.resources {
		p := strings.ToLower(strings.TrimSpace(r.Pattern))
		if p == "" {
			continue
		}
		if p == host {
			return true
		}
		if strings.HasPrefix(p, ".") && strings.HasSuffix(host, p) {
			return true
		}
	}
	return false
}

// portAllowed 检查端口是否在资源允许范围内
func portAllowed(spec string, port uint16) bool {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return true
	}
	for _, part := range strings.FieldsFunc(spec, func(r rune) bool { return r == '/' || r == ',' }) {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if strings.Contains(part, "-") {
			segs := strings.SplitN(part, "-", 2)
			lo, e1 := strconv.Atoi(strings.TrimSpace(segs[0]))
			hi, e2 := strconv.Atoi(strings.TrimSpace(segs[1]))
			if e1 == nil && e2 == nil && int(port) >= lo && int(port) <= hi {
				return true
			}
			continue
		}
		if v, err := strconv.Atoi(part); err == nil && v == int(port) {
			return true
		}
	}
	return false
}

func (s *State) ResID(host string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	host = strings.ToLower(strings.TrimSpace(host))
	ip := net.ParseIP(host)
	best, bestLen := "", -1
	for _, r := range s.resources {
		p := strings.ToLower(r.Pattern)
		if p == "" {
			continue
		}
		if ip != nil && strings.Contains(p, "-") && !strings.Contains(p, "/") {
			// IP 段: a-b
			if segs := strings.SplitN(p, "-", 2); len(segs) == 2 {
				lo := net.ParseIP(strings.TrimSpace(segs[0])).To4()
				hi := net.ParseIP(strings.TrimSpace(segs[1])).To4()
				if lo != nil && hi != nil {
					ip4 := ip.To4()
					if ip4 != nil && bytes.Compare(ip4, lo) >= 0 && bytes.Compare(ip4, hi) <= 0 {
						return r.ResID
					}
				}
			}
			continue
		}
		if ip != nil && strings.Contains(p, "/") {
			if _, cidr, err := net.ParseCIDR(p); err == nil && cidr.Contains(ip) {
				return r.ResID
			}
			continue
		}
		if ip != nil && p == host {
			return r.ResID
		}
		if strings.HasPrefix(p, ".") {
			if strings.HasSuffix(host, p) && len(p) > bestLen {
				bestLen, best = len(p), r.ResID
			}
		} else if strings.Contains(p, ".") && (host == p || strings.HasSuffix(host, "."+p)) {
			if len(p) > bestLen {
				bestLen, best = len(p), r.ResID
			}
		}
	}
	return best
}

// checkSession 查询会话状态，必要时续期 token
func checkSession(api *apiClient, st *State, deviceID, cfgPath string) (bool, error) {
	var data struct {
		SessionStatus  string `json:"SessionStatus"`
		Token          string `json:"Token"`
		TokenTimestamp int64  `json:"TokenTimestamp"`
		UserName       string `json:"userName"`
	}
	r, err := api.call("POST", "/access/1.0/linux/json/device/netStatus", map[string]string{
		"deviceId": deviceID,
	})
	if err != nil {
		return false, err
	}
	if r.ErrCode != "0" {
		return false, fmt.Errorf("%s %s", r.ErrCode, r.ErrMsg)
	}
	if err := json.Unmarshal(r.Data, &data); err != nil {
		return false, err
	}
	if data.UserName != "" && data.UserName != st.Username() {
		st.setUsername(data.UserName)
	}
	if data.Token != "" && data.Token != st.Token() {
		st.setToken(data.Token, data.TokenTimestamp)
		api.token = data.Token
		log.Printf("[会话] Token 已续期")
		_ = saveTokenString(cfgPath, data.Token)
	}
	// netStatus 不校验 token，这里用资源接口确认 token 是否仍有效
	tr, terr := api.call("POST", "/access/1.0/linux/json/ztpResource/list", map[string]string{
		"deviceid": deviceID, "listType": "0", "queryStr": "",
	})
	tokenValid := true
	if terr == nil && tr.ErrCode == "21120055" {
		tokenValid = false
	}
	sessionOK := data.SessionStatus == "0" || data.SessionStatus == "8"
	return sessionOK && tokenValid, nil
}

// startRefreshers: 定期检查会话状态、续期 token、刷新资源
func startRefreshers(api *apiClient, st *State, deviceID, cfgPath string, baseResources []Resource) {
	go func() {
		// 资源每 10 分钟刷新
		refreshRes := func() {
			if st.Token() == "" {
				return
			}
			pol, polErr := fetchPolicyResources(api, deviceID)
			res, err := fetchResources(api, deviceID)
			if polErr == nil && len(pol) > 0 {
				extra := append([]Resource{}, res...)
				extra = append(extra, baseResources...)
				st.setResources(mergeResources(pol, extra))
				log.Printf("[资源] 策略表 %d 条（含域名/IP 映射）", len(pol))
			} else if err == nil && len(res) > 0 {
				st.setResources(mergeResources(res, baseResources))
				log.Printf("[资源] 已刷新 %d 条", len(res))
			} else if err != nil {
				log.Printf("[资源] 刷新失败: %v", err)
			}
		}
		refreshRes()
		ticker := time.NewTicker(10 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			refreshRes()
		}
	}()

	go func() {
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		lastStatus := ""
		for range ticker.C {
			if st.Token() == "" {
				continue
			}
			ok, err := checkSession(api, st, deviceID, cfgPath)
			if err != nil {
				log.Printf("[会话] 状态检查失败: %v", err)
				continue
			}
			st.mu.Lock()
			st.sessionOK = ok
			st.mu.Unlock()
			if ok {
				if lastStatus != "ok" {
					log.Printf("[会话] 正常")
				}
				lastStatus = "ok"
				st.SetStateIfNotBusy("connected")
			} else {
				if lastStatus != "expired" {
					log.Printf("[会话] 已过期，请重新登录")
				}
				lastStatus = "expired"
				st.SetStateIfNotBusy("offline")
			}
		}
	}()
}

// builtinDirectDomains 走公网入口、不需要隧道的域名
var builtinDirectDomains = []string{"app.cscec5b.com.cn"}

// dnsCache 域名→IP 缓存（10 分钟）
var (
	dnsCacheMu sync.Mutex
	dnsCache   = map[string]dnsEntry{}
)

type dnsEntry struct {
	ip string
	at time.Time
}

// isPublicEntry 判断域名是否解析到 SDP 公网入口（122.191.10.x）
func isPublicEntry(host string) bool {
	dnsCacheMu.Lock()
	if e, ok := dnsCache[host]; ok && time.Since(e.at) < 10*time.Minute {
		dnsCacheMu.Unlock()
		return strings.HasPrefix(e.ip, "122.191.10.")
	}
	dnsCacheMu.Unlock()
	ip, err := resolveRealIP(host)
	if err != nil {
		return false
	}
	dnsCacheMu.Lock()
	dnsCache[host] = dnsEntry{ip: ip, at: time.Now()}
	dnsCacheMu.Unlock()
	return strings.HasPrefix(ip, "122.191.10.")
}

// isExplicitDirectDomain 只看显式名单（不做 DNS，供规则生成使用）
func isExplicitDirectDomain(cfg *Config, host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	all := append(append([]string{}, builtinDirectDomains...), cfg.DirectDomains...)
	for _, d := range all {
		d = strings.ToLower(strings.TrimSpace(d))
		if d == "" {
			continue
		}
		if host == d || strings.HasSuffix(host, "."+d) {
			return true
		}
	}
	return false
}

// isDirectDomain 判断域名是否应直接连接
func isDirectDomain(cfg *Config, host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	all := append(append([]string{}, builtinDirectDomains...), cfg.DirectDomains...)
	for _, d := range all {
		d = strings.ToLower(strings.TrimSpace(d))
		if d == "" {
			continue
		}
		if host == d || strings.HasSuffix(host, "."+d) {
			return true
		}
	}
	// 解析到 SDP 公网入口的域名也直连（如 app.cscec5b.com.cn）
	return isPublicEntry(host)
}

// builtinResources 内置已知资源映射（服务端列表不返回的子域）
var builtinResources = []Resource{
	{Pattern: "bip.cscec5b.com.cn", ResID: "135", Ports: "443,8001,20558"},
	{Pattern: "oa.cscec5b.com.cn", ResID: "241", Ports: "443"},
	{Pattern: "oa.cscec5b.com.cn", ResID: "194", Ports: "9443"},
	{Pattern: "portal.cscec5b.com.cn", ResID: "244", Ports: "80,24-3300,4000-65534"},
	{Pattern: "erp.hnzjdc.com", ResID: "191", Ports: "9010-9023"},
}

// mergeResources 合并并去重（按 pattern+resid）
func mergeResources(primary, extra []Resource) []Resource {
	seen := map[string]bool{}
	var out []Resource
	for _, list := range [][]Resource{builtinResources, primary, extra} {
		for _, r := range list {
			key := r.Pattern + "|" + r.ResID + "|" + r.Ports
			if seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, r)
		}
	}
	return out
}

// fetchResources 调 ztpResource/list，解析出域名/IP → ResID
func fetchResources(api *apiClient, deviceID string) ([]Resource, error) {
	r, err := api.call("POST", "/access/1.0/linux/json/ztpResource/list", map[string]string{
		"deviceid": deviceID, "listType": "0", "queryStr": "",
	})
	if err != nil {
		return nil, err
	}
	if r.ErrCode != "0" {
		return nil, fmt.Errorf("%s %s", r.ErrCode, r.ErrMsg)
	}
	var data struct {
		ReturnLists []struct {
			Data []struct {
				ResID string `json:"ResID"`
				IP    string `json:"IP"`
			} `json:"Data"`
		} `json:"returnLists"`
	}
	if err := json.Unmarshal(r.Data, &data); err != nil {
		return nil, err
	}
	var out []Resource
	seen := map[string]bool{}
	for _, g := range data.ReturnLists {
		for _, res := range g.Data {
			for _, entry := range strings.Split(res.IP, "##") {
				entry = strings.TrimSpace(entry)
				// 格式: "ALL host:ports"
				fields := strings.Fields(entry)
				if len(fields) < 2 {
					continue
				}
				hostPort := fields[1]
				host, ports := hostPort, ""
				if i := strings.LastIndex(hostPort, ":"); i > 0 {
					host = hostPort[:i]
					ports = hostPort[i+1:]
				}
				host = strings.TrimSpace(host)
				ports = strings.TrimSpace(ports)
				if host == "" || host == "*" {
					continue
				}
				key := host + "|" + res.ResID + "|" + ports
				if seen[key] {
					continue
				}
				seen[key] = true
				out = append(out, Resource{Pattern: host, ResID: res.ResID, Ports: ports})
			}
		}
	}
	return out, nil
}
