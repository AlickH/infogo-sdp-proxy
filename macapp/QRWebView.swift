import SwiftUI
import WebKit

/// 二维码视图：直接加载官方登录页，拦截扫码后的跳转
// 二维码容器：直接加载官方登录页，拦截跳转判断扫码完成
struct QRContainer: View {
    let url: String
    let onScanned: () -> Void
    @State private var loaded = false

    var body: some View {
        ZStack {
            if !loaded || url.isEmpty {
                ProgressView()
            } else {
                Color.clear
            }
            if !url.isEmpty {
                QRWebView(url: url, onLoaded: {
                    withAnimation(.easeOut(duration: 0.18)) { loaded = true }
                }, onScanned: onScanned)
                .opacity(loaded ? 1 : 0)
            }
        }
        .onChange(of: url) { _ in loaded = false }
    }
}

struct QRWebView: NSViewRepresentable {
    let url: String
    let onLoaded: () -> Void
    let onScanned: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 460), configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.autoresizingMask = [.width, .height]
        // 官方页面最小宽度约 375pt，缩 0.8 后完整显示且居中
        wv.pageZoom = 0.8
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        guard !url.isEmpty, context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        context.coordinator.onLoaded = onLoaded
        context.coordinator.onScanned = onScanned
        if let u = URL(string: url) {
            wv.load(URLRequest(url: u))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL = ""
        var onLoaded: (() -> Void)?
        var onScanned: (() -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onLoaded?() }
        }

        /// 页面扫码后会被重定向到 SDP 服务端（redirect_uri），拦截它并通知轮询
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = navigationAction.request.url,
               u.host?.contains("sdp.cscec5b.com.cn") == true,
               u.path.contains("/wework/user") {
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.onScanned?() }
                return
            }
            decisionHandler(.allow)
        }
    }
}
