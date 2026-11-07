package main

// 从登录页提取二维码图片：GET /wwopen/sso/qrImg?key=xxx

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var qrKeyRe = regexp.MustCompile(`qrImg\?key=([0-9A-Za-z_]+)`)

// fetchLoginQR 打开登录页 → 提取 key → 下载二维码 PNG
func fetchLoginQR(pageURL string) ([]byte, error) {
	u, err := url.Parse(pageURL)
	if err != nil {
		return nil, err
	}
	host := u.Hostname()
	realIP, err := resolveRealIP(host)
	if err != nil {
		return nil, fmt.Errorf("解析 %s 失败: %w", host, err)
	}
	addr := net.JoinHostPort(realIP, "443")
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 10 * time.Second}
			return d.DialContext(ctx, "tcp", addr)
		},
		TLSClientConfig: &tls.Config{ServerName: host, InsecureSkipVerify: true},
	}
	c := &http.Client{Transport: tr, Timeout: 20 * time.Second}

	// 1) 取登录页
	resp, err := c.Get(pageURL)
	if err != nil {
		return nil, err
	}
	html, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return nil, err
	}
	m := qrKeyRe.FindSubmatch(html)
	if m == nil {
		return nil, fmt.Errorf("登录页中未找到二维码 key")
	}
	key := string(m[1])

	// 2) 取二维码图片
	imgURL := fmt.Sprintf("%s://%s/wwopen/sso/qrImg?key=%s", u.Scheme, u.Host, key)
	resp2, err := c.Get(imgURL)
	if err != nil {
		return nil, err
	}
	defer resp2.Body.Close()
	img, err := io.ReadAll(resp2.Body)
	if err != nil {
		return nil, err
	}
	if !strings.HasPrefix(string(img[:min(8, len(img))]), "\x89PNG") {
		return nil, fmt.Errorf("二维码图片格式异常")
	}
	return img, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
