import SwiftUI
import WebKit
import WTMarkdownKit

/// 预览视图：WKWebView 封装，支持增量更新（不重载页面，滚动位置天然保持）。
struct PreviewView: NSViewRepresentable {
    @Binding var html: String
    @Binding var currentSlug: String?
    var themeCSS: String
    /// 读者的版式（版心/字号/行距）变量层。与主题分开：切主题不冲掉版式。
    var layoutCSS: String
    var diff: BlockDiff?
    var jump: JumpRequest?
    var generation: Int
    var documentTitle: String
    var baseURL: URL?
    /// Where the reader was, shared with the editor across view rebuilds.
    var positionMemory: PositionMemory?
    /// 分栏联动：把这一行对应的块滚到视口顶部。
    var scrollLine: SplitScrollRequest?
    /// 视口顶部落在哪一行（源码行号，找不到块时报 -1）。
    var onLineChange: ((Int) -> Void)?
    /// 每个顶层块的源码起始行，与 `html` 里拼出的块一一对应。
    var blockLines: [Int] = []

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
            coordinator.lastLayoutCSS = layoutCSS
            coordinator.reload()
            return
        }

        if html != coordinator.lastHTML {
            coordinator.lastHTML = html
            coordinator.lastBlockLines = blockLines
            let lines = PreviewView.encodeLines(blockLines)
            if let diff, !diff.isEmpty {
                // 增量：只替换变化段，未变块（图片/图表）保持原位
                let payload = diffPayload(diff)
                coordinator.webView.evaluateJavaScript("__wtmdUpdateRange(\(payload), \(lines))")
            } else {
                let json = encodeJS(html)
                coordinator.webView.evaluateJavaScript("__wtmdUpdate(\(json), \(lines))")
            }
        } else if blockLines != coordinator.lastBlockLines {
            // 文本没变、只有行号变了（理论上同一份文本不会，但换文档时会走 reload
            // 之外的路径）——顺手对齐一次，免得联动指到旧行。
            coordinator.lastBlockLines = blockLines
            coordinator.webView.evaluateJavaScript("__wtmdSetLines(\(PreviewView.encodeLines(blockLines)))")
        }

        // 主题热切换：只替换变量层，正文 DOM 与滚动位置不动
        if themeCSS != coordinator.lastThemeCSS {
            coordinator.lastThemeCSS = themeCSS
            coordinator.applyTheme(themeCSS)
        }

        // 版式同理：拖滑块时只换那几个变量，页面不重载
        if layoutCSS != coordinator.lastLayoutCSS {
            coordinator.lastLayoutCSS = layoutCSS
            coordinator.applyLayout(layoutCSS)
        }

        if let jump, jump.id != coordinator.lastJumpID {
            coordinator.lastJumpID = jump.id
            let json = encodeJS(jump.slug)
            coordinator.webView.evaluateJavaScript(
                "var el = document.getElementById(\(json)); if (el) el.scrollIntoView({behavior:'smooth', block:'start'});"
            )
        }

        // 分栏联动：源码光标换了段，把预览滚过去
        if let scrollLine, scrollLine.id != coordinator.lastScrollLineID {
            coordinator.lastScrollLineID = scrollLine.id
            coordinator.scrollToLine(scrollLine.line)
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
        var lastBlockLines: [Int] = []
        var lastThemeCSS = ""
        var lastLayoutCSS = ""
        var lastGeneration = -1
        var lastJumpID = ""
        var lastScrollLineID = 0
        /// 文档未加载完时暂存的主题，didFinish 后补发。
        private var pendingThemeCSS: String?
        /// 同上，版式。
        private var pendingLayoutCSS: String?
        /// 同上，联动滚动。
        private var pendingScrollLine: Int?
        /// 刚装载完的一小段时间内不报联动行号：恢复上次位置本身会触发 scroll 事件，
        /// 那一帧的位置是「上次读到哪」，不是「读者现在滚到哪」。让它去推源码，
        /// 会把刚恢复好的光标位置顶回文首。
        private var ignoreLineUntil: TimeInterval = 0
        /// 重建前记住的锚点，页面加载完成后回填一次。
        private var pendingAnchor: PositionMemory.PreviewAnchor?

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
                includeScript: true,
                layoutCSS: parent.layoutCSS
            )
            // 重载后的 DOM 就是当前 html/主题这一代，先对齐基准：
            // 否则首帧会把上一轮的 diff 套用到刚装载的 DOM 上（模式切换回来时会错位）
            lastHTML = parent.html
            lastBlockLines = parent.blockLines
            lastThemeCSS = parent.themeCSS
            lastLayoutCSS = parent.layoutCSS
            lastGeneration = parent.generation
            // 换文档时 startSession 会作废旧锚点，所以这里读到的要么是本篇的
            // 位置，要么是 nil（新文档，从头看起）。
            parent.positionMemory?.startSession(generation: parent.generation)
            pendingAnchor = parent.positionMemory?.previewAnchor
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

        /// 应用版式：与主题同一套队列，加载中先存着。
        func applyLayout(_ css: String) {
            guard !webView.isLoading else {
                pendingLayoutCSS = css
                return
            }
            let json = PreviewView.encodeJSStatic(css)
            webView.evaluateJavaScript("__wtmdSetLayout(\(json))")
        }

        /// 滚到某一行对应的块（分栏联动）。加载中先存着，didFinish 后补一次。
        func scrollToLine(_ line: Int) {
            guard !webView.isLoading else {
                pendingScrollLine = line
                return
            }
            webView.evaluateJavaScript("__wtmdScrollToLine(\(line))")
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ignoreLineUntil = ProcessInfo.processInfo.systemUptime + 0.6
                // 刚装载的 DOM 还没有行号，先打一遍（联动从这里开始才有意义）
                self.webView.evaluateJavaScript("__wtmdSetLines(\(PreviewView.encodeLines(self.parent.blockLines)))")
                if let pending = self.pendingThemeCSS {
                    self.pendingThemeCSS = nil
                    let json = PreviewView.encodeJSStatic(pending)
                    self.webView.evaluateJavaScript("__wtmdSetTheme(\(json))")
                }
                if let pending = self.pendingLayoutCSS {
                    self.pendingLayoutCSS = nil
                    let json = PreviewView.encodeJSStatic(pending)
                    self.webView.evaluateJavaScript("__wtmdSetLayout(\(json))")
                }
                // 回到原来的位置：DOM 就绪才有元素可量。放在主题补发之后，
                // 是因为主题只改 CSS 变量、不改块高度（量早量晚差不了几像素）。
                if let anchor = self.pendingAnchor {
                    self.pendingAnchor = nil
                    self.webView.evaluateJavaScript(
                        "__wtmdRestoreAnchor(\(anchor.blockIndex), \(anchor.offset))"
                    )
                }
                // 联动滚动放在最后：它代表「光标现在在哪」，比上次的位置更权威。
                if let line = self.pendingScrollLine {
                    self.pendingScrollLine = nil
                    self.webView.evaluateJavaScript("__wtmdScrollToLine(\(line))")
                }
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "wtmd", let body = message.body as? [String: Any] else { return }
            if let index = (body["anchor"] as? NSNumber)?.intValue,
               let offset = (body["offset"] as? NSNumber)?.doubleValue {
                let anchor = PositionMemory.PreviewAnchor(
                    blockIndex: index,
                    offset: CGFloat(offset)
                )
                DispatchQueue.main.async { [weak self] in
                    self?.parent.positionMemory?.recordPreviewAnchor(anchor)
                }
            }
            if let slug = body["slug"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.currentSlug = slug
                }
            }
            // 分栏联动：视口顶部落在哪一行。每帧一条，先取回调再跳线程——
            // parent 是个 struct，异步块里再去读它就晚了一拍。
            if let line = (body["line"] as? NSNumber)?.intValue, line >= 0,
               ProcessInfo.processInfo.systemUptime >= ignoreLineUntil {
                let handler = parent.onLineChange
                DispatchQueue.main.async { handler?(line) }
            }
        }
    }

    private static func encodeJSStatic(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode([s]),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// `[0, 2, 5]` → JS 数组字面量。行号都是非负整数，不需要转义。
    static func encodeLines(_ lines: [Int]) -> String {
        "[" + lines.map(String.init).joined(separator: ",") + "]"
    }
}
