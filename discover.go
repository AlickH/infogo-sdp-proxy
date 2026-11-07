package main

// 未知内网域名自动发现资源 ID：
// 隧道被 0521 拒绝时，扫描 1..420 找到可用的 resid，缓存到配置并重试。

import (
	"crypto/tls"
	"encoding/json"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// tunnelUsable 验证隧道是否真的能到达目标（对 TLS 端口做一次握手）
func tunnelUsable(conn net.Conn, host string, port uint16) bool {
	defer conn.Close()
	if port != 443 && port != 8443 && port != 9102 && port != 9443 && port != 10443 {
		return true
	}
	tc := tls.Client(conn, &tls.Config{ServerName: host, InsecureSkipVerify: true})
	_ = tc.SetDeadline(time.Now().Add(5 * time.Second))
	if err := tc.Handshake(); err != nil {
		return false
	}
	_ = tc.Close()
	return true
}

// discoverResID 扫描候选资源 ID，返回第一个可用的
func discoverResID(cfg *Config, st *State, host string, port uint16) string {
	if recentlyFailed(host) {
		return ""
	}
	if !beginDiscover(host) {
		return ""
	}
	defer endDiscover(host)
	log.Printf("[资源] %s 开始自动发现资源 ID（候选 %d 个）", host, len(candidatesFor(st)))
	token := st.Token()
	if token == "" {
		return ""
	}
	gateways := strings.Split(cfg.Gateway, ",")
	var gw string
	for _, g := range gateways {
		if g = strings.TrimSpace(g); g != "" {
			gw = g
			break
		}
	}
	if gw == "" {
		return ""
	}

	candidates := candidatesFor(st)
	var found atomic.Value
	sem := make(chan struct{}, 24)
	var wg sync.WaitGroup
	deadline := time.Now().Add(20 * time.Second)
	for _, resid := range candidates {
		if found.Load() != nil || time.Now().After(deadline) {
			break
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(rid string) {
			defer wg.Done()
			defer func() { <-sem }()
			if found.Load() != nil {
				return
			}
			conn, err := dialOneGateway(gw, cfg.ServerName, token, host, port, rid)
			if err == nil {
				if tunnelUsable(conn, host, port) {
					found.Store(rid)
				} else {
					conn.Close()
				}
			}
		}(resid)
	}
	wg.Wait()
	if v := found.Load(); v != nil {
		return v.(string)
	}
	markFailed(host)
	log.Printf("[资源] %s 自动发现失败（30 分钟内不再重试）", host)
	return ""
}

// activeCfgPath 当前配置文件路径（main 设置）
var activeCfgPath string

// 失败缓存 + 进行中集合：同一域名不并发重复扫描
var (
	discoverFailMu   sync.Mutex
	discoverFailed   = map[string]time.Time{}
	discoverInFlight = map[string]bool{}
)

func recentlyFailed(host string) bool {
	discoverFailMu.Lock()
	defer discoverFailMu.Unlock()
	if t, ok := discoverFailed[host]; ok && time.Since(t) < 30*time.Minute {
		return true
	}
	return false
}

func markFailed(host string) {
	discoverFailMu.Lock()
	discoverFailed[host] = time.Now()
	discoverFailMu.Unlock()
}

// beginDiscover 抢占扫描权，避免并发重复扫描
func beginDiscover(host string) bool {
	discoverFailMu.Lock()
	defer discoverFailMu.Unlock()
	if discoverInFlight[host] {
		return false
	}
	discoverInFlight[host] = true
	return true
}

func endDiscover(host string) {
	discoverFailMu.Lock()
	delete(discoverInFlight, host)
	discoverFailMu.Unlock()
}

// learnResource 缓存发现结果并持久化
func learnResource(cfg *Config, st *State, host, resid string) {
	cfgPath := activeCfgPath
	st.mu.Lock()
	st.resources = append(st.resources, Resource{Pattern: host, ResID: resid})
	st.mu.Unlock()

	if cfg.LearnedResources == nil {
		cfg.LearnedResources = map[string]string{}
	}
	cfg.LearnedResources[host] = resid
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return
	}
	if err := os.WriteFile(cfgPath, data, 0600); err != nil {
		log.Printf("[资源] 保存学习结果失败: %v", err)
	}
}

// needDiscover 判断错误是否值得触发资源发现
func needDiscover(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "0521") || strings.Contains(msg, "0520")
}

// dialDirect 直连目标：用公共 DNS 解析，避开系统 fake-IP
func dialDirect(host string, port uint16) (net.Conn, error) {
	addr := host
	if net.ParseIP(host) == nil {
		ip, err := resolveRealIP(host)
		if err != nil {
			return nil, err
		}
		addr = ip
	}
	return net.DialTimeout("tcp", net.JoinHostPort(addr, strconv.Itoa(int(port))), 10*time.Second)
}

// candidatesFor 生成候选资源 ID 列表
func candidatesFor(st *State) []string {
	st.mu.RLock()
	seen := map[string]bool{}
	var out []string
	for _, r := range st.resources {
		if r.ResID != "" && !seen[r.ResID] {
			seen[r.ResID] = true
			out = append(out, r.ResID)
		}
	}
	st.mu.RUnlock()
	if len(out) < 10 {
		out = out[:0]
		for i := 1; i <= 200; i++ {
			out = append(out, strconv.Itoa(i))
		}
	}
	return out
}
