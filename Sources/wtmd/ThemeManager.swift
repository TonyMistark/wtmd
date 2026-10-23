import AppKit
import Foundation
import SwiftUI

/// 一套主题：明/暗两份变量层文本（至少其一）。
struct Theme: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let author: String
    let isBuiltIn: Bool
    let light: String?
    let dark: String?

    /// 拼接为主题 CSS 文本；非法（两份皆空）时回落默认主题。
    var cssText: String {
        StyleSheet.cssText(light: light, dark: dark)
            ?? StyleSheet.cssText(light: Theme.defaultLight, dark: Theme.defaultDark)!
    }

    var hasLight: Bool { !(light?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    var hasDark: Bool { !(dark?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

// MARK: - .wttheme 格式加载（纯函数，可单测）

enum ThemeFormat {
    struct Metadata: Decodable {
        var name: String?
        var author: String?
        /// 自定义 CSS 文件名，默认 light.css / dark.css
        var light: String?
        var dark: String?
    }

    /// 从 `.wttheme` 文件夹加载主题：目录须含 theme.json + light.css / dark.css（至少其一）。
    /// 任何格式问题返回 nil（调用方跳过该目录，不崩溃）。
    static func loadFolder(_ url: URL) -> Theme? {
        let metaURL = url.appendingPathComponent("theme.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Metadata.self, from: data),
              let name = meta.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }

        func read(_ fileName: String?) -> String? {
            guard let fileName else { return nil }
            guard !fileName.contains("/") else { return nil } // 防路径逃逸
            return try? String(
                contentsOf: url.appendingPathComponent(fileName), encoding: .utf8
            )
        }

        let light = read(meta.light ?? "light.css")
        let dark = read(meta.dark ?? "dark.css")
        guard StyleSheet.cssText(light: light, dark: dark) != nil else { return nil }

        return Theme(
            id: "custom.\(url.lastPathComponent)",
            name: name,
            author: meta.author ?? "",
            isBuiltIn: false,
            light: light,
            dark: dark
        )
    }
}

// MARK: - 内置主题

extension Theme {
    static let defaultID = "builtin.default"

    /// 无衬线、跟随系统的现代样式（v0.1 默认外观原样迁移）。
    static let defaultLight = """
    --bg: #ffffff;
    --fg: #1f2328;
    --secondary: #59636e;
    --border: #d1d9e0;
    --accent: #0969da;
    --link: #0969da;
    --code-bg: #f0f2f5;
    --pre-bg: #f6f8fa;
    --pre-border: #e4e8ec;
    --th-bg: #f6f8fa;
    --quote-bar: #d1d9e0;
    --quote-fg: #59636e;
    --font-body: -apple-system, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    --font-heading: -apple-system, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    --font-mono: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
    """

    static let defaultDark = """
    --bg: #1e2126;
    --fg: #e2e6eb;
    --secondary: #9aa4af;
    --border: #3d444d;
    --accent: #6cb2ff;
    --link: #6cb2ff;
    --code-bg: #2b2f36;
    --pre-bg: #25282e;
    --pre-border: #33373d;
    --th-bg: #25282e;
    --quote-bar: #3d444d;
    --quote-fg: #9aa4af;
    --font-body: -apple-system, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    --font-heading: -apple-system, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    --font-mono: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
    """

    /// 纸墨：衬线、暖白、书卷气；夜间为深褐底米金字的夜读模式。
    static let paperInkLight = """
    --bg: #faf7f0;
    --fg: #2b2620;
    --secondary: #6b6357;
    --border: #ddd2bf;
    --accent: #a63f34;
    --link: #a63f34;
    --code-bg: #f0e9da;
    --pre-bg: #f5efe2;
    --pre-border: #e6dcc8;
    --th-bg: #f5efe2;
    --quote-bar: #c9bda3;
    --quote-fg: #6b6357;
    --font-body: "Songti SC", "Noto Serif SC", "Source Han Serif SC", Georgia, "Times New Roman", serif;
    --font-heading: "Songti SC", "Noto Serif SC", "Source Han Serif SC", Georgia, serif;
    --font-mono: "SF Mono", ui-monospace, Menlo, monospace;
    """

    static let paperInkDark = """
    --bg: #211c16;
    --fg: #e8ddc8;
    --secondary: #a89a80;
    --border: #4a4133;
    --accent: #cc6b5c;
    --link: #cc6b5c;
    --code-bg: #2e2820;
    --pre-bg: #2a2419;
    --pre-border: #3c3426;
    --th-bg: #2a2419;
    --quote-bar: #4a4133;
    --quote-fg: #a89a80;
    --font-body: "Songti SC", "Noto Serif SC", "Source Han Serif SC", Georgia, "Times New Roman", serif;
    --font-heading: "Songti SC", "Noto Serif SC", "Source Han Serif SC", Georgia, serif;
    --font-mono: "SF Mono", ui-monospace, Menlo, monospace;
    """

    /// 终端：等宽、高对比、常暗——像在深夜的 shell 里读文档。
    static let terminalDark = """
    --bg: #0d1117;
    --fg: #c9d1d9;
    --secondary: #8b949e;
    --border: #30363d;
    --accent: #58e6a9;
    --link: #79c0ff;
    --code-bg: #161b22;
    --pre-bg: #161b22;
    --pre-border: #30363d;
    --th-bg: #161b22;
    --quote-bar: #238636;
    --quote-fg: #8b949e;
    --font-body: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
    --font-heading: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
    --font-mono: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
    blockquote { border-left: 3px double var(--quote-bar); }
    """

    static let builtIns: [Theme] = [
        Theme(id: defaultID, name: t("wtmd Default"), author: "wtmd", isBuiltIn: true,
              light: defaultLight, dark: defaultDark),
        Theme(id: "builtin.paperInk", name: t("Paper & Ink"), author: "wtmd", isBuiltIn: true,
              light: paperInkLight, dark: paperInkDark),
        Theme(id: "builtin.terminal", name: t("Terminal"), author: "wtmd", isBuiltIn: true,
              light: nil, dark: terminalDark),
    ]
}

// MARK: - 主题管理器

@MainActor
final class ThemeManager: ObservableObject {
    @Published private(set) var themes: [Theme] = []
    @Published private(set) var currentThemeID: String {
        didSet { UserDefaults.standard.set(currentThemeID, forKey: Self.storageKey) }
    }

    private static let storageKey = "wtmd.themeID"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey)
        currentThemeID = Theme.defaultID
        themes = []
        themes = Theme.builtIns + Self.scanCustomThemes()
        if let saved, themes.contains(where: { $0.id == saved }) {
            currentThemeID = saved
        }
    }

    var currentTheme: Theme {
        themes.first { $0.id == currentThemeID } ?? Theme.builtIns[0]
    }

    var currentThemeCSS: String { currentTheme.cssText }

    func select(_ id: String) {
        guard themes.contains(where: { $0.id == id }) else { return }
        currentThemeID = id
    }

    /// 重新扫描自定义主题目录（拖入新 .wttheme 后调用）。
    func reload() {
        let selected = currentThemeID
        themes = Theme.builtIns + Self.scanCustomThemes()
        if themes.contains(where: { $0.id == selected }) {
            currentThemeID = selected
        } else {
            currentThemeID = Theme.defaultID
        }
    }

    static var themesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("wtmd/Themes", isDirectory: true)
    }

    /// 打开（必要时创建）主题目录，用户拖入 .wttheme 文件夹即安装。
    func openThemesFolder() {
        let dir = Self.themesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private static func scanCustomThemes() -> [Theme] {
        let dir = themesDirectory
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { ThemeFormat.loadFolder($0) }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - 编辑器取用

extension Theme {
    /// 解析某份变量层文本里的 `--x: value;` 行。主题文本除了变量还可能带
    /// 整条规则（如终端主题的 blockquote），这里只要变量。
    static func parseVariables(_ raw: String?) -> [String: String] {
        guard let raw else { return [:] }
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--") else { continue }
            let body = trimmed.dropFirst(2)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(body[body.index(after: colon)...])
            if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
            let value_ = value.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value_.isEmpty else { continue }
            result[key] = value_
        }
        return result
    }

    /// `#rgb` / `#rgba` / `#rrggbb` / `#rrggbbaa` → 颜色。认不出就给 nil，
    /// 调用方回落系统语义色——主题是数据，坏一个值不能弄瞎编辑器。
    static func color(hex: String) -> NSColor? {
        var body = hex.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("#") else { return nil }
        body.removeFirst()
        guard [3, 4, 6, 8].contains(body.count), let value = UInt64(body, radix: 16) else { return nil }

        func byte(_ shift: Int) -> CGFloat { CGFloat((value >> shift) & 0xFF) / 255.0 }
        /// `#rgb` 里的每一位顶四位用：`f` → 255。
        func nibble(_ digitIndex: Int) -> CGFloat {
            let digits = Array(body.reversed())
            guard let v = UInt64(String(digits[digitIndex]), radix: 16) else { return 0 }
            return CGFloat(v) / 15.0
        }
        switch body.count {
        case 3:
            return NSColor(srgbRed: nibble(2), green: nibble(1), blue: nibble(0), alpha: 1)
        case 4:
            return NSColor(srgbRed: nibble(3), green: nibble(2), blue: nibble(1), alpha: nibble(0))
        case 6:
            return NSColor(srgbRed: byte(16), green: byte(8), blue: byte(0), alpha: 1)
        default:
            return NSColor(srgbRed: byte(24), green: byte(16), blue: byte(8), alpha: byte(0))
        }
    }

    /// CSS 字体栈里的第一个真实字族名，跳过通用关键字（monospace 等）。
    static func firstFontFamily(inCSSStack stack: String) -> String? {
        let generic: Set<String> = [
            "ui-monospace", "monospace", "ui-serif", "serif", "sans-serif",
            "ui-rounded", "system-ui", "cursive", "fantasy",
        ]
        for part in stack.split(separator: ",") {
            var name = part.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("'") || name.hasPrefix("\"") {
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            guard !name.isEmpty else { continue }
            if generic.contains(name.lowercased()) { continue }
            return name
        }
        return nil
    }
}

/// 编辑器从主题里取的那一份：预览吃整份 CSS，编辑器（`NSTextView`）只能拿
/// 背景色、前景色和等宽字族。明暗两套都留着，由动态颜色供应商在绘制时
/// 按当时的 appearance 自己挑——系统切深浅色不用谁通知谁。
///
/// 只存原始数据（主题 id、字族、hex 字符串），颜色对象在应用那一刻才造：
/// 这个结构体在每次 SwiftUI 刷新时都会重新求值，拿 NSColor 做 Equatable
/// 的话动态供应商每次都是新实例，编辑器就会每敲一个键都重铺一遍高亮。
struct EditorThemeStyle: Equatable {
    var themeID: String
    var monoFontFamily: String?
    var lightBackground: String?
    var lightForeground: String?
    var darkBackground: String?
    var darkForeground: String?

    init?(theme: Theme) {
        let light = Theme.parseVariables(theme.light)
        let dark = Theme.parseVariables(theme.dark)
        // 连一份变量都没有的主题不参与（内置主题至少有其一）。
        guard !light.isEmpty || !dark.isEmpty else { return nil }

        // 一侧缺色时借用另一侧：只有暗色变体的主题（终端）在浅色 appearance
        // 下照样用它的深底，跟预览的行为一致。
        let bg = light["bg"] ?? dark["bg"]
        let fg = light["fg"] ?? dark["fg"]
        themeID = theme.id
        monoFontFamily = Theme.firstFontFamily(
            inCSSStack: light["font-mono"] ?? dark["font-mono"] ?? ""
        )
        lightBackground = bg
        lightForeground = fg
        darkBackground = dark["bg"] ?? light["bg"]
        darkForeground = dark["fg"] ?? light["fg"]
    }
}

// MARK: - 偏好设置面板

struct ThemeSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        Form {
            Picker(t("Theme"), selection: themeSelection) {
                ForEach(themeManager.themes) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }

            if !themeManager.currentTheme.isBuiltIn {
                LabeledContent(t("Source", context: "theme"), value: t("Custom"))
            }
            LabeledContent(t("Author"), value: themeManager.currentTheme.author.isEmpty ? "—" : themeManager.currentTheme.author)
            LabeledContent(t("Appearance"), value: appearanceDescription)

            HStack {
                Button(t("Open Themes Folder…")) { themeManager.openThemesFolder() }
                Spacer()
                Button(t("Rescan")) { themeManager.reload() }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var themeSelection: Binding<String> {
        Binding(
            get: { themeManager.currentThemeID },
            set: { themeManager.select($0) }
        )
    }

    private var appearanceDescription: String {
        let theme = themeManager.currentTheme
        switch (theme.hasLight, theme.hasDark) {
        case (true, true): return t("Light / Dark (follows system)")
        case (true, false): return t("Light only")
        case (false, true): return t("Dark")
        case (false, false): return "—"
        }
    }
}
