import Foundation

/// 一次文本编辑：把 `range` 换成 `text`。
///
/// 纯函数只负责算，不负责做——编辑器把它交给 `insertText(_:replacementRange:)`
/// 一次落地，撤销栈里就是一步。
struct MarkdownEdit: Equatable {
    var range: NSRange
    var text: String
    /// 落地后应设置的选区；`nil` 表示沿用系统默认（插入点落在插入文本之后）。
    var selectionAfter: NSRange?

    init(range: NSRange, text: String, selectionAfter: NSRange? = nil) {
        self.range = range
        self.text = text
        self.selectionAfter = selectionAfter
    }
}

/// 回车续行、Tab 缩进、⇧Tab 反缩进。
///
/// 全是纯函数：给文本与选区，算出该替换哪一段、换成什么，不碰视图。
/// 认的写法和语法高亮是同一套（`-` / `1.` / `- [ ]` / `>` / 围栏），
/// 所以屏幕上染成橙色的那个 marker，回车时一定也认得出。
enum MarkdownEditing {
    /// 缩进宽度。两空格是 GFM 嵌套列表的通行写法；`\t` 在不同渲染器里宽度不定。
    static let indentUnit = "  "

    // MARK: - 回车

    /// 回车时是否要自己处理。`nil` 表示交回系统（普通换行）。
    static func newline(in text: String, selection: NSRange) -> MarkdownEdit? {
        let ns = text as NSString
        let caret = min(max(0, selection.location), ns.length)
        let start = lineStart(before: caret, in: ns)
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)

        // 行首、纯空白行：普通换行
        guard !trimmed.isEmpty else { return nil }
        // 围栏行本身、围栏内部：代码里的回车就是回车
        guard !isFenceLine(trimmed) else { return nil }
        guard !isInsideFence(ns, before: start) else { return nil }

        // 表格行：补一行，而不是把表格断开。带选区时交回系统——读者在选东西
        if selection.length == 0, let row = tableRow(in: ns, lineStart: start) {
            return appendRow(after: row, in: ns)
        }

        guard let marker = parsePrefix(prefix) else { return nil }

        // 空项只对「光标停着」成立：带选区时读者的意思显然是拆行，不是退出列表
        if selection.length == 0, marker.content.trimmingCharacters(in: .whitespaces).isEmpty {
            // 空项：把 marker 清掉，缩进留着——嵌套列表退出后仍属于父项
            return MarkdownEdit(
                range: NSRange(location: start, length: caret - start),
                text: marker.indent
            )
        }

