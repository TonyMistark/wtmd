import AppKit
import Foundation
import SwiftUI

// MARK: - 编辑器的数据模型

/// 主题里人可以直接调的那些变量。其余（`pre-border`、`th-bg`）是派生的：
/// 让用户同时去调「边框」和「代码块边框」只会调出不一致。
enum ThemePalette {
    /// 主色组：默认展开，直接决定观感。
    static let primary = [
        "bg", "fg", "secondary", "border", "accent",
        "link", "code-bg", "pre-bg", "quote-bar", "quote-fg",
    ]
    /// 高亮组：初值来自基底，收在折叠区里——不写代码的人一辈子不用碰。
    static let highlights = [
        "hl-keyword", "hl-string", "hl-number",
        "hl-comment", "hl-type", "hl-meta",
    ]
    static let all = primary + highlights
}

/// 一份正在编辑的主题。值类型：单测直接构造，不用起界面。
struct ThemeDraft: Equatable {
    var name: String
    var author: String
    /// 正在编辑的既有主题 id（nil = 新建）——保存时决定覆盖哪个文件夹。
    var editingID: String?
    var light: Appearance
    var dark: Appearance

    struct Appearance: Equatable {
        var colors: [String: String]
        var fonts: Fonts
    }

    struct Fonts: Equatable {
        /// 完整 CSS 字体栈。编辑器只给第一个字族，栈尾的回落由我们补。
        var body: String
        var heading: String
        var mono: String
    }

    // MARK: 从主题载入

    /// 以某套主题为初值起一份草稿。缺的变量按默认主题补齐——基底可以是
    /// 一个只带单侧的 base16 主题，草稿仍然要是完整可保存的一份。
    init(basedOn theme: Theme?, name: String? = nil, editing: Bool = false) {
        let source = theme ?? Theme.builtIns[0]
        let lightVars = Theme.parseVariables(source.light)
        let darkVars = Theme.parseVariables(source.dark)
        // 单侧主题（终端、base16）在另一侧没有变量：两侧都用它，与预览的行为一致。
        let baseVars = lightVars.isEmpty ? darkVars : lightVars

        self.name = name ?? (editing ? source.name : t("My Theme"))
        self.author = editing ? source.author : ""
        self.editingID = editing && !source.isBuiltIn ? source.id : nil
        self.light = Self.appearance(from: lightVars.isEmpty ? baseVars : lightVars)
        self.dark = Self.appearance(from: darkVars.isEmpty ? baseVars : darkVars)
    }

    static func appearance(from vars: [String: String]) -> Appearance {
        Appearance(colors: colors(from: vars), fonts: SourceFonts(vars: vars).fonts)
    }

    /// 直接给值的构造（测试用）。
    init(
        name: String,
        author: String = "",
        editingID: String? = nil,
        light: Appearance,
        dark: Appearance
    ) {
        self.name = name
        self.author = author
        self.editingID = editingID
        self.light = light
        self.dark = dark
    }

    /// 变量表 → 编辑器要管的那些键，缺的用默认主题同名字段补。
    static func colors(from vars: [String: String]) -> [String: String] {
        let defaults = Theme.parseVariables(
            vars["bg"].map(Theme.isDarkColor) == true ? Theme.defaultDark : Theme.defaultLight
        )
        var result: [String: String] = [:]
        for key in ThemePalette.all {
            result[key] = normalizedHex(vars[key]) ?? normalizedHex(defaults[key]) ?? "#000000"
        }
        return result
    }

    // MARK: 导出

    /// 一侧的变量层文本。变量顺序固定，方便比对与 diff。
    func css(for appearance: Appearance) -> String {
        var lines: [String] = []
        for key in ThemePalette.primary {
            guard let value = Self.normalizedHex(appearance.colors[key]) else { continue }
            lines.append("--\(key): \(value);")
            // 派生项紧跟源项：代码块边框跟边框走，表头底跟代码块底走。
            if key == "border" { lines.append("--pre-border: \(value);") }
            if key == "pre-bg" { lines.append("--th-bg: \(value);") }
        }
        for key in ThemePalette.highlights {
            guard let value = Self.normalizedHex(appearance.colors[key]) else { continue }
            lines.append("--\(key): \(value);")
        }
        lines.append("--font-body: \(Self.fontStack(appearance.fonts.body));")
        lines.append("--font-heading: \(Self.fontStack(appearance.fonts.heading));")
        lines.append("--font-mono: \(Self.fontStack(appearance.fonts.mono));")
        return lines.joined(separator: "\n")
    }

