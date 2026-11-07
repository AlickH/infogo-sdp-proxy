package main

// SDP 二维码登录流程（逆向所得）：
//   1. GET  server/info                  → pubKey / ZJTConfig / ControlUrl
//   2. 拼二维码 URL（portal.cscec.com/wwopen/sso/qrConnect）
//   3. 轮询 POST wework/user (action=check) → 中建通 token + username
//   4. RSA 加密 token，POST auth/index      → 客户端 Token
//   5. POST check/success、ZtpGateway/getGateway

import (
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"time"
)

type ServerInfo struct {
	PubKey     string      `json:"pubKey"`
	ControlURL string      `json:"ControlUrl"`
	ServerIP   string      `json:"SERVERIP"`
	ServerPort json.Number `json:"SERVERPORT"`
	ZJTConfig  struct {
		URL     string `json:"url"`
		CorpID  string `json:"corpId"`
		AgentID string `json:"agentid"`
		IsProxy bool   `json:"ServerProxy"`
	} `json:"ZJTConfig"`
	WeWorkConfig struct {
		CorpID  string `json:"corpId"`
		AgentID string `json:"agentid"`
	} `json:"WeWorkConfig"`
}

type apiResp struct {
	ErrCode string          `json:"errcode"`
	ErrMsg  string          `json:"errmsg"`
	Data    json.RawMessage `json:"data"`
}

// ---------- HTTP 封装（模拟客户端请求格式）----------

type apiClient struct {
	base  string // https://sdp.cscec5b.com.cn:17441
	token string
	http  *http.Client
}

// resolveRealIP 用公共 DNS 解析真实 IP，绕开本机代理的 fake-IP DNS
func resolveRealIP(host string) (string, error) {
	for _, dns := range []string{"223.5.5.5:53", "114.114.114.114:53", "8.8.8.8:53"} {
		r := &net.Resolver{
			PreferGo: true,
			Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
				d := net.Dialer{Timeout: 3 * time.Second}
				return d.DialContext(ctx, "udp", dns)
			},
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		addrs, err := r.LookupHost(ctx, host)
		cancel()
		if err != nil || len(addrs) == 0 {
			continue
		}
		for _, a := range addrs {
			if ip := net.ParseIP(a); ip != nil && ip.To4() != nil {
				return a, nil
			}
		}
	}
	return "", fmt.Errorf("无法解析 %s 的真实 IP", host)
}

func newAPIClient(base string) *apiClient {
	base = strings.TrimRight(base, "/")
	u, err := url.Parse(base)
	realIP, ipErr := "", error(nil)
	if err == nil {
		realIP, ipErr = resolveRealIP(u.Hostname())
	}
	var client *http.Client
	if ipErr == nil && u != nil {
		hostname := u.Hostname()
		port := u.Port()
		if port == "" {
			port = "443"
		}
		addr := net.JoinHostPort(realIP, port)
		tr := &http.Transport{
			DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
				d := net.Dialer{Timeout: 10 * time.Second}
				return d.DialContext(ctx, "tcp", addr)
			},
			TLSClientConfig: &tls.Config{ServerName: hostname, InsecureSkipVerify: true},
		}
		client = &http.Client{Transport: tr, Timeout: 30 * time.Second}
		if os.Getenv("SDP_DEBUG") != "" {
			fmt.Printf("[login] 服务端解析: %s -> %s\n", hostname, realIP)
		}
	} else {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	return &apiClient{base: base, http: client}
}

