import Foundation
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 功能中心

/// 面板本身只是一堆按钮，真正会错的是两件事：**它会说什么**（行尾的
/// 状态文案）和**它指向哪里**（每一行是不是真的有一条命令接得住）。
/// 这两处都是纯函数，单独守。
@Suite("功能中心")
struct ControlCenterTests {
    private var commands: [AppCommand] { CommandCatalog.staticCommands }

    private func rows(_ context: ControlCenterContext = ControlCenterContext()) -> [ControlCenterRow] {
        ControlCenterCatalog.sections(context, commands: commands).flatMap(\.rows)
    }

    private func row(_ kind: CommandKind, _ context: ControlCenterContext = ControlCenterContext()) -> ControlCenterRow? {
        rows(context).first { $0.action == .command(kind) }
    }

    // MARK: 结构

    @Test("三组：写作、外观、应用与帮助")
    func sectionsAreThree() {
        let sections = ControlCenterCatalog.sections(ControlCenterContext(), commands: commands)
        #expect(sections.map(\.title) == ["写作", "外观", "应用与帮助"])
    }

    @Test("写作组先说话：日历在最前，历史第二，目标第三")
    func writingSectionOrder() {
        let writing = ControlCenterCatalog.sections(ControlCenterContext(), commands: commands)[0]
        #expect(writing.rows.map(\.action) == [
            .command(.showCalendar),
            .command(.showHistory),
            .settings(.theme),
        ])
    }

    @Test("每行的 id 唯一——ForEach 靠它认人")
    func rowIdentifiersAreUnique() {
        let identifiers = rows().map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("命令行的标题、图标、快捷键都从命令表来，不另写一份")
    func commandRowsBorrowFromTheCatalog() {
        let calendar = row(.showCalendar)
        #expect(calendar?.title == "写作日历…")
        #expect(calendar?.symbol == "calendar")
        #expect(calendar?.shortcut.map(ShortcutFormatter.label) == "⇧⌘Y")

        let history = row(.showHistory)
        #expect(history?.title == "版本历史…")
        #expect(history?.shortcut.map(ShortcutFormatter.label) == "⌘Y")
    }

    @Test("引用的每一条命令都真的登记过——没有一条落到兜底的问号")
    func everyCommandRowResolves() {
        for row in rows() {
            guard case .command(let kind) = row.action else { continue }
            #expect(
                CommandCatalog.command(for: kind) != nil,
                "命令表里没有 \(kind.id)"
            )
            #expect(row.symbol != "questionmark.circle", "\(kind.id) 落到了兜底图标")
            #expect(row.title != kind.id, "\(kind.id) 只有 id，没有标题")
        }
    }

    @Test("设置…进了命令表：⌘K 也能搜到它")
    func settingsIsACommand() {
        let command = CommandCatalog.command(for: .openSettings)
        #expect(command?.title == "设置…")
        #expect(command?.shortcut.map(ShortcutFormatter.label) == "⌘,")
        #expect(command?.section == .app)
    }

    @Test("设置的两页名字写死在 rawValue 里——改了会让老用户的选择丢掉")
    func settingsTabRawValuesAreStable() {
        #expect(SettingsTab.theme.rawValue == "theme")
        #expect(SettingsTab.shortcuts.rawValue == "shortcuts")
        #expect(SettingsTab.storageKey == "wtmd.settings.tab")
    }

    // MARK: 可用性

    @Test("没有文档时版本历史灰着，其余照旧")
    func historyIsDisabledWithoutADocument() {
        var context = ControlCenterContext()
        context.hasDocument = false
        #expect(row(.showHistory, context)?.isEnabled == false)
        #expect(row(.showCalendar, context)?.isEnabled == true)

        context.hasDocument = true
        #expect(row(.showHistory, context)?.isEnabled == true)
    }

    @Test("正在检查更新时那一行点不动——免得叠着发两次请求")
    func updateRowIsDisabledWhileChecking() {
        var context = ControlCenterContext()
        context.update = .checking
        #expect(row(.checkForUpdates, context)?.isEnabled == false)

        context.update = .upToDate(version: "0.14.1")
        #expect(row(.checkForUpdates, context)?.isEnabled == true)
    }

    // MARK: 副标题

    @Test("日历行：今日净增 + 目标，千分位自己数")
    func calendarSubtitleShowsTodayAndGoal() {
        #expect(ControlCenterCatalog.calendarSubtitle(todayNet: 320, goal: 1000) == "今日 +320 · 目标 1,000")
        #expect(ControlCenterCatalog.calendarSubtitle(todayNet: 1240, goal: 0) == "今日 +1,240")
        // 删字的日子：负数用真减号，不是连字符
        #expect(ControlCenterCatalog.calendarSubtitle(todayNet: -12, goal: 1000) == "今日 −12 · 目标 1,000")
    }

    @Test("日历行：今天没写就说没写，别显示一个「+0」")
    func calendarSubtitleSaysNothingYet() {
        #expect(ControlCenterCatalog.calendarSubtitle(todayNet: 0, goal: 1000) == "今天还没写 · 目标 1,000")
        #expect(ControlCenterCatalog.calendarSubtitle(todayNet: nil, goal: 0) == "今天还没写")
        #expect(ControlCenterCatalog.calendarSubtitle(todayNet: 0, goal: 0) == "今天还没写")
    }

    @Test("历史行：有版本就报个数，没有就说没有")
    func historySubtitleCountsVersions() {
        #expect(ControlCenterCatalog.historySubtitle(count: 0) == "还没有旧版")
        #expect(ControlCenterCatalog.historySubtitle(count: 12) == "12 个版本")
    }

    @Test("目标行：未设置时说未设置")
    func goalSubtitle() {
        #expect(ControlCenterCatalog.goalSubtitle(0) == "未设置")
        #expect(ControlCenterCatalog.goalSubtitle(1000) == "每天 1,000 字")
    }

    @Test("版式与打印：显示会被带进设置页的那两个值")
    func appearanceSubtitles() {
        #expect(ControlCenterCatalog.layoutSubtitle(measure: 680, fontSize: 17) == "版心 680 · 17 px")
        #expect(
            ControlCenterCatalog.printingSubtitle(marginMM: 18, pageNumbers: true)
                == "页边距 18 mm · 页码开"
        )
        #expect(
            ControlCenterCatalog.printingSubtitle(marginMM: 12.5, pageNumbers: false)
                == "页边距 12 mm · 页码关"
        )
    }

    @Test("快捷键行：改过几处就说几处")
    func shortcutSubtitle() {
        #expect(ControlCenterCatalog.shortcutSubtitle(0) == "出厂设置")
        #expect(ControlCenterCatalog.shortcutSubtitle(3) == "3 处改派")
    }

    @Test("更新行：四种状态四句话，闲时什么都不说")
    func updateSubtitle() {
        #expect(ControlCenterCatalog.updateSubtitle(.idle) == nil)
        #expect(ControlCenterCatalog.updateSubtitle(.checking) == "正在检查…")
        #expect(ControlCenterCatalog.updateSubtitle(.upToDate(version: "0.14.1")) == "v0.14.1 已是最新")
        #expect(
            ControlCenterCatalog.updateSubtitle(
                .available(version: "0.15.0", releaseURL: URL(string: "https://example.com")!)
            ) == "v0.15.0 可用"
        )
        #expect(ControlCenterCatalog.updateSubtitle(.failed) == "上次检查失败")
    }

    // MARK: 主题行

    @Test("主题行不是命令：它展开一个子菜单，换完还留在面板里")
    func themeRowOpensAMenu() {
        let themes = rows().first { $0.action == .themes }
        #expect(themes != nil)
        #expect(themes?.symbol == "paintpalette")

        var context = ControlCenterContext()
        context.themeName = "素纸"
        let titled = rows(context).first { $0.action == .themes }
        #expect(titled?.subtitle == "素纸")
    }

    @Test("没有主题名时行尾留白，不写一对空引号")
    func themeSubtitleIsNilWhenUnknown() {
        #expect(rows().first { $0.action == .themes }?.subtitle == nil)
    }

    // MARK: 兜底

    @Test("命令表少了某一条时留一个灰行，而不是让整块面板开不出来")
    func missingCommandFallsBackToADisabledRow() {
        let sections = ControlCenterCatalog.sections(ControlCenterContext(), commands: [])
        let all = sections.flatMap(\.rows)
        let calendar = all.first { $0.action == .command(.showCalendar) }
        #expect(calendar != nil)
        #expect(calendar?.isEnabled == false)
        #expect(calendar?.symbol == "questionmark.circle")
        // 副标题照旧给——至少还能看出这一行原本要说什么
        #expect(calendar?.subtitle != nil)
    }
}

