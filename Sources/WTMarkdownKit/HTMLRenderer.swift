import Foundation

/// 将块级 AST 渲染为 HTML。标题生成锚点 id，顶层标题锚点按序收集供大纲使用。
public final class HTMLRenderer {
    /// 渲染过程中收集的顶层标题锚点（与解析器顶层标题回调一一对应）。
    private(set) var headingAnchors: [String] = []
    private var slugCounts: [String: Int] = [:]
    private var inlineCounter = 0
    private var placeholders: [String: String] = [:]

    public init() {}

    public func render(_ blocks: [Block]) -> String {
        render(blocks, footnotes: [])
    }

    /// 带脚注的渲染：正文 `[^id]` 替换为上标链接，文末输出脚注区块。
    public func render(_ blocks: [Block], footnotes: [Footnote]) -> String {
        // 先收集正文引用顺序（renderInline 会在遍历中登记）
        footnoteOrder = []
        let body = renderBlocks(blocks, depth: 0)

        guard !footnoteOrder.isEmpty else { return body }

        let byID = Dictionary(uniqueKeysWithValues: footnotes.map { ($0.id, $0.text) })
        // 只渲染有定义的引用；悬空引用（无定义）不进区块
        let definedOrder = footnoteOrder.filter { byID[$0] != nil }
        guard !definedOrder.isEmpty else { return body }

        var section = "\n<section class=\"footnotes\" data-wtmd-footnotes>\n<ol>\n"
        for (num, id) in definedOrder.enumerated() {
            let n = num + 1
            let text = byID[id] ?? ""
            let safeID = escapeAttr(id)
            section += "<li id=\"fn-\(n)\" data-fn-id=\"\(safeID)\">\(renderInline(text))"
            section += " <a href=\"#fnref-\(n)\" class=\"footnote-backref\" aria-label=\"回到正文\">↩</a></li>\n"
        }
        section += "</ol>\n</section>\n"
        return body + section
    }

    /// 正文引用出现顺序（渲染过程中登记）。
    private var footnoteOrder: [String] = []

    // MARK: - 块级

    private func renderBlocks(_ blocks: [Block], depth: Int) -> String {
        blocks.map { renderBlock($0, depth: depth) }.joined()
    }

    private func renderBlock(_ block: Block, depth: Int) -> String {
        switch block {
        case .heading(let level, let text):
            let slug = slug(for: text)
            if depth == 0 { headingAnchors.append(slug) }
            return "<h\(level) id=\"\(slug)\">\(renderInline(text))</h\(level)>\n"

        case .paragraph(let text):
            return "<p>\(renderInline(text))</p>\n"

        case .code(let language, let code):
            let cls = language.map { " class=\"language-\(escapeAttr($0))\"" } ?? ""
            return "<pre><code\(cls)>\(escapeText(code))</code></pre>\n"

        case .quote(let blocks):
            return "<blockquote>\n\(renderBlocks(blocks, depth: depth + 1))</blockquote>\n"

        case .list(let ordered, let start, let items):
            let tag = ordered ? "ol" : "ul"
            let startAttr = ordered && start != 1 ? " start=\"\(max(start, 1))\"" : ""
            let body = items.map(renderItem).joined()
            return "<\(tag)\(startAttr)>\n\(body)</\(tag)>\n"

        case .table(let header, let alignments, let rows):
            return renderTable(header: header, alignments: alignments, rows: rows)

        case .divider:
            return "<hr />\n"
        }
    }

    private func renderItem(_ item: ListItem) -> String {
        var inner = renderBlocks(item.blocks, depth: 1)
        // 紧凑列表：单项仅含一个段落时不包 <p>
        if item.blocks.count == 1, case .paragraph(let text)? = item.blocks.first {
            inner = renderInline(text)
        }
        if let task = item.taskState {
            let checked = task == .checked ? " checked" : ""
            return "<li class=\"task\"><input type=\"checkbox\" disabled\(checked)> \(inner)</li>\n"
        }
        return "<li>\(inner)</li>\n"
    }

