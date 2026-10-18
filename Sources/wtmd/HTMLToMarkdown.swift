import AppKit

/// HTML → Markdown。
///
/// 解析器是自己写的：不引依赖，也不借 `NSAttributedString(html:)`——那条路要过
/// WebKit、只能主线程跑，而且它把标题层级压成字号，反推回来只能猜。粘贴板上的
/// HTML 结构其实很规整（浏览器与 Word 都是），够用的子集手写反而更可控。
///
/// 对外只有一个纯函数 `markdown(fromHTML:)`，测试直接喂 HTML 片段。
enum HTMLToMarkdown {
    // MARK: - 入口

    /// 粘贴板上的富文本。图片不在这里——那是落地管线的事。
    @MainActor
    static func markdown(from pasteboard: NSPasteboard) -> String? {
        if let html = pasteboard.string(forType: .html),
           let markdown = markdown(fromHTML: html), !markdown.isEmpty {
            return markdown
        }
        // 只有 RTF（Word、Pages、备忘录）：先转 HTML，再走同一条路
        guard let rtf = pasteboard.data(forType: .rtf),
              let html = html(fromRTF: rtf),
              let markdown = markdown(fromHTML: html), !markdown.isEmpty else {
            return nil
        }
        return markdown
    }

    @MainActor
    private static func html(fromRTF data: Data) -> String? {
        guard let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        guard let html = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        ) else { return nil }
        return String(data: html, encoding: .utf8)
    }

    /// 整份 HTML（或一段片段）转成 Markdown。没有可落地的内容时返回 nil。
    static func markdown(fromHTML html: String) -> String? {
        // 粘贴板里的东西不该有这么大，超了直接放弃：宁可粘成原文，也不卡住
        guard html.utf8.count <= 4_000_000 else { return nil }
        var parser = Parser(html: html)
        let nodes = parser.parse()
        let body = tidy(blocks(from: nodes).joined(separator: "\n\n"))
        return body.isEmpty ? nil : body
    }

    // MARK: - 块级渲染

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "nav",
        "ul", "ol", "li", "dl", "dt", "dd", "blockquote", "pre", "table", "thead",
        "tbody", "tfoot", "tr", "td", "th", "hr", "figure", "figcaption", "form",
        "fieldset", "address", "details", "summary", "h1", "h2", "h3", "h4", "h5", "h6",
        "body", "html", "center",
    ]

    /// 容器：本身不产出文字，只把孩子的块拼起来。
    private static let containerTags: Set<String> = [
        "div", "section", "article", "header", "footer", "main", "aside", "nav",
        "figure", "figcaption", "form", "fieldset", "address", "details", "summary",
        "body", "html", "center", "li", "dt", "dd", "thead", "tbody", "tfoot",
    ]

    private static func isBlock(_ tag: String) -> Bool {
        blockTags.contains(tag)
    }

    static func blocks(from nodes: [Node]) -> [String] {
        var blocks: [String] = []
        var pending: [Node] = []

        func flush() {
            guard !pending.isEmpty else { return }
            let text = inlineString(pending).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(text) }
            pending.removeAll()
        }

        for node in nodes {
            if node.isText {
                pending.append(node)
                continue
            }
            if isBlock(node.tag) {
                flush()
                if let block = blockText(node) {
                    let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { blocks.append(trimmed) }
                }
            } else {
                pending.append(node)
            }
        }
        flush()
        return blocks
    }

    private static func blockText(_ node: Node) -> String? {
        switch node.tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(node.tag.dropFirst())) ?? 1
            let text = inlineString(node.children).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return String(repeating: "#", count: max(1, min(6, level))) + " " + text

        case "p":
            let text = inlineString(node.children).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text

        case "blockquote":
            let inner = blocks(from: node.children).joined(separator: "\n\n")
            guard !inner.isEmpty else { return nil }
            return inner
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> " + $0 }
                .joined(separator: "\n")

        case "pre":
            return codeBlock(node)

        case "ul":
            return list(node, ordered: false, depth: 0)

        case "ol":
            return list(node, ordered: true, depth: 0)

        case "table":
            return table(node)

        case "hr":
            return "---"

        case "br":
            return nil

        default:
            if containerTags.contains(node.tag) {
                let inner = blocks(from: node.children).joined(separator: "\n\n")
                return inner.isEmpty ? nil : inner
            }
            let text = inlineString([node]).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    // MARK: - 列表

    private static func list(_ node: Node, ordered: Bool, depth: Int) -> String? {
        let items = node.children.filter { $0.tag == "li" }
        guard !items.isEmpty else {
            let inner = blocks(from: node.children).joined(separator: "\n\n")
            return inner.isEmpty ? nil : inner
        }

        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []

        for (offset, item) in items.enumerated() {
            let marker = ordered ? "\(offset + 1). " : "- "
            var inlineNodes: [Node] = []
            var nested: [String] = []

            for child in item.children {
                if child.tag == "ul" || child.tag == "ol" {
                    if let block = list(child, ordered: child.tag == "ol", depth: depth + 1) {
                        nested.append(block)
                    }
                } else if child.tag == "p" {
                    // 列表项里的段落并进本行：Markdown 的松散列表不好读，也没人想要
                    if !inlineNodes.isEmpty {
                        inlineNodes.append(Node(tag: "#text", text: " "))
                    }
                    inlineNodes.append(contentsOf: child.children)
                } else if isBlock(child.tag) {
                    if let block = blockText(child) { nested.append(block) }
                } else {
                    inlineNodes.append(child)
                }
            }

            let text = inlineString(inlineNodes).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(indent + marker + text)
            lines.append(contentsOf: nested)
        }

        let body = lines.joined(separator: "\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
    }

    // MARK: - 代码块

    private static func codeBlock(_ node: Node) -> String? {
        var raw = ""
        collectRawText(node, into: &raw)
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while text.hasPrefix("\n") { text.removeFirst() }
        while text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty else { return nil }

        let language = codeLanguage(node)
        let fence = text.contains("```") ? "````" : "```"
        return fence + language + "\n" + text + "\n" + fence
    }

    private static func collectRawText(_ node: Node, into buffer: inout String) {
        if node.isText {
            buffer += node.text
            return
        }
        for child in node.children { collectRawText(child, into: &buffer) }
    }

    private static func codeLanguage(_ node: Node) -> String {
        let candidates = [node.attributes["class"]] + node.children.map { $0.attributes["class"] }
        for candidate in candidates.compactMap({ $0 }) {
            for token in candidate.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                for prefix in ["language-", "lang-"] where token.hasPrefix(prefix) {
                    return String(token.dropFirst(prefix.count))
                }
            }
        }
        return ""
    }

    // MARK: - 表格

    private static func table(_ node: Node) -> String? {
        var rows: [Node] = []
        collectRows(node, into: &rows)
        guard !rows.isEmpty else { return nil }

        var grid: [[String]] = rows.map { row in
            row.children
                .filter { $0.tag == "td" || $0.tag == "th" }
                .map { cell in
                    inlineString(cell.children)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: " ")
                }
        }
        let columns = max(1, grid.map(\.count).max() ?? 0)
        for index in grid.indices {
            while grid[index].count < columns { grid[index].append("") }
        }

        func line(_ cells: [String]) -> String {
            "| " + cells.joined(separator: " | ") + " |"
        }

        var lines = [line(grid[0])]
        lines.append("|" + String(repeating: " --- |", count: columns))
        for row in grid.dropFirst() { lines.append(line(row)) }
        return lines.joined(separator: "\n")
    }

    private static func collectRows(_ node: Node, into rows: inout [Node]) {
        for child in node.children {
            if child.tag == "tr" {
                rows.append(child)
            } else if child.tag == "thead" || child.tag == "tbody" || child.tag == "tfoot" || child.tag == "table" {
                collectRows(child, into: &rows)
            }
        }
    }

    // MARK: - 行内

    static func inlineString(_ nodes: [Node]) -> String {
        var writer = InlineWriter()
        inline(nodes, into: &writer)
        return writer.result
    }

    private static func inline(_ nodes: [Node], into writer: inout InlineWriter) {
        for node in nodes {
            if node.isText {
                writer.write(node.text)
                continue
            }
            switch node.tag {
            case "br":
                // 硬换行：两个空格 + 换行是 Markdown 里唯一到处都认的写法
                writer.writeRaw("  \n")

            case "strong", "b":
                writeWrapped(node.children, marker: "**", into: &writer)

            case "em", "i":
                writeWrapped(node.children, marker: "*", into: &writer)

            case "del", "s", "strike":
                writeWrapped(node.children, marker: "~~", into: &writer)

            case "code", "kbd", "samp", "tt":
                let raw = rawText(node).replacingOccurrences(of: "\n", with: " ")
                let text = raw.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let fence = text.contains("`") ? "``" : "`"
                writer.writeRaw(fence + text + fence)

            case "a":
                let href = node.attributes["href"] ?? ""
                let text = inlineString(node.children).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if href.isEmpty || href.hasPrefix("#") || href.hasPrefix("javascript:") {
                    writer.writeRaw(text)
                } else {
                    writer.writeRaw("[\(text)](\(href))")
                }

            case "img":
                let source = node.attributes["src"] ?? ""
                guard !source.isEmpty else { continue }
                let alt = node.attributes["alt"] ?? ""
                writer.writeRaw("![\(alt)](\(source))")

            case "script", "style", "head", "title":
                break

            default:
                // Word 的粗体有时只写在 style 里，没有 b/strong 标签
                let style = (node.attributes["style"] ?? "")
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "")
                let text = inlineString(node.children)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                var decorated = trimmed
                if style.contains("font-weight:bold") || style.contains("font-weight:700") {
                    decorated = "**" + decorated + "**"
                }
                if style.contains("font-style:italic") {
                    decorated = "*" + decorated + "*"
                }
                writer.writeRaw(decorated)
            }
        }
    }

    private static func writeWrapped(_ children: [Node], marker: String, into writer: inout InlineWriter) {
        let text = inlineString(children).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        writer.writeRaw(marker + text + marker)
    }

    private static func rawText(_ node: Node) -> String {
        var buffer = ""
        collectRawText(node, into: &buffer)
        return buffer
    }

    // MARK: - 清洗

    private static func tidy(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // 连续空行压成一行：块之间本来就隔着一个空行
        var collapsed: [String] = []
        var blanks = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blanks += 1
                if blanks > 1 { continue }
                collapsed.append("")
            } else {
                blanks = 0
                collapsed.append(line)
            }
        }
        lines = collapsed
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 转义

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&" else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            guard let semicolon = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semicolon) <= 10 else {
                result.append("&")
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index)..<semicolon])
            if let decoded = decode(name) {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append("&")
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decode(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let body = name.dropFirst()
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                value = UInt32(body.dropFirst(), radix: 16)
            } else {
                value = UInt32(body)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "mdash": return "—"
        case "ndash": return "–"
        case "hellip": return "…"
        case "lsquo": return "‘"
        case "rsquo": return "’"
        case "ldquo": return "“"
        case "rdquo": return "”"
        case "middot": return "·"
        case "bull": return "•"
        case "copy": return "©"
        case "reg": return "®"
        case "trade": return "™"
        case "times": return "×"
        default: return nil
        }
    }

    // MARK: - 行内缓冲

    /// 把空白压成单个空格，同时不让行首带空格。
    /// Markdown 对空白敏感的地方（缩进、行尾两个空格）都由 `writeRaw` 直接写，绕开压缩。
    private struct InlineWriter {
        private(set) var out = ""
        private var pendingSpace = false

        mutating func write(_ text: String) {
            for character in text {
                if character.isWhitespace {
                    if !out.isEmpty { pendingSpace = true }
                } else {
                    if pendingSpace {
                        out.append(" ")
                        pendingSpace = false
                    }
                    out.append(character)
                }
            }
        }

        mutating func writeRaw(_ text: String) {
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(text)
        }

        var result: String { out }
    }

    // MARK: - 节点

    final class Node {
        let tag: String
        let attributes: [String: String]
        var children: [Node] = []
        var text = ""

        init(tag: String, attributes: [String: String] = [:], text: String = "") {
            self.tag = tag
            self.attributes = attributes
            self.text = text
        }

        var isText: Bool { tag == "#text" }
    }

    // MARK: - 解析

    private struct Parser {
        private let chars: [Character]
        private var index = 0
        private static let voidTags: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
            "meta", "param", "source", "track", "wbr",
        ]

        init(html: String) {
            chars = Array(html)
        }

        mutating func parse() -> [Node] {
            let root = Node(tag: "#root")
            var stack: [Node] = [root]

            while index < chars.count {
                if chars[index] == "<" {
                    handle(readTag(), stack: &stack)
                } else {
                    let text = readText()
                    guard !text.isEmpty else { continue }
                    stack[stack.count - 1].children.append(
                        Node(tag: "#text", text: HTMLToMarkdown.decodeEntities(text))
                    )
                }
            }
            return root.children
        }

        private enum Token {
            case open(name: String, attributes: [String: String], selfClosing: Bool)
            case close(name: String)
            case other
        }

        private mutating func readTag() -> Token {
            // 注释里可能有 `>`，先按 `-->` 整段跳过
            if matches("!--", at: index + 1) {
                if let close = find("-->", from: index + 4) {
                    index = close + 3
                } else {
                    index = chars.count
                }
                return .other
            }
            guard let end = firstIndex(of: ">", from: index + 1) else {
                index = chars.count
                return .other
            }
            var body = String(chars[(index + 1)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            index = end + 1

            if body.hasPrefix("!") || body.hasPrefix("?") { return .other }
            if body.hasPrefix("/") {
                return .close(name: body.dropFirst().trimmingCharacters(in: .whitespaces).lowercased())
            }
            var selfClosing = false
            if body.hasSuffix("/") {
                selfClosing = true
                body.removeLast()
            }
            let name = String(body.prefix { !$0.isWhitespace }).lowercased()
            let attributes = parseAttributes(String(body.dropFirst(name.count)))
            return .open(name: name, attributes: attributes, selfClosing: selfClosing)
        }

        private mutating func handle(_ token: Token, stack: inout [Node]) {
            switch token {
            case .other:
                break

            case .close(let name):
                // 只弹到匹配的那一层：多余的 `</div>` 不该把整棵树清空
                if let position = stack.lastIndex(where: { $0.tag == name }), position > 0 {
                    stack.removeSubrange(position...)
                }

            case .open(let name, let attributes, let selfClosing):
                if name == "script" || name == "style" || name == "head" || name == "title" {
                    skipRawElement(name)
                    return
                }
                while let top = stack.last, top.tag != "#root", closes(top.tag, for: name) {
                    stack.removeLast()
                }
                let node = Node(tag: name, attributes: attributes)
                stack[stack.count - 1].children.append(node)
                if !selfClosing && !Parser.voidTags.contains(name) {
                    stack.append(node)
                }
            }
        }

        /// 隐式闭合：`<li>` 没写 `</li>` 时，下一个 `<li>` 就是它的结束。
        private func closes(_ open: String, for new: String) -> Bool {
            switch open {
            case "p": return HTMLToMarkdown.blockTags.contains(new)
            case "li": return new == "li"
            case "td", "th": return new == "td" || new == "th" || new == "tr"
            case "tr": return new == "tr"
            case "option": return new == "option"
            default: return false
            }
        }

        private mutating func skipRawElement(_ name: String) {
            let rest = String(chars[index...])
            guard let range = rest.range(of: "</\(name)", options: .caseInsensitive) else {
                index = chars.count
                return
            }
            index += rest.distance(from: rest.startIndex, to: range.lowerBound)
            if let end = firstIndex(of: ">", from: index) { index = end + 1 }
        }

        private mutating func readText() -> String {
            let start = index
            while index < chars.count, chars[index] != "<" { index += 1 }
            return String(chars[start..<index])
        }

        private func parseAttributes(_ source: String) -> [String: String] {
            var attributes: [String: String] = [:]
            let characters = Array(source)
            var cursor = 0
            while cursor < characters.count {
                let stepStart = cursor
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                var name = ""
                while cursor < characters.count, characters[cursor] != "=", !characters[cursor].isWhitespace {
                    name.append(characters[cursor])
                    cursor += 1
                }
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                var value = ""
                if cursor < characters.count, characters[cursor] == "=" {
                    cursor += 1
                    while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                    if cursor < characters.count, characters[cursor] == "\"" || characters[cursor] == "'" {
                        let quote = characters[cursor]
                        cursor += 1
                        while cursor < characters.count, characters[cursor] != quote {
                            value.append(characters[cursor])
                            cursor += 1
                        }
                        if cursor < characters.count { cursor += 1 }
                    } else {
                        while cursor < characters.count, !characters[cursor].isWhitespace {
                            value.append(characters[cursor])
                            cursor += 1
                        }
                    }
                }
                if !name.isEmpty {
                    attributes[name.lowercased()] = HTMLToMarkdown.decodeEntities(value)
                }
                // 兜底：这一轮没前进就强制推一格，绝不死循环
                if cursor == stepStart { cursor += 1 }
            }
            return attributes
        }

        private func firstIndex(of character: Character, from start: Int) -> Int? {
            var cursor = max(0, start)
            while cursor < chars.count {
                if chars[cursor] == character { return cursor }
                cursor += 1
            }
            return nil
        }

        private func find(_ pattern: String, from start: Int) -> Int? {
            var cursor = max(0, start)
            while cursor < chars.count {
                if matches(pattern, at: cursor) { return cursor }
                cursor += 1
            }
            return nil
        }

        private func matches(_ pattern: String, at position: Int) -> Bool {
            let target = Array(pattern)
            guard position >= 0, position + target.count <= chars.count else { return false }
            for offset in 0..<target.count where chars[position + offset] != target[offset] {
                return false
            }
            return true
        }
    }
}