    /// hex 归一化为小写 `#rrggbb`；认不出返回 nil（坏值宁可不出现在文件里）。
    static func normalizedHex(_ raw: String?) -> String? {
        guard var body = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            return nil
        }
        if body.hasPrefix("#") { body.removeFirst() }
        guard [3, 4, 6, 8].contains(body.count), body.allSatisfy(\.isHexDigit) else { return nil }
        // 三位/四位简写展开成六位/八位，写进文件里更明确。
        if body.count <= 4 {
            body = body.map { "\($0)\($0)" }.joined()
        }
        return "#" + body.lowercased()
    }

    /// 编辑器只调「第一个字族」，后面的回落由程序补：换台机器没装这个字体
    /// 也不至于退到 Times。
    static func fontStack(_ family: String) -> String {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.defaultBodyStack }
        if trimmed == trimmed.lowercased(), trimmed.contains(",") { return trimmed } // 已是完整栈
        let escaped = trimmed.contains(" ") ? "\"\(trimmed)\"" : trimmed
        return "\(escaped), \(Self.defaultBodyStack)"
    }

    static let defaultBodyStack =
        "-apple-system, \"SF Pro Text\", \"PingFang SC\", \"Hiragino Sans GB\", \"Microsoft YaHei\", sans-serif"
    static let defaultMonoStack = "\"SF Mono\", ui-monospace, Menlo, Consolas, monospace"

    // MARK: 校验

    /// WCAG 相对亮度与对比度。低对比只警告不阻止——有人就爱浅灰字。
    static func contrastRatio(foreground: String, background: String) -> Double? {
        guard let fg = luminance(foreground), let bg = luminance(background) else { return nil }
        let lighter = max(fg, bg)
        let darker = min(fg, bg)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ hex: String) -> Double? {
        guard let color = Theme.color(hex: hex)?.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    /// 低于这个值就提一句：正文可能看不清。
    static let contrastWarningThreshold = 3.0
}

/// 从一份变量表里取出三个字体栈（只留第一个字族名）。
private struct SourceFonts {
    var fonts: ThemeDraft.Fonts

    init(vars: [String: String]) {
        func family(_ stack: String?, fallback: String) -> String {
            guard let stack, let name = Theme.firstFontFamily(inCSSStack: stack) else { return fallback }
            return name
        }
        fonts = ThemeDraft.Fonts(
            body: family(vars["font-body"], fallback: ""),
            heading: family(vars["font-heading"], fallback: ""),
            mono: family(vars["font-mono"], fallback: "")
        )
    }
}

extension Theme {
    /// 这个颜色是不是偏暗（用来判断单侧主题该喂给哪一侧的默认值）。
    static func isDarkColor(_ hex: String) -> Bool {
        guard let color = Theme.color(hex: hex)?.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * Double(color.redComponent)
            + 0.7152 * Double(color.greenComponent)
            + 0.0722 * Double(color.blueComponent) < 0.5
    }
}

// MARK: - 写盘

enum ThemeSaveError: LocalizedError, Equatable {
    case emptyName
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return t("Give the theme a name first.")
        case .alreadyExists(let name): return t("A theme named “{}” already exists.", name)
        }
    }
}

enum ThemeStore {
    /// 文件夹名：只留 ASCII 字母数字，其余折成连字符。中文名会整段被折掉，
    /// 于是退回时间戳——display name 存在 theme.json 里，文件夹名只是 id。
    static func slug(for name: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            let isASCIIAlnum = (scalar.value < 128)
                && (CharacterSet.alphanumerics.contains(scalar))
            if isASCIIAlnum {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if out.isEmpty {
            out = "theme-\(Int(Date().timeIntervalSince1970))"
        }
        return out
    }

    static func folderName(for draft: ThemeDraft) -> String {
        // 编辑既有主题时沿用原文件夹名，改名字不至于变成另一套主题。
        if let editingID = draft.editingID, editingID.hasPrefix("custom.") {
            return String(editingID.dropFirst("custom.".count))
        }
        return slug(for: draft.name) + ".wttheme"
    }

    /// 写出一套 `.wttheme`。`overwrite == false` 且目标已存在时抛
    /// `.alreadyExists`，由界面问「覆盖还是另存」。
    @discardableResult
    static func write(
        _ draft: ThemeDraft,
        to directory: URL,
        overwrite: Bool
    ) throws -> URL {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ThemeSaveError.emptyName }

        let folder = directory.appendingPathComponent(folderName(for: draft), isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path), !overwrite {
            throw ThemeSaveError.alreadyExists(name)
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta: [String: String] = [
            "name": name,
            "author": draft.author.trimmingCharacters(in: .whitespacesAndNewlines),
            "light": "light.css",
            "dark": "dark.css",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: folder.appendingPathComponent("theme.json"))
        try draft.css(for: draft.light).write(
            to: folder.appendingPathComponent("light.css"), atomically: true, encoding: .utf8
        )
        try draft.css(for: draft.dark).write(
            to: folder.appendingPathComponent("dark.css"), atomically: true, encoding: .utf8
        )
        return folder
    }

    /// 同名副本的落点：`name 2`、`name 3`……
    static func copyName(_ name: String, in directory: URL) -> String {
        var index = 2
        while true {
            let candidate = "\(name) \(index)"
            let folder = directory.appendingPathComponent(slug(for: candidate) + ".wttheme")
            if !FileManager.default.fileExists(atPath: folder.path) { return candidate }
            index += 1
        }
    }
}
