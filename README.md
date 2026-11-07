# Infogo SDP 独立代理（纯 Go）

不依赖官方客户端、不接管网络（无 utun/TUN）、无需 Docker。
自己完成 **中建通二维码登录** + **SOCKS5 代理**，把内网资源流量交给代理软件（Surge/Clash 等）按需转发。

## 交付物

| 平台 | 形式 | 位置 |
|---|---|---|
| macOS | `SDP.app`（原生主界面 + 菜单栏图标） | `dist/SDP.app` → 安装到 `~/Applications/` |
| Windows | `SDP-Windows.zip`（exe + 脚本，网页管理界面） | `dist/SDP-Windows.zip` |
| 通用 | 单文件 CLI | `dist/sdp-proxy-darwin-*`、`dist/sdp-proxy-windows-amd64.exe` |

## 主界面（状态机）

界面按连接状态自动切换，和官方客户端流程一致：

| 状态 | 界面 | 说明 |
|---|---|---|
| `connected` | ✓ 已连接 + 账号 / 会话 / 资源列表 | 正常在线，不显示扫码 |
| `login_required` | 需要登录 → 「扫码登录」按钮 | 首次使用或 token 丢失 |
| `scanning` | 二维码 + 步骤条（① 扫码） | 等待中建通扫码，二维码自动刷新 |
| `checking` | 验证中（② 认证 → ③ 安检） | 扫码后自动认证、下单、激活会话 |
| `offline` | ⚠ 连接已断开 → 「重新扫码登录」 | 会话过期时自动跳转 |

**日志**收在底部「日志」按钮里（macOS 打开独立日志窗口，Windows 为抽屉面板），不占主界面。

- **macOS**：`SDP.app` 原生窗口 + 菜单栏图标（打开主界面 / 查看日志 / 退出）
- **Windows**：`SDP代理.bat` 启动后浏览器打开同一界面（http://127.0.0.1:28181）

## 快速开始（macOS App）

1. 双击 `SDP.app`
2. 主界面点「扫码登录」→ 用中建通扫码
3. 登录成功后自动启动代理（127.0.0.1:11095）
4. Surge 配置指向 `socks5, 127.0.0.1, 11095`

## 快速开始（命令行）

```bash
# 1. 登录（弹出二维码链接，用中建通扫码）
./sdp-proxy-darwin-arm64 -config config.json -login

# 2. 登录成功后程序自动启动 SOCKS5 代理
#    监听 127.0.0.1:11095
```

Surge 配置：

```ini
[Proxy]
CSCEC = socks5, 127.0.0.1, 11095, ip-version=v4-only

[Rule]
RULE-SET,https://raw.githubusercontent.com/AlickH/RuleSet/master/myCSCEC.list,CSCEC,no-resolve
```

## 配置

```json
{
  "gateway": "122.191.10.77:27442,122.191.10.77:37442,122.191.10.77:47442",
  "server_name": "sdp.cscec5b.com.cn",
  "server_base": "https://sdp.cscec5b.com.cn:17441",
  "device_id": "888499",
  "listen": "127.0.0.1:11095",
  "resources": [
    {"domain": "cscec5b.com.cn", "resid": "241"},
    {"domain": "cscec.com", "resid": "241"},
    {"domain": "erp.hnzjdc.com", "resid": "191"},
    {"domain": "portal.cscec5b.com.cn", "resid": "244"}
  ]
}
```

| 字段 | 说明 |
|---|---|
| `gateway` | 网关地址（逗号分隔，按顺序尝试） |
| `server_name` | TLS SNI |
| `server_base` | 服务端 API 地址（登录用） |
| `device_id` | 设备 ID（默认 888499） |
| `listen` | 本地 SOCKS5 监听 |
| `resources` | 域名 → 资源 ID 映射（子域名自动匹配） |

## 登录流程（已完全逆向）

```
1. GET  /server/info?basIP=&firsturl=&version=6039.3746   → pubKey / ZJTConfig / ControlUrl
2. 生成二维码：<ZJT url>/wwopen/sso/qrConnect?appid=<corpId>&agentid=<agentid>
              &redirect_uri=<ControlUrl>/access/1.0/linux/json/wework/user?deviceid&time&zjt=1
              &state=&login_type=jssdk
3. POST /wework/user  (body: action=check&deviceid&time)  → 中建通 token + username
4. RSA-PKCS1v15(token, pubKey) → POST /auth/index        → 客户端 Token
5. POST /check/success, POST /ZtpGateway/getGateway      → 激活会话、获取网关
```

关键细节（踩过的坑）：

