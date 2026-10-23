import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 挑哪一扇

/// 点 Dock 图标要举一扇窗出来。挑错了比不挑更糟：把人塞进一个 sheet、
/// 一个读不到键盘的面板、或者一扇已经关掉的窗——屏幕上一个像素都不会动。
/// 规则写成纯函数，这里逐条钉住。
@Suite("激活时举哪扇窗")
struct AppActivationPickTests {
    private func info(
        visible: Bool = true,
        miniaturized: Bool = false,
        sheet: Bool = false,
        canBecomeKey: Bool = true,
        panel: Bool = false
    ) -> AppActivation.WindowInfo {
        // 贴近真实 NSWindow：`isVisible` 对缩着的窗返回 false（#175）。
        .init(
            isVisible: visible && !miniaturized,
            isMiniaturized: miniaturized,
            isSheet: sheet,
            canBecomeKey: canBecomeKey,
            isPanel: panel
        )
    }

    @Test("上次用的那扇还在：就举它，哪怕后面还有更新的窗")
    func prefersLastKeyWindow() {
        let windows = [info(), info(), info()]
        #expect(AppActivation.pick(from: windows, lastKey: 2) == .raise(2))
    }

    @Test("上次用的那扇缩进了 Dock：叫醒它，而不是当它关了再开一扇新的")
    func lastKeyMiniaturizedStillChosen() {
        let windows = [info(miniaturized: true)]
        #expect(AppActivation.pick(from: windows, lastKey: 0) == .deminiaturize(0))

        // 后面还有一扇看得见的：lastKey 缩着也算「还在」，人的意图是回那扇
        #expect(AppActivation.pick(from: [info(miniaturized: true), info()], lastKey: 0)
                == .deminiaturize(0))
    }

    @Test("上次那扇真关了：挑一扇看得见的，而不是对着关掉的空举")
    func skipsClosedLastKeyWindow() {
        let windows = [info(), info(visible: false), info()]
        #expect(AppActivation.pick(from: windows, lastKey: 1) == .raise(0))
    }

    @Test("缩进 Dock 的那扇：叫醒它，不是当它不存在")
    func deminiaturizesWhenOnlyMinimized() {
        let windows = [info(miniaturized: true)]
        #expect(AppActivation.pick(from: windows) == .deminiaturize(0))
    }

    @Test("多扇都缩着：按顺序叫醒第一扇")
    func firstMinimizedInOrderWins() {
        let windows = [info(miniaturized: true), info(miniaturized: true)]
        #expect(AppActivation.pick(from: windows) == .deminiaturize(0))
    }

    @Test("看得见的优先于缩着的")
    func visibleBeatsMinimized() {
        let windows = [info(miniaturized: true), info()]
        #expect(AppActivation.pick(from: windows) == .raise(1))
    }

    @Test("sheet 不参与：它挂在别人身上，自己拿不出手")
    func skipsSheets() {
        let windows = [info(sheet: true), info()]
        #expect(AppActivation.pick(from: windows) == .raise(1))
        #expect(AppActivation.pick(from: [info(sheet: true)]) == nil)
    }

    @Test("当不了主的窗不参与（`canBecomeKey == false`）")
    func skipsWindowsThatCannotBecomeKey() {
        let windows = [info(canBecomeKey: false), info()]
        #expect(AppActivation.pick(from: windows) == .raise(1))
    }

    @Test("普通窗优先于面板：面板多半是临时的，随时会消失")
    func ordinaryWindowsBeatPanels() {
        let windows = [info(panel: true), info()]
        #expect(AppActivation.pick(from: windows) == .raise(1))
        // 只剩面板时还是得举一个——总不能什么都不做
        #expect(AppActivation.pick(from: [info(panel: true)]) == .raise(0))
    }

    @Test("屏幕外的窗口不算「有」：举起来之前得先挪回看得见的地方")
    func offScreenWindowsDoNotCount() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(AppActivation.isOnScreen(CGRect(x: 100, y: 100, width: 600, height: 400),
                                         screens: [screen]))
        // 拔掉外接屏之后，记下来的位置就落在这种地方
        #expect(!AppActivation.isOnScreen(CGRect(x: 3000, y: 1200, width: 600, height: 400),
                                          screens: [screen]))
        // 擦着个边也算看得见：人自己把它拖到边上的，不该被挪走
        #expect(AppActivation.isOnScreen(CGRect(x: 1400, y: 100, width: 600, height: 400),
                                         screens: [screen]))
        // 量不到屏幕时（测试进程）别乱挪
        #expect(AppActivation.isOnScreen(CGRect(x: 3000, y: 1200, width: 600, height: 400),
                                         screens: []))
    }

    @Test("一扇看得见的都没有：返回 nil，交给调用方开一扇新的")
    func nothingToRaise() {
        #expect(AppActivation.pick(from: []) == nil)
        #expect(AppActivation.pick(from: [info(visible: false), info(visible: false)]) == nil)
    }
}

