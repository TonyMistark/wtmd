import Foundation
import SwiftUI

// MARK: - Section

/// Where a command lives. The palette groups its results by section; menus use
/// the same value to decide which submenu a command belongs to.
enum CommandSection: String, CaseIterable, Identifiable {
    case file
    case edit
    case view
    case writing
    case theme
    case app
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: return "文件"
        case .edit: return "编辑"
        case .view: return "视图"
        case .writing: return "写作"
        case .theme: return "主题"
        case .app: return "应用"
        case .recent: return "最近文件"
        }
    }
}

// MARK: - Kind

/// The identity of a command: pure data, no closure, therefore comparable and
/// testable. Execution and state live in `CommandRuntime`, which switches on
/// this value — keeping a command's *definition* separate from its *effects*.
enum CommandKind: Hashable {
    /// Create a blank document.
    case newDocument
    /// Show the open-document panel.
    case openDocument
    /// Show the open-folder panel and adopt it as the workspace.
    case openFolder
    /// Save (or save-as for an untitled document).
    case save
    /// Export the preview as a standalone HTML file.
    case exportHTML
    /// Export as Word (.docx).
    case exportWord
    /// Print / save as PDF.
    case exportPDF
    /// Find inside the current document.
    case find
    /// Find and replace inside the current document.
    case findReplace
    /// Full-text search across the whole folder workspace.
    case searchWorkspace
    /// Flip between source and preview.
    case toggleMode
    /// Source and preview side by side.
    case toggleSplit
    /// Show or hide the sidebar.
    case toggleSidebar
    /// Close the current workspace, back to single-document mode.
    case closeWorkspace
    /// Typewriter mode: keep the caret line vertically centred.
    case toggleTypewriter
    /// Focus mode: dim everything but the current paragraph.
    case toggleFocus
    /// Switch the rendering theme.
    case selectTheme(String)
    /// Reveal the themes folder in Finder.
    case openThemesFolder
    /// Rescan themes from disk.
    case rescanThemes
    /// Ask GitHub for the latest release, ignoring the daily throttle.
    case checkForUpdates
    /// Open a file from the recent list.
    case openRecent(URL)

    /// Stable identifier: used by the palette's `Identifiable`, the menus'
    /// `ForEach`, and the tests. Never localise this.
    var id: String {
        switch self {
        case .newDocument: return "file.new"
        case .openDocument: return "file.open"
        case .openFolder: return "file.openFolder"
        case .save: return "file.save"
        case .exportHTML: return "file.exportHTML"
        case .exportWord: return "file.exportWord"
        case .exportPDF: return "file.exportPDF"
        case .find: return "edit.find"
        case .findReplace: return "edit.replace"
        case .searchWorkspace: return "edit.searchWorkspace"
        case .toggleMode: return "view.toggleMode"
        case .toggleSplit: return "view.toggleSplit"
        case .toggleSidebar: return "view.toggleSidebar"
        case .closeWorkspace: return "workspace.close"
        case .toggleTypewriter: return "writing.typewriter"
        case .toggleFocus: return "writing.focus"
        case .selectTheme(let id): return "theme.select.\(id)"
        case .openThemesFolder: return "theme.openFolder"
        case .rescanThemes: return "theme.rescan"
        case .checkForUpdates: return "app.checkForUpdates"
        case .openRecent(let url): return "recent.\(url.absoluteString)"
        }
    }
}

// MARK: - Command

/// The metadata of a command — the single definition shared by the menus and
/// the palette, so a title or shortcut is only ever written once.
struct AppCommand: Identifiable {
    let kind: CommandKind
    let title: String
    let section: CommandSection
    let symbol: String
    let shortcut: KeyboardShortcut?
    /// Extra search terms (English aliases) so "typewriter" also finds 打字机模式.
    let keywords: [String]
    /// Grey text on the right of a result row — recent files show their folder.
    let subtitle: String?

    var id: String { kind.id }

    /// 换一条快捷键、其余原样（用户改派时的包装）。
    func withShortcut(_ newShortcut: KeyboardShortcut?) -> AppCommand {
        AppCommand(
            kind: kind, title: title, section: section, symbol: symbol,
            shortcut: newShortcut, keywords: keywords, subtitle: subtitle
        )
    }
}

// MARK: - Catalog

