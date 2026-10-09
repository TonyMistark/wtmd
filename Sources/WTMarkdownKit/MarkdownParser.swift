import Foundation

/// 轻量级 Markdown 解析器：两阶段（块级切分 → 行级内联展开）。
/// 支持 CommonMark 常用子集 + GFM 扩展（表格、任务列表、删除线）。
public struct MarkdownParser: Sendable {
    public init() {}

    public func parse(_ source: String) -> [Block] {
        parse(source, onHeading: nil)
    }

    /// 解析并回调顶层标题（level, text, line），用于构建大纲。
    public func parse(
        _ source: String,
        onHeading: ((Int, String, Int) -> Void)? = nil
    ) -> [Block] {
        var noFootnotes: [Footnote]? = nil
        return parse(source, onHeading: onHeading, footnotes: &noFootnotes)
    }

    /// 带脚注收集的解析（渲染入口使用）。
    func parse(
        _ source: String,
        onHeading: ((Int, String, Int) -> Void)?,
        footnotes: inout [Footnote]?
    ) -> [Block] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        // 预扫描：剥离脚注定义行（允许任意位置），收集到 footnotes
        if footnotes != nil {
            var defs: [Footnote] = []
            var kept: [String] = []
            for line in lines {
                if let fn = Self.footnoteDefinition(line) {
                    defs.append(fn)
                } else {
                    kept.append(line)
                }
            }
            footnotes = defs
            lines = kept
        }
        return parseLines(lines, topLevel: true, onHeading: onHeading)
    }

    /// 匹配 `    [^id]: 内容` 形式的脚注定义行（缩进 ≤3 空格）。
    static func footnoteDefinition(_ line: String) -> Footnote? {
        var indent = 0
        var view = line[...]
        while let first = view.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            view = view.dropFirst()
            if indent > 3 { return nil }
        }
        guard view.hasPrefix("[^") else { return nil }
        let afterMarker = view.dropFirst(2)
        guard let close = afterMarker.firstIndex(of: "]") else { return nil }
        let id = String(afterMarker[..<close])
        guard !id.isEmpty, !id.contains(" ") else { return nil }
        let rest = afterMarker[afterMarker.index(after: close)...]
        guard rest.hasPrefix(":") else { return nil }
        let content = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return Footnote(id: id, text: content)
    }

    // MARK: - 块级解析

    func parseLines(
        _ lines: [String],
        topLevel: Bool,
        onHeading: ((Int, String, Int) -> Void)?
    ) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // 围栏代码块
            if let fence = Self.fenceStart(trimmed) {
                flushParagraph()
                var code: [String] = []
                var j = i + 1
                let closeMarker = String(repeating: fence.char, count: fence.length)
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(closeMarker) { break }
                    code.append(lines[j])
                    j += 1
                }
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n")))
                i = j + 1
                continue
            }

            // 标题
            if let (level, text) = Self.headingInfo(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text: text))
                if topLevel, let onHeading {
                    onHeading(level, text, i)
                }
                i += 1
                continue
            }

            // 分隔线
            if Self.isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                i += 1
                continue
            }

            // 引用块
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var content = String(t.dropFirst())
                        if content.hasPrefix(" ") { content.removeFirst() }
                        quoteLines.append(content)
                        i += 1
                    } else if !t.isEmpty, !quoteLines.isEmpty, !Self.isBlockStartLine(t) {
                        // 懒惰延续：引用内紧跟的普通文本
                        quoteLines.append(t)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.quote(parseLines(quoteLines, topLevel: false, onHeading: nil)))
                continue
            }

            // 表格（当前行含 | 且下一行是分隔行）
            if Self.isTableStart(lines, at: i) {
                flushParagraph()
                let header = Self.splitRow(lines[i])
                let alignments = Self.parseAlignments(lines[i + 1])
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    rows.append(Self.splitRow(lines[j]))
                    j += 1
                }
                blocks.append(.table(header: header, alignments: alignments, rows: rows))
                i = j
                continue
            }

            // 列表
            if Self.markerMatch(trimmed) != nil {
                flushParagraph()
                var listLines: [String] = []
                var lastContentIndent = 0
                var j = i
                while j < lines.count {
                    let l = lines[j]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if let m = Self.markerMatch(t) {
                        listLines.append(t)
                        lastContentIndent = m.contentIndent
                        j += 1
                        continue
                    }
                    let ind = Self.indent(of: l)
                    if !listLines.isEmpty && ind >= lastContentIndent {
                        listLines.append(l)
                        j += 1
                        continue
                    }
                    if !listLines.isEmpty && !Self.isBlockStartLine(t) {
                        // 懒惰延续：列表项后紧跟的普通文本
                        listLines.append(l)
                        j += 1
                        continue
                    }
                    break
                }
                blocks.append(contentsOf: parseList(listLines))
                i = j
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - 列表

    private func parseList(_ lines: [String]) -> [Block] {
        guard let first = Self.markerMatch(lines.first ?? "") else {
            return [.paragraph(lines.joined(separator: "\n"))]
        }
        let ordered = first.isOrdered
        var start = first.number
        var items: [ListItem] = []
        var i = 0

        while i < lines.count {
            guard let m = Self.markerMatch(lines[i]) else {
                i += 1
                continue
            }
            // 标记类型变化（有序 ⇄ 无序）：结束当前列表，剩余部分递归解析
            if !items.isEmpty && m.isOrdered != ordered && m.indent <= first.indent {
                return [.list(ordered: ordered, start: start, items: items)]
                    + parseList(Array(lines[i...]))
            }
            var content: [String] = [m.rest ?? ""]
            i += 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                // 同级或更浅的列表项 → 下一项
                if let m2 = Self.markerMatch(t), m2.indent <= m.indent {
                    break
                }
                let ind = Self.indent(of: l)
                if ind >= m.contentIndent {
                    content.append(String(l.dropFirst(min(ind, m.contentIndent))))
                    i += 1
                } else if !t.isEmpty && !Self.isBlockStartLine(t) {
                    // 懒惰延续
                    content.append(t)
                    i += 1
                } else {
                    break
                }
            }

            var taskState: TaskState?
            if !ordered, let head = content.first {
                if head == "[ ]" || head.hasPrefix("[ ] ") {
                    taskState = .unchecked
                    content[0] = String(head.dropFirst(3))
                } else if head == "[x]" || head == "[X]"
                    || head.hasPrefix("[x] ") || head.hasPrefix("[X] ") {
                    taskState = .checked
                    content[0] = String(head.dropFirst(3))
                }
                if content[0].isEmpty { content.removeFirst() }
            }

            let itemBlocks = parseLines(content, topLevel: false, onHeading: nil)
            items.append(ListItem(blocks: itemBlocks, taskState: taskState))
        }

        if ordered && items.isEmpty { start = 1 }
        return [.list(ordered: ordered, start: start, items: items)]
    }

    // MARK: - 行匹配辅助

    struct Marker: Sendable {
        let indent: Int
        let contentIndent: Int
        let isOrdered: Bool
        let number: Int
        let rest: String?
    }

    static func markerMatch(_ line: String) -> Marker? {
        var indent = 0
        var chars = line.makeIterator()
        var lead: [Character] = []
        while let ch = chars.next() {
            if ch == " " { indent += 1; lead.append(ch) }
            else if ch == "\t" { indent += 4; lead.append(ch) }
            else { break }
        }
        let afterLead = String(line.dropFirst(lead.count))
        guard let first = afterLead.first else { return nil }

        var markerLen = 0
        var isOrdered = false
        var number = 1

        if first == "-" || first == "*" || first == "+" {
            markerLen = 1
        } else if first.isNumber {
            var digits = 0
            var j = afterLead.startIndex
            var n = 0
            while j < afterLead.endIndex, afterLead[j].isNumber, digits < 9 {
                n = n * 10 + (afterLead[j].wholeNumberValue ?? 0)
                j = afterLead.index(after: j)
                digits += 1
            }
            guard j < afterLead.endIndex else { return nil }
            let after = afterLead[j]
            guard after == "." || after == ")" else { return nil }
            number = n
            isOrdered = true
            markerLen = digits + 1
        } else {
            return nil
        }

        let afterMarker = String(afterLead.dropFirst(markerLen))
        if afterMarker.isEmpty {
            return Marker(
                indent: indent,
                contentIndent: indent + markerLen + 1,
                isOrdered: isOrdered,
                number: number,
                rest: nil
            )
        }
        guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
        let content = afterMarker.trimmingCharacters(in: .whitespaces)
        return Marker(
            indent: indent,
            contentIndent: indent + markerLen + 1,
            isOrdered: isOrdered,
            number: number,
            rest: content.isEmpty ? nil : content
        )
    }

    static func indent(of line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 }
            else if ch == "\t" { n += 4 }
            else { break }
        }
        return n
    }

    static func headingInfo(_ line: String) -> (Int, String)? {
        var level = 0
        var it = line.makeIterator()
        while let ch = it.next(), ch == "#" { level += 1 }
        guard (1...6).contains(level) else { return nil }
        let rest = String(line.dropFirst(level))
        guard rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // 去掉闭合的 #
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    static func fenceStart(_ line: String) -> (char: Character, length: Int, language: String?)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        var length = 0
        for ch in line {
            if ch == first { length += 1 } else { break }
        }
        guard length >= 3 else { return nil }
        let language = String(line.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        guard first != "`" || !language.contains("`") else { return nil }
        return (first, length, language.isEmpty ? nil : language)
    }

    static func isDivider(_ line: String) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        guard chars.count >= 3, let first = chars.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return chars.allSatisfy { $0 == first }
    }

    /// 是否为会打断段落/列表的块级起始行（标题、围栏、分隔线、引用）。
    static func isBlockStartLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if headingInfo(t) != nil { return true }
        if fenceStart(t) != nil { return true }
        if isDivider(t) { return true }
        if t.hasPrefix(">") { return true }
        return false
    }

    // MARK: - 表格

    static func isTableStart(_ lines: [String], at i: Int) -> Bool {
        guard i + 1 < lines.count else { return false }
        let current = lines[i].trimmingCharacters(in: .whitespaces)
        let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
        guard current.contains("|"), next.contains("|") else { return false }
        let cells = splitRow(next)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell
            guard !c.isEmpty else { return false }
            var s = c
            if s.hasPrefix(":") { s.removeFirst() }
            if s.hasSuffix(":") { s.removeLast() }
            return !s.isEmpty && s.allSatisfy { $0 == "-" }
        }
    }

    static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let placeholder = "\u{2}"
        let protected = t.replacingOccurrences(of: "\\|", with: placeholder)
        let cells = protected.components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
        return cells
    }

    static func parseAlignments(_ delimiterLine: String) -> [TableAlignment] {
        splitRow(delimiterLine).map { cell in
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            if left { return .left }
            return .none
        }
    }
}
