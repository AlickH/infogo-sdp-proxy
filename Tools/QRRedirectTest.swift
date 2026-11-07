import AppKit
import WebKit

func out(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// 验证扫码后的重定向拦截逻辑（不需要真实扫码）
@main
struct QRRedirectTest {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let cfg = WKWebViewConfiguration()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 460), configuration: cfg)
        let coord = QRWebView.Coordinator()
        var scanned = false
        coord.onScanned = { scanned = true; out("onScanned 已触发") }
        wv.navigationDelegate = coord

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = wv
        window.orderFront(nil)

        wv.loadHTMLString("<html><body>placeholder</body></html>", baseURL: nil)
        // 模拟扫码后官方页面跳转到 redirect_uri 的导航
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let redirect = "https://sdp.cscec5b.com.cn:17441/access/1.0/linux/json/wework/user?deviceid=888499&time=123&zjt=1"
            out("模拟跳转: \(redirect)")
            wv.load(URLRequest(url: URL(string: redirect)!))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            out(scanned ? "结果: 拦截成功 ✅" : "结果: 未触发拦截 ❌")
            NSApp.terminate(nil)
        }
        app.run()
    }
}
