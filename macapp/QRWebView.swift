import SwiftUI
import WebKit

/// 二维码视图：直接加载官方登录页
/// - 页面缩放到 300 宽（官方最小宽度 375）
/// - 注入 CSS 去掉顶部灰色留白、白底贴顶
/// - 扫码后跳转必须放行（服务端靠这次请求记录扫码），收到响应后再取消渲染
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

    static let viewSize = CGSize(width: 300, height: 352)

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let wv = WKWebView(frame: NSRect(origin: .zero, size: Self.viewSize), configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.autoresizingMask = [.width, .height]
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
        private var injected = false

        /// 官方页面 body 是灰色、白卡片从 y=120 开始，这里贴顶并铺满
        private static let layoutJS = """
        (function(){
          document.body.style.background = '#ffffff';
          var panel = document.querySelector('.loginPanel');
          if (panel) { panel.style.marginTop = '-120px'; }
          document.documentElement.style.background = '#ffffff';
        })();
        """

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            injected = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !injected {
                injected = true
                webView.evaluateJavaScript(Self.layoutJS, completionHandler: nil)
            }
            DispatchQueue.main.async { self.onLoaded?() }
        }

        /// 扫码后页面会跳到 redirect_uri：必须放行请求（服务端靠它记录扫码），
        /// 但收到响应后取消渲染，避免面板里出现原始页面。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let u = navigationResponse.response.url,
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
