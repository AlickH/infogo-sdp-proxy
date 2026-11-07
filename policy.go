package main

// 从 /access/2.0/linux/json/resource/distributeConfig 拉取完整资源策略表
// （官方客户端 TUN2Socks 用的就是这张表，包含所有 域名/IP → 资源ID 映射）

import (
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

type distPolicy struct {
	ResIpContent     string   `json:"resIpContent"`
	ResDomainContent string   `json:"resDomainContent"`
	ResID            string   `json:"resID"`
	FakeIPEnable     string   `json:"fakeIpEnable"`
	GatewayID        []string `json:"gatewayID"`
}

// fetchPolicyResources 拉取资源策略并转换为 Resource 列表
func fetchPolicyResources(api *apiClient, deviceID string) ([]Resource, error) {
	if api == nil || api.token == "" {
		return nil, fmt.Errorf("未登录")
	}
	path := "/access/2.0/linux/json/resource/distributeConfig"
	ts := time.Now().UnixMilli()
	full := api.base + path + "?deviceid=" + deviceID + "&local_lguage_set=zh&cache=" + fmt.Sprint(ts)

	sessionStr := strings.TrimPrefix(full, api.base)
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
		return nil, err
	}
	req.Header.Set("Session-Num", hex.EncodeToString(sum[:]))
	req.Header.Set("Referer", api.base+"/")
	req.Header.Set("User-Agent", "Mozilla/5.0")
	req.Header.Set("Web-Token", api.token)

	resp, err := api.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var wrapper struct {
		ErrCode json.RawMessage `json:"errcode"`
		ErrMsg  string          `json:"errmsg"`
		Data    struct {
			AppPolicy []distPolicy `json:"appPolicy"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &wrapper); err != nil {
		return nil, fmt.Errorf("策略解析失败: %v", err)
	}
	if len(wrapper.Data.AppPolicy) == 0 {
		return nil, fmt.Errorf("策略为空: %s", truncate(string(body), 120))
	}

	var out []Resource
	seen := map[string]bool{}
	add := func(pattern, ports, resid string) {
		pattern = strings.TrimSpace(pattern)
		if pattern == "" || resid == "" {
			return
		}
		key := pattern + "|" + resid + "|" + ports
		if seen[key] {
			return
		}
		seen[key] = true
		out = append(out, Resource{Pattern: pattern, ResID: resid, Ports: ports})
	}
	for _, p := range wrapper.Data.AppPolicy {
		for _, it := range parsePolicyEntries(p.ResDomainContent) {
			add(it.host, it.ports, p.ResID)
		}
		for _, it := range parsePolicyEntries(p.ResIpContent) {
			add(it.host, it.ports, p.ResID)
		}
	}
	return out, nil
}

type policyItem struct {
	host  string
	ports string
}

// parsePolicyEntries 解析 "host [TCP]/443,8001##host2 /80-90" 形式
func parsePolicyEntries(s string) []policyItem {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	var out []policyItem
	for _, chunk := range strings.Split(s, "##") {
		chunk = strings.TrimSpace(chunk)
		if chunk == "" {
			continue
		}
		var host, ports string
		if i := strings.Index(chunk, "/"); i >= 0 {
			host = strings.TrimSpace(chunk[:i])
			ports = strings.TrimSpace(chunk[i+1:])
		} else {
			host = chunk
		}
		// 去掉协议标记 TCP/UDP/ALL
		fields := strings.Fields(host)
		if len(fields) > 1 {
			last := strings.ToUpper(fields[len(fields)-1])
			if last == "TCP" || last == "UDP" || last == "ALL" {
				host = strings.Join(fields[:len(fields)-1], " ")
			}
		}
		host = strings.TrimSpace(host)
		if host == "" {
			continue
		}
		out = append(out, policyItem{host: host, ports: ports})
	}
	return out
}

// ipRangeToCIDRs 把 IPv4 区间转成 CIDR 列表
func ipRangeToCIDRs(start, end string) []string {
	s := net.ParseIP(strings.TrimSpace(start)).To4()
	e := net.ParseIP(strings.TrimSpace(end)).To4()
	if s == nil || e == nil {
		return nil
	}
	si := binary.BigEndian.Uint32(s)
	ei := binary.BigEndian.Uint32(e)
	if si > ei {
		si, ei = ei, si
	}
	var out []string
	for si <= ei {
		// 最大对齐块
		bits := 32
		for bits > 0 {
			mask := uint32(0xFFFFFFFF) << (32 - (bits - 1))
			if si&mask != si {
				break
			}
			bits--
		}
		for bits < 32 {
			blockEnd := si + (uint32(1) << (32 - bits)) - 1
			if blockEnd > ei {
				bits++
				continue
			}
			break
		}
		size := uint32(1) << (32 - bits)
		out = append(out, fmt.Sprintf("%s/%d", net.IP(s).To4().String(), bits))
		si += size
		if size == 0 {
			break
		}
	}
	return out
}
