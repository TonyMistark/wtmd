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
        .init(
            isVisible: visible,
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

    @Test("上次那扇关了：挑一扇看得见的，而不是对着关掉的空举")
    func skipsClosedLastKeyWindow() {
        let windows = [info(), info(visible: false), info()]
        #expect(AppActivation.pick(from: windows, lastKey: 1) == .raise(0))
    }

    @Test("缩进 Dock 的那扇：叫醒它，不是当它不存在")
    func deminiaturizesWhenOnlyMinimized() {
        let windows = [info(miniaturized: true)]
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
