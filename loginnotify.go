package main

// 企业微信扫码页在扫码确认后会通过 postMessage 把结果 URL 发给父窗口，
// 由客户端自己 POST 到 SDP 服务端完成扫码登记（官方客户端即如此）。

import (
	"context"
	"crypto/md5"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// handleLoginNotify 接收页面回传的数据并转发到 SDP 服务端
func (d *dashboard) handleLoginNotify(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Data string `json:"data"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSONResp(w, map[string]any{"ok": false, "error": "bad json"})
		return
	}
	log.Printf("[扫码] 页面回传 (state=%s): %.300s", d.lm.state, body.Data)
	d.lm.mu.Lock()
	d.lm.notifiedAt = time.Now().UnixMilli()
	d.lm.mu.Unlock()
	go forwardScanNotify(body.Data)
	writeJSONResp(w, map[string]any{"ok": true})
}

// forwardScanNotify 把页面回传的 URL POST 给服务端
func forwardScanNotify(data string) {
	data = strings.TrimSpace(data)
	if !strings.HasPrefix(data, "http") {
		log.Printf("[扫码] 回传内容不是 URL，忽略")
		return
	}
	u, err := url.Parse(data)
	if err != nil {
		log.Printf("[扫码] URL 解析失败: %v", err)
		return
	}
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		if u.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	realIP, err := resolveRealIP(host)
	if err != nil {
		log.Printf("[扫码] 解析 %s 失败: %v", host, err)
		return
	}
	tr := &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 10 * time.Second}
			return d.DialContext(ctx, "tcp", net.JoinHostPort(realIP, port))
		},
		TLSClientConfig: &tls.Config{ServerName: host, InsecureSkipVerify: true},
	}
	client := &http.Client{Transport: tr, Timeout: 30 * time.Second}

	// Session-Num：对 path+query 做过滤后 md5
	sessionStr := u.RequestURI()
	var filtered strings.Builder
	for _, r := range sessionStr {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			strings.ContainsRune("=&()/.?_'\"<>", r) || r == ':' || r == '%' {
			filtered.WriteRune(r)
		}
	}
	sum := md5.Sum([]byte(filtered.String()))

	req, err := http.NewRequest("POST", data, nil)
	if err != nil {
		log.Printf("[扫码] 构造请求失败: %v", err)
		return
	}
	req.Header.Set("Session-Num", hex.EncodeToString(sum[:]))
	req.Header.Set("Referer", u.Scheme+"://"+u.Host+"/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("[扫码] 转发失败: %v", err)
		return
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	log.Printf("[扫码] 转发结果 HTTP %d: %s", resp.StatusCode, truncate(string(raw), 300))
}

// handleLoginPage 提供内嵌登录页的包装页（同源，可转发 message）
func (d *dashboard) handleLoginPage(w http.ResponseWriter, r *http.Request) {
	d.lm.mu.Lock()
	pageURL := d.lm.url
	d.lm.mu.Unlock()
	if pageURL == "" {
		http.NotFound(w, r)
		return
	}
	html := fmt.Sprintf(`<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>html,body{margin:0;height:100%%;background:#fff;overflow:hidden}
body{display:flex;align-items:center;justify-content:center;padding:26px 0 14px;box-sizing:border-box;background:#fff}
#f{width:300px;height:400px;border:0;display:block;flex:none}</style></head>
<body>
<iframe id="f" src="%s" width="300" height="400" frameborder="0" scrolling="no" allowtransparency="true"></iframe>
<script>
window.addEventListener('message', function(e){
  try {
    var d = (typeof e.data === 'string') ? e.data : JSON.stringify(e.data);
    fetch('/api/login/notify', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({data:d})});
  } catch (err) {}
});
var f = document.getElementById('f');
f.onload = function(){ try { f.contentWindow.postMessage('ask_usePostMessage','*'); } catch(e){} };
</script>
</body></html>`, pageURL)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(html))
}