// MARK: - 装配

/// 规则对了，没人调用也是白搭：delegate 得装上、Dock 那一下得走到这里、
/// 一扇窗都没有时得能开回主窗。
@Suite("激活装配")
struct AppActivationAssemblyTests {
    @Test func theAppInstallsTheDelegate() throws {
        let source = try String(contentsOf: Self.appURL, encoding: .utf8)
        #expect(
            source.contains("@NSApplicationDelegateAdaptor(AppDelegate.self)"),
            "App 没装 delegate，Dock 那一下没人接"
        )
    }

    @Test func reopenRaisesAWindowOrOpensOne() throws {
        let source = try String(contentsOf: Self.activationURL, encoding: .utf8)
        #expect(source.contains("func applicationShouldHandleReopen"), "没有接 reopen")
        #expect(source.contains("raiseFrontWindow()"), "reopen 里没有举窗")
        #expect(source.contains("openMain"), "一扇窗都没有时没有开窗的通道")
        // 窗口缩着、或者应用在后台，都得真的把它弄到眼前
        #expect(source.contains("deminiaturize"), "缩着的窗没被叫醒")
        #expect(source.contains("activate("), "没有激活应用")
        #expect(source.contains("NSScreen.screens"), "屏幕外的窗口没被挪回来")
    }

    @Test func theRootViewHandsOverOpenMain() throws {
        let source = try String(contentsOf: Self.windowRootURL, encoding: .utf8)
        #expect(source.contains("AppActivation.openMain"), "根视图没把「开主窗」交出去")
        #expect(source.contains("openWindow(id: WindowScene.main)"), "开主窗走错了场景")
    }

    @Test func jumpingToADocumentActivatesTheApp() throws {
        let source = try String(contentsOf: Self.windowModelURL, encoding: .utf8)
        #expect(source.contains("AppActivation.bringToFront(target)"), "跳转只提了窗、没激活应用")
    }

    // MARK: 辅助

    static let appURL = sourceURL("wtmdApp.swift")
    static let activationURL = sourceURL("AppActivation.swift")
    static let windowRootURL = sourceURL("WindowRoot.swift")
    static let windowModelURL = sourceURL("WindowModel.swift")

    private static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // wtmdTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/wtmd/\(name)")
    }
}

// MARK: - 右键 Dock 图标

/// 窗口全关掉之后，人右键 Dock 图标是去找入口的。系统默认那份菜单里
/// 只有「显示所有窗口」和一个空列表——这里补的是「新建窗口」。
@Suite("Dock 菜单")
@MainActor
struct AppDockMenuTests {
    /// 菜单项的 `target` 是弱引用：delegate 没人持有的话，菜单还没点就被回收了，
    /// 点下去自然什么都不发生。真应用里它由 `@NSApplicationDelegateAdaptor` 持有。
    private let delegate = AppDelegate()

    private func makeMenu() -> NSMenu? {
        delegate.applicationDockMenu(NSApplication.shared)
    }

    @Test("右键菜单里有「新建窗口」和「设置…」，前者挂着 ⌘N")
    func dockMenuOffersNewWindowAndSettings() throws {
        let menu = try #require(makeMenu())
        #expect(menu.items.count == 2)
        #expect(menu.items[0].title == t("New Window"))
        #expect(menu.items[0].keyEquivalent == "n")
        #expect(menu.items[0].keyEquivalentModifierMask == .command)
        #expect(menu.items[1].title == t("Settings…"))
        // 每一项都得有人接：target 为 nil 的菜单项在 Dock 上点下去什么都不会发生。
        #expect(menu.items.allSatisfy { $0.target != nil })
        #expect(menu.items.allSatisfy { $0.action != nil })
    }

    @Test("「新建窗口」走的是 ⌘N 那条路，不是举旧窗")
    func newWindowItemOpensAFreshWindow() throws {
        let menu = try #require(makeMenu())
        var opened = 0
        AppActivation.newWindow = { opened += 1 }
        defer { AppActivation.newWindow = nil }

        let item = menu.items[0]
        NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item)

        #expect(opened == 1)
    }

    @Test("还没装上窗口通道时退回主窗，而不是无声无息")
    func newWindowFallsBackToTheMainWindow() throws {
        let menu = try #require(makeMenu())
        var opened = 0
        AppActivation.newWindow = nil
        AppActivation.openMain = { opened += 1 }
        defer { AppActivation.openMain = nil }

        let item = menu.items[0]
        NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item)

        #expect(opened == 1)
    }

    @Test("「设置…」开的是设置窗口")
    func settingsItemOpensSettings() throws {
        let menu = try #require(makeMenu())
        var opened = 0
        SettingsWindow.install { opened += 1 }
        defer { SettingsWindow.install(nil) }

        let item = menu.items[1]
        NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item)

        #expect(opened == 1)
    }

    @Test("根视图把「另起一桌」也交出去了")
    func theRootViewHandsOverNewWindow() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/wtmd/WindowRoot.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("AppActivation.newWindow"), "根视图没把「开新窗」交出去")
        #expect(source.contains("openNewWindow(inheriting:"), "新窗口没走窗口表那条路")
    }
}

