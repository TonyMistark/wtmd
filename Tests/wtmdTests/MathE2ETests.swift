import Foundation
import Testing
import WebKit
import WTMarkdownKit
@testable import wtmd

// MARK: - KaTeX 数学公式端到端（离屏 WKWebView）

/// mermaid 的教训平移：只有真实引擎守得住渲染行为与 DOM 不变式——
/// 顶层子元素数不变、KaTeX 不往 body 挂临时节点、失败降级为可见源码。
@MainActor
private final class OffscreenMathPreview: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func load(_ html: String) async {
        web.navigationDelegate = self
        web.loadHTMLString(html, baseURL: nil)
        if finished { return }
        await withCheckedContinuation { self.waiter = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        waiter?.resume()
        waiter = nil
    }

    @discardableResult
    func js(_ source: String) async -> Any? {
        await withCheckedContinuation { cont in
            web.evaluateJavaScript(source) { value, _ in cont.resume(returning: value) }
        }
    }

    func int(_ source: String) async -> Int? {
        (await js(source)) as? Int
    }

    func bool(_ source: String) async -> Bool? {
        (await js(source)) as? Bool
    }

    func waitUntil(_ condition: String, seconds: Double = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (await bool(condition)) == true { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}

private let mathPageThemeCSS = """
:root{--bg:#ffffff;--fg:#222222;--pre-bg:#f5f5f5;--border:#dddddd;--th-bg:#eeeeee;\
--code-bg:#f5f5f5;--quote-bar:#888888;--font-body:sans-serif;--accent:#07C160;\
--font-mono:ui-monospace,monospace;}
"""

private func mathTestDocument(_ markdown: String, includeScript: Bool = true) -> String {
    let result = WTMarkdown.render(markdown)
    return StyleSheet.fullDocument(
        title: "Math",
        body: result.html,
        themeCSS: mathPageThemeCSS,
        includeScript: includeScript
    )
}

/// 行内与块级公式在真实 KaTeX 下渲染为 .katex 元素；
/// 前置验证三条不变式：顶层子元素数不变、body 无 KaTeX 泄漏节点、
/// 占位标记为已渲染（增量渲染据此跳过）。
@Test @MainActor func katexRendersInlineAndDisplayMath() async throws {
    let doc = mathTestDocument("能量 $E=mc^2$ 守恒\n\n$$\\int_0^1 x\\,dx = \\frac{1}{2}$$")
    let preview = OffscreenMathPreview()
    await preview.load(doc)

    let rendered = await preview.waitUntil(
        "document.querySelectorAll('#wtmd-content .katex').length >= 2"
    )
    #expect(rendered)

    // 前置验证 ①：顶层子元素数 == 块数（span 在段落内部，不得增删顶层节点）
    let topLevel = await preview.int(
        "document.getElementById('wtmd-content').children.length"
    )
    let blockCount = await preview.int(
        "document.querySelectorAll('#wtmd-content > *').length"
    )
    #expect(topLevel == 2)
    #expect(topLevel == blockCount)

    // 前置验证 ②：KaTeX 不往 #wtmd-content 之外挂可见节点（body 只应有 content 一个子元素）
    let bodyChildren = await preview.int("document.body.children.length")
    #expect(bodyChildren == 1)

    // 占位已标记渲染完成
    let pending = await preview.int(
        "document.querySelectorAll('.wtmd-math:not([data-rendered])').length"
    )
    #expect(pending == 0)

    // 行内公式出现在段落里（displayMode 区分）
    let inlineCount = await preview.int(
        "document.querySelectorAll('#wtmd-content p > span.wtmd-math > .katex').length"
    )
    #expect(inlineCount == 1)
    let displayCount = await preview.int(
        "document.querySelectorAll('.wtmd-math[data-display=\"1\"] .katex-display').length"
    )
    #expect(displayCount == 1)
}

/// 非法公式降级：源码保留可见（wtmd-math-failed），不白屏、无 DOM 污染。
@Test @MainActor func katexFailureDegradesToVisibleSource() async throws {
    let doc = mathTestDocument("坏公式 $\\notacommand{x}$ 在这里")
    let preview = OffscreenMathPreview()
    await preview.load(doc)

    let failed = await preview.waitUntil(
        "!!document.querySelector('.wtmd-math.wtmd-math-failed')"
    )
    #expect(failed)

    // 源码保留可见（textContent 恢复为原始公式）
    let sourceVisible = await preview.bool(
        "document.querySelector('.wtmd-math.wtmd-math-failed').textContent === '\\\\notacommand{x}'"
    )
    #expect(sourceVisible == true)

    // 无污染：body 仍只有 content 一个子元素；正常公式不受连累
    let bodyChildren = await preview.int("document.body.children.length")
    #expect(bodyChildren == 1)
}

/// 增量更新链路：__wtmdUpdateRange 换入的新块里的公式也要被渲染（diff 触发路径）。
@Test @MainActor func incrementalUpdateRendersNewMath() async throws {
    // 初始文档必须含公式：KaTeX 资源按需注入，无数学的文档不加载脚本
    let doc = mathTestDocument("前缀段 $x_1$ 撑住。")
    let preview = OffscreenMathPreview()
    await preview.load(doc)
    #expect(await preview.waitUntil(
        "!!document.querySelector('.wtmd-math .katex')"
    ))

    // 真实增量路径：整块替换为另一段公式，__wtmdUpdateRange 内部会触发 KaTeX 扫描
    let newBlockHTML = HTMLRenderer().renderBlockArray([Block.paragraph("新段 $a^2+b^2=c^2$")], footnotes: [])
    let updated = await preview.bool("""
    (function () {
      __wtmdUpdateRange({ prefix: 0, suffix: 0, replacement: [\(newBlockHTML.joined().debugDescription)] });
      return document.querySelectorAll('#wtmd-content .wtmd-math').length === 1;
    })()
    """)
    #expect(updated == true)

    let rendered = await preview.waitUntil(
        // 新公式已渲染：.katex 存在，且渲染产物含等号（前缀 x_1 没有）
        "!!document.querySelector('.wtmd-math .katex') && document.querySelector('.wtmd-math').textContent.indexOf('=') >= 0"
    )
    #expect(rendered)

    // 替换后顶层子元素数仍是 1（不变式）
    #expect(await preview.int(
        "document.getElementById('wtmd-content').children.length"
    ) == 1)
}

/// 导出 HTML（includeScript: false）：KaTeX 资源仍随文档携带（同 mermaid 策略），
/// 静态打开即渲染公式。
@Test @MainActor func exportedHTMLRendersMathWithoutInteractionScript() async throws {
    let doc = mathTestDocument("静导出 $\\pi \\approx 3.14$", includeScript: false)
    #expect(doc.contains("katex"))
    #expect(doc.contains("data:font/woff2;base64,"))

    let preview = OffscreenMathPreview()
    await preview.load(doc)
    let rendered = await preview.waitUntil(
        "!!document.querySelector('.wtmd-math .katex')"
    )
    #expect(rendered)
}
