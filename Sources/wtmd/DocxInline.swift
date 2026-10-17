import Foundation

/// 一段内联文本的呈现属性（DOCX 的 run）。
struct DocxRun: Equatable {
    enum Content: Equatable {
        case text(String)
        case image(src: String, alt: String)
    }

    var content: Content
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var link: String?

    static func text(_ text: String) -> DocxRun {
        DocxRun(content: .text(text))
    }
}

/// Markdown 内联 → run 列表（导出 Word 用）。
///
/// **为什么自带一份内联解析**：`HTMLRenderer` 产出的是 HTML 字符串，
/// 再从 HTML 反解回 run 既脆弱（`<input>` 之类的非 XML 空元素）又慢；
/// 而库里的内联解析是 internal。这里刻意只实现导出需要的子集：
/// 行内代码、图片、链接、自动链接、粗体、斜体、删除线、反斜杠转义。
///
/// **明确不做**：`$…$` 数学（原样输出为文本）、`[^1]` 脚注（解析器把定义行
/// 收进了内部状态，导出侧拿不到），两者都保留为可读的原文。
enum DocxInline {
    private enum Kind {
        case code, image, link, autolink, boldStrong, boldUnderscore, italicStar, italicUnderscore, strike, bareURL
    }

    private struct Style {
        var bold = false
        var italic = false
        var strike = false
        var link: String?
    }

    private static let patterns: [(Kind, String)] = [
        (.code, "(?s)(`+)(.+?)\\1"),
        (.image, "!\\[([^\\]\\n]*)\\]\\(\\s*([^\\s)]+)(?:\\s+\"([^\"]*)\")?\\s*\\)"),
        (.link, "\\[([^\\]\\n]+)\\]\\(\\s*([^\\s)]+)(?:\\s+\"([^\"]*)\")?\\s*\\)"),
        (.autolink, "<((?:https?|mailto):[^>\\s]+)>"),
        (.boldStrong, "(?s)\\*\\*(.+?)\\*\\*"),
        (.boldUnderscore, "(?s)(?<![\\w_])__(.+?)__(?![\\w_])"),
        (.italicStar, "\\*(?=[^\\s*])([^*\\n]*[^\\s*])\\*"),
        (.italicUnderscore, "(?<![\\w_])_([^_\\n]+)_(?![\\w_])"),
        (.strike, "(?s)~~(.+?)~~"),
        (.bareURL, "(?<![\\w'\"=\\(/])(https?://[^\\s<>\\)\"']+)"),
    ]

    private struct Hit {
        var range: NSRange
        var kind: Kind
        var match: NSTextCheckingResult
    }

    static func runs(_ raw: String) -> [DocxRun] {
        var result: [DocxRun] = []
        scan(NSString(string: raw), style: Style(), into: &result)
        return result
    }

    // MARK: - 扫描

    private static func scan(_ text: NSString, style: Style, into runs: inout [DocxRun]) {
        var index = 0
        while index < text.length {
            guard let hit = earliestHit(in: text, from: index) else {
                append(text: text.substring(from: index), style: style, into: &runs)
                return
            }
            if hit.range.location > index {
                let plain = text.substring(with: NSRange(location: index, length: hit.range.location - index))
                append(text: plain, style: style, into: &runs)
            }
            runs.append(contentsOf: expand(hit, in: text, style: style))
            index = hit.range.location + hit.range.length
        }
    }

    /// 所有模式里最靠左的那个；同位置时按模式顺序取先者（行内代码优先）。
    /// 被反斜杠转义掉的标记（`\*不是斜体\*`）不参与匹配。
    private static func earliestHit(in text: NSString, from index: Int) -> Hit? {
        var best: Hit?
        let searchRange = NSRange(location: index, length: text.length - index)
        for (kind, pattern) in patterns {
            guard let regex = regex(pattern) else { continue }
            for match in regex.matches(in: text as String, range: searchRange) {
                if isEscaped(match.range.location, in: text) { continue }
                if let current = best, current.range.location <= match.range.location { break }
                best = Hit(range: match.range, kind: kind, match: match)
                break
            }
        }
        return best
    }

    /// 该位置前是否紧跟着奇数个反斜杠（即被转义）。
    private static func isEscaped(_ location: Int, in text: NSString) -> Bool {
        var count = 0
        var cursor = location - 1
        while cursor >= 0, text.character(at: cursor) == 0x5C {
            count += 1
            cursor -= 1
        }
        return count % 2 == 1
    }

    // MARK: - 展开

    private static func expand(_ hit: Hit, in text: NSString, style: Style) -> [DocxRun] {
        func group(_ i: Int) -> String {
            guard i < hit.match.numberOfRanges, hit.match.range(at: i).location != NSNotFound else { return "" }
            return text.substring(with: hit.match.range(at: i))
        }

        switch hit.kind {
        case .code:
            var code = group(2)
            if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" ") {
                code = String(code.dropFirst().dropLast())
            }
            // 行内代码屏蔽其它标记，但保留链接颜色（链接里的代码仍是链接）
            var run = DocxRun(content: .text(code), code: true)
            run.link = style.link
            return [run]

        case .image:
            return [DocxRun(content: .image(src: group(2), alt: group(1)))]

        case .link:
            var nestedStyle = style
            nestedStyle.link = group(2)
            var nested: [DocxRun] = []
            scan(NSString(string: group(1)), style: nestedStyle, into: &nested)
            return nested

        case .autolink, .bareURL:
            var run = DocxRun(content: .text(group(1)), link: group(1))
            run.bold = style.bold
            run.italic = style.italic
            return [run]

        case .boldStrong, .boldUnderscore:
            var nestedStyle = style
            nestedStyle.bold = true
            var nested: [DocxRun] = []
            scan(NSString(string: group(1)), style: nestedStyle, into: &nested)
            return nested

        case .italicStar, .italicUnderscore:
            var nestedStyle = style
            nestedStyle.italic = true
            var nested: [DocxRun] = []
            scan(NSString(string: group(1)), style: nestedStyle, into: &nested)
            return nested

        case .strike:
            var nestedStyle = style
            nestedStyle.strike = true
            var nested: [DocxRun] = []
            scan(NSString(string: group(1)), style: nestedStyle, into: &nested)
            return nested
        }
    }

    // MARK: - 文本收尾

    /// 反斜杠转义在拼接明文时还原；空串直接丢弃，避免产生空 run。
    private static func append(text: String, style: Style, into runs: inout [DocxRun]) {
        let unescaped = unescape(text)
        guard !unescaped.isEmpty else { return }
        var run = DocxRun.text(unescaped)
        run.bold = style.bold
        run.italic = style.italic
        run.strike = style.strike
        run.link = style.link
        runs.append(run)
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        guard let regex = regex("\\\\([\\\\`*_{}\\[\\]()#+\\-.!~>])") else { return text }
        let ns = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            ns.replaceCharacters(in: match.range, with: ns.substring(with: match.range(at: 1)))
        }
        return ns as String
    }

    // MARK: - 正则缓存

    private static let lock = NSLock()
    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = compiled
        return compiled
    }
}
