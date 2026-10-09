import Foundation

/// WTMarkdownKit 对外 API：一次渲染，同时产出 HTML 与大纲。
public enum WTMarkdown: Sendable {
    /// 渲染 Markdown → HTML 正文（含脚注区块）+ 大纲。
    public static func render(_ markdown: String) -> RenderResult {
        var headings: [(level: Int, text: String, line: Int)] = []
        let parser = MarkdownParser()
        var footnotes: [Footnote]? = []
        let blocks = parser.parse(markdown, onHeading: { level, text, line in
            headings.append((level, text, line))
        }, footnotes: &footnotes)
        let renderer = HTMLRenderer()
        let html = renderer.render(blocks, footnotes: footnotes ?? [])

        let anchors = renderer.headingAnchors
        var outline: [OutlineItem] = []
        for (idx, h) in headings.enumerated() {
            let slug = idx < anchors.count ? anchors[idx] : "section-\(idx)"
            outline.append(
                OutlineItem(level: h.level, text: HTMLRenderer.plainText(h.text), slug: slug, line: h.line)
            )
        }
        return RenderResult(html: html, outline: outline)
    }

    /// 仅渲染 HTML。
    public static func html(_ markdown: String) -> String {
        render(markdown).html
    }
}
