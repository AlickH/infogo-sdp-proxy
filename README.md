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

### 重新构建 / 公证（两步）

合并后只有 **一个** 系统扩展（`com.alick.sdp-proxy.ne`），App 与扩展都由 `xcodebuild`
用同一张 Developer ID 证书签好，不再需要手工组装目录、也不再需要二次签名：

```bash
# 1. 编译 + 签名 → dist/SDP.app（未公证）
./scripts/build-xcode.sh

# 2. 打包 ZIP → asc 公证（--wait）→ staple → Gatekeeper 校验
./scripts/notarize.sh
```

前置：钥匙串里有 Developer ID Application 证书、`asc` 已登录（`asc auth doctor`）、
两个 profile（`build/profiles/` 已被 `.gitignore` 忽略）：

```bash
mkdir -p build/profiles
asc profiles download --id <app-profile-id> --output build/profiles/app.provisionprofile
asc profiles download --id <ne-profile-id>  --output build/profiles/ne.provisionprofile
```

`notarize.sh` 先 `codesign --verify --deep --strict` 确认 hardened runtime 与安全时间戳，
再提交公证；偶发 `S3 upload failed` 属瞬时错误，脚本会自动重试一次。

> 2026-11-12 实测：提交返回 `"status":"Accepted"`，`stapler validate` 报
> **The validate action worked!**，票据已附到 `dist/SDP.app`。

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
  -framework NetworkExtension -framework SystemExtensions \
  macapp/SDPApp.swift macapp/Views.swift macapp/QRWebView.swift \
  macapp/NEManager.swift macapp/WGManager.swift macapp/TSManager.swift \
  macapp/Core/*.swift \
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

## macOS：Tailscale 标签页

菜单栏面板新增第三个 tab **Tailscale**，与 SDP / WireGuard 并列。仅 macOS 原生 SwiftUI App 提供；Windows / Go CLI 的 Web UI 不含该 tab。

### 界面

| 区域 | 内容 |
|---|---|
| 状态 | BackendState（Running / NeedsLogin / Starting…）、本机 `100.x.y.z`、tailnet、RX/TX |
| 登录 | 交互式登录时显示「打开登录链接」，浏览器完成 SSO 后节点自动上线 |
| 节点 | 对端节点列表（在线 / 直连 / DERP 中继 / 离线） |
| 配置 | 多配置列表，支持新建、编辑、删除、切换；右上角 `+` 打开编辑 Sheet |
| 底部 | 连接开关 + 退出登录；日志按钮切换为「Tailscale 日志」 |

### 配置字段

| 字段 | 说明 |
|---|---|
| Control URL | 默认 `https://controlplane.tailscale.com`，可指向自建 Headscale |
| Auth Key | `tskey-...` 预授权；留空则走交互式 SSO 登录 |
| 设备名 / MTU | 自定义 hostname；MTU 默认 1280 |
| 捕获路由 | 默认 `100.64.0.0/10`（CGNAT 段） |
| 广播子网 | 逗号分隔 CIDR，作为 subnet router 广播 |
| Exit Node | 节点名或 IP，可留空 |
| MagicDNS / 接受子网路由 / Shield incoming / On-Demand | 开关 |

配置持久化在 `~/.sdp-proxy/tailscale.json`，日志 `~/.sdp-proxy/tailscale.log`（2MB 滚动）。环境变量 `SDP_TS_AUTO=1` 可在启动时自动连接。

### 网段隔离

| 隧道 | 网段 |
|---|---|
| SDP NE | `172.30.0.0/16`、`10.240.0.0/12`、`122.191.10.0/24` |
| WireGuard | 配置里的 `AllowedIPs`（常见 `10.0.0.0/24`） |
| Tailscale | `100.64.0.0/10` |

三段互不重叠，三个隧道可以同时开启而不会互相劫持。

### 系统扩展（三个功能合并为一个 SDPNE）

| 文件 | 作用 |
|---|---|
| `ne/Merged/MergedProvider.swift` | 唯一的 `NEPacketTunnelProvider`：一条 packet flow + `features` 开关 |
| `ne/Merged/PacketDispatcher.swift` | 按目的 IP 最长前缀分流数据包、按 `name:` 前缀分发控制消息、`onOutbound` 回写 flow |
| `ne/Merged/SDPEngine.swift` | SDP 引擎：socketpair + hev（lwIP + SOCKS5）代理管道 |
| `ne/Merged/WGEngine.swift` | WireGuard 引擎：wgbridge 内存隧道（`TsbridgeWg*`） |
| `ne/Merged/TSEngine.swift` | Tailscale 引擎：`TSBridgeRuntime(ownsFlow: false)` + `Tsbridge` framework |
| `ne/Merged/EngineProtocol.swift` | `TunnelEngine` 协议与 `IPPrefix` 分类器 |
| `ne/TailscaleRuntime.swift` | `TailscaleRuntime` 桥接协议、`TSTunnelSettings`、`TSMessageRouter` |
| `ne/Info.plist` | 唯一扩展的 plist：`NEProviderClasses = SDPNE.MergedProvider` |
| `ne/SDPNE.entitlements` | packet-tunnel-provider-systemextension + App Group |
| `macapp/MergedTunnel.swift` | 合并隧道门面：旧配置迁移、功能开关、`providerConfiguration` 下发 |
| `macapp/{NEManager,WGManager,TSManager}.swift` | 三个功能各自的配置 / 状态 / 日志 / 安装 |
| `scripts/build-xcode.sh` | xcodegen → Release 构建 → `dist/SDP.app`（App + SDPNE 一起签名） |
| `scripts/notarize.sh` | ZIP → `asc` 公证 → staple → Gatekeeper 校验 |
| `scripts/build-tsbridge.sh` | 用 gomobile 把 Tailscale daemon 编译成 `Tsbridge.xcframework` |
| `assets/SDP-Info.plist` | App 的 Info.plist |
| `tsbridge/bridge.go` | Go 桥接包：`tailscale.com/tsnet` → gobind 兼容的极简 API |
| `tsbridge/packetdevice.go` | `tun.Device` 实现，注入 `tsnet.Server.Tun`，双向搬运裸 IP 包 |
| `tsbridge/packetdevice_test.go` | 数据面契约单测（含 `-race`） |
| `Tools/TSBridgeRuntime.swift` | 调用 `Tsbridge` framework 的 `TailscaleRuntime` 实现 |
| `Tools/TSTunnelSelfTest.swift` | 宿主层端到端自检（41 项，无需签名/引擎/扩展上下文） |

App 侧只通过 `sendProviderMessage` 与扩展通信，不走 HTTP；三个功能共用一条隧道，
消息用 `<engine>:` 前缀寻址：

```
Views.swift (SDP / WireGuard / Tailscale 三个 tab)
  → AppModel.toggleNE() / toggleWG() / toggleTS()
  → NEManager / WGManager / TSManager
  → MergedTunnel.shared.set("sdp" | "wg" | "ts", enabled: ...)  ← 单条 NETunnelProviderManager
  → SDPNE.MergedProvider（providerConfiguration["features"] = ["sdp","wg","ts"]）
  → PacketDispatcher → SDPEngine / WGEngine / TSEngine
       "ts:status"   → TSRuntimeStatus JSON（backendState / selfIPs / authURL / tailnet / peers / rxBytes / txBytes）
       "ts:logout"   → 清除登录态
       "wg:..." / "sdp:..." → 对应引擎
```

### 构建依赖（gomobile / Tailscale 引擎）

Tailscale 官方开源的有两块：`github.com/tailscale/tailscale`（daemon：`ipn` / `wgengine` / `cmd/tailscaled`）和 `github.com/tailscale/libtailscale`（BSD-3-Clause）。后者用 `go build -buildmode=c-archive` 产出 C 静态库 `libtailscale.a` + `tailscale.h`，其 `swift/` 目录还提供官方 **`TailscaleKit.framework`**（Xcode `make macos` 编译，含 `TailscaleNode` / `URLSession+Tailscale` / LocalAPI）。注意它**不是 gomobile**。

`tailscale/ipn-go-bridge` 这个仓库不存在（404），Apple NetworkExtension 的宿主层与数据面桥接仍是闭源的。`TailscaleKit` 是进程内 userspace 嵌入式网络接口（listen / dial / URLSession 代理），仓库里没有 `NEPacketTunnelFlow` / `tun.Device` 数据面桥接，C API 也不暴露 tun 注入点。因此本项目用 `gomobile` 编译自己的 `Tsbridge.xcframework`，并利用开源 daemon 的 `tsnet.Server.Tun` 注入点（`tsnet/tsnet.go:332`）实现真正的 packet tunnel 数据面。

1. 安装工具链（一次性）：

   ```bash
   go install golang.org/x/mobile/cmd/gomobile@latest
   export PATH="$(go env GOPATH)/bin:$PATH"
   gomobile init
   ```

2. 编译引擎 framework：

   ```bash
   ./scripts/build-tsbridge.sh
   # 默认产物 /tmp/Tsbridge.xcframework（约 104MB，arm64 + x86_64 静态库）
   ```

   `tsbridge/` 是独立 Go module，把 `tailscale.com/tsnet` 封装成 gobind 兼容的极简 API：`TsbridgeStart / Stop / Status / Logout / LoginInteractive / Version`（状态 JSON）与 `TsbridgeDeliverInboundPacket / ReadOutboundPacket`（裸 IP 包搬运）。直接 `gomobile bind tailscale.com/tsnet` 会因多返回值方法等复杂类型报错甚至 panic，所以必须走这层封装。`packetdevice.go` 实现 `tun.Device` 并注入 `tsnet.Server.Tun`。生成的头文件在 `Tsbridge.framework/Headers/Tsbridge.objc.h`。

3. 编译整个扩展（App + SDPNE 一起）：

   ```bash
   ./scripts/build-xcode.sh      # xcodegen 生成工程 → Release 构建 → dist/SDP.app
   ./scripts/notarize.sh         # 公证 + staple（发行时必须）
   ```

   `Tools/TSBridgeRuntime.swift` 已经作为 SDPNE 的编译源挂在 `project.yml` 里，
   `-D TS_HAS_BRIDGE` 与 `-framework Tsbridge` 也在同一处配置，不再需要单独编译
   某个「TSNE 二进制」。三个功能由 `providerConfiguration["features"]` 决定启用哪些。

4. profile 只需要两个：`build/profiles/{app,ne}.provisionprofile`
   （旧的三扩展方案要四个，`wg` / `ts` 已随合并删除）。

> **数据面已接通**：Go 侧 `tsbridge/packetdevice.go` 实现 `tun.Device` 的 8 个方法并注入 `tsnet.Server.Tun`，Swift 侧 `Tools/TSBridgeRuntime.swift` 用 `packetFlow.readPackets` → `TsbridgeDeliverInboundPacket`、`TsbridgeReadOutboundPacket` → `packetFlow.writePackets` 双向搬运**裸 IP 包**（无 utun 的 4 字节 AF 头，协议族由首字节高 4 位判定），并配置 `100.64.0.0/10` includedRoutes 与 MagicDNS。契约由 `tsbridge/packetdevice_test.go`（含 `-race`）验证。
>
> ⚠️ 签名 / 公证链路已打通（单扩展包实测 Accepted 且 staple 成功），但**合并后的三引擎
> 运行时仍未上真机验证**：WG / TS 的内存隧道与 SDP 的 socketpair 管道共用同一条
> `NEPacketTunnelNetworkSettings` 后是否冲突、开关单独启停是否互不影响，都需要装到
> `/Applications` 后实测。任一路由未命中时包会落到 SDP 兜底（未启用则丢弃），不会静默串流。

### 宿主层自检（无需签名 / 无需引擎）

```bash
swiftc -parse-as-library -target arm64-apple-macosx13.0 \
  -framework NetworkExtension -framework Network \
  -framework AppKit -framework SystemExtensions \
  ne/TailscaleRuntime.swift macapp/TSManager.swift Tools/TSTunnelSelfTest.swift \
  -o /tmp/ts-selftest && /tmp/ts-selftest
```

覆盖 41 项：CIDR→掩码、`TSTunnelSettings.build` 路由/掩码/网关/DNS/MTU、`TSConfig` / `TSStore` Codable 往返、App↔扩展 `status` JSON 契约、`TSMessageRouter` 的 `ping` / `status` / `logout` / 未知命令、缺引擎行为，以及 Mock 引擎 `start → applySettings → status → logout → stop` 全生命周期。全部 PASS 时进程返回 0。

> `NEPacketTunnelProvider` 不能在非扩展环境实例化（访问其 Swift 存储属性会崩），所以消息通道逻辑抽到了独立的 `TSMessageRouter`，自检测的是它而不是直接构造 Provider。

### 当前状态

| 能力 | 状态 |
|---|---|
| 三隧道合并为单扩展（`MergedProvider` + 分类器 + 三引擎） | 已完成，`BUILD SUCCEEDED` |
| tailnet 配置 / 状态轮询 / 日志 | 已完成 |
| Tailscale 宿主层（生命周期、配置下发、消息通道） | 已完成，自检 41/41 |
| Tailscale Go 引擎 framework | 已完成：`build-tsbridge.sh` 产出 104MB xcframework，Swift 可链接并调用 |
| IP 包转发（tun.Device ↔ packetFlow，经 dispatcher） | 已实现，编译 + 单测通过；**待真机 NE 环境验证** |
| Developer ID 签名 / 公证 / staple | 已完成：单扩展发行包 Accepted，`stapler validate` 通过 |
| 合并后运行时正确性 | **待验证**：三引擎路由/DNS 合并、功能开关互不影响均未经真机验证 |
| `dist/SDP.app` 与源码的一致性 | **已过期**：现存公证件早于 4 处 Manager 逻辑修复，发行前需重建 + 重新公证 |
