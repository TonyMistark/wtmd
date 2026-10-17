import Foundation
import Testing
import WebKit
import WTMarkdownKit
@testable import wtmd

// MARK: - 对照模式下的增量渲染开销

/// 分栏只是让预览常驻可见，渲染链路与预览模式完全相同：输入 → 250ms 防抖 →
/// 后台渲染 → BlockDiff → 一次 `__wtmdUpdateRange`。所以「分栏会不会卡」等价于
/// 「一次增量的 JS 往返有多贵」，这里就量这一件事。
///
/// 注意口径：这是**复杂度退化警报网**，不是性能口径。共享 CI runner 的绝对耗时
/// 波动很大，真正的观感要用 Instruments 在人机交互下测。
@MainActor
private final class BenchmarkPage: NSObject, WKNavigationDelegate {
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

    func run(_ source: String) async {
        await withCheckedContinuation { cont in
            web.evaluateJavaScript(source) { _, _ in cont.resume() }
        }
    }
}

/// 5000 行、约 1000 块的文档。
private func longMarkdown(extraParagraphs: Int) -> String {
    var lines: [String] = []
    for section in 0..<250 {
        lines.append("## 第 \(section) 节")
        lines.append("")
        for para in 0..<9 {
            lines.append("第 \(section) 节的第 \(para) 段正文，带一点**加粗**、`行内代码` 与[链接](https://example.com)。")
            lines.append("")
        }
    }
    for i in 0..<extraParagraphs {
        lines.append("末尾新增的第 \(i) 段，用来制造一块变化。")
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

/// 把 BlockDiff 编成 `__wtmdUpdateRange` 吃的 JS 对象字面量（与 PreviewView 同构）。
private func payload(_ diff: BlockDiff) -> String {
    func literal(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode([s]),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
    let parts = diff.replacement.map(literal)
    return "{prefix: \(diff.commonPrefix), suffix: \(diff.commonSuffix), replacement: [\(parts.joined(separator: ","))]}"
}

private let benchmarkThemeCSS = """
:root{--bg:#ffffff;--fg:#222222;--pre-bg:#f5f5f5;--border:#dddddd;--th-bg:#eeeeee;\
--code-bg:#f5f5f5;--quote-bar:#888888;--font-body:sans-serif;--accent:#07C160;}
"""

@Test @MainActor func splitPreviewIncrementalUpdateStaysCheap() async throws {
    // 两代文档：每次只多一段，于是每次 diff 都只替换最后一个块
    let base = WTMarkdown.render(longMarkdown(extraParagraphs: 0))
    let page = BenchmarkPage()
    await page.load(
        StyleSheet.fullDocument(
            title: "benchmark",
            body: base.html,
            themeCSS: benchmarkThemeCSS,
            includeScript: true
        )
    )

    var previousBlocks = base.blocks
    var samples: [Double] = []
    for step in 1...20 {
        let next = WTMarkdown.render(longMarkdown(extraParagraphs: step))
        let diff = BlockDiff.compute(old: previousBlocks, new: next.blocks)
        #expect(!diff.isEmpty)
        previousBlocks = next.blocks

        let start = Date()
        await page.run("__wtmdUpdateRange(\(payload(diff)))")
        samples.append(Date().timeIntervalSince(start) * 1000)
    }

    let sorted = samples.sorted()
    let median = sorted[sorted.count / 2]
    let worst = sorted.last ?? 0
    print(String(format: "基准：分栏增量 JS 往返 中位 %.1fms / 最慢 %.1fms（%d 次，%d 块）",
                 median, worst, samples.count, previousBlocks.count))

    // 复杂度警报网：一次增量往返超过半秒说明退化成了全量重排
    #expect(median < 500)
    #expect(worst < 1_500)
}