- `Session-Num` 头 = md5(路径+参数)，参数用 **原始值**（未 URL 编码），并过滤掉白名单外字符
- POST 参数放 **body**，URL 只带 `local_lguage_set` 和 `cache`
- 必须用公共 DNS 解析真实 IP 直连（本机代理的 fake-IP DNS 会把请求劫持到别处）

## 网关数据协议（已完全逆向）

```
TLS 连接网关 → SOCKS5 (0x80 no-auth)
  → 认证: 0x80 | len(token) | token | len(resid) | resid
  → CONNECT: 05 01 00 | 03 len(domain) domain | port | 00 | len | base64(JSON)
  → 之后是原始字节流（内层 TLS/HTTP 直接透传）
```

JSON：`{"version":1,"data":{"client_ip":"<本机IP>","process_name":"isaproxy","os":"linux"}}`

## 签名与公证

macOS 发行包使用 **Developer ID Application: Ning Huang (KLU8GF65GP)** 签名，
已通过 Apple 公证（Notarization）并 staple 票据，Gatekeeper 验证结果：

```
SDP.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: Ning Huang (KLU8GF65GP)
```

重新签名/公证流程：

```bash
ID="Developer ID Application: Ning Huang (KLU8GF65GP)"
codesign --force --options runtime --timestamp --sign "$ID" SDP.app/Contents/Resources/sdp-proxy
codesign --force --options runtime --timestamp --sign "$ID" SDP.app
ditto -c -k --keepParent SDP.app SDP.zip
asc notarization submit --file SDP.zip --wait
xcrun stapler staple SDP.app
```

## 构建

```bash
GOOS=darwin  GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o dist/sdp-proxy-darwin-arm64 .
GOOS=darwin  GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/sdp-proxy-darwin-amd64 .
GOOS=windows GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/sdp-proxy-windows-amd64.exe .
```

## 自动能力

- **Token 续期**：每 60 秒调 `device/netStatus`，服务端下发新 token 时自动更新并保存
- **资源自动发现**：登录后从 `ztpResource/list` 拉取资源（域名/IP/CIDR → ResID），每 10 分钟刷新；`config.resources` 作为补充
- **会话检测**：`SessionStatus` 非 0/8 时日志提示需要重新扫码登录

## 独立使用（不需要 Surge）

App 自带 PAC 自动代理配置，内网域名走隧道、其余流量直连：

1. 打开 App 主界面 → 点「**设为系统代理**」
   - macOS：自动通过 PAC（http://127.0.0.1:28181/proxy.pac）配置系统自动代理
   - Windows：双击 `设置系统代理.bat`（写入 AutoConfigURL）
2. 之后浏览器/大多数 App 的内网访问自动走隧道，其他网站直连
3. 取消：再点一次「取消系统代理」/ 运行 `取消系统代理.bat`

> 也可以用 Surge/Clash/Proxifier 手动把 SOCKS5 指向 `127.0.0.1:11095`，两种方式二选一。

## 规则订阅（Surge / Clash 零维护）

App 会根据实时资源列表自动生成规则文件，代理软件只需填一次订阅地址，以后**不用再手工加规则**：

| 软件 | 配置 |
|---|---|
| Surge | `RULE-SET,http://127.0.0.1:28181/surge.list,CSCEC,no-resolve` |
| Clash | `rule-providers` 指向 `http://127.0.0.1:28181/clash.list`（behavior: classical） |
| 系统代理 | PAC 地址 `http://127.0.0.1:28181/proxy.pac` |

生成的规则包含：内网域名（DOMAIN-SUFFIX）、精确 IP、CIDR（IP-CIDR,no-resolve）。
注意 `sdp.cscec5b.com.cn`（控制通道）需要在规则集之前设置为 DIRECT。

## 与 Surge / Clash 等代理软件共存

可以同时运行，互不冲突（实测 Surge + App 共存：OA 200、其他网站 200）。注意三点：

| 项 | 说明 |
|---|---|
| 端口 | App 用 `11095`（SOCKS5）/ `28181`（界面），与 Surge 端口不冲突 |
| 系统代理 | **只能一个生效**。App 的「设为系统代理」和 Surge 的系统代理会互相覆盖，二选一 |
| Surge 增强模式(TUN) | 会接管 App 连网关的 TCP，需在 Surge 加直连规则：`IP-CIDR,122.191.10.77/32,DIRECT,no-resolve`，否则可能形成回环 |

推荐用法：
- **用 Surge 分流**：Surge 规则 `CSCEC = socks5, 127.0.0.1, 11095`，App 不点系统代理
- **不装 Surge**：App 点「设为系统代理」（PAC），其余代理软件不要开系统代理/TUN

