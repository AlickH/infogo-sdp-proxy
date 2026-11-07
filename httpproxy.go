package main

// HTTP 代理（CONNECT + 普通 HTTP），供 Windows/macOS 系统代理使用
// 优点：CONNECT 请求里保留域名，避免客户端先本地解析成 IP 导致资源匹配失败

import (
	"bufio"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"
)

func startHTTPProxy(cfg *Config, st *State) {
	addr := cfg.HTTPListen
	if addr == "" {
		addr = "127.0.0.1:11096"
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Printf("[HTTP] 监听失败: %v", err)
		return
	}
	log.Printf("[HTTP] HTTP 代理: %s", addr)
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleHTTPConn(conn, cfg, st)
	}
}

func handleHTTPConn(conn net.Conn, cfg *Config, st *State) {
	defer conn.Close()
	br := bufio.NewReader(conn)
	req, err := http.ReadRequest(br)
	if err != nil {
		return
	}
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))

	// CONNECT 隧道
	if req.Method == http.MethodConnect {
		host, portStr, err := net.SplitHostPort(req.Host)
		if err != nil {
			host, portStr = req.Host, "443"
		}
		port, _ := strconv.Atoi(portStr)
		up, err := openUpstream(cfg, st, host, uint16(port))
		if err != nil {
			_, _ = conn.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
			return
		}
		defer up.Close()
		_, _ = conn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
		_ = conn.SetDeadline(time.Time{})
		relay(conn, up)
		return
	}

	// 普通 HTTP 代理请求（absolute-form）
	if !req.URL.IsAbs() {
		_, _ = conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n"))
		return
	}
	host := req.URL.Hostname()
	port := req.URL.Port()
	if port == "" {
		port = "80"
	}
	p, _ := strconv.Atoi(port)
	up, err := openUpstream(cfg, st, host, uint16(p))
	if err != nil {
		_, _ = conn.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
		return
	}
	defer up.Close()
	req.RequestURI = ""
	_ = conn.SetDeadline(time.Time{})
	if err := req.Write(up); err != nil {
		return
	}
	relay(conn, up)
}

// openUpstream 按资源匹配选择：隧道 or 直连
func openUpstream(cfg *Config, st *State, host string, port uint16) (net.Conn, error) {
	if isDirectDomain(cfg, host) {
		if up, err := dialDirect(host, port); err == nil {
			log.Printf("[HTTP直连] %s:%d (公网入口)", host, port)
			return up, nil
		} else {
			log.Printf("[HTTP直连失败] %s:%d: %v", host, port, err)
			return nil, err
		}
	}
	resid := st.ResIDPort(host, port)
	if resid != "" {
		up, err := dialGateway(cfg, st.Token(), host, port, resid)
		if err == nil {
			log.Printf("[HTTP隧道] %s:%d (resid=%s)", host, port, resid)
			return up, nil
		}
		log.Printf("[HTTP隧道失败] %s:%d resid=%s: %v", host, port, resid, err)
		if needDiscover(err) && !st.HostKnown(host) {
			if newResid := discoverResID(cfg, st, host, port); newResid != "" {
				log.Printf("[资源] %s 发现可用资源 resid=%s（已缓存）", host, newResid)
				learnResource(cfg, st, host, newResid)
				if up2, err2 := dialGateway(cfg, st.Token(), host, port, newResid); err2 == nil {
					log.Printf("[HTTP隧道] %s:%d (resid=%s)", host, port, newResid)
					return up2, nil
				}
			}
		}
		if cfg.FallbackDirect == nil || !*cfg.FallbackDirect {
			return nil, err
		}
	}
	up, err := dialDirect(host, port)
	if err == nil {
		log.Printf("[HTTP直连] %s:%d", host, port)
	}
	return up, err
}

// relay 双向复制
func relay(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(b, a)
		if c, ok := b.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(a, b)
		if c, ok := a.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	wg.Wait()
}