/// The command list. Titles, shortcuts and search terms are defined here once;
/// the menus and the palette both read from it.
enum CommandCatalog {
    /// Commands that do not depend on the theme list or the recent files.
    ///
    /// Order matters: it is the order the palette shows for an empty query, and
    /// the tie-breaker when two commands score the same.
    static let staticCommands: [AppCommand] = [
        AppCommand(
            kind: .newDocument, title: "新建文档", section: .file,
            symbol: "square.and.pencil", shortcut: KeyboardShortcut("n", modifiers: .command),
            keywords: ["new", "create", "blank"], subtitle: nil
        ),
        AppCommand(
            kind: .openDocument, title: "打开…", section: .file,
            symbol: "folder", shortcut: KeyboardShortcut("o", modifiers: .command),
            keywords: ["open", "file", "document"], subtitle: nil
        ),
        AppCommand(
            kind: .openFolder, title: "打开文件夹…", section: .file,
            symbol: "folder.badge.plus", shortcut: KeyboardShortcut("o", modifiers: [.command, .shift]),
            keywords: ["open", "folder", "workspace", "directory"], subtitle: nil
        ),
        AppCommand(
            kind: .save, title: "保存", section: .file,
            symbol: "square.and.arrow.down", shortcut: KeyboardShortcut("s", modifiers: .command),
            keywords: ["save", "write"], subtitle: nil
        ),
        AppCommand(
            kind: .exportHTML, title: "导出 HTML…", section: .file,
            symbol: "square.and.arrow.up", shortcut: KeyboardShortcut("e", modifiers: [.command, .shift]),
            keywords: ["export", "html", "share"], subtitle: nil
        ),
        AppCommand(
            kind: .exportWord, title: "导出 Word…", section: .file,
            symbol: "doc.richtext", shortcut: nil,
            keywords: ["word", "docx", "office", "export"], subtitle: nil
        ),
        AppCommand(
            kind: .exportPDF, title: "打印 / 存为 PDF…", section: .file,
            symbol: "printer", shortcut: KeyboardShortcut("p", modifiers: .command),
            keywords: ["print", "pdf", "export"], subtitle: nil
        ),
        AppCommand(
            kind: .find, title: "查找…", section: .edit,
            symbol: "magnifyingglass", shortcut: KeyboardShortcut("f", modifiers: .command),
            keywords: ["find", "search", "lookup", "查找", "搜索"], subtitle: nil
        ),
        AppCommand(
            // ⌥⌘F 是专注模式，别抢；R 记「Replace」。
            kind: .findReplace, title: "查找与替换…", section: .edit,
            symbol: "arrow.2.squarepath",
            shortcut: KeyboardShortcut("r", modifiers: [.command, .option]),
            keywords: ["replace", "find", "search", "替换"], subtitle: nil
        ),
        AppCommand(
            kind: .searchWorkspace, title: "在工作区中搜索…", section: .edit,
            symbol: "text.magnifyingglass",
            shortcut: KeyboardShortcut("f", modifiers: [.command, .shift]),
            keywords: ["search", "workspace", "folder", "grep", "全局搜索", "搜索文件夹"],
            subtitle: nil
        ),
        AppCommand(
            kind: .toggleMode, title: "思绪 ⇄ 成文", section: .view,
            symbol: "arrow.left.arrow.right", shortcut: KeyboardShortcut("/", modifiers: .command),
            keywords: ["mode", "preview", "source", "edit", "toggle"], subtitle: nil
        ),
        AppCommand(
            kind: .toggleSplit, title: "对照（源码 ｜ 成文）", section: .view,
            symbol: "rectangle.split.2x1",
            shortcut: KeyboardShortcut("\\", modifiers: [.command, .shift]),
            keywords: ["split", "compare", "side", "columns", "对照", "分栏"], subtitle: nil
        ),
        AppCommand(
            kind: .toggleSidebar, title: "侧栏", section: .view,
            symbol: "sidebar.left", shortcut: nil,
            keywords: ["sidebar", "outline", "panel"], subtitle: nil
        ),
        AppCommand(
            kind: .closeWorkspace, title: "关闭工作区", section: .view,
            symbol: "xmark.circle", shortcut: nil,
            keywords: ["close", "workspace", "folder"], subtitle: nil
        ),
        AppCommand(
            kind: .toggleTypewriter, title: "打字机模式", section: .writing,
            symbol: "align.vertical.center", shortcut: KeyboardShortcut("t", modifiers: [.command, .option]),
            keywords: ["typewriter", "center", "centre", "writing"], subtitle: nil
        ),
        AppCommand(
            kind: .toggleFocus, title: "专注模式", section: .writing,
            symbol: "scope", shortcut: KeyboardShortcut("f", modifiers: [.command, .option]),
            keywords: ["focus", "dim", "paragraph", "writing"], subtitle: nil
        ),
        AppCommand(
            kind: .openThemesFolder, title: "打开主题文件夹…", section: .theme,
            symbol: "folder", shortcut: nil,
            keywords: ["theme", "folder", "install"], subtitle: nil
        ),
        AppCommand(
            kind: .rescanThemes, title: "重新扫描主题", section: .theme,
            symbol: "arrow.clockwise", shortcut: nil,
            keywords: ["theme", "rescan", "reload", "refresh"], subtitle: nil
        ),
        AppCommand(
            kind: .checkForUpdates, title: "检查更新…", section: .app,
            symbol: "arrow.triangle.2.circlepath", shortcut: nil,
            keywords: ["update", "upgrade", "version", "release", "github"], subtitle: nil
        ),
    ]

    /// One command per theme, so the palette can switch themes without leaving
    /// the keyboard.
    static func themeCommands(for themes: [Theme]) -> [AppCommand] {
        themes.map { theme in
            AppCommand(
                kind: .selectTheme(theme.id), title: theme.name, section: .theme,
                symbol: "paintpalette", shortcut: nil,
                keywords: ["theme", "appearance", theme.id], subtitle: nil
            )
        }
    }

