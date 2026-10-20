import AppKit
import Foundation

/// 「点了 Dock 图标，窗口却不出来」的那一半责任。
///
/// 应用被激活时，系统只会把**它记得的那扇窗**拿到前面：那扇窗可能已经关了
/// （用户按了 ⌘W）、缩进了 Dock、或者根本不是一扇能当主的窗（sheet、
/// 只用来收键的浮面）。这时候菜单栏换了名字，屏幕上一个像素都没动——看起来
/// 就是「点了没反应」，而且只在某些状态之后才出现，所以「有时候又好了」。
///
/// 这里自己挑一扇：最近一次成为 key 的那扇最优先，其次是一扇看得见的普通
/// 窗口，缩着的就叫醒它。挑的规则写成纯函数，测试不必真开窗。
enum AppActivation {
    /// 一扇窗在这件事上需要知道的全部。`NSWindow` 不进测试。
    struct WindowInfo: Equatable {
        var isVisible: Bool
        var isMiniaturized: Bool
        var isSheet: Bool
        var canBecomeKey: Bool
        var isPanel: Bool
    }

    enum Action: Equatable {
        case raise(Int)
        /// 缩在 Dock 里的那扇：先叫醒，再拿到前面。
        case deminiaturize(Int)
    }

    // MARK: - 挑哪一扇

    /// - Parameter lastKey: 最近一次成为 key 的那扇在数组里的位置。
    ///
    /// 顺序是有讲究的：**看得见的普通窗口** > 看得见的面板 > 缩着的。
    /// 面板排在后面，是因为它多半是临时的（查找条、面板），把人塞进一个
    /// 随时会消失的窗口里，比什么都不做更让人困惑。
    static func pick(from windows: [WindowInfo], lastKey: Int? = nil) -> Action? {
        let eligible = windows.indices.filter {
            !windows[$0].isSheet && windows[$0].canBecomeKey
        }
        guard !eligible.isEmpty else { return nil }

        // 上一次用的那扇：人点 Dock 想让回来的通常就是它。
        // 但它可能已经关掉了——关掉的窗再举一次，屏幕上什么都不会发生。
        if let lastKey, eligible.contains(lastKey), windows[lastKey].isVisible {
            return action(at: lastKey, in: windows)
        }

        let visible = eligible.filter { windows[$0].isVisible }
        let groups: [[Int]] = [
            visible.filter { !windows[$0].isMiniaturized && !windows[$0].isPanel },
            visible.filter { !windows[$0].isMiniaturized },
            visible.filter { windows[$0].isMiniaturized && !windows[$0].isPanel },
            visible.filter { windows[$0].isMiniaturized },
        ]
        for group in groups {
            if let index = group.first { return action(at: index, in: windows) }
        }
        // 一扇看得见的都没有：交给调用方去开一扇新的。
        return nil
    }

    private static func action(at index: Int, in windows: [WindowInfo]) -> Action {
        windows[index].isMiniaturized ? .deminiaturize(index) : .raise(index)
    }

    // MARK: - 动手

    /// 这扇窗还在某块屏幕上吗？
    ///
    /// 拔掉外接屏、改过分辨率之后，记下来的位置可能落在不存在的区域里：
    /// 窗口「在」，只是人看不见——点 Dock 图标当然也就「没反应」。
    static func isOnScreen(_ frame: CGRect, screens: [CGRect]) -> Bool {
        guard !screens.isEmpty else { return true }
        return screens.contains { $0.intersects(frame) }
    }

    /// 最近一次成为 key 的窗口。弱引用：那扇窗关掉之后不能拽着它不放。
    private(set) static weak var lastKey: NSWindow?

    /// 没有窗可举时开一扇的通道。由根视图装进来——`openWindow` 只在场景里读得到。
    static var openMain: (() -> Void)?

    static func remember(_ window: NSWindow?) {
        guard let window, window.sheetParent == nil else { return }
        lastKey = window
    }

    /// 挑一扇看得见的拿到前面并激活应用。一扇都没有就返回 false。
    @MainActor
    @discardableResult
    static func raiseFrontWindow() -> Bool {
        let app = NSApplication.shared
        let windows = app.windows
        guard let action = pick(from: windows.map(info), lastKey: windows.firstIndex {
            $0 === lastKey
        }) else { return false }

        if app.isHidden { app.unhide(nil) }
        activate(app)

        switch action {
        case .raise(let index):
            recenterIfOffScreen(windows[index])
            windows[index].makeKeyAndOrderFront(nil)
        case .deminiaturize(let index):
            recenterIfOffScreen(windows[index])
            windows[index].deminiaturize(nil)
            windows[index].makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// 摆在看不见的地方就先挪回屏幕中间——举了但看不见，和没举一样。
    @MainActor
    private static func recenterIfOffScreen(_ window: NSWindow) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !isOnScreen(window.frame, screens: screens) else { return }
        window.center()
    }

    /// 把指定的那扇拿到前面，顺带把应用激活。缩着的先叫醒。
    ///
    /// 只 `makeKeyAndOrderFront` 是不够的：应用在后台时，窗口会在自己的层里
    /// 往前提，人看到的还是别的 app——「跳过去」跳了个寂寞。
    @MainActor
    static func bringToFront(_ window: NSWindow) {
        let app = NSApplication.shared
        if app.isHidden { app.unhide(nil) }
        activate(app)
        recenterIfOffScreen(window)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// 应用已经在前面、却没有一扇 key 窗：把看得见的那扇认作主窗。
    ///
    /// 少了这一句，窗口虽然露在外面，键盘却还在别处——写不了字，点哪儿都像
    /// 「没到最前面」。只在真的没有 key 窗时动手，不抢 sheet 与设置窗口的焦点。
    @MainActor
    static func ensureKeyWindow() {
        let app = NSApplication.shared
        guard app.isActive, app.keyWindow == nil else { return }
        let windows = app.windows
        guard let action = pick(from: windows.map(info), lastKey: windows.firstIndex {
            $0 === lastKey
        }) else { return }
        switch action {
        case .raise(let index):
            windows[index].makeKeyAndOrderFront(nil)
        case .deminiaturize(let index):
            windows[index].deminiaturize(nil)
            windows[index].makeKeyAndOrderFront(nil)
        }
    }

    private static func info(_ window: NSWindow) -> WindowInfo {
        WindowInfo(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isSheet: window.sheetParent != nil,
            canBecomeKey: window.canBecomeKey,
            isPanel: window is NSPanel
        )
    }

    private static func activate(_ app: NSApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(ignoringOtherApps: true)
        }
    }
}

/// 点 Dock 图标那一下走这里。SwiftUI 自己的实现只认「上一次那扇窗」，
/// 那扇窗没了就什么都不做——所以先问一句我们能不能举一扇出来。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                AppActivation.remember(note.object as? NSWindow)
            }
        }
    }

    /// 返回值是「这件事我处理完了」。举不出一扇窗（全关了）就返回 false，
    /// 让系统按自己的规矩开一扇新的。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let raised = AppActivation.raiseFrontWindow()
        // 留一行轨迹：这个 bug 只在某些状态之后出现，下次复发时针眼在这里。
        CrashBreadcrumbs.note("reopen hasVisible=\(flag) raised=\(raised)")
        if raised { return true }
        guard let open = AppActivation.openMain else { return false }
        open()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppActivation.remember(NSApplication.shared.keyWindow)
        AppActivation.ensureKeyWindow()
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }
}