func (a *apiClient) call(method, path string, params map[string]string) (*apiResp, error) {
	ts := time.Now().UnixMilli()
	baseURL := fmt.Sprintf("%s%s?local_lguage_set=zh&cache=%d", a.base, path, ts)

	// Session-Num：按客户端逻辑，把参数用原始值追加到 URL 后过滤字符再 md5
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	sessionURL := baseURL
	for _, k := range keys {
		sessionURL += "&" + k + "=" + params[k]
	}
	sessionStr := strings.TrimPrefix(sessionURL, a.base)
	var filtered strings.Builder
	for _, r := range sessionStr {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			strings.ContainsRune("=&()/.?_'\"<>", r) {
			filtered.WriteRune(r)
		}
	}
	sum := md5.Sum([]byte(filtered.String()))

	requestURL := baseURL
	var bodyReader io.Reader
	if method == "GET" {
		// GET 参数放 URL
		for _, k := range keys {
			requestURL += "&" + k + "=" + url.QueryEscape(params[k])
		}
	} else if len(keys) > 0 {
		// POST 参数放 body（URL 只保留 cache，与客户端一致）
		form := url.Values{}
		for _, k := range keys {
			form.Set(k, params[k])
		}
		bodyReader = strings.NewReader(form.Encode())
	}

	req, err := http.NewRequest(method, requestURL, bodyReader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Session-Num", hex.EncodeToString(sum[:]))
	req.Header.Set("Referer", a.base+"/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	if method != "GET" {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if a.token != "" {
		req.Header.Set("Web-Token", a.token)
	}
	resp, err := a.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var r apiResp
	if i := strings.IndexByte(string(raw), '{'); i > 0 {
		raw = raw[i:]
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("响应解析失败: %v, body=%s", err, truncate(string(raw), 200))
	}
	if os.Getenv("SDP_DEBUG") != "" {
		fmt.Printf("[debug] %s %s\n  Session-Num=%s\n  resp=%s %s\n", method, requestURL, hex.EncodeToString(sum[:]), r.ErrCode, r.ErrMsg)
	}
	return &r, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// ---------- 登录 ----------

type loginResult struct {
	Token     string
	Timestamp string
	UserID    string
	DeviceID  string
	RoleID    string
	UserName  string
}

// loginCtx 登录会话上下文
type loginCtx struct {
	api      *apiClient
	info     ServerInfo
	base     string
	deviceID string
}

// prepareLogin 获取服务端配置
func prepareLogin(baseURL, deviceID string) (*loginCtx, error) {
	api := newAPIClient(baseURL)
	resp, err := api.call("GET", "/access/1.0/linux/json/server/info", map[string]string{
		"basIP": "", "firsturl": "", "version": "6039.3746",
	})
	if err != nil {
		return nil, fmt.Errorf("获取服务端配置失败: %w", err)
	}
	if resp.ErrCode != "0" {
		return nil, fmt.Errorf("server/info 失败: %s %s", resp.ErrCode, resp.ErrMsg)
	}
	var info ServerInfo
	if err := json.Unmarshal(resp.Data, &info); err != nil {
		return nil, fmt.Errorf("解析 server/info 失败: %w", err)
	}
	if info.ControlURL == "" {
		info.ControlURL = baseURL
	}
	return &loginCtx{api: api, info: info, base: baseURL, deviceID: deviceID}, nil
}

// qrURL 生成二维码链接（含时间戳）
func (c *loginCtx) qrURL() (string, int64) {
	ts := time.Now().UnixMilli()
	redirect := fmt.Sprintf("%s/access/1.0/linux/json/wework/user?deviceid=%s&time=%d&zjt=1", c.info.ControlURL, c.deviceID, ts)
	portal := c.info.ZJTConfig.URL
	if portal == "" {
		portal = "https://portal.cscec.com"
	}
	u := fmt.Sprintf("%s/wwopen/sso/qrConnect?appid=%s&agentid=%s&redirect_uri=%s&state=&login_type=jssdk&t=%d",
		portal, c.info.ZJTConfig.CorpID, c.info.ZJTConfig.AgentID, url.QueryEscape(redirect), ts+5)
	return u, ts
}

// pollScan 查询一次扫码状态
func (c *loginCtx) pollScan(ts int64) (token, username string, done bool) {
	r, err := c.api.call("POST", "/access/1.0/linux/json/wework/user", map[string]string{
		"action": "check", "deviceid": c.deviceID, "time": fmt.Sprintf("%d", ts),
	})
	if err != nil || r.ErrCode != "0" {
		return "", "", false
	}
	var d struct {
		State    bool   `json:"state"`
		Token    string `json:"token"`
		Username string `json:"username"`
	}
	if json.Unmarshal(r.Data, &d) == nil && d.State {
		return d.Token, d.Username, true
	}
	return "", "", false
}

// finish 完成认证：RSA 加密 → auth/index → 安检上报 → 网关列表
func (c *loginCtx) finish(wecomToken, username string) (*loginResult, error) {
	enc, err := rsaEncrypt(c.info.PubKey, wecomToken)
	if err != nil {
		return nil, fmt.Errorf("RSA 加密失败: %w", err)
	}
	authResp, err := c.api.call("POST", "/access/1.0/linux/json/auth/index", map[string]string{
		"type":          "User",
		"user_name":     base64.StdEncoding.EncodeToString([]byte(username)),
		"password":      enc,
		"weworkqrlogin": "1",
		"zjt":           "1",
		"deviceid":      c.deviceID,
		"autoAuth":      "0",
		"hintOver":      "0",
		"idp":           "",
		"isRecord":      "1",
		"remoteIp":      "",
		"tokenId":       "",
	})
	if err != nil {
		return nil, fmt.Errorf("认证请求失败: %w", err)
	}
	if authResp.ErrCode != "0" {
		return nil, fmt.Errorf("认证失败: %s %s", authResp.ErrCode, authResp.ErrMsg)
	}
	var auth struct {
		Token          string      `json:"Token"`
		TokenTimestamp json.Number `json:"TokenTimestamp"`
		UserID         string      `json:"UserID"`
		DeviceID       string      `json:"DeviceID"`
		RoleID         string      `json:"RoleID"`
		UserName       string      `json:"UserName"`
	}
	if err := json.Unmarshal(authResp.Data, &auth); err != nil {
		return nil, fmt.Errorf("解析认证响应失败: %w", err)
	}
	if auth.Token == "" {
		return nil, fmt.Errorf("认证响应中没有 Token")
	}
	c.api.token = auth.Token
	_, _ = c.api.call("POST", "/access/1.0/linux/json/check/success", map[string]string{
		"deviceid": auth.DeviceID, "roleid": auth.RoleID, "policyid": "3", "sceneid": "3",
	})
	_, _ = c.api.call("POST", "/access/1.0/linux/json/ZtpGateway/getGateway", map[string]string{})
	return &loginResult{
		Token:     auth.Token,
		Timestamp: auth.TokenTimestamp.String(),
		UserID:    auth.UserID,
		DeviceID:  auth.DeviceID,
		RoleID:    auth.RoleID,
		UserName:  auth.UserName,
	}, nil
}

// doLogin CLI 登录：打印二维码、轮询、自动刷新
func doLogin(baseURL, deviceID string, openBrowser bool) (*loginResult, error) {
	ctx, err := prepareLogin(baseURL, deviceID)
	if err != nil {
		return nil, err
	}
	fmt.Printf("[login] 服务端: %s (ZJT corp=%s agent=%s)\n", ctx.info.ControlURL, ctx.info.ZJTConfig.CorpID, ctx.info.ZJTConfig.AgentID)

	qr, ts := ctx.qrURL()
	fmt.Println("[login] 请用中建通扫描二维码登录：")
	fmt.Println(qr)
	if openBrowser {
		openInBrowser(qr)
	}

	for round := 0; round < 3; round++ {
		if round > 0 {
			qr, ts = ctx.qrURL()
			fmt.Println("[login] 二维码已刷新：")
			fmt.Println(qr)
			if openBrowser {
				openInBrowser(qr)
			}
		}
		deadline := time.Now().Add(2 * time.Minute)
		for time.Now().Before(deadline) {
			if tok, user, done := ctx.pollScan(ts); done {
				fmt.Printf("[login] 扫码成功: %s\n", user)
				res, err := ctx.finish(tok, user)
				if err != nil {
					return nil, err
				}
				fmt.Printf("[login] 认证成功: user=%s device=%s\n", res.UserName, res.DeviceID)
				return res, nil
			}
			time.Sleep(2 * time.Second)
		}
	}
	return nil, fmt.Errorf("扫码超时或未成功")
}

// rsaEncrypt 用服务端公钥做 PKCS#1 v1.5 加密（与 JSEncrypt 一致）
func rsaEncrypt(pubPEM string, plain string) (string, error) {
	block, _ := pem.Decode([]byte(pubPEM))
	if block == nil {
		return "", fmt.Errorf("公钥解析失败")
	}
	pub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return "", err
	}
	rsaPub, ok := pub.(*rsa.PublicKey)
	if !ok {
		return "", fmt.Errorf("不是 RSA 公钥")
	}
	cipher, err := rsa.EncryptPKCS1v15(rand.Reader, rsaPub, []byte(plain))
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(cipher), nil
}

func openInBrowser(u string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", u)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
		hideWindow(cmd)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	_ = cmd.Start()
}

func saveTokenToConfig(cfgPath string, res *loginResult) error {
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return err
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return err
	}
	m["token"] = res.Token
	if err := writeJSON(cfgPath, m); err != nil {
		return err
	}
	fmt.Printf("[login] Token 已保存到 %s\n", cfgPath)
	return nil
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0600)
}

// saveTokenString 只更新配置里的 token 字段
func saveTokenString(cfgPath, token string) error {
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		return err
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return err
	}
	m["token"] = token
	return writeJSON(cfgPath, m)
}
