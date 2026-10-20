import AppKit
import Foundation
import SwiftUI

// MARK: - 设置标签页

/// 设置窗口的五页。功能中心要能直达其中一页，所以这一层得有个名字。
///
/// 存的是 `rawValue`：设置窗口和功能中心共用一个 `@AppStorage` 键，谁改都算数。
/// 一页一件事——原来「写作 / 版式 / 打印」三块挤在主题页下半截，点完落在
/// 最上面，看起来就像没反应。
enum SettingsTab: String, CaseIterable, Identifiable {
    case theme
    case writing
    case layout
    case printing
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .theme: return t("Theme", "主题")
        case .writing: return t("Writing", "写作")
        case .layout: return t("Layout", "版式")
        case .printing: return t("Printing", "打印")
        case .shortcuts: return t("Shortcuts", "快捷键")
        }
    }

    var symbol: String {
        switch self {
        case .theme: return "paintpalette"
        case .writing: return "character.cursor.ibeam"
        case .layout: return "text.alignleft"
        case .printing: return "printer"
        case .shortcuts: return "keyboard"
        }
    }

    /// `UserDefaults` 里的键名。默认页是「主题」——第一次打开设置时人找的多半是外观。
    static let storageKey = "wtmd.settings.tab"
}

/// 打开设置窗口，必要时先把它翻到某一页。
///
/// SwiftUI 没有「打开设置并选中第 N 个标签页」的公开 API：`SettingsLink` 只会打开
/// 窗口。能直达的路径只有一条——先把选择写进 `@AppStorage`，再打开窗口。
///
/// 打开的那一下得靠视图环境里的 `openSettings`：AppKit 的
/// `showSettingsWindow:` 在 SwiftUI 生命周期下并不可靠（命令发出去没人接，
/// 点了就是没反应）。可命令层与面板都拿不到环境值，所以由根视图出现时把
/// 动作挂在这里，三处共用同一个入口。
@MainActor
enum SettingsWindow {
    /// 由根视图注入。`nil` 时回退到 AppKit 的动作，给没有窗口的环境用。
    private static var opener: (() -> Void)?

    static func install(_ opener: (() -> Void)?) {
        self.opener = opener
    }

    /// 打开上次停留的那一页。
    static func open() {
        guard let raw = UserDefaults.standard.string(forKey: SettingsTab.storageKey),
              let tab = SettingsTab(rawValue: raw)
        else {
            open(.theme)
            return
        }
        open(tab)
    }

    static func open(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey)
        if let opener {
            opener()
        } else if let app = NSApp {
            // macOS 13 起是 showSettingsWindow:，之前叫 showPreferencesWindow:。
            // 两条都试：点了没反应比多试一次难查得多。
            if !app.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                app.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
        // 测试进程里没有 NSApp（`NSApp` 是隐式解包的可选）——这里不是错，
        // 只是没窗口可激活。
        NSApp?.activate(ignoringOtherApps: true)
    }
}

// MARK: - 一行

/// 功能中心的一行：纯数据，标题与图标都从 `CommandCatalog` 拷过来，
/// 所以这里的文案不可能和菜单、⌘K 说岔。
struct ControlCenterRow: Identifiable {
    enum Action: Hashable {
        /// 走 `CommandRuntime`——与菜单、⌘K 同一条路。
        case command(CommandKind)
        /// 主题：就地展开一个子菜单，换完还留在面板里。
        case themes
        /// 打开设置窗口的某一页。
        case settings(SettingsTab)
        /// 在访达里打开崩溃报告文件夹。
        case crashFolder
    }

    let action: Action
    /// 稳定标识里动作之外的那一段。三个入口都通往设置的主题页，但它们是
    /// 三件不同的事——`ForEach` 得把它们当三个人看，否则列表会错位。
    var key: String? = nil
    let title: String
    /// 右侧的灰字：今日净增、版本数、当前主题……面板的价值一半在这里。
    let subtitle: String?
    let symbol: String
    let shortcut: KeyboardShortcut?
    let isEnabled: Bool

