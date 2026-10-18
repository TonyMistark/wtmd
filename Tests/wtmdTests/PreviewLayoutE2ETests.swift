import Foundation
import Testing
import WebKit
import WTMarkdownKit
@testable import wtmd

// MARK: - 版式端到端（离屏 WKWebView）

/// 字面断言守不住「滑块真的改变了版面」。这组用例把页面跑起来，量计算样式，
/// 再调 `__wtmdSetLayout` 确认热更新不打乱 DOM。
@MainActor
private final class OffscreenLayoutPreview: NSObject, WKNavigationDelegate {
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

    func js(_ source: String) async -> Any? {
        await withCheckedContinuation { cont in
            web.evaluateJavaScript(source) { value, _ in cont.resume(returning: value) }
        }
    }

    func int(_ source: String) async -> Int? { (await js(source)) as? Int }
    func string(_ source: String) async -> String? { (await js(source)) as? String }

    /// 轮询直到 JS 条件返回 true
    func waitUntil(_ condition: String, seconds: Double = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (await js(condition)) as? Bool == true { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

private let layoutTestTheme = """
:root{--bg:#ffffff;--fg:#222222;--pre-bg:#f5f5f5;--border:#dddddd;--th-bg:#eeeeee;\
--code-bg:#f5f5f5;--quote-bar:#888888;--font-body:sans-serif;--accent:#07C160;}
"""

private func layoutTestDocument(layoutCSS: String?) -> String {
    let markdown = """
    # 版式

    第一段，用来量行距与字号。

    第二段，也用来量。
    """
    let body = WTMarkdown.render(markdown).html
    return StyleSheet.fullDocument(
        title: "Layout",
        body: body,
        themeCSS: layoutTestTheme,
        includeScript: true,
        layoutCSS: layoutCSS ?? ""
    )
}

private func computed(_ property: String, of selector: String) -> String {
    "getComputedStyle(document.querySelector('\(selector)')).\(property)"
}

/// `34.2px` → 34.2。行距是乘出来的，浏览器给的是舍入后的浮点，别按字符串比。
private func points(_ raw: String?) -> Double {
    Double((raw ?? "").replacingOccurrences(of: "px", with: "")) ?? .nan
}

@Test @MainActor func withoutLayoutTheOldDefaultsStillApply() async throws {
    let preview = OffscreenLayoutPreview()
    await preview.load(layoutTestDocument(layoutCSS: nil))
    #expect(await preview.waitUntil("document.readyState === 'complete'"))

    #expect(await preview.string(computed("maxWidth", of: "#wtmd-content")) == "760px")
    #expect(await preview.string(computed("fontSize", of: "body")) == "16px")
    // 16 × 1.75
    #expect(abs(points(await preview.string(computed("lineHeight", of: "body"))) - 28) < 0.1)
}

@Test @MainActor func layoutCSSChangesMeasureSizeAndLeading() async throws {
    let css = """
    :root {
      --wtmd-measure: 600px;
      --wtmd-font-size: 18px;
      --wtmd-line-height: 1.90;
    }
    """
    let preview = OffscreenLayoutPreview()
    await preview.load(layoutTestDocument(layoutCSS: css))
    #expect(await preview.waitUntil("document.readyState === 'complete'"))

    #expect(await preview.string(computed("maxWidth", of: "#wtmd-content")) == "600px")
    #expect(await preview.string(computed("fontSize", of: "body")) == "18px")
    // 18 × 1.9
    #expect(abs(points(await preview.string(computed("lineHeight", of: "body"))) - 34.2) < 0.1)
}

/// 拖滑块走的是热更新：只换变量文本，DOM 一个节点都不该被替换。
@Test @MainActor func setLayoutUpdatesInPlace() async throws {
    let preview = OffscreenLayoutPreview()
    await preview.load(layoutTestDocument(layoutCSS: ":root { --wtmd-measure: 600px; }"))
    #expect(await preview.waitUntil("document.readyState === 'complete'"))

    // 在正文节点上做个记号：热更新后它必须还在（重载页面会丢）
    _ = await preview.js(
        "document.querySelector('#wtmd-content h1').setAttribute('data-probe', 'kept')"
    )
    let before = await preview.int("document.getElementById('wtmd-content').children.length")

    let updated = """
    :root {
      --wtmd-measure: 900px;
      --wtmd-font-size: 20px;
      --wtmd-line-height: 1.50;
    }
    """
    let json = try #require(
        String(data: JSONEncoder().encode([updated]), encoding: .utf8).map { String($0.dropFirst().dropLast()) }
    )
    _ = await preview.js("__wtmdSetLayout(\(json))")

    #expect(await preview.string(computed("maxWidth", of: "#wtmd-content")) == "900px")
    #expect(await preview.string(computed("fontSize", of: "body")) == "20px")
    #expect(abs(points(await preview.string(computed("lineHeight", of: "body"))) - 30) < 0.1)
    #expect(await preview.int("document.getElementById('wtmd-content').children.length") == before)
    #expect(await preview.string("document.querySelector('#wtmd-content h1').getAttribute('data-probe')") == "kept")
}

/// 版式与主题各一层：换主题不能把字号行距一起冲掉。
@Test @MainActor func switchingThemeKeepsTheLayout() async throws {
    let preview = OffscreenLayoutPreview()
    await preview.load(layoutTestDocument(layoutCSS: ":root { --wtmd-measure: 720px; --wtmd-font-size: 19px; }"))
    #expect(await preview.waitUntil("document.readyState === 'complete'"))

    let newTheme = """
    :root{--bg:#111111;--fg:#eeeeee;--pre-bg:#1c1c1c;--border:#333333;--th-bg:#222222;\
    --code-bg:#1c1c1c;--quote-bar:#666666;--font-body:serif;--accent:#ff8800;}
    """
    let json = try #require(
        String(data: JSONEncoder().encode([newTheme]), encoding: .utf8).map { String($0.dropFirst().dropLast()) }
    )
    _ = await preview.js("__wtmdSetTheme(\(json))")

    // 主题生效了（背景变了），版式还在
    #expect(await preview.string(computed("backgroundColor", of: "body")) == "rgb(17, 17, 17)")
    #expect(await preview.string(computed("maxWidth", of: "#wtmd-content")) == "720px")
    #expect(await preview.string(computed("fontSize", of: "body")) == "19px")
}
