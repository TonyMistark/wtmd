import Foundation
import Testing
import WebKit
import WTMarkdownKit
@testable import wtmd

// MARK: - 预览锚点端到端（离屏 WKWebView）

/// 锚点的算术只有真引擎能验：`getBoundingClientRect` / `scrollTo` 的行为、
/// 重载后布局是否还原到同一高度，字符串断言守不住。
@MainActor
private final class OffscreenPreviewPage: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
    private var waiter: CheckedContinuation<Void, Never>?

    func load(_ html: String) async {
        web.navigationDelegate = self
        web.loadHTMLString(html, baseURL: nil)
        await withCheckedContinuation { self.waiter = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waiter?.resume()
        waiter = nil
    }

    @discardableResult
    func js(_ source: String) async -> Any? {
        await withCheckedContinuation { cont in
            web.evaluateJavaScript(source) { value, _ in cont.resume(returning: value) }
        }
    }

    func int(_ source: String) async -> Int? { (await js(source)) as? Int }
    func bool(_ source: String) async -> Bool? { (await js(source)) as? Bool }
    func number(_ source: String) async -> Double? { (await js(source)) as? Double }

    func waitUntil(_ condition: String, seconds: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (await bool(condition)) == true { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

private let anchorThemeCSS = """
:root{--bg:#ffffff;--fg:#222222;--pre-bg:#f5f5f5;--border:#dddddd;--th-bg:#eeeeee;\
--code-bg:#f5f5f5;--quote-bar:#888888;--font-body:sans-serif;--accent:#07C160;}
"""

/// 一页够长的文档：单向滚动几百像素才有意义。
private func anchorPage() -> String {
    var markdown = "# 锚点\n\n"
    for i in 1...30 {
        markdown += "## 第 \(i) 节\n\n"
        markdown += String(repeating: "第 \(i) 节的正文，用来把页面撑得足够长。\n\n", count: 4)
    }
    let result = WTMarkdown.render(markdown)
    return StyleSheet.fullDocument(
        title: "anchor",
        body: result.html,
        themeCSS: anchorThemeCSS,
        includeScript: true
    )
}

/// 记下的锚点在新页面（= 重建后的预览）里能把读者放回原处。
@Test @MainActor func previewAnchorRestoresAcrossAReload() async throws {
    let before = OffscreenPreviewPage()
    await before.load(anchorPage())

    let scrolled = await before.bool("(function () { window.scrollTo(0, 1200); return true; })()")
    #expect(scrolled == true)
    #expect(await before.waitUntil("window.scrollY > 1100"))

    let index = await before.int("__wtmdCurrentAnchor().index") ?? -1
    let offset = await before.number("__wtmdCurrentAnchor().offset") ?? 0
    let scrollY = await before.number("window.scrollY") ?? 0
    // 滚动到中段：锚点不可能还停在第一块
    #expect(index > 0)
    #expect(scrollY > 1100)

    // 重建：新的 WKWebView + 同一份文档（⌘/ 切回预览时走的就是这条路）
    let after = OffscreenPreviewPage()
    await after.load(anchorPage())
    #expect(await after.int("window.scrollY") == 0)

    let restored = await after.bool("__wtmdRestoreAnchor(\(index), \(offset))")
    #expect(restored == true)
    let newScrollY = await after.number("window.scrollY") ?? 0
    #expect(abs(newScrollY - scrollY) <= 2)
}

/// 文首不加修饰：锚点就是第 0 块。偏移为负——文档顶部有内边距，
/// 第一块的顶边落在视口顶边之下。
@Test @MainActor func previewAnchorAtTheTopIsTheFirstBlock() async throws {
    let page = OffscreenPreviewPage()
    await page.load(anchorPage())

    #expect(await page.int("__wtmdCurrentAnchor().index") == 0)
    let offset = await page.number("__wtmdCurrentAnchor().offset") ?? 1
    #expect(offset <= 0)
    #expect(offset > -200)
}

/// 下标越界（文档被删短了）不能抛、不能乱滚，老实返回 false 让原生侧忽略。
@Test @MainActor func restoringAnImpossibleAnchorIsANoOp() async throws {
    let page = OffscreenPreviewPage()
    await page.load(anchorPage())
    let top = await page.number("window.scrollY") ?? 0

    #expect(await page.bool("__wtmdRestoreAnchor(9999, -40)") == false)
    #expect(await page.number("window.scrollY") == top)
    #expect(await page.bool("__wtmdRestoreAnchor(-1, 0)") == false)
}

/// 锚点不得改变 DOM：还原只是滚动，不是重建（顶层块数不变式）。
@Test @MainActor func restoringKeepsTheTopLevelBlockCount() async throws {
    let page = OffscreenPreviewPage()
    await page.load(anchorPage())
    let count = await page.int("document.getElementById('wtmd-content').children.length")

    _ = await page.bool("(function () { window.scrollTo(0, 900); return true; })()")
    #expect(await page.waitUntil("window.scrollY > 800"))
    _ = await page.bool("__wtmdRestoreAnchor(2, -30)")

    #expect(await page.int("document.getElementById('wtmd-content').children.length") == count)
}
