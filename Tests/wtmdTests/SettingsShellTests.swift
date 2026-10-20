import Foundation
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 设置目录

/// 设置窗口左侧那一列是纯数据：分类、顺序、每页的标题与图标。真正会错的
/// 是**顺序**（改成什么样都要可预期）、**重复**（一页出现两次）和
/// **rawValue**（改了老读者的选择就丢）。
@Suite("设置目录")
struct SettingsCatalogTests {
    /// 侧栏里出现的页：分类里除账户区之外的所有页，按 `allCases` 的顺序。
    private var listedTabs: [SettingsTab] {
        SettingsGroup.allCases.filter { $0 != .profile }.flatMap(\.tabs)
    }

    @Test("左侧四类：个人、写作、外观、应用与帮助")
    func groupsInOrder() {
        #expect(SettingsGroup.allCases.map(\.title) == ["个人", "写作", "外观", "应用与帮助"])
        #expect(SettingsGroup.allCases.map(\.rawValue) == ["profile", "writing", "appearance", "app"])
    }

    @Test("列表里的页：写作、主题、版式、打印、快捷键、应用——各出现一次")
    func listedTabsInOrder() {
        #expect(listedTabs == [.writing, .theme, .layout, .printing, .shortcuts, .app])
        #expect(Set(listedTabs).count == listedTabs.count)
    }

    @Test("个人信息不进列表：它是顶部那块账户区")
    func profileIsTheAccountBlock() {
        #expect(SettingsTab.profile.group == .profile)
        #expect(!listedTabs.contains(.profile))
        #expect(SettingsGroup.profile.tabs.isEmpty)
    }

    @Test("每一页都有标题与图标，互不相同")
    func tabsHaveDistinctTitlesAndSymbols() {
        let titles = SettingsTab.allCases.map(\.title)
        let symbols = SettingsTab.allCases.map(\.symbol)
        #expect(Set(titles).count == titles.count)
        #expect(Set(symbols).count == symbols.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test("rawValue 写死在 defaults 里——改了会让老读者的选择丢掉")
    func rawValuesAreStable() {
        #expect(SettingsTab.profile.rawValue == "profile")
        #expect(SettingsTab.writing.rawValue == "writing")
        #expect(SettingsTab.theme.rawValue == "theme")
        #expect(SettingsTab.layout.rawValue == "layout")
        #expect(SettingsTab.printing.rawValue == "printing")
        #expect(SettingsTab.shortcuts.rawValue == "shortcuts")
        #expect(SettingsTab.app.rawValue == "app")
        #expect(SettingsTab.storageKey == "wtmd.settings.tab")
    }

    @Test("第一次打开落在个人信息——列表的第一行")
    func fallbackIsProfile() {
        #expect(SettingsTab.fallback == .profile)
    }

    @Test("更新状态四句话，闲时不说话")
    func updateSummary() {
        #expect(UpdateStatus.idle.summary == nil)
        #expect(UpdateStatus.checking.summary == "正在检查…")
        #expect(UpdateStatus.upToDate(version: "0.15.2").summary == "v0.15.2 已是最新")
        #expect(
            UpdateStatus.available(
                version: "0.16.0", releaseURL: URL(string: "https://example.com")!
            ).summary == "v0.16.0 可用"
        )
        #expect(UpdateStatus.failed.summary == "上次检查失败")
    }
}

// MARK: - 装配

/// 目录对了，窗口没这么摆也是白搭。源码装配断言守的是「我们真的这么接」：
/// 侧栏在、详情在、工具栏那颗按钮开的是设置、旧浮层没留下。
@Suite("设置窗口装配")
struct SettingsAssemblyTests {
    @Test func theShellIsSidebarPlusDetail() throws {
        let source = try String(contentsOf: Self.shellURL, encoding: .utf8)
        #expect(source.contains("func sidebarRow(_ tab: SettingsTab)"), "左侧没有按页渲染的行")
        #expect(source.contains("ForEach(SettingsGroup.allCases"), "左侧没有按分类分组")
        #expect(source.contains("ProfileAvatar("), "账户区没有头像")
        // macOS 26 的 sidebar 列表会把高亮涂到分组标题上，所以这里是自绘行
        #expect(!source.contains("List(selection:"), "左侧又用回了系统列表")
        // 详情区跟着选择走：七页都在 switch 里
        for tab in SettingsTab.allCases {
            #expect(source.contains("case .\(tab.rawValue):"), "详情里没有 \(tab.rawValue) 这一页")
        }
    }

    @Test func theSettingsSceneUsesTheShell() throws {
        let source = try String(contentsOf: Self.appURL, encoding: .utf8)
        #expect(source.contains("Settings {\n            SettingsShell()"), "设置场景还是旧的标签页")
        #expect(source.contains("environmentObject(shared.profile)"), "没把个人信息交给设置窗口")
        #expect(!source.contains("TabView(selection: $tab)"), "旧的 TabView 还留着")
    }

    @Test func theToolbarCarriesTheAvatar() throws {
        let source = try String(contentsOf: Self.contentViewURL, encoding: .utf8)
        let toolbar = try #require(Self.body(of: "toolbarContent", in: source))
        #expect(toolbar.contains("SettingsWindow.open(.profile)"), "工具栏那颗按钮没开设置")
        #expect(toolbar.contains("ProfileAvatar("), "工具栏上没有头像")
        // 旧的功能中心从工具栏和窗口里都退休了
        #expect(!toolbar.contains("controlCenterVisible"), "工具栏还留着功能中心状态")
        #expect(!source.contains("ControlCenterPanel"), "窗口里还挂着旧浮层")
        #expect(!source.contains("slider.horizontal.3"), "工具栏还是旧的功能中心图标")
    }

    @Test func theWindowInjectsProfile() throws {
        let source = try String(contentsOf: Self.windowRootURL, encoding: .utf8)
        #expect(source.contains("environmentObject(model.shared.profile)"), "窗口没拿到个人信息")
    }

    @Test func theAboutPanelHasOneImplementation() throws {
        let source = try String(contentsOf: Self.catalogURL, encoding: .utf8)
        #expect(source.contains("AboutPanel.show()"), "菜单里的「关于」没走共用实现")
        #expect(!source.contains("orderFrontStandardAboutPanel"), "关于面板又抄了一份")
    }

    // MARK: 辅助

    static let contentViewURL = sourceURL("ContentView.swift")
    static let windowRootURL = sourceURL("WindowRoot.swift")
    static let appURL = sourceURL("wtmdApp.swift")
    static let shellURL = sourceURL("SettingsWindow.swift")
    static let catalogURL = sourceURL("CommandCatalog.swift")

    private static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // wtmdTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/wtmd/\(name)")
    }

    /// 花括号配平，取出某个 `var …: ` 声明的函数体。
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
