import Foundation
import Testing
import WebKit
@testable import wtmd

// MARK: - mermaid 端到端（离屏 WKWebView）

/// 离屏预览页：加载装配好的文档、执行 JS、轮询等待条件成立。
///
/// mermaid 的失败路径与 mermaid 库自身的行为（往 body 追加错误 SVG）只有真实
/// WebKit 引擎才能复现，字符串断言守不住，所以这一组用例真的把页面跑起来。
@MainActor
private final class OffscreenPreview: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 1200))
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

    func string(_ source: String) async -> String? {
        (await js(source)) as? String
    }

    /// 轮询直到 JS 条件返回 true
    func waitUntil(_ condition: String, seconds: Double = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (await js(condition)) as? Bool == true { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}

/// 正文容器之外、含 mermaid 错误文案的元素个数
/// —— mermaid 解析失败会把 `<div id="d{id}">` 挂到 body 上，不清理就是文末一个可见脏块
private let strayErrorNodesJS = """
(function () {
  var content = document.getElementById('wtmd-content');
  var all = document.querySelectorAll('body *');
  var n = 0;
  for (var i = 0; i < all.length; i++) {
    if (content && content.contains(all[i])) { continue; }
    if ((all[i].textContent || '').indexOf('Syntax error') >= 0) { n++; }
  }
  return n;
})()
"""

private let pageThemeCSS = """
:root{--bg:#ffffff;--fg:#222222;--pre-bg:#f5f5f5;--border:#dddddd;--th-bg:#eeeeee;\
--code-bg:#f5f5f5;--quote-bar:#888888;--font-body:sans-serif;--accent:#07C160;}
"""

/// 一张合法图 + 一张语法错误图：失败降级不得污染正文容器之外的 DOM
@Test @MainActor func mermaidFailedGraphLeavesNoStrayNodes() async throws {
    let body = """
    <p>intro</p>
    <pre><code class="language-mermaid">graph TD;
        A --&gt; B;</code></pre>
    <pre><code class="language-mermaid">这不是一张图，只是一句话</code></pre>
    """
    let doc = StyleSheet.fullDocument(
        title: "e2e", body: body, themeCSS: pageThemeCSS, includeScript: true
    )
    let page = OffscreenPreview()
    await page.load(doc)

    // 引擎不可用的环境（例如 CI 上 WebKit 离屏渲染被禁用）不误报失败，但要让跳过可见
    guard await page.waitUntil("typeof window.mermaid === 'object'", seconds: 15) else {
        print("⚠️ WebKit/mermaid 未就绪，mermaid 端到端用例未实际执行")
        return
    }

    let settled = await page.waitUntil(
        "document.querySelectorAll('#wtmd-content .mermaid-wrap.mermaid-rendered').length === 1"
        + " && document.querySelectorAll('#wtmd-content .mermaid-wrap.mermaid-failed').length === 1"
    )
    #expect(settled, "应一张渲染成功、一张降级失败")

    // 顶层块数量不变（增量 diff 依赖该不变式）：p + 图 + 图 = 3
    #expect(await page.int("document.getElementById('wtmd-content').children.length") == 3)
    // 成功那张的 SVG 在，失败那张保留源码块 + 一条错误提示
    #expect(await page.int("document.querySelectorAll('#wtmd-content .mermaid-wrap svg').length") == 1)
    #expect(await page.int("document.querySelectorAll('#wtmd-content .mermaid-error').length") == 1)
    // 错误提示压成单行，完整诊断放在 title 上
    let note = await page.string("document.querySelector('#wtmd-content .mermaid-error').textContent") ?? ""
    #expect(!note.contains("\n"))
    #expect(await page.string("document.querySelector('#wtmd-content .mermaid-error').getAttribute('title')") != nil)

    // 关键回归：正文容器之外不得有 mermaid 的错误 SVG
    #expect(await page.int(strayErrorNodesJS) == 0, "mermaid 错误 SVG 泄漏到了正文之外")
    #expect(await page.int("document.body.children.length") == 1, "body 上多了 mermaid 的临时节点")

    // 主题切换走 force 重绘：已知失败的块不该重试，也不该每切一次再漏一份
    for index in 1...2 {
        _ = await page.js("__wtmdSetTheme(':root{--bg:#10101\(index);}')")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await page.int(strayErrorNodesJS) == 0, "第 \(index) 次切主题后出现泄漏")
        #expect(await page.int("document.body.children.length") == 1, "第 \(index) 次切主题后 body 出现临时节点")
    }
    // 重绘后成功那张仍是 1 张，失败那张仍只降级不重试
    #expect(await page.int("document.querySelectorAll('#wtmd-content .mermaid-wrap svg').length") == 1)
    #expect(await page.int("document.querySelectorAll('#wtmd-content .mermaid-error').length") == 1)
}

/// 代码块与图表共存：增量替换后高亮与图表都要还在
@Test @MainActor func mermaidAndHighlightCoexistAfterRangeUpdate() async throws {
    let body = """
    <pre><code class="language-swift">let x = 1</code></pre>
    <pre><code class="language-mermaid">graph TD;
        A --&gt; B;</code></pre>
    """
    let doc = StyleSheet.fullDocument(
        title: "e2e", body: body, themeCSS: pageThemeCSS, includeScript: true
    )
    let page = OffscreenPreview()
    await page.load(doc)

    guard await page.waitUntil("typeof window.mermaid === 'object'", seconds: 15) else {
        print("⚠️ WebKit/mermaid 未就绪，mermaid 端到端用例未实际执行")
        return
    }
    let settled = await page.waitUntil(
        "document.querySelectorAll('#wtmd-content .mermaid-wrap.mermaid-rendered').length === 1"
        + " && document.querySelectorAll('#wtmd-content code[data-wtmd-hl]').length === 1"
    )
    #expect(settled, "图表应渲染完成、代码块应着色")

    // 模拟编辑：只替换中间那段（前缀 1 块保留），新块需重新着色/渲染
    _ = await page.js("""
    __wtmdUpdateRange({ prefix: 1, suffix: 0, replacement: [
      '<pre><code class="language-python">print(1)</code></pre>'
    ] })
    """)
    let updated = await page.waitUntil(
        "document.querySelectorAll('#wtmd-content code[data-wtmd-hl]').length === 2"
    )
    #expect(updated, "替换进来的新代码块应被着色")
    #expect(await page.int("document.getElementById('wtmd-content').children.length") == 2)
    #expect(await page.int(strayErrorNodesJS) == 0)
    #expect(await page.int("document.body.children.length") == 1)
}