    private func renderTable(header: [String], alignments: [TableAlignment], rows: [[String]]) -> String {
        var html = "<table>\n<thead>\n<tr>\n"
        for (idx, cell) in header.enumerated() {
            html += "<th\(alignAttr(alignments, idx))>\(renderInline(cell))</th>\n"
        }
        html += "</tr>\n</thead>\n<tbody>\n"
        for row in rows {
            html += "<tr>\n"
            for idx in 0..<max(header.count, row.count) {
                let cell = idx < row.count ? row[idx] : ""
                html += "<td\(alignAttr(alignments, idx))>\(renderInline(cell))</td>\n"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        return html
    }

    private func alignAttr(_ alignments: [TableAlignment], _ idx: Int) -> String {
        guard idx < alignments.count else { return "" }
        switch alignments[idx] {
        case .left: return " style=\"text-align:left\""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        case .none: return ""
        }
    }

    // MARK: - 内联

    func renderInline(_ raw: String) -> String {
        var s = raw
        // 尖括号自动链接（转义前处理，包含 < >）
        s = replace(s, pattern: "<(https?://[^>\\s]+)>") { m in
            let url = substring(of: s, m.range(at: 1))
            return protect("<a href=\"\(escapeAttr(url))\">\(escapeText(url))</a>")
        }
        s = escapeText(s)
        // 硬换行：行尾两个空格（转义后插入，避免 <br /> 被二次转义）
        s = replace(s, pattern: " {2,}\\n") { _ in "<br />\n" }
        s = renderEscaped(s)
        return restore(s)
    }

    private func renderEscaped(_ s: String) -> String {
        var t = s

        // 行内代码（最先处理，保护其中的其他标记）
        t = replace(t, pattern: "(?s)(`+)(.+?)\\1") { m in
            var code = substring(of: t, m.range(at: 2))
            if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" ") {
                code = String(code.dropFirst().dropLast())
            }
            return protect("<code>\(code)</code>")
        }

        // 脚注引用 [^id]（在图片/链接之前，登记出现顺序）
        t = replace(t, pattern: "\\[\\^([^\\]\\s]+)\\]") { m in
            let id = substring(of: t, m.range(at: 1))
            if !footnoteOrder.contains(id) { footnoteOrder.append(id) }
            let n = footnoteOrder.firstIndex(of: id)! + 1
            return protect("<sup id=\"fnref-\(n)\" class=\"footnote-ref\"><a href=\"#fn-\(n)\" data-footnote-id=\"\(escapeAttr(id))\">\(n)</a></sup>")
        }

        // 图片
        t = replace(t, pattern: "!\\[([^\\]\\n]*)\\]\\(\\s*([^\\s)]+)(?:\\s+\"([^\"]*)\")?\\s*\\)") { m in
            let alt = substring(of: t, m.range(at: 1))
            let src = substring(of: t, m.range(at: 2))
            let title = m.range(at: 3).location != NSNotFound
                ? substring(of: t, m.range(at: 3)) : nil
            let titleAttr = title.map { " title=\"\(escapeAttr($0))\"" } ?? ""
            return protect("<img src=\"\(escapeAttr(src))\" alt=\"\(escapeAttr(alt))\"\(titleAttr) />")
        }

        // 链接
        t = replace(t, pattern: "\\[([^\\]\\n]+)\\]\\(\\s*([^\\s)]+)(?:\\s+\"([^\"]*)\")?\\s*\\)") { m in
            let text = substring(of: t, m.range(at: 1))
            let href = substring(of: t, m.range(at: 2))
            let title = m.range(at: 3).location != NSNotFound
                ? substring(of: t, m.range(at: 3)) : nil
            let titleAttr = title.map { " title=\"\(escapeAttr($0))\"" } ?? ""
            return protect("<a href=\"\(escapeAttr(href))\"\(titleAttr)>\(renderEscaped(text))</a>")
        }

        // 粗体
        t = replace(t, pattern: "(?s)\\*\\*(.+?)\\*\\*") { m in
            protect("<strong>\(renderEscaped(substring(of: t, m.range(at: 1))))</strong>")
        }
        t = replace(t, pattern: "(?s)(?<![\\w_])__(.+?)__(?![\\w_])") { m in
            protect("<strong>\(renderEscaped(substring(of: t, m.range(at: 1))))</strong>")
        }

        // 斜体
        t = replace(t, pattern: "\\*(?=[^\\s*])([^*\\n]*[^\\s*])\\*") { m in
            protect("<em>\(renderEscaped(substring(of: t, m.range(at: 1))))</em>")
        }
        t = replace(t, pattern: "(?<![\\w_])_([^_\\n]+)_(?![\\w_])") { m in
            protect("<em>\(renderEscaped(substring(of: t, m.range(at: 1))))</em>")
        }

        // 删除线
        t = replace(t, pattern: "(?s)~~(.+?)~~") { m in
            protect("<del>\(renderEscaped(substring(of: t, m.range(at: 1))))</del>")
        }

        // 裸链接
        t = replace(t, pattern: "(?<![\\w'\"=\\(/])(https?://[^\\s<>\\)\"']+)") { m in
            let url = substring(of: t, m.range(at: 1))
            return protect("<a href=\"\(escapeAttr(url))\">\(url)</a>")
        }

        return t
    }

    // MARK: - 占位符机制

    private func protect(_ html: String) -> String {
        inlineCounter += 1
        let key = "\u{1}w\(inlineCounter)\u{1}"
        placeholders[key] = html
        return key
    }

    private func restore(_ s: String) -> String {
        var out = s
        for _ in 0..<32 {
            var changed = false
            for (key, value) in placeholders where out.contains(key) {
                out = out.replacingOccurrences(of: key, with: value)
                changed = true
            }
            if !changed { break }
        }
        return out
    }

    // MARK: - 工具

    private func replace(
        _ s: String,
        pattern: String,
        transform: (NSTextCheckingResult) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = NSMutableString(string: s)
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            guard m.range.location != NSNotFound, m.range.upperBound <= ns.length else { continue }
            ns.replaceCharacters(in: m.range, with: transform(m))
        }
        return ns as String
    }

    private func substring(of s: String, _ range: NSRange) -> String {
        guard range.location != NSNotFound, range.location >= 0 else { return "" }
        let ns = s as NSString
        guard range.upperBound <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    private func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeAttr(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - 锚点

    private func slug(for text: String) -> String {
        var base = ""
        for ch in Self.plainText(text).lowercased() {
            if ch.isLetter || ch.isNumber {
                base.append(ch)
            } else if ch == " " || ch == "-" || ch == "_" {
                base.append("-")
            }
        }
        while base.contains("--") {
            base = base.replacingOccurrences(of: "--", with: "-")
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "section" }
        let n = slugCounts[base, default: 0]
        slugCounts[base] = n + 1
        return n == 0 ? base : "\(base)-\(n)"
    }

    /// 提取内联标记的纯文本（用于大纲显示）。
    public static func plainText(_ s: String) -> String {
        var t = s
        let image = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\([^)]*\\)")
        let link = try! NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\([^)]*\\)")
        let code = try! NSRegularExpression(pattern: "`([^`]*)`")
        func sub(_ re: NSRegularExpression) -> String {
            re.stringByReplacingMatches(
                in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1"
            )
        }
        t = sub(image)
        t = sub(link)
        t = sub(code)
        for marker in ["**", "__", "~~", "*", "_"] {
            t = t.replacingOccurrences(of: marker, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
