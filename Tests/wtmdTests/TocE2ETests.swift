import Foundation
import Testing
import WebKit
import WTMarkdownKit
@testable import wtmd

// MARK: - [TOC] 端到端（离屏 WKWebView）

/// 真实引擎验证三件事：TOC 是 #wtmd-content 的普通顶层子元素（增量渲染不变式）、
/// 点击目录条目发生页内滚动（JS 委托生效）、点击不改变顶层子元素数量。
/// 字符串断言守不住 DOM 结构与滚动行为，这一组用例真的把页面跑起来。
@MainActor
private final class OffscreenTocPreview: NSObject, WKNavigationDelegate {
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

    /// 轮询直到 JS 条件返回 true
    func waitUntil(_ condition: String, seconds: Double = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (await bool(condition)) == true { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}

private let tocPageThemeCSS = """
:root{--bg:#ffffff;--fg:#222222;--pre-bg:#f5f5f5;--border:#dddddd;--th-bg:#eeeeee;\
--code-bg:#f5f5f5;--quote-bar:#888888;--font-body:sans-serif;--accent:#07C160;}
"""

private func tocTestDocument() -> String {
    // TOC 在文首 + 若干高标题，保证点击目录后页面必须滚动
    var markdown = "[TOC]\n\n"
    for i in 1...12 {
        markdown += "## 标题\(i)\n\n"
        markdown += String(repeating: "这是第 \(i) 节的正文段落，用来撑起页面高度。\n\n", count: 8)
    }
    let result = WTMarkdown.render(markdown)
    return StyleSheet.fullDocument(
        title: "TOC",
        body: result.html,
        themeCSS: tocPageThemeCSS,
        includeScript: true
    )
}

@Test @MainActor func tocAnchorClickScrollsPreview() async throws {
    let preview = OffscreenTocPreview()
    await preview.load(tocTestDocument())

    // 不变式：#wtmd-content 顶层子元素数 == 块数（TOC nav 是普通顶层元素，无包装节点）
    let topLevel = await preview.int(
        "document.getElementById('wtmd-content').children.length"
    )
    let blockCount = await preview.int(
        "document.querySelectorAll('#wtmd-content > *').length"
    )
    #expect(topLevel != nil)
    #expect(topLevel == blockCount)
    #expect((await preview.bool(
        "!!document.querySelector('#wtmd-content > nav.wtmd-toc')"
    )) == true)

    let before = await preview.int("window.scrollY") ?? 0

    // 模拟点击目录里指向最后一个标题的条目
    let clicked = await preview.bool("""
    (function () {
      var links = document.querySelectorAll('.wtmd-toc a');
      if (!links.length) { return false; }
      links[links.length - 1].click();
      return true;
    })()
    """)
    #expect(clicked == true)

    // 平滑滚动是异步的：轮询等 scrollY 增长
    let scrolled = await preview.waitUntil(
        "window.scrollY > \(before) + 200"
    )
    #expect(scrolled)

    // 点击不得增删顶层子节点
    let topLevelAfter = await preview.int(
        "document.getElementById('wtmd-content').children.length"
    )
    #expect(topLevelAfter == topLevel)
}

/// 导出 HTML（includeScript: false，无交互脚本）：目录保留为静态锚点列表，
/// 浏览器原生 `#hash` 跳转即可用；条目 href 必须能在文档里找到对应 id。
@Test func exportedHTMLKeepsStaticTOCAnchors() {
    let result = WTMarkdown.render("[TOC]\n\n# 第一章\n\n## 安装")
    let html = StyleSheet.fullDocument(
        title: "TOC",
        body: result.html,
        themeCSS: tocPageThemeCSS,
        includeScript: false
    )
    #expect(html.contains("<nav class=\"wtmd-toc\""))
    #expect(html.contains("<a href=\"#第一章\">第一章</a>"))
    // 每个 TOC 锚点在正文里都有对应的标题 id
    #expect(html.contains("<h1 id=\"第一章\">"))
    #expect(html.contains("<h2 id=\"安装\">"))
}
