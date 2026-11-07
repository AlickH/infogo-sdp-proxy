package main

// 系统代理开关（Windows: WinINET AutoConfigURL；macOS: networksetup PAC）

import (
	"fmt"
	"os/exec"
	"runtime"
	"strings"
)

// wininetProxy 读取 Windows 系统代理配置
type wininetProxy struct {
	AutoConfigURL string
	ProxyEnable   bool
	ProxyServer   string
}

func readWinINETProxy() wininetProxy {
	var p wininetProxy
	key := `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`
	// AutoConfigURL
	c := exec.Command("reg", "query", key, "/v", "AutoConfigURL")
	hideWindow(c)
	if out, err := c.Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			if strings.Contains(line, "AutoConfigURL") {
				fields := strings.Fields(line)
				if len(fields) >= 3 {
					p.AutoConfigURL = fields[len(fields)-1]
				}
			}
		}
	}
	// ProxyEnable / ProxyServer
	c = exec.Command("reg", "query", key, "/v", "ProxyEnable")
	hideWindow(c)
	if out, err := c.Output(); err == nil {
		if strings.Contains(string(out), "0x1") {
			p.ProxyEnable = true
		}
	}
	c = exec.Command("reg", "query", key, "/v", "ProxyServer")
	hideWindow(c)
	if out, err := c.Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			if strings.Contains(line, "ProxyServer") {
				fields := strings.Fields(line)
				if len(fields) >= 3 {
					p.ProxyServer = fields[len(fields)-1]
				}
			}
		}
	}
	return p
}

// otherSystemProxyPresent 判断是否存在其他系统代理 / PAC
func otherSystemProxyPresent() bool {
	if runtime.GOOS != "windows" {
		return false
	}
	p := readWinINETProxy()
	// 指向本程序的都算自己的（包括旧版本留下的 PAC）
	if p.AutoConfigURL != "" && !strings.Contains(p.AutoConfigURL, ":28181") {
		return true
	}
	if p.ProxyEnable && p.ProxyServer != "" && !strings.Contains(p.ProxyServer, ":11096") {
		return true
	}
	return false
}

// systemProxyEnabled 判断系统代理是否指向本 App 的 PAC
func systemProxyEnabled() bool {
	switch runtime.GOOS {
	case "windows":
		p := readWinINETProxy()
		return p.ProxyEnable && strings.Contains(p.ProxyServer, ":11096")
	case "darwin":
		for _, svc := range macServices() {
			out, _ := exec.Command("/usr/sbin/networksetup", "-getautoproxyurl", svc).Output()
			if strings.Contains(string(out), "28181") && strings.Contains(string(out), "Enabled: Yes") {
				return true
			}
		}
	}
	return false
}

// setSystemProxy 开启/关闭系统代理
func setSystemProxy(enable bool) error {
	pac := "http://127.0.0.1:28181/proxy.pac"
	switch runtime.GOOS {
	case "windows":
		key := `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`
		if enable {
			// 清理旧版本留下的 PAC，改用标准手动代理（Windows 设置里可见）
			del := exec.Command("reg", "delete", key, "/v", "AutoConfigURL", "/f")
			hideWindow(del)
			_ = del.Run()
			if out, err := runReg(key, "ProxyServer", "REG_SZ", "127.0.0.1:11096"); err != nil {
				return fmt.Errorf("%v: %s", err, out)
			}
			if out, err := runReg(key, "ProxyOverride", "REG_SZ", "<local>"); err != nil {
				return fmt.Errorf("%v: %s", err, out)
			}
			if out, err := runReg(key, "ProxyEnable", "REG_DWORD", "1"); err != nil {
				return fmt.Errorf("%v: %s", err, out)
			}
			return nil
		}
		_, _ = runReg(key, "ProxyEnable", "REG_DWORD", "0")
		del := exec.Command("reg", "delete", key, "/v", "AutoConfigURL", "/f")
		hideWindow(del)
		_ = del.Run()
		return nil
	case "darwin":
		svcs := macServices()
		if len(svcs) == 0 {
			return fmt.Errorf("未找到活动网络服务")
		}
		svc := svcs[0]
		if enable {
			if out, err := exec.Command("/usr/sbin/networksetup", "-setautoproxyurl", svc, pac).CombinedOutput(); err != nil {
				return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
			}
			if out, err := exec.Command("/usr/sbin/networksetup", "-setautoproxystate", svc, "on").CombinedOutput(); err != nil {
				return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
			}
		} else {
			if out, err := exec.Command("/usr/sbin/networksetup", "-setautoproxystate", svc, "off").CombinedOutput(); err != nil {
				return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
			}
		}
		return nil
	}
	return fmt.Errorf("当前平台不支持")
}

// macServices 返回有 IPv4 地址的网络服务名
func macServices() []string {
	out, err := exec.Command("/usr/sbin/networksetup", "-listallnetworkservices").Output()
	if err != nil {
		return nil
	}
	var res []string
	for _, line := range strings.Split(string(out), "\n") {
		svc := strings.TrimSpace(line)
		if svc == "" || strings.HasPrefix(svc, "*") || strings.Contains(svc, "An asterisk") {
			continue
		}
		info, err := exec.Command("/usr/sbin/networksetup", "-getinfo", svc).Output()
		if err == nil && strings.Contains(string(info), "IP address:") {
			res = append(res, svc)
		}
	}
	return res
}

// runReg 写注册表值
func runReg(key, name, typ, value string) (string, error) {
	cmd := exec.Command("reg", "add", key, "/v", name, "/t", typ, "/d", value, "/f")
	hideWindow(cmd)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}