// MARK: - 装配

/// 面板渲染得再对，工具栏上没有那颗按钮也是白搭。源码装配断言守的是
/// 「我们真的这么摆」——这份副本被谁顺手删了也没人喊。
@Suite("功能中心装配")
struct ControlCenterAssemblyTests {
    @Test func theToolbarCarriesTheControlCenterButton() throws {
        let source = try String(contentsOf: Self.contentViewURL, encoding: .utf8)
        let toolbar = try #require(Self.body(of: "toolbarContent", in: source))

        #expect(toolbar.contains("controlCenterVisible.toggle()"), "工具栏上没有功能中心按钮")
        #expect(toolbar.contains("ControlRowTip") == false)

        // 主题菜单收进面板之后，工具栏不再有自己的主题入口——两处入口
        // 迟早说岔（一个当场换，一个面板里换，改的却是同一份偏好）。
        #expect(!toolbar.contains("paintpalette"), "工具栏里还留着主题菜单")
    }

    @Test func thePanelFloatsOverTheDetailArea() throws {
        let source = try String(contentsOf: Self.contentViewURL, encoding: .utf8)
        let layer = try #require(Self.body(of: "controlCenterLayer", in: source))
        #expect(layer.contains("ControlCenterPanel"))

        let body = try #require(Self.body(of: "body", in: source))
        #expect(body.contains("controlCenterVisible") || source.contains("controlCenterLayer"))
    }

