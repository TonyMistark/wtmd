import Foundation

/// 文本统计：中英混合口径。
/// - 字数：CJK 字符逐字计 + 西文单词逐词计
/// - 词数：西文单词数（不含 CJK）
/// - 阅读时长：中文 300 字/分钟 + 英文 200 词/分钟
public struct TextStatistics: Equatable, Sendable {
    public let characters: Int
    public let words: Int
    public let readingMinutes: Int

    public init(characters: Int, words: Int, readingMinutes: Int) {
        self.characters = characters
        self.words = words
        self.readingMinutes = readingMinutes
    }

    /// 从纯文本统计。Markdown 标记本身不计入（标题符、强调符、链接 URL 等）。
    public static func count(_ markdown: String) -> TextStatistics {
        let plain = stripMarkdown(markdown)

        var cjk = 0
        var latinWords = 0

        var inWord = false
        for scalar in plain.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
                inWord = false
            } else if scalar.properties.isAlphabetic || scalar == "'" {
                if !inWord {
                    latinWords += 1
                    inWord = true
                }
            } else {
                inWord = false
            }
        }

        // 阅读时长：不足一分钟按一分钟；无实际内容为 0
        let total = cjk + latinWords
        let minutes = total == 0
            ? 0
            : max(Int((Double(cjk) / 300.0 + Double(latinWords) / 200.0).rounded(.up)), 1)
        return TextStatistics(
            characters: total,
            words: latinWords,
            readingMinutes: minutes
        )
    }

    /// 去除 Markdown 标记，保留阅读文本。
    static func stripMarkdown(_ source: String) -> String {
        var lines: [String] = []
        var inFence = false

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue } // 代码块不计入阅读统计
            if isFootnoteDef(trimmed) { continue } // 脚注定义不重复计
            lines.append(line)
        }

        var text = lines.joined(separator: " ")

        // 图片 → 替换为 alt 文本
        text = replace(text, "!\\[([^\\]]*)\\]\\([^)]*\\)", "$1")
        // 链接 → 保留链接文字
        text = replace(text, "\\[([^\\]]*)\\]\\([^)]*\\)", "$1")
        // 行内代码 → 内容保留
        // 标题/强调/删除线标记符
        for marker in ["#", "**", "__", "~~", "*", "_", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        // 列表标记与引用符
        text = replace(text, "(^|\\s)[>+\\-]+\\s", "$1")

        return text
    }

    private static func isFootnoteDef(_ line: String) -> Bool {
        guard line.hasPrefix("[^") else { return false }
        return line.contains("]:")
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template
        )
    }

    /// CJK 判定：汉字 + 假名 + 谚文（全角标点不计字数）。
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK 统一汉字
             0x3400...0x4DBF,   // 扩展 A
             0x3040...0x30FF,   // 平假名 + 片假名
             0xAC00...0xD7AF:   // 谚文音节
            return true
        default:
            return false
        }
    }
}
