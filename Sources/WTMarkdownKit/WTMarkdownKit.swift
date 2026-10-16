import Foundation

/// WTMarkdownKit 对外 API：一次渲染，同时产出 HTML、顶层块数组与大纲。
public enum WTMarkdown: Sendable {
    /// 渲染 Markdown → HTML 正文（含脚注区块）+ 顶层块数组 + 大纲。
    /// 解析只发生一次；`blocks` 供增量渲染复用，不必二次解析。
    public static func render(_ markdown: String) -> RenderResult {
        var headings: [(level: Int, text: String, line: Int)] = []
        let parser = MarkdownParser()
        var footnotes: [Footnote]? = []
        let blocks = parser.parse(markdown, onHeading: { level, text, line in
            headings.append((level, text, line))
        }, footnotes: &footnotes)
        let renderer = HTMLRenderer()
        let blockHTML = renderer.renderBlockArray(blocks, footnotes: footnotes ?? [])
        let html = blockHTML.joined()

        let anchors = renderer.headingAnchors
        var outline: [OutlineItem] = []
        for (idx, h) in headings.enumerated() {
            let slug = idx < anchors.count ? anchors[idx] : "section-\(idx)"
            outline.append(
                OutlineItem(level: h.level, text: HTMLRenderer.plainText(h.text), slug: slug, line: h.line)
            )
        }
        return RenderResult(html: html, outline: outline, blocks: blockHTML)
    }

    /// 仅渲染 HTML。
    public static func html(_ markdown: String) -> String {
        render(markdown).html
    }
}
