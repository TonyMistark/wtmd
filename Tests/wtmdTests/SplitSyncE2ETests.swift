import Foundation
import Testing
import WebKit
import WTMarkdownKit
@testable import wtmd

// MARK: - 分栏联动的端到端（离屏 WKWebView）

/// 联动里真正需要真引擎的只有三件事：`getBoundingClientRect` 量出来的块位置、
/// `scrollTo` 之后的实际落点、以及增量替换后行号是否还挂在正确的节点上。
/// 字符串断言一个都守不住。
@MainActor
private final class SplitPreviewPage: NSObject, WKNavigationDelegate {
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

private let splitThemeCSS = """
:root{--bg:#ffffff;--fg:#222222;--pre-bg:#f5f5f5;--border:#dddddd;--th-bg:#eeeeee;\
--code-bg:#f5f5f5;--quote-bar:#888888;--font-body:sans-serif;--accent:#07C160;}
"""

private func syncMarkdown(sections: Int = 20) -> String {
    var markdown = "# 联动\n\n"
    for i in 1...sections {
        markdown += "## 第 \(i) 节\n\n"
        markdown += String(repeating: "第 \(i) 节的正文，用来把这一块撑得够高，滚过去才看得出来。\n\n", count: 3)
    }
    return markdown
}

private func syncPage(_ result: RenderResult) -> String {
    StyleSheet.fullDocument(
        title: "sync",
        body: result.html,
        themeCSS: splitThemeCSS,
        includeScript: true
    )
}

private func jsonStringArray(_ items: [String]) -> String {
    let data = try! JSONEncoder().encode(items)
    return String(data: data, encoding: .utf8)!
}

private func markLinesJS(_ lines: [Int]) -> String {
    "(function () { __wtmdSetLines(\(PreviewView.encodeLines(lines))); return true; })()"
}

/// 逐个节点核对行号是否与渲染结果对齐。返回第一个不对的块下标，
/// 全对返回 -1（长度不符返回 -2）——比「滚过去看看落在哪」严格得多：
/// 增量更新最容易出的错正是「部分节点还是旧行号」，滚一滚未必看得出来。
private func misalignedLineJS(_ lines: [Int]) -> String {
    """
    (function () {
      var kids = document.getElementById('wtmd-content').children;
      var lines = \(PreviewView.encodeLines(lines));
      if (kids.length !== lines.length) { return -2; }
      for (var i = 0; i < kids.length; i++) {
        if (typeof kids[i].__wtmdLine !== 'number' || kids[i].__wtmdLine !== lines[i]) { return i; }
      }
      return -1;
    })()
    """
}

/// 打上行号之后，视口顶部就是第一块——行号 0。
@Test @MainActor func markingLinesStartsAtTheTopBlock() async throws {
    let result = WTMarkdown.render(syncMarkdown())
    let page = SplitPreviewPage()
    await page.load(syncPage(result))
    _ = await page.bool(markLinesJS(result.blockLines))

    #expect(await page.int("__wtmdCurrentAnchor().line") == 0)
}

/// 滚到某一块的行号，视口顶部就该是那一块。
@Test @MainActor func scrollingToALineLandsOnItsBlock() async throws {
    let result = WTMarkdown.render(syncMarkdown())
    let page = SplitPreviewPage()
    await page.load(syncPage(result))
    _ = await page.bool(markLinesJS(result.blockLines))

    // 挑一块在页面中段的（每节 4 块左右，第 26 块大约是第五节）
    let index = 26
    let target = result.blockLines[index]
    #expect(await page.bool("__wtmdScrollToLine(\(target))") == true)
    #expect(await page.waitUntil("window.scrollY > 0"))

    let landed = await page.int("__wtmdCurrentAnchor().line") ?? -99
    #expect(landed == target)
}

/// 滚到最底下再回头：回程也得落在块上，不能停在某个随便的位置。
@Test @MainActor func scrollingBackToTheFirstLineReturnsToTheTop() async throws {
    let result = WTMarkdown.render(syncMarkdown())
    let page = SplitPreviewPage()
    await page.load(syncPage(result))
    _ = await page.bool(markLinesJS(result.blockLines))

    _ = await page.bool("__wtmdScrollToLine(\(result.blockLines.last!))")
    #expect(await page.waitUntil("window.scrollY > 1000"))

    _ = await page.bool("__wtmdScrollToLine(0)")
    #expect(await page.waitUntil("window.scrollY < 1"))
    #expect(await page.int("__wtmdCurrentAnchor().line") == 0)
}

/// 行号是空的（比如加载中还来不及打）：联动老老实实什么都不做，
/// 不能把读者扔到文首或文末。
@Test @MainActor func withoutLinesTheSyncIsANoOp() async throws {
    let result = WTMarkdown.render(syncMarkdown())
    let page = SplitPreviewPage()
    await page.load(syncPage(result))

    #expect(await page.int("__wtmdCurrentAnchor().line") == -1)
    #expect(await page.bool("__wtmdScrollToLine(12)") == false)
    #expect(await page.number("window.scrollY") == 0)
}

/// 全量替换（`__wtmdUpdate`）之后，新节点必须拿到新的行号。
@Test @MainActor func fullUpdateRefreshesTheLines() async throws {
    let before = WTMarkdown.render(syncMarkdown())
    let page = SplitPreviewPage()
    await page.load(syncPage(before))
    _ = await page.bool(markLinesJS(before.blockLines))

    let after = WTMarkdown.render("新插入的开头\n\n" + syncMarkdown())
    // html 是一整串：__wtmdUpdate 直接把它 merge 进 #wtmd-content
    let applied = await page.bool(
        "(function () { __wtmdUpdate(\(jsonStringArray([after.html]))[0], "
            + "\(PreviewView.encodeLines(after.blockLines))); return true; })()"
    )
    #expect(applied == true)

    #expect(await page.int("document.getElementById('wtmd-content').children.length") == after.blocks.count)
    #expect(await page.int(misalignedLineJS(after.blockLines)) == -1)
    #expect(await page.int("__wtmdCurrentAnchor().line") == 0)

    let target = after.blockLines[10]
    _ = await page.bool("__wtmdScrollToLine(\(target))")
    #expect(await page.waitUntil("__wtmdCurrentAnchor().line === \(target)"))
}

/// 增量替换（`__wtmdUpdateRange`）之后行号要重打：变化段之后的块都后移了，
/// 拿着旧行号去联动就会把人带到隔壁段落。
@Test @MainActor func incrementalUpdateRemapsTheLines() async throws {
    let markdown = syncMarkdown()
    let before = WTMarkdown.render(markdown)
    let page = SplitPreviewPage()
    await page.load(syncPage(before))
    _ = await page.bool(markLinesJS(before.blockLines))

    // 在第一节里插一段：其后所有块整体后移两行
    let edited = markdown.replacingOccurrences(
        of: "## 第 1 节\n",
        with: "## 第 1 节\n\n插进来的一段。\n"
    )
    let after = WTMarkdown.render(edited)
    let diff = BlockDiff.compute(old: before.blocks, new: after.blocks)
    #expect(!diff.isEmpty)

    let payload = "{prefix: \(diff.commonPrefix), suffix: \(diff.commonSuffix), "
        + "replacement: \(jsonStringArray(diff.replacement))}"
    let applied = await page.bool(
        "(function () { __wtmdUpdateRange(\(payload), \(PreviewView.encodeLines(after.blockLines))); return true; })()"
    )
    #expect(applied == true)

    #expect(await page.int("document.getElementById('wtmd-content').children.length") == after.blocks.count)
    // 变化段之后的块都后移了：每个节点都必须拿到**新**行号
    #expect(await page.int(misalignedLineJS(after.blockLines)) == -1)

    // 取一块在插入点之后、又不在文末的（文末附近滚不过去，会被页面底部夹住）
    let index = 30
    let target = after.blockLines[index]
    _ = await page.bool("__wtmdScrollToLine(\(target))")
    #expect(await page.waitUntil("window.scrollY > 0"))
    let landed = await page.int("__wtmdCurrentAnchor().line") ?? -99
    #expect(landed == target)
}

/// 打行号只挂属性，不动 DOM 结构：顶层块数这条不变式不能被联动破坏。
@Test @MainActor func markingLinesKeepsTheBlockCount() async throws {
    let result = WTMarkdown.render(syncMarkdown())
    let page = SplitPreviewPage()
    await page.load(syncPage(result))

    let count = await page.int("document.getElementById('wtmd-content').children.length")
    #expect(count == result.blocks.count)

    _ = await page.bool(markLinesJS(result.blockLines))
    #expect(await page.int("document.getElementById('wtmd-content').children.length") == count)
}