// MARK: - 从设置里打开写作日历

/// 日历是一扇自己的窗（`CalendarWindow`），设置窗口里没有那份 `DocumentStore`——
/// 所以入口靠 `CalendarRequest` 回到窗口表上取主窗那本账。这几条钉住
/// 「有表就开窗、没表不崩」。
@Suite("设置里打开写作日历", .serialized)
@MainActor
struct CalendarRequestTests {
    @Test("没有窗口表：什么都不发生，也不崩")
    func doesNothingWithoutCoordinator() {
        let previous = CalendarRequest.coordinator
        defer { CalendarRequest.coordinator = previous }

        CalendarRequest.coordinator = nil
        CalendarWindow.close()
        CalendarRequest.show()

        #expect(!CalendarWindow.isVisible, "没有表就不该凭空开出一扇日历")
    }

    @Test("有窗口表：把日历开出来，读的是主窗那本账")
    func opensTheCalendarFromTheWindowTable() throws {
        let previous = CalendarRequest.coordinator
        defer {
            CalendarRequest.coordinator = previous
            CalendarWindow.close()
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-calendar-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults(suiteName: "wtmd.calendar.\(UUID().uuidString)")!
        let shared = SharedAppEnvironment(
            writingStats: WritingStats(defaults: defaults),
            recentFiles: RecentFiles(userDefaults: defaults),
            conflicts: ConflictArchive(directory: root.appendingPathComponent("conflicts")),
            history: DocumentHistory(directory: root.appendingPathComponent("history"))
        )
        let coordinator = WindowCoordinator(
            shared: shared,
            primary: WindowModel(
                session: Session(persist: false, defaults: defaults),
                shared: shared,
                draftDirectory: root.appendingPathComponent("primary", isDirectory: true),
                startsBlank: true
            ),
            draftRoot: root,
            defaults: defaults
        )
        CalendarRequest.coordinator = coordinator

        CalendarRequest.show()

        #expect(CalendarWindow.isVisible, "设置里点日历，该开出一扇日历窗")
        #expect(CalendarWindow.isShowing(store: coordinator.primary.store))
    }

    @Test("装配：设置页有按钮，应用启动时把窗口表装上")
    func thePathIsWired() throws {
        let settings = try source("SettingsPages.swift")
        #expect(settings.contains("CalendarRequest.show()"), "设置里没有打开日历的按钮")

        let app = try source("wtmdApp.swift")
        #expect(app.contains("CalendarRequest.coordinator = coordinator"), "启动时没把窗口表装上")
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/wtmd/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Dock 点击的归宿

/// 点 Dock 图标，人要的是「我刚才那扇窗回来」。曾经在「全缩着」时把 reopen
/// 交回系统去换神灯动画——但 SwiftUI WindowGroup 应用里系统接手开的是
/// **一扇新窗**，缩着的原窗纹丝不动（#217）。这组钉住现在的规矩：
/// 自己举，缩着的自己叫醒；真的一扇都没有才开新的。
@Suite("Dock 点击的归宿")
struct DockReopenTests {
    @Test("缩着的窗是自己叫醒的候选，不是新开一扇的理由")
    func minimizedWindowsAreCandidates() {
        #expect(AppActivation.pick(from: [AppActivation.WindowInfo(
            isVisible: false, isMiniaturized: true, isSheet: false,
            canBecomeKey: true, isPanel: false
        )]) == .deminiaturize(0))
    }

    @Test("真的一扇都没有（连缩着的都没有）：返回 nil，调用方开新窗")
    func nothingAtAllOpensANewOne() {
        #expect(AppActivation.pick(from: []) == nil)
        #expect(AppActivation.pick(from: [AppActivation.WindowInfo(
            isVisible: false, isMiniaturized: false, isSheet: false,
            canBecomeKey: true, isPanel: false
        )]) == nil)
    }

    @Test("装配：reopen 一律自己举，不再交给系统")
    func reopenHandlesItself() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/wtmd/AppActivation.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // 交给系统的旧路已被拔掉：系统在 SwiftUI 应用里会开一扇新窗（#217）
        #expect(!source.contains("defersToSystem"), "reopen 还留着「交给系统」的捷径")
        #expect(!source.contains("deferToSystemFallback"), "兜底计时器还留着")
        #expect(source.contains("raiseFrontWindow()"), "reopen 里没有举窗")
        #expect(source.contains("deminiaturize"), "缩着的窗没被叫醒")
        // 放出来之后不该再 order front：那一下会把还没跑完的动画拽到终点。
        #expect(!source.contains("deminiaturize(nil)\n            windows[index].makeKeyAndOrderFront"))
    }
}
