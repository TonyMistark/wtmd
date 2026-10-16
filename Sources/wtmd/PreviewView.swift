import SwiftUI
import WebKit
import WTMarkdownKit

/// 预览视图：WKWebView 封装，支持增量更新（不重载页面，滚动位置天然保持）。
struct PreviewView: NSViewRepresentable {
    @Binding var html: String
    @Binding var currentSlug: String?
    var themeCSS: String
    var diff: BlockDiff?
    var jump: JumpRequest?
    var generation: Int
    var documentTitle: String
    var baseURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.reload()
        return coordinator.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if generation != coordinator.lastGeneration {
            coordinator.lastGeneration = generation
            coordinator.lastHTML = html
            coordinator.lastThemeCSS = themeCSS
            coordinator.reload()
            return
        }

        if html != coordinator.lastHTML {
            coordinator.lastHTML = html
            if let diff, !diff.isEmpty {
                // 增量：只替换变化段，未变块（图片/图表）保持原位
                let payload = diffPayload(diff)
                coordinator.webView.evaluateJavaScript("__wtmdUpdateRange(\(payload))")
            } else {
                let json = encodeJS(html)
                coordinator.webView.evaluateJavaScript("__wtmdUpdate(\(json))")
            }
        }

        // 主题热切换：只替换变量层，正文 DOM 与滚动位置不动
        if themeCSS != coordinator.lastThemeCSS {
            coordinator.lastThemeCSS = themeCSS
            coordinator.applyTheme(themeCSS)
        }

        if let jump, jump.id != coordinator.lastJumpID {
            coordinator.lastJumpID = jump.id
            let json = encodeJS(jump.slug)
            coordinator.webView.evaluateJavaScript(
                "var el = document.getElementById(\(json)); if (el) el.scrollIntoView({behavior:'smooth', block:'start'});"
            )
        }
    }

    private func encodeJS(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode([s]),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        // JSON 数组 ["..."] → 取出元素即合法 JS 字符串字面量
        return String(json.dropFirst().dropLast())
    }

    /// BlockDiff → JS 对象字面量 {prefix, suffix, replacement: [...]}。
    private func diffPayload(_ diff: BlockDiff) -> String {
        let parts = diff.replacement.map { encodeJS($0) }
        return "{prefix: \(diff.commonPrefix), suffix: \(diff.commonSuffix), replacement: [\(parts.joined(separator: ","))]}"
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: PreviewView
        let webView: WKWebView
        var lastHTML = ""
        var lastThemeCSS = ""
        var lastGeneration = -1
        var lastJumpID = ""
        /// 文档未加载完时暂存的主题，didFinish 后补发。
        private var pendingThemeCSS: String?

        init(_ parent: PreviewView) {
            self.parent = parent

            let config = WKWebViewConfiguration()
            let userContent = config.userContentController
            let script = WKUserScript(
                source: StyleSheet.script,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            userContent.addUserScript(script)

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.setValue(false, forKey: "drawsBackground")
            self.webView = webView

            super.init()
            userContent.add(self, name: "wtmd")
            webView.navigationDelegate = self
        }

        func reload() {
            let html = StyleSheet.fullDocument(
                title: parent.documentTitle,
                body: parent.html,
                themeCSS: parent.themeCSS,
                includeScript: true
            )
            // 重载后的 DOM 就是当前 html/主题这一代，先对齐基准：
            // 否则首帧会把上一轮的 diff 套用到刚装载的 DOM 上（模式切换回来时会错位）
            lastHTML = parent.html
            lastThemeCSS = parent.themeCSS
            lastGeneration = parent.generation
            webView.loadHTMLString(html, baseURL: parent.baseURL)
        }

        /// 应用主题：加载中则入队，否则立即注入。
        func applyTheme(_ css: String) {
            guard !webView.isLoading else {
                pendingThemeCSS = css
                return
            }
            let json = PreviewView.encodeJSStatic(css)
            webView.evaluateJavaScript("__wtmdSetTheme(\(json))")
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let pending = self.pendingThemeCSS {
                    self.pendingThemeCSS = nil
                    let json = PreviewView.encodeJSStatic(pending)
                    self.webView.evaluateJavaScript("__wtmdSetTheme(\(json))")
                }
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "wtmd",
                  let body = message.body as? [String: Any],
                  let slug = body["slug"] as? String
            else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.currentSlug = slug
            }
        }
    }

    private static func encodeJSStatic(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode([s]),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}