    var id: String {
        let base: String
        switch action {
        case .command(let kind): base = "cmd:" + kind.id
        case .themes: base = "themes"
        case .settings(let tab): base = "settings:" + tab.rawValue
        case .crashFolder: base = "crashFolder"
        }
        return key.map { base + "#" + $0 } ?? base
    }
}

struct ControlCenterSection: Identifiable {
    let title: String
    let rows: [ControlCenterRow]

    var id: String { title }
}

// MARK: - 状态

/// 面板要显示的状态。视图负责把值取出来，`ControlCenterCatalog` 负责把它们
/// 变成句子——于是「显示什么」可以断言，「怎么摆」才留给视图。
struct ControlCenterContext {
    var hasDocument = false
    /// nil：这台机器还没有账本（或今天一个字没动）。
    var todayNet: Int? = nil
    var goal = 0
    var historyCount = 0
    var themeName = ""
    var measure = 0
    var fontSize = 0
    var marginMM: Double = 0
    var pageNumbers = false
    var update: UpdateStatus = .idle
    var hasCrashReports = false
    var reassignedShortcuts = 0
}

// MARK: - 目录

/// 面板的分组与行。纯函数：给定状态与命令表，输出固定的结构。
enum ControlCenterCatalog {
    static func sections(_ context: ControlCenterContext, commands: [AppCommand]) -> [ControlCenterSection] {
        [writing(context, commands), appearance(context, commands), app(context, commands)]
    }

    // MARK: 写作

    private static func writing(
        _ context: ControlCenterContext, _ commands: [AppCommand]
    ) -> ControlCenterSection {
        let historyOn = context.hasDocument
        return ControlCenterSection(
            title: t("Writing", "写作"),
            rows: [
                command(
                    .showCalendar, in: commands,
                    subtitle: calendarSubtitle(todayNet: context.todayNet, goal: context.goal)
                ),
                command(
                    .showHistory, in: commands,
                    subtitle: historySubtitle(count: context.historyCount), isEnabled: historyOn
                ),
                settings(
                    .writing, key: "goal", title: t("Daily Goal…", "每日目标…"),
                    symbol: "target", subtitle: goalSubtitle(context.goal)
                ),
            ]
        )
    }

    // MARK: 外观

    private static func appearance(
        _ context: ControlCenterContext, _ commands: [AppCommand]
    ) -> ControlCenterSection {
        ControlCenterSection(
            title: t("Appearance", "外观"),
            rows: [
                ControlCenterRow(
                    action: .themes, title: t("Theme", "主题"),
                    subtitle: context.themeName.isEmpty ? nil : context.themeName,
                    symbol: "paintpalette", shortcut: nil, isEnabled: true
                ),
                settings(
                    .layout, key: "layout", title: t("Reading Layout…", "阅读版式…"),
                    symbol: "text.alignleft",
                    subtitle: layoutSubtitle(measure: context.measure, fontSize: context.fontSize)
                ),
                settings(
                    .printing, key: "printing", title: t("Printing…", "打印设置…"),
                    symbol: "printer",
                    subtitle: printingSubtitle(
                        marginMM: context.marginMM, pageNumbers: context.pageNumbers
                    )
                ),
            ]
        )
    }

    // MARK: 应用与帮助

    private static func app(
        _ context: ControlCenterContext, _ commands: [AppCommand]
    ) -> ControlCenterSection {
        let checking = context.update == .checking
        return ControlCenterSection(
            title: t("App & Help", "应用与帮助"),
            rows: [
                command(.about, in: commands, subtitle: nil),
                command(.openSettings, in: commands, subtitle: nil),
                settings(
                    .shortcuts, key: "shortcuts", title: t("Keyboard Shortcuts…", "快捷键…"),
                    symbol: "keyboard", subtitle: shortcutSubtitle(context.reassignedShortcuts)
                ),
                command(
                    .checkForUpdates, in: commands,
                    subtitle: updateSubtitle(context.update), isEnabled: !checking
                ),
                command(.reportProblem, in: commands, subtitle: nil),
                ControlCenterRow(
                    action: .crashFolder, title: t("Crash Reports Folder", "崩溃报告文件夹"),
                    subtitle: context.hasCrashReports
                        ? t("Reports are kept here", "有报告留在里面")
                        : t("Nothing so far", "还没有报告"),
                    symbol: "waveform.path.ecg", shortcut: nil, isEnabled: true
                ),
            ]
        )
    }

