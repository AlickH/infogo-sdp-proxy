package main

// 临时诊断：探测某个域名在各网关 / 各 resid 下的 CONNECT 结果

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func (d *dashboard) handleProbe(w http.ResponseWriter, r *http.Request) {
	host := strings.TrimSpace(r.URL.Query().Get("host"))
	portStr := r.URL.Query().Get("port")
	port, _ := strconv.Atoi(portStr)
	if port == 0 {
		port = 443
	}
	if host == "" {
		writeJSONResp(w, map[string]any{"ok": false, "error": "missing host"})
		return
	}
	token := d.st.Token()
	if token == "" {
		writeJSONResp(w, map[string]any{"ok": false, "error": "未登录，先扫码登录"})
		return
	}
	candidates := []string{"", "241", "244", "191", "240", "242", "243", "245", "246", "247", "248", "249", "250"}
	if rg := r.URL.Query().Get("range"); rg != "" {
		parts := strings.SplitN(rg, "-", 2)
		if len(parts) == 2 {
			lo, _ := strconv.Atoi(parts[0])
			hi, _ := strconv.Atoi(parts[1])
			if lo > 0 && hi >= lo && hi-lo <= 800 {
				candidates = candidates[:0]
				for i := lo; i <= hi; i++ {
					candidates = append(candidates, strconv.Itoa(i))
				}
			}
		}
	}
	onlyGW := r.URL.Query().Get("gw")
	useIP := r.URL.Query().Get("ip") == "1"
	target := host
	if t := r.URL.Query().Get("target"); t != "" {
		target = t
		useIP = true
	} else if useIP {
		ip, err := resolveRealIP(host)
		if err != nil {
			writeJSONResp(w, map[string]any{"ok": false, "error": "解析失败: " + err.Error()})
			return
		}
		target = ip
	}
	gateways := strings.Split(d.cfg.Gateway, ",")
	type result struct {
		Gateway string `json:"gateway"`
		ResID   string `json:"resid"`
		OK      bool   `json:"ok"`
		Err     string `json:"err,omitempty"`
	}
	type outcome struct {
		Gateway string
		ResID   string
		Err     error
	}
	ch := make(chan outcome, len(gateways)*len(candidates))
	for _, gw := range gateways {
		gw = strings.TrimSpace(gw)
		if gw == "" {
			continue
		}
		if onlyGW != "" && !strings.Contains(gw, onlyGW) {
			continue
		}
		for _, resid := range candidates {
			go func(gw, resid string) {
				conn, err := dialOneGatewayEx(gw, d.cfg.ServerName, token, target, uint16(port), resid, useIP)
				if err == nil {
					conn.Close()
				}
				ch <- outcome{Gateway: gw, ResID: resid, Err: err}
			}(gw, resid)
		}
	}
	total := len(gateways) * len(candidates)
	deadline := time.After(25 * time.Second)
	var results []result
	done := 0
	for done < total {
		select {
		case o := <-ch:
			done++
			if o.Err == nil {
				results = append(results, result{Gateway: o.Gateway, ResID: o.ResID, OK: true})
			} else {
				results = append(results, result{Gateway: o.Gateway, ResID: o.ResID, Err: o.Err.Error()})
			}
		case <-deadline:
			results = append(results, result{Gateway: "(remaining)", ResID: "", Err: "timeout"})
			done = total
		}
	}
	b, _ := json.MarshalIndent(map[string]any{"host": host, "target": target, "port": port, "useIP": useIP, "results": results}, "", "  ")
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(b)
}

// handleResList 调试：拉取服务端资源列表原始返回
func (d *dashboard) handleResList(w http.ResponseWriter, r *http.Request) {
	listType := r.URL.Query().Get("type")
	if listType == "" {
		listType = "0"
	}
	queryStr := r.URL.Query().Get("q")
	resp, err := d.api.call("POST", "/access/1.0/linux/json/ztpResource/list", map[string]string{
		"deviceid": d.deviceID, "listType": listType, "queryStr": queryStr,
	})
	if err != nil {
		writeJSONResp(w, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(resp.Data)
}

// handleRaw 调试：调用服务端接口并返回原始 JSON
func (d *dashboard) handleRaw(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Query().Get("path")
	if path == "" {
		writeJSONResp(w, map[string]any{"ok": false, "error": "missing path"})
		return
	}
	params := map[string]string{}
	for k, v := range r.URL.Query() {
		if k == "path" {
			continue
		}
		if len(v) > 0 {
			params[k] = v[len(v)-1]
		}
	}
	method := r.URL.Query().Get("method")
	if method == "" {
		method = "POST"
	}
	resp, err := d.api.call(method, path, params)
	if err != nil {
		writeJSONResp(w, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(resp.Data)
}

// handleDiscover 调试：对域名执行资源 ID 发现
func (d *dashboard) handleDiscover(w http.ResponseWriter, r *http.Request) {
	host := strings.TrimSpace(r.URL.Query().Get("host"))
	portStr := r.URL.Query().Get("port")
	port, _ := strconv.Atoi(portStr)
	if port == 0 {
		port = 443
	}
	if host == "" {
		writeJSONResp(w, map[string]any{"ok": false, "error": "missing host"})
		return
	}
	if d.st.Token() == "" {
		writeJSONResp(w, map[string]any{"ok": false, "error": "未登录"})
		return
	}
	resid := discoverResID(d.cfg, d.st, host, uint16(port))
	writeJSONResp(w, map[string]any{"ok": resid != "", "host": host, "resid": resid})
}

// handleRawText 调试：GET 服务端接口并返回原始文本（不解析 JSON）
func (d *dashboard) handleRawText(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Query().Get("path")
	if path == "" {
		writeJSONResp(w, map[string]any{"ok": false, "error": "missing path"})
		return
	}
	ts := time.Now().UnixMilli()
	full := d.api.base + path
	if strings.Contains(path, "?") {
		full += "&local_lguage_set=zh&cache=" + strconv.FormatInt(ts, 10)
	} else {
		full += "?local_lguage_set=zh&cache=" + strconv.FormatInt(ts, 10)
	}
	sessionStr := strings.TrimPrefix(full, d.api.base)
	var filtered strings.Builder
	for _, ch := range sessionStr {
		if (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
			strings.ContainsRune("=&()/.?_'\"<>", ch) {
			filtered.WriteRune(ch)
		}
	}
	sum := md5.Sum([]byte(filtered.String()))
	req, err := http.NewRequest("GET", full, nil)
	if err != nil {
		writeJSONResp(w, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	req.Header.Set("Session-Num", hex.EncodeToString(sum[:]))
	req.Header.Set("Referer", d.api.base+"/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	if d.api.token != "" {
		req.Header.Set("Web-Token", d.api.token)
	}
	resp, err := d.api.http.Do(req)
	if err != nil {
		writeJSONResp(w, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write(body)
}
