import Foundation

/// 工作区根目录下的 `.wtmdignore`：一行一条，写清楚哪些文件不该被翻。
///
/// 为什么要有它：搜索是逐文件读盘的，一个 `assets/` 或 `导出/` 目录里躺着
/// 几百个没人会当稿子看的 Markdown 时，每敲一个字就读一遍它们——慢，而且
/// 结果会被淹没。规则跟着工作区走，不跟着应用走：同一个应用打开两份书稿，
/// 各自的忽略清单本来就该不同。
///
/// 语法只取够用的那一小撮：`#` 注释、`*`、`?`、`**`、结尾 `/` 表示目录。
/// 不实现 `!` 反选——没有它的时候，规则是「加起来」的；有了它，就得解释
/// 先后顺序，而没人会去读那份说明。
struct WorkspaceIgnore: Equatable {
    /// 原始规则，按文件里的顺序。空行与注释已经滤掉。
    let patterns: [String]

    static let empty = WorkspaceIgnore(patterns: [])
    static let fileName = ".wtmdignore"

    var isEmpty: Bool { patterns.isEmpty }

    // MARK: - 读

    /// 从工作区根目录读一次。没有这个文件就是「什么都不忽略」。
    static func load(root: URL?) -> WorkspaceIgnore {
        guard let root else { return .empty }
        let url = root.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return parse(text)
    }

    static func parse(_ text: String) -> WorkspaceIgnore {
        let lines = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            // 行尾注释也算注释：规则里不会有人真想匹配 ` # 说明`。
            if let hash = trimmed.range(of: " #") {
                trimmed = String(trimmed[trimmed.startIndex..<hash.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return trimmed
        }
        return WorkspaceIgnore(patterns: lines)
    }

    // MARK: - 匹配

    /// `relativePath` 是相对工作区根的路径，用 `/` 分隔。
    func matches(relativePath path: String, isDirectory: Bool = false) -> Bool {
        guard !patterns.isEmpty else { return false }
        // 目录规则（结尾带 `/`）只对目录生效；文件规则对两者都试——
        // 一条 `草稿` 既可能指文件，也可能指整个文件夹。
        return patterns.contains { pattern in
            let directoryOnly = pattern.hasSuffix("/")
            if directoryOnly && !isDirectory { return false }
            let cleaned = directoryOnly ? String(pattern.dropLast()) : pattern
            return Glob.matches(cleaned, path: path)
        }
    }

    /// 这条路径或它的任一上层目录被忽略了吗？
    func excludes(relativePath path: String, isDirectory: Bool = false) -> Bool {
        if matches(relativePath: path, isDirectory: isDirectory) { return true }
        guard !isDirectory else { return false }
        var components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return false }
        components.removeLast()
        var prefix = ""
        for component in components {
            prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
            if matches(relativePath: prefix, isDirectory: true) { return true }
        }
        return false
    }
}

// MARK: - glob

/// 够用的 glob：`**` 跨目录，`*` 不跨，`?` 一个字符。
enum Glob {
    static func matches(_ pattern: String, path: String) -> Bool {
        // 不含斜杠的规则匹配任意层级：写 `draft` 就该盖住 `书稿/draft`。
        guard let expression = regex(for: pattern) else { return false }
        if !pattern.contains("/") {
            let name = (path as NSString).lastPathComponent
            return expression.matches(name) || expression.matches(path)
        }
        return expression.matches(path)
    }

    static func regex(for pattern: String) -> NSRegularExpression? {
        var source = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            switch character {
            case "*":
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let after = pattern.index(after: next)
                    // `**/` 允许零层：`导出/**/*.md` 也得匹配 `导出/清单.md`。
                    if after < pattern.endIndex, pattern[after] == "/" {
                        source += "(?:.*/)?"
                        index = pattern.index(after: after)
                        continue
                    }
                    source += ".*"
                    index = after
                    continue
                }
                source += "[^/]*"
            case "?":
                source += "[^/]"
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
                source += "\\\(character)"
            default:
                source += String(character)
            }
            index = pattern.index(after: index)
        }
        source += "$"
        // 模式来自用户输入，转义已经做过；失败时退化成「不匹配」而不是崩。
        return try? NSRegularExpression(pattern: source)
    }
}

private extension NSRegularExpression {
    /// 整个字符串是否被这条正则吃下。
    func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return firstMatch(in: text, range: range) != nil
    }
}
