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
        Theme(id: defaultID, name: "wtmd 默认", author: "wtmd", isBuiltIn: true,
              light: defaultLight, dark: defaultDark),
        Theme(id: "builtin.paperInk", name: "纸墨", author: "wtmd", isBuiltIn: true,
              light: paperInkLight, dark: paperInkDark),
        Theme(id: "builtin.terminal", name: "终端", author: "wtmd", isBuiltIn: true,
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

// MARK: - 偏好设置面板

struct ThemeSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        Form {
            Picker("主题", selection: themeSelection) {
                ForEach(themeManager.themes) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }

            if !themeManager.currentTheme.isBuiltIn {
                LabeledContent("来源", value: "自定义")
            }
            LabeledContent("作者", value: themeManager.currentTheme.author.isEmpty ? "—" : themeManager.currentTheme.author)
            LabeledContent("外观", value: appearanceDescription)

            HStack {
                Button("打开主题文件夹…") { themeManager.openThemesFolder() }
                Spacer()
                Button("重新扫描") { themeManager.reload() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 240)
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
        case (true, true): return "浅色 / 深色（跟随系统）"
        case (true, false): return "仅浅色"
        case (false, true): return "常暗"
        case (false, false): return "—"
        }
    }
}
