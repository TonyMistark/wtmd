import Foundation

/// WTMarkdownKit 对外 API：一次渲染，同时产出 HTML、顶层块数组与大纲。
public enum WTMarkdown: Sendable {
    /// 渲染 Markdown → HTML 正文（含脚注区块）+ 顶层块数组 + 大纲。
    /// 解析只发生一次；`blocks` 供增量渲染复用，不必二次解析。
    ///
    /// 行号（`blockLines`）与块 HTML **分开交出去**，不写进标签：块字符串是
    /// `BlockDiff` 的比较基准，一旦每次都把「第几行」嵌进去，在文档前面插一行
    /// 就会让后面每一块的字符串都变，增量渲染退化成整篇重画。
    public static func render(_ markdown: String) -> RenderResult {
        var headings: [(level: Int, text: String, line: Int)] = []
        let parser = MarkdownParser()
        var footnotes: [Footnote]? = []
        let numbered = parser.parseNumbered(markdown, onHeading: { level, text, line in
            headings.append((level, text, line))
        }, footnotes: &footnotes)
        let blocks = numbered.map(\.block)
        var blockLines = numbered.map(\.line)
        let renderer = HTMLRenderer()
        var blockHTML = renderer.renderBlockArray(blocks, footnotes: footnotes ?? [])

        let anchors = renderer.headingAnchors
        var outline: [OutlineItem] = []
        for (idx, h) in headings.enumerated() {
            let slug = idx < anchors.count ? anchors[idx] : "section-\(idx)"
            outline.append(
                OutlineItem(level: h.level, text: HTMLRenderer.plainText(h.text), slug: slug, line: h.line)
            )
        }

        // 回填 TOC：`.toc` 块先渲染成哨兵，大纲收集完毕后换成真目录。
        // 每个占位都展开为完整目录（多个 [TOC] 各得一份）。
        // renderBlockArray 对 blocks 逐块 map（脚注区块只追加在尾部），前缀下标一一对应。
        // 目录块不参与分栏联动：它的高度来自全文标题，源码里只有一行 `[TOC]`。
        for (idx, block) in blocks.enumerated() where idx < blockHTML.count {
            if case .toc = block {
                blockHTML[idx] = renderer.renderTOC(outline)
            }
        }

        // 脚注区块是渲染时追加的，没有对应的源码行
        if blockHTML.count > blockLines.count {
            blockLines.append(contentsOf: repeatElement(-1, count: blockHTML.count - blockLines.count))
        }

        let html = blockHTML.joined()
        return RenderResult(html: html, outline: outline, blocks: blockHTML, blockLines: blockLines)
    }

    /// 仅渲染 HTML。
    public static func html(_ markdown: String) -> String {
        render(markdown).html
    }
}