        let editRange = selection.length > 0 ? selection : NSRange(location: caret, length: 0)
        return MarkdownEdit(range: editRange, text: "\n" + marker.continuation)
    }

    // MARK: - 缩进

    /// Tab（`outdent == false`）与 ⇧Tab（`true`）。
    ///
    /// 多行选区整块替换、整块保持选中——连续按 Tab 能一层层往里推。
    static func indent(in text: String, selection: NSRange, outdent: Bool) -> MarkdownEdit? {
        let ns = text as NSString
        let start = min(max(0, selection.location), ns.length)
        let end = min(max(start, selection.location + selection.length), ns.length)
        let blockStart = lineStart(before: start, in: ns)

        // 块尾取「选区末端所在行」的内容末尾：只按了行首时不该把下一行卷进来
        let anchor = end > blockStart ? end - 1 : end
        let newline = ns.range(
            of: "\n",
            options: [],
            range: NSRange(location: anchor, length: ns.length - anchor)
        )
        let blockEnd = newline.location == NSNotFound ? ns.length : newline.location
        let block = ns.substring(with: NSRange(location: blockStart, length: blockEnd - blockStart))

        // 空行 Tab：插缩进单位，不留制表符
        if !outdent, selection.length == 0, block.isEmpty {
            return MarkdownEdit(
                range: NSRange(location: blockStart, length: 0),
                text: indentUnit,
                selectionAfter: NSRange(location: blockStart + (indentUnit as NSString).length, length: 0)
            )
        }

        var lines = block.components(separatedBy: "\n")
        var deltas: [Int] = []
        for (index, line) in lines.enumerated() {
            if outdent {
                let (trimmed, removed) = removingIndent(from: line)
                lines[index] = trimmed
                deltas.append(-removed)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                deltas.append(0)  // 空行不产生尾随空白
            } else {
                lines[index] = indentUnit + line
                deltas.append((indentUnit as NSString).length)
            }
        }
        guard deltas.contains(where: { $0 != 0 }) else { return nil }

        let newBlock = lines.joined(separator: "\n")
        let stillCollapsed = selection.length == 0 && lines.count == 1
        let after: NSRange
        if stillCollapsed {
            let caret = start - blockStart + deltas[0]
            after = NSRange(location: blockStart + max(0, caret), length: 0)
        } else {
            after = NSRange(location: blockStart, length: (newBlock as NSString).length)
        }
        return MarkdownEdit(
            range: NSRange(location: blockStart, length: blockEnd - blockStart),
            text: newBlock,
            selectionAfter: after
        )
    }

    // MARK: - Tab（表格优先，其余缩进）

    /// Tab / ⇧Tab：在表格里是「去下一格」，别的地方还是缩进。
    ///
    /// 表格里退回缩进就等于往行首塞空格，那会把整张表推出对齐之外——
    /// 所以表格行的 Tab 一律由单元格导航接管（最后一格之后补行）。
    static func tab(in text: String, selection: NSRange, outdent: Bool) -> MarkdownEdit? {
        if selection.length == 0,
           let move = cellStep(in: text, caret: selection.location, outdent: outdent) {
            return move
        }
        return indent(in: text, selection: selection, outdent: outdent)
    }

    // MARK: - 表格

    /// 一行的表格结构。位置全是绝对偏移（NSString 口径）。
    private struct TableRow {
        var lineStart: Int
        /// 行内容末尾（不含换行符）。
        var lineEnd: Int
        /// 未被转义的 `|` 的位置，含首尾。
        var pipes: [Int]
        /// 分隔行：每格只有 `-`、`:` 和空白。
        var isSeparator: Bool

        /// 列数：行尾有 `|` 时是「竖线数 - 1」，没收尾时最后一段也算一格。
        func columnCount(in ns: NSString) -> Int {
            guard !pipes.isEmpty else { return 0 }
            let endsWithPipe = pipes.last.map { allWhitespace(ns, from: $0 + 1, to: lineEnd) } ?? false
            return endsWithPipe ? max(0, pipes.count - 1) : max(1, pipes.count)
        }
    }

    /// 光标所在格的下标。
    private static func cellIndex(of caret: Int, in row: TableRow, columns: Int) -> Int {
        guard columns > 0 else { return 0 }
        let before = row.pipes.filter { $0 < caret }.count
        return min(max(0, before - 1), columns - 1)
    }

    /// 第 `index` 格可落笔的位置：跳过前导空白；整格空白就停在格内第一个空格之后。
    private static func cellStart(_ index: Int, in row: TableRow, ns: NSString) -> Int {
        let rawStart = row.pipes[min(index, row.pipes.count - 1)] + 1
        let rawEnd = index + 1 < row.pipes.count ? row.pipes[index + 1] : row.lineEnd
        var cursor = rawStart
        while cursor < rawEnd, isSpace(ns.character(at: cursor)) { cursor += 1 }
        if cursor >= rawEnd {
            // 空格铺满整格：落在第一个空格之后，敲字时两侧还留着一点余地
            return min(rawStart + 1, rawEnd)
        }
        return cursor
    }

    /// Tab / ⇧Tab 在单元格之间走一步。不在表格里返回 nil。
    private static func cellStep(in text: String, caret: Int, outdent: Bool) -> MarkdownEdit? {
        let ns = text as NSString
        let location = min(max(0, caret), ns.length)
        let start = lineStart(before: location, in: ns)
        guard !isInsideFence(ns, before: start) else { return nil }
        guard let row = tableRow(in: ns, lineStart: start) else { return nil }
        // 分隔行不是写字的地方：原地不动，别把 `| --- |` 推成缩进行
        guard !row.isSeparator else { return caretMove(to: location) }

        let columns = row.columnCount(in: ns)
        guard columns > 0 else { return nil }
        let current = cellIndex(of: location, in: row, columns: columns)

        if outdent {
            if current > 0 {
                return caretMove(to: cellStart(current - 1, in: row, ns: ns))
            }
            guard let previous = adjacentRow(before: row, in: ns) else { return nil }
            let previousColumns = previous.columnCount(in: ns)
            guard previousColumns > 0 else { return nil }
            return caretMove(
                to: cellStart(previousColumns - 1, in: previous, ns: ns)
            )
        }

        if current + 1 < columns {
            return caretMove(to: cellStart(current + 1, in: row, ns: ns))
        }
        if let next = adjacentRow(after: row, in: ns) {
            return caretMove(to: cellStart(0, in: next, ns: ns))
        }
        // 最后一格：与其停在原地，不如把下一行备好
        return appendRow(after: row, in: ns)
    }

    /// 只挪光标，不动一个字。
    private static func caretMove(to location: Int) -> MarkdownEdit {
        let range = NSRange(location: location, length: 0)
        return MarkdownEdit(range: range, text: "", selectionAfter: range)
    }

    /// 在当前行下面补一行空行，光标落在第一格。
    private static func appendRow(after row: TableRow, in ns: NSString) -> MarkdownEdit {
        let columns = max(1, row.columnCount(in: ns))
        // 不猜列宽：与其按字符数硬凑（中日韩全角会让对齐失真），不如写得短而整齐
        let empty = "|" + String(repeating: "  |", count: columns)
        let insertAt = row.lineEnd
        return MarkdownEdit(
            range: NSRange(location: insertAt, length: 0),
            text: "\n" + empty,
            // `|` 之后留一格：正好是两个空格中的第一个之后
            selectionAfter: NSRange(location: insertAt + 3, length: 0)
        )
    }

    /// 紧邻的上一行 / 下一行，只在它还是表格行时返回。
    ///
    /// 分隔行不算数：从表头 ⇧Tab 应该退到上一行的最后一格，而不是卡在 `| --- |` 上。
    private static func adjacentRow(before row: TableRow, in ns: NSString) -> TableRow? {
        var line = row.lineStart
        while line > 0 {
            line = lineStart(before: line - 1, in: ns)
            guard let candidate = tableRow(in: ns, lineStart: line) else { return nil }
            if candidate.isSeparator { continue }
            return candidate
        }
        return nil
    }

    private static func adjacentRow(after row: TableRow, in ns: NSString) -> TableRow? {
        var line = row.lineEnd
        while line < ns.length {
            let newline = ns.range(
                of: "\n",
                options: [],
                range: NSRange(location: line, length: ns.length - line)
            )
            guard newline.location != NSNotFound else { return nil }
            line = newline.location + 1
            guard let candidate = tableRow(in: ns, lineStart: line) else { return nil }
            if candidate.isSeparator { continue }
            return candidate
        }
        return nil
    }

    /// 认出一行表格。只认以 `|` 开头的行（与高亮、GFM 的写法一致）。
    private static func tableRow(in ns: NSString, lineStart: Int) -> TableRow? {
        var start = 0
        var end = 0
        var contentsEnd = 0
        ns.getLineStart(
            &start,
            end: &end,
            contentsEnd: &contentsEnd,
            for: NSRange(location: lineStart, length: 0)
        )
        let line = ns.substring(with: NSRange(location: start, length: contentsEnd - start))
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return nil }

        var pipes: [Int] = []
        var index = start
        while index < contentsEnd {
            let character = ns.character(at: index)
            if character == 0x7C {  // `|`
                // 反斜杠转义的竖线是单元格内容，不是分隔
                var backslashes = 0
                var probe = index - 1
                while probe >= start, ns.character(at: probe) == 0x5C {
                    backslashes += 1
                    probe -= 1
                }
                if backslashes % 2 == 0 { pipes.append(index) }
            }
            index += 1
        }
        guard !pipes.isEmpty else { return nil }

        let base = TableRow(lineStart: start, lineEnd: contentsEnd, pipes: pipes, isSeparator: false)
        return TableRow(
            lineStart: start,
            lineEnd: contentsEnd,
            pipes: pipes,
            isSeparator: isSeparatorRow(base, in: ns)
        )
    }

    private static func isSeparatorRow(_ row: TableRow, in ns: NSString) -> Bool {
        let columns = row.columnCount(in: ns)
        guard columns > 0 else { return false }
        var sawDash = false
        for index in 0..<columns {
            let rawStart = row.pipes[index] + 1
            let rawEnd = index + 1 < row.pipes.count ? row.pipes[index + 1] : row.lineEnd
            var cursor = rawStart
            var dashes = 0
            while cursor < rawEnd {
                let character = ns.character(at: cursor)
                if character == 0x2D {  // `-`
                    dashes += 1
                } else if character != 0x3A, !isSpace(character) {  // 非 `:`、非空白
                    return false
                }
                cursor += 1
            }
            if dashes == 0 { return false }
            sawDash = true
        }
        return sawDash
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    /// `from..<to` 全是空白（用来判断行尾有没有收尾竖线）。
    private static func allWhitespace(_ ns: NSString, from: Int, to: Int) -> Bool {
        guard from <= to, to <= ns.length else { return false }
        var index = from
        while index < to {
            if !isSpace(ns.character(at: index)) { return false }
            index += 1
        }
        return true
    }

    // MARK: - 行内杂务

    /// 去掉行首最多一个缩进单位。返回新行与实际去掉的字数。
    private static func removingIndent(from line: String) -> (String, Int) {
        var index = line.startIndex
        var removed = 0
        while removed < indentUnit.count, index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
            removed += 1
        }
        if removed == 0, index < line.endIndex, line[index] == "\t" {
            index = line.index(after: index)
            removed = 1
        }
        return (String(line[index...]), removed)
    }

    /// 光标之前最近一个换行的位置 + 1。
    private static func lineStart(before caret: Int, in ns: NSString) -> Int {
        guard caret > 0 else { return 0 }
        let previous = ns.range(
            of: "\n",
            options: .backwards,
            range: NSRange(location: 0, length: caret)
        )
        return previous.location == NSNotFound ? 0 : previous.location + 1
    }

    private static func isFenceLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// 这一段之前有奇数个围栏行，说明光标在代码块内部。
    private static func isInsideFence(_ ns: NSString, before location: Int) -> Bool {
        var index = 0
        var fences = 0
        while index < location {
            var start = 0
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: index, length: 0)
            )
            let line = ns.substring(with: NSRange(location: start, length: contentsEnd - start))
            if isFenceLine(line.trimmingCharacters(in: .whitespaces)) { fences += 1 }
            if end <= index { break }
            index = end
        }
        return fences % 2 == 1
    }

    // MARK: - 前缀解析

    /// 一行（行首到光标）拆出来的东西：缩进、续行要接的整串、marker 之后的内容。
    private struct Prefix {
        var indent: String
        var continuation: String
        var content: String
    }

    /// 认引用与列表标记。`- 项` 的 marker 后空白原样保留，`1.` 的编号 +1。
    private static func parsePrefix(_ prefix: String) -> Prefix? {
        var rest = Substring(prefix)

        // 行首缩进
        var indent = ""
        while let character = rest.first, character == " " || character == "\t" {
            indent.append(character)
            rest = rest.dropFirst()
        }

        // 引用：`>` 可套多层，标记后最多吃一个空格
        var quote = ""
        while rest.first == ">" {
            quote.append(">")
            rest = rest.dropFirst()
            if rest.first == " " {
                quote.append(" ")
                rest = rest.dropFirst()
            }
        }

        // 引用与列表之间可能还有一段缩进
        var listIndent = ""
        while let character = rest.first, character == " " || character == "\t" {
            listIndent.append(character)
            rest = rest.dropFirst()
        }
        let leading = indent + listIndent
        let fullIndent = quote + leading

        // 无序列表 / 任务列表
        if let marker = rest.first, "-*+".contains(marker) {
            var body = String(marker)
            rest = rest.dropFirst()
            var gap = ""
            while let character = rest.first, character == " " || character == "\t" {
                gap.append(character)
                rest = rest.dropFirst()
            }
            guard !gap.isEmpty else { return nil }  // `-abc` 不是列表

            if rest.first == "[" {
                let afterOpen = rest.dropFirst()
                if let mark = afterOpen.first, mark == " " || mark == "x" || mark == "X",
                   let close = afterOpen.dropFirst().first, close == "]" {
                    let tail = afterOpen.dropFirst(2)
                    var taskGap = ""
                    var rest = tail
                    while let character = rest.first, character == " " || character == "\t" {
                        taskGap.append(character)
                        rest = rest.dropFirst()
                    }
                    if !taskGap.isEmpty || rest.isEmpty {
                        // 续行一律回到未勾选——新的一项还没做完
                        return Prefix(
                            indent: leading,
                            continuation: fullIndent + body + gap + "[ ] ",
                            content: String(rest)
                        )
                    }
                }
            }

            return Prefix(
                indent: leading,
                continuation: fullIndent + body + gap,
                content: String(rest)
            )
        }

        // 有序列表：编号 +1，`.` 与 `)` 各自保留
        var digits = ""
        while let character = rest.first, character.isNumber {
            digits.append(character)
            rest = rest.dropFirst()
        }
        if !digits.isEmpty, let separator = rest.first, separator == "." || separator == ")" {
            rest = rest.dropFirst()
            var gap = ""
            while let character = rest.first, character == " " || character == "\t" {
                gap.append(character)
                rest = rest.dropFirst()
            }
            guard !gap.isEmpty else { return nil }
            let next = (Int(digits) ?? 1) + 1
            return Prefix(
                indent: leading,
                continuation: fullIndent + "\(next)\(separator)" + gap,
                content: String(rest)
            )
        }

        // 纯引用
        if !quote.isEmpty {
            return Prefix(indent: indent, continuation: fullIndent, content: String(rest))
        }
        return nil
    }
}