    // MARK: 行的取法

    private static func command(
        _ kind: CommandKind, in commands: [AppCommand],
        subtitle: String?, isEnabled: Bool = true
    ) -> ControlCenterRow {
        guard let command = commands.first(where: { $0.kind == kind }) else {
            // 命令表里没有这一条：宁可留个空标题也不要崩——面板不该因为
            // 漏登记一条命令就整块开不出来。测试会守住「每个 kind 都登记过」。
            return ControlCenterRow(
                action: .command(kind), title: kind.id, subtitle: subtitle,
                symbol: "questionmark.circle", shortcut: nil, isEnabled: false
            )
        }
        return ControlCenterRow(
            action: .command(kind), title: command.title, subtitle: subtitle,
            symbol: command.symbol, shortcut: command.shortcut, isEnabled: isEnabled
        )
    }

    private static func settings(
        _ tab: SettingsTab, key: String, title: String, symbol: String, subtitle: String?
    ) -> ControlCenterRow {
        ControlCenterRow(
            action: .settings(tab), key: key, title: title, subtitle: subtitle,
            symbol: symbol, shortcut: nil, isEnabled: true
        )
    }

    // MARK: 副标题

    /// 「今天写了多少」——这是面板里最该被一眼看到的一行。
    static func calendarSubtitle(todayNet: Int?, goal: Int) -> String {
        let net = todayNet ?? 0
        let amount = WritingCalendarText.signed(net)
        if net == 0 {
            return goal > 0
                ? t("nothing yet · goal \(WritingCalendarText.grouped(goal))", "今天还没写 · 目标 \(WritingCalendarText.grouped(goal))")
                : t("nothing yet", "今天还没写")
        }
        return goal > 0
            ? t("\(amount) · goal \(WritingCalendarText.grouped(goal))", "今日 \(amount) · 目标 \(WritingCalendarText.grouped(goal))")
            : t("\(amount) today", "今日 \(amount)")
    }

    static func historySubtitle(count: Int) -> String {
        count == 0
            ? t("No earlier versions", "还没有旧版")
            : t("\(count) versions", "\(count) 个版本")
    }

    static func goalSubtitle(_ goal: Int) -> String {
        goal > 0
            ? t("\(WritingCalendarText.grouped(goal)) characters a day", "每天 \(WritingCalendarText.grouped(goal)) 字")
            : t("Not set", "未设置")
    }

    static func layoutSubtitle(measure: Int, fontSize: Int) -> String {
        t("measure \(measure) · \(fontSize) px", "版心 \(measure) · \(fontSize) px")
    }

    static func printingSubtitle(marginMM: Double, pageNumbers: Bool) -> String {
        let margin = String(format: "%.0f", marginMM)
        let numbers = pageNumbers ? t("page numbers on", "页码开") : t("page numbers off", "页码关")
        return t("margin \(margin) mm · \(numbers)", "页边距 \(margin) mm · \(numbers)")
    }

    static func shortcutSubtitle(_ count: Int) -> String {
        count > 0
            ? t("\(count) reassigned", "\(count) 处改派")
            : t("Factory defaults", "出厂设置")
    }

    static func updateSubtitle(_ status: UpdateStatus) -> String? {
        switch status {
        case .idle: return nil
        case .checking: return t("Checking…", "正在检查…")
        case .upToDate(let version): return t("v\(version) is up to date", "v\(version) 已是最新")
        case .available(let version, _): return t("v\(version) available", "v\(version) 可用")
        case .failed: return t("Last check failed", "上次检查失败")
        }
    }
}