    /// One command per recent file, subtitled with its folder.
    static func recentCommands(for urls: [URL]) -> [AppCommand] {
        urls.map { url in
            AppCommand(
                kind: .openRecent(url),
                title: url.deletingPathExtension().lastPathComponent,
                section: .recent,
                symbol: "doc.text",
                shortcut: nil,
                keywords: [url.lastPathComponent, url.deletingLastPathComponent().lastPathComponent],
                subtitle: abbreviatedFolder(of: url)
            )
        }
    }

    /// Everything the palette can run. Sections appear in the order they are
    /// concatenated here — which is also the empty-query display order.
    ///
    /// `overrides` carries the user's re-assignments (`ShortcutOverrides`);
    /// an entry for a command's id replaces the factory shortcut.
    static func commands(
        themes: [Theme],
        recentFiles: [URL],
        overrides: [String: RecordedShortcut] = [:]
    ) -> [AppCommand] {
        (staticCommands + themeCommands(for: themes) + recentCommands(for: recentFiles))
            .map { $0.applying(overrides: overrides) }
    }

    /// Look a command up by kind. The menus declare their *structure* (slots,
    /// order, dividers) but take every title and shortcut from here.
    ///
    /// Returns nil only if a kind was never registered — a programming error we
    /// would rather skip silently than crash on.
    ///
    /// Looks in `staticCommands` first so the common case allocates nothing:
    /// this runs from the app's `body`, which is re-evaluated on every
    /// keystroke.
    static func command(
        for kind: CommandKind,
        themes: [Theme] = [],
        overrides: [String: RecordedShortcut] = [:]
    ) -> AppCommand? {
        let found: AppCommand?
        if let hit = staticCommands.first(where: { $0.kind == kind }) {
            found = hit
        } else {
            found = themeCommands(for: themes).first { $0.kind == kind }
        }
        return found?.applying(overrides: overrides)
    }

    private static func abbreviatedFolder(of url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

private extension AppCommand {
    /// 把用户的改派套到一条出厂命令上。
    func applying(overrides: [String: RecordedShortcut]) -> AppCommand {
        guard let recorded = overrides[kind.id], let shortcut = recorded.keyboardShortcut,
              shortcut != self.shortcut
        else { return self }
        return withShortcut(shortcut)
    }
}

// MARK: - Runtime

/// State and execution for commands — the single entry point shared by the
/// menus and the palette.
///
/// Kept apart from `CommandCatalog` so definitions stay pure data (testable)
/// while every side effect is funnelled through one place.
@MainActor
struct CommandRuntime {
    let store: DocumentStore
    let workspace: WorkspaceStore
    let writing: WritingSettings
    let updates: UpdateChecker

    private var themeManager: ThemeManager { store.themeManager }

    /// Current state of a switch-like command, or nil when it is a plain action.
    /// The menus use this to decide between `Toggle` and `Button`.
    func isOn(_ command: AppCommand) -> Bool? {
        switch command.kind {
        case .toggleTypewriter: return writing.typewriter
        case .toggleFocus: return writing.focusMode
        case .toggleSidebar: return store.sidebarVisible
        case .toggleSplit: return store.mode == .split
        case .selectTheme(let id): return themeManager.currentThemeID == id
        default: return nil
        }
    }

    func isEnabled(_ command: AppCommand) -> Bool {
        switch command.kind {
        case .save:
            // Nothing to save on the welcome screen. Otherwise an untitled
            // document can still be saved (via save-as) — only a clean, named
            // document greys out.
            return !store.showsWelcome && (store.isDirty || store.fileURL == nil)
        case .closeWorkspace:
            return workspace.isOpen
        case .checkForUpdates:
            return !updates.isChecking
        case .find, .findReplace:
            // 欢迎页没有文本可找
            return !store.showsWelcome
        case .openRecent(let url):
            // A recent file may have been moved away. Greying it out beats
            // doing nothing when clicked.
            return FileManager.default.fileExists(atPath: url.path)
        default:
            return true
        }
    }

    func run(_ command: AppCommand) {
        switch command.kind {
        case .newDocument: store.newDocument()
        case .openDocument: store.openPanel()
        case .openFolder: workspace.openPanel()
        case .save: store.save()
        case .exportHTML: store.exportHTML()
        case .exportWord: store.exportWord()
        case .exportPDF: store.exportPDF()
        case .find: store.showFind(replacing: false)
        case .findReplace: store.showFind(replacing: true)
        case .searchWorkspace: store.workspaceSearch.present(root: workspace.root)
        case .toggleMode: store.toggleMode()
        case .toggleSplit: store.toggleSplit()
        case .toggleSidebar: store.sidebarVisible.toggle()
        case .closeWorkspace: workspace.close()
        case .toggleTypewriter: writing.typewriter.toggle()
        case .toggleFocus: writing.focusMode.toggle()
        case .selectTheme(let id): themeManager.select(id)
        case .openThemesFolder: themeManager.openThemesFolder()
        case .rescanThemes: themeManager.reload()
        case .checkForUpdates: Task { await updates.check(force: true) }
        case .openRecent(let url): store.open(url: url)
        }
    }
}
