import AppKit
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
        case .file: return t("File")
        case .edit: return t("Edit")
        case .view: return t("View")
        case .writing: return t("Writing")
        case .theme: return t("Theme")
        case .app: return t("App")
        case .recent: return t("Recent Files")
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
    /// Reveal the current file in Finder.
    case showInFinder
    /// Copy the current file's full path to the clipboard.
    case copyFilePath
    /// Browse the versions kept for the current document.
    case showHistory
    /// Show the writing calendar: a year of daily net additions.
    case showCalendar
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
    /// Open the settings window on the page it was last on.
    case openSettings
    /// 系统标准「关于」面板：版本、图标、一行说明。
    case about
    /// Open a pre-filled GitHub issue with versions and system details.
    case reportProblem
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
        case .showInFinder: return "file.reveal"
        case .copyFilePath: return "file.copyPath"
        case .showHistory: return "file.history"
        case .showCalendar: return "view.calendar"
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
        case .openSettings: return "app.settings"
        case .about: return "app.about"
        case .reportProblem: return "app.reportProblem"
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
    /// Computed, not stored: titles follow the system language, and a stored
    /// array would freeze whichever language ran first.
    static var staticCommands: [AppCommand] = [
        AppCommand(
            kind: .newDocument, title: t("New Document"), section: .file,
            symbol: "square.and.pencil", shortcut: KeyboardShortcut("n", modifiers: .command),
            // 新建 = 另起一扇窗：搜「window」「窗口」也该找到它。
            keywords: ["new", "create", "blank", "window", "新窗口"], subtitle: nil
        ),
        AppCommand(
            kind: .openDocument, title: t("Open…"), section: .file,
            symbol: "folder", shortcut: KeyboardShortcut("o", modifiers: .command),
            keywords: ["open", "file", "document"], subtitle: nil
        ),
        AppCommand(
            kind: .openFolder, title: t("Open Folder…"), section: .file,
            symbol: "folder.badge.plus", shortcut: KeyboardShortcut("o", modifiers: [.command, .shift]),
            keywords: ["open", "folder", "workspace", "directory"], subtitle: nil
        ),
        AppCommand(
            kind: .save, title: t("Save"), section: .file,
            symbol: "square.and.arrow.down", shortcut: KeyboardShortcut("s", modifiers: .command),
            keywords: ["save", "write"], subtitle: nil
        ),
        AppCommand(
            kind: .showInFinder, title: t("Reveal in Finder"), section: .file,
            symbol: "folder", shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]),
            keywords: ["finder", "reveal", "folder", "location", "show", "访达", "文件夹", "位置", "所在位置"],
            subtitle: nil
        ),
        AppCommand(
            kind: .copyFilePath, title: t("Copy File Path"), section: .file,
            symbol: "link", shortcut: nil,
            keywords: ["copy", "path", "location", "clipboard", "复制", "路径", "地址", "剪贴板"],
            subtitle: nil
        ),
        AppCommand(
            kind: .showHistory, title: t("Version History…"), section: .file,
            symbol: "clock.arrow.circlepath", shortcut: KeyboardShortcut("y", modifiers: .command),
            keywords: ["history", "versions", "revisions", "restore", "版本", "历史", "旧版"],
            subtitle: nil
        ),
        AppCommand(
            kind: .exportHTML, title: t("Export HTML…"), section: .file,
            symbol: "square.and.arrow.up", shortcut: KeyboardShortcut("e", modifiers: [.command, .shift]),
            keywords: ["export", "html", "share"], subtitle: nil
        ),
        AppCommand(
            kind: .exportWord, title: t("Export Word…"), section: .file,
            symbol: "doc.richtext", shortcut: nil,
            keywords: ["word", "docx", "office", "export"], subtitle: nil
        ),
        AppCommand(
            kind: .exportPDF, title: t("Print / Save as PDF…"), section: .file,
            symbol: "printer", shortcut: KeyboardShortcut("p", modifiers: .command),
            keywords: ["print", "pdf", "export"], subtitle: nil
        ),
        AppCommand(
            kind: .find, title: t("Find…"), section: .edit,
            symbol: "magnifyingglass", shortcut: KeyboardShortcut("f", modifiers: .command),
            keywords: ["find", "search", "lookup", "查找", "搜索"], subtitle: nil
        ),
        AppCommand(
            // ⌥⌘F 是专注模式，别抢；R 记「Replace」。
            kind: .findReplace, title: t("Find & Replace…"), section: .edit,
            symbol: "arrow.2.squarepath",
            shortcut: KeyboardShortcut("r", modifiers: [.command, .option]),
            keywords: ["replace", "find", "search", "替换"], subtitle: nil
        ),
        AppCommand(
            kind: .searchWorkspace, title: t("Search Workspace…"), section: .edit,
            symbol: "text.magnifyingglass",
            shortcut: KeyboardShortcut("f", modifiers: [.command, .shift]),
            keywords: ["search", "workspace", "folder", "grep", "全局搜索", "搜索文件夹"],
            subtitle: nil
        ),
        AppCommand(
            kind: .toggleMode, title: t("Source ⇄ Preview"), section: .view,
            symbol: "arrow.left.arrow.right", shortcut: KeyboardShortcut("/", modifiers: .command),
            keywords: ["mode", "preview", "source", "edit", "toggle"], subtitle: nil
        ),
        AppCommand(
            kind: .toggleSplit, title: t("Split (Source ｜ Preview)"), section: .view,
            symbol: "rectangle.split.2x1",
            shortcut: KeyboardShortcut("\\", modifiers: [.command, .shift]),
            keywords: ["split", "compare", "side", "columns", "对照", "分栏"], subtitle: nil
        ),
        AppCommand(
            kind: .toggleSidebar, title: t("Sidebar"), section: .view,
            symbol: "sidebar.left", shortcut: nil,
            keywords: ["sidebar", "outline", "panel"], subtitle: nil
        ),
        AppCommand(
            // ⌘⇧Y 挨着版本历史的 ⌘Y：一个是「这篇的过去」，一个是「这一年写过的」。
            kind: .showCalendar, title: t("Writing Calendar…"), section: .view,
            symbol: "calendar", shortcut: KeyboardShortcut("y", modifiers: [.command, .shift]),
            keywords: ["calendar", "stats", "streak", "daily", "history", "日历", "统计", "连续"],
            subtitle: nil
        ),
        AppCommand(
            kind: .closeWorkspace, title: t("Close Workspace"), section: .view,
            symbol: "xmark.circle", shortcut: nil,
            keywords: ["close", "workspace", "folder"], subtitle: nil
        ),
        AppCommand(
            kind: .toggleTypewriter, title: t("Typewriter Mode"), section: .writing,
            symbol: "align.vertical.center", shortcut: KeyboardShortcut("t", modifiers: [.command, .option]),
            keywords: ["typewriter", "center", "centre", "writing"], subtitle: nil
        ),
        AppCommand(
            kind: .toggleFocus, title: t("Focus Mode"), section: .writing,
            symbol: "scope", shortcut: KeyboardShortcut("f", modifiers: [.command, .option]),
            keywords: ["focus", "dim", "paragraph", "writing"], subtitle: nil
        ),
        AppCommand(
            kind: .openThemesFolder, title: t("Open Themes Folder…"), section: .theme,
            symbol: "folder", shortcut: nil,
            keywords: ["theme", "folder", "install"], subtitle: nil
        ),
        AppCommand(
            kind: .rescanThemes, title: t("Rescan Themes"), section: .theme,
            symbol: "arrow.clockwise", shortcut: nil,
            keywords: ["theme", "rescan", "reload", "refresh"], subtitle: nil
        ),
        AppCommand(
            // 关于本来只在 App 菜单里（系统默认项）。登记进来，⌘K 与功能中心
            // 就都能到——同一个面板不该有三套说法。
            kind: .about, title: t("About wtmd"), section: .app,
            symbol: "info.circle", shortcut: nil,
            keywords: ["about", "version", "credits", "关于", "版本", "说明"],
            subtitle: nil
        ),
        AppCommand(
            // 设置窗口本来只有 ⌘, 这一条路，且藏在 App 菜单里。登记进来，
            // ⌘K 与功能中心就都能直达——同一个动作不该有三套说法。
            kind: .openSettings, title: t("Settings…"), section: .app,
            symbol: "gearshape", shortcut: KeyboardShortcut(",", modifiers: .command),
            keywords: ["settings", "preferences", "options", "配置", "设置", "偏好"],
            subtitle: nil
        ),
        AppCommand(
            kind: .checkForUpdates, title: t("Check for Updates…"), section: .app,
            symbol: "arrow.triangle.2.circlepath", shortcut: nil,
            keywords: ["update", "upgrade", "version", "release", "github"], subtitle: nil
        ),
        AppCommand(
            kind: .reportProblem, title: t("Report a Problem…"), section: .app,
            symbol: "exclamationmark.bubble", shortcut: nil,
            keywords: [
                "report", "problem", "bug", "crash", "issue", "feedback",
                "反馈", "问题", "崩溃", "报告", "报错",
            ],
            subtitle: nil
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
    /// 开新窗口的通道。`nil`（测试、离线视图）时「新建」退回本窗口。
    var windows: WindowCoordinator? = nil

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
        case .showHistory:
            // 没有名字的草稿没有历史（它没有稳定身份）；有名字就让它可点——
            // 面板自己会说「还没有留下旧版」，比灰着一个不说原因的菜单好。
            return store.fileURL != nil
        case .showInFinder, .copyFilePath:
            // 草稿还没有落在磁盘上，无处可寻、无路可抄。
            return store.fileURL != nil
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
        case .newDocument: newDocument()
        case .openDocument: store.openPanel()
        case .openFolder: workspace.openPanel()
        case .save: store.save()
        case .showInFinder: revealInFinder()
        case .copyFilePath: copyFilePath()
        case .showHistory: store.showHistory()
        case .showCalendar: CalendarWindow.show(store: store, goal: writing.dailyGoal)
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
        case .openSettings: SettingsWindow.open()
        case .about: AboutPanel.show()
        case .reportProblem: store.reportProblem()
        case .openRecent(let url): store.open(url: url)
        }
    }

    /// 在 Finder 里亮出这篇文件：不打开文件夹自己——选中它。
    private func revealInFinder() {
        guard let url = store.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 把完整路径放进剪贴板。状态栏悬停看得到 `~/…` 缩写，复制出去的
    /// 必须是机器认的全路径——终端、脚本都吃这个。
    private func copyFilePath() {
        guard let url = store.fileURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    /// 新建 = 另起一桌。
    ///
    /// ⌘N 以前会把手上这篇换掉：写第二篇时，第一篇就从窗口里消失了。多窗口之后
    /// 「新建」应当是**再开一扇窗**，手上这篇留在原地——这才对得起「一篇稿子一扇窗」。
    /// 没有窗口通道时（测试、无人值守的视图）仍退回本窗口新建。
    ///
    /// 新窗口接着用当前窗口的文件夹：同一间书房，另一张桌子。文件由读者自己
    /// 起名保存，侧栏那颗「新建」按钮照旧在原地建文件。
    private func newDocument() {
        if let windows, windows.openNewWindow(inheriting: workspace.root) != nil {
            return
        }
        store.newDocument()
    }
}

// MARK: - 谁能被改派

extension CommandCatalog {
    /// 允许改派快捷键的命令 = **有菜单项承载**的那批。
    ///
    /// AppKit 的快捷键只由菜单项的 key equivalent 派发：没有菜单项的命令，在设置里
    /// 派了也是哑键（⌃L 侧栏就是这样按下去没反应的）。所以「能改派」这件事得由
    /// 菜单结构说话，不能由目录说话——目录里的命令有一半是给 ⌘K 用的。
    static var menuCarriedKinds: Set<CommandKind> {
        Set(staticCommands.map(\.kind)).subtracting(systemOwnedKinds)
    }

    /// 菜单项由系统摆的命令：键位不归我们，改了也不会生效，所以不列进改派表。
    ///
    /// 目前只有「设置…」：App 菜单里那一项由 SwiftUI 的 `Settings` 场景自己插，
    /// ⌘, 归它。`replace(replacing: .appSettings)` 试过——系统那一项照样在，
    /// 结果是两条「设置…」并排。
    static let systemOwnedKinds: Set<CommandKind> = [.openSettings]
}