    @Test func theWindowInjectsPrintingSettingsForThePanel() throws {
        let source = try String(contentsOf: Self.windowRootURL, encoding: .utf8)
        #expect(source.contains("environmentObject(model.shared.printing)"))
    }

    @Test func theSettingsSheetRemembersItsTab() throws {
        let source = try String(contentsOf: Self.appURL, encoding: .utf8)
        #expect(source.contains("TabView(selection: $tab)"))
        #expect(source.contains(".tag(SettingsTab.theme.rawValue)"))
        #expect(source.contains(".tag(SettingsTab.shortcuts.rawValue)"))
    }

    // MARK: 辅助

    static let contentViewURL = sourceURL("ContentView.swift")
    static let windowRootURL = sourceURL("WindowRoot.swift")
    static let appURL = sourceURL("wtmdApp.swift")

    private static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // wtmdTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/wtmd/\(name)")
    }

    /// 花括号配平，取出某个声明（`private var toolbarContent`、`var body`…）的函数体。
    static func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: "var \(declaration): ") else { return nil }
        var depth = 0
        var index = start.upperBound
        var body = ""
        while index < source.endIndex {
            let character = source[index]
            body.append(character)
            if character == "{" {
                depth += 1
            } else if character == "}" {
                if depth == 0 { return body }
                depth -= 1
            }
            index = source.index(after: index)
        }
        return nil
    }
}