## 各平台接管方式

| 平台 | 接管机制 | 生效范围 |
|---|---|---|
| macOS | 系统 PAC（`networksetup` 自动代理）→ HTTP 代理 `127.0.0.1:11096` / SOCKS5 `11095` | 认系统代理的应用 |
| Windows | 注册表 `AutoConfigURL` → PAC → HTTP 代理 `127.0.0.1:11096` | 认系统代理（WinINET）的应用，如浏览器/Electron |
| 通用 | SOCKS5 `127.0.0.1:11095`（给 Surge/Clash/Proxifier） | 由代理软件决定 |

> 为什么系统代理用 HTTP 代理而不是 SOCKS5：WinINET 对 SOCKS5 常先本地解析成 IP，导致域名匹配失效；HTTP CONNECT 保留原始域名，更可靠。SOCKS5 端口保留给第三方代理软件使用。

PAC 判断支持三类目标：

| 类型 | 示例 | PAC 实现 |
|---|---|---|
| 域名后缀 | `cscec5b.com.cn` | 后缀匹配 |
| 精确 IP | `208.98.43.99` | 字符串相等 |
| CIDR | `10.241.65.0/24` | `isInNet(host, net, mask)` |

## Windows：没有前置代理时

App 只提供本地 SOCKS5(11095) / HTTP(11096) 代理。没有 Surge/Clash 等前端时：

1. 必须打开「系统代理」（界面里或托盘右键），写入 PAC
2. 只覆盖认系统代理的程序（浏览器 / Electron / Office 等）
3. 不认系统代理的程序需 Proxifier/Clash 指向 `127.0.0.1:11095`

退出行为：退出时自动关闭系统代理（若为本程序开启），并关闭界面窗口。

## 说明

- 不创建 utun/TUN，不接管系统网络，只提供一个本地 SOCKS5
- 无审查/杀毒检测等模块
- 网关证书不校验（与官方 isaproxy 一致）
- Token 约 25 分钟~12 小时由服务端决定，失效后重新 `-login`


## macOS 重装后图标显示为通用占位图

LaunchServices 会缓存旧图标，重装到同一路径后可能仍显示占位图，执行：

```bash
./scripts/refresh-icon-cache.sh ~/Applications/SDP.app
```

内部会执行 `lsregister -f` + `touch`，然后重启 Finder。


## macOS 版：纯 Swift 实现

macOS 端已不再依赖 Go 子进程，全部逻辑在 Swift 内完成：

```
macapp/Core/
├── Config.swift      # 配置读写
├── DNS.swift         # 公共 DNS 解析（223.5.5.5，避开 fake-IP）
├── SessionNum.swift  # Session-Num 签名（MD5）
├── TLSHTTP.swift     # 裸 TLS HTTP/1.1（指定连接 IP + SNI）
├── ApiClient.swift   # SDP API 客户端
├── RSA.swift         # RSA PKCS#1 加密（登录认证）
├── Gateway.swift     # 网关隧道协议（auth/CONNECT 帧）
├── Streams.swift     # 字节流抽象与双向转发
├── ProxyServer.swift # 本地 SOCKS5 / HTTP 代理 / 规则服务
├── RuleStore.swift   # 资源规则匹配（域名/IP/CIDR/端口）
├── RuleText.swift    # PAC / Surge / Clash 规则生成
└── Engine.swift      # 登录、会话、策略、状态机
```

构建（无需 Go）：

```bash
swiftc -parse-as-library -O -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework Cocoa -framework WebKit \
  -framework Network -framework Security -framework CryptoKit \
  macapp/SDPApp.swift macapp/Views.swift macapp/QRWebView.swift macapp/Core/*.swift \
  -o SDP.app/Contents/MacOS/SDP
```

Windows 版仍为 Go 单文件（`go build -ldflags "-H=windowsgui"`）。

### macOS 核心自检

```bash
# 策略表 / 隧道 / RSA
swiftc -parse-as-library -O -target arm64-apple-macosx13.0 \
  -framework Network -framework Security -framework CryptoKit \
  macapp/Core/*.swift Tools/main.swift -o /tmp/sdptest && /tmp/sdptest

# 扫码重定向拦截（无需真实扫码）
swiftc -parse-as-library -O -target arm64-apple-macosx13.0 \
  -framework AppKit -framework WebKit -framework SwiftUI \
  macapp/QRWebView.swift Tools/QRRedirectTest.swift -o /tmp/qrtest && /tmp/qrtest
```
