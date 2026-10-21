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

    /// 「另起一桌」的通道：与 ⌘N 同一条路（新会话、接着用当前文件夹）。
    /// 同样是根视图装进来的——它得拿到窗口表。
    static var newWindow: (() -> Void)?

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

/// 从别的窗口打开写作日历。
///
/// 日历是写作窗口上的一张 sheet，挂在那个窗口的 `DocumentStore` 上；设置窗口是
/// 独立场景，手里没有那份 store。所以入口只能反过来：按下按钮的这一边不打开
/// 任何东西，只留一句「有人要日历」，由窗口那边接单。
///
/// 窗口还在（哪怕缩着）就直接摊开；一扇都没有就先记着，等窗口回来再接。
@MainActor
enum CalendarRequest {
    /// 由窗口根视图装进来。返回 `false` 表示眼下没有能摊开它的窗。
    static var present: (() -> Bool)?

    /// 窗还没开时先记的一笔。窗口出现（`ContentView` 的 `onAppear`）再兑现。
    private(set) static var pending = false

    static func show() {
        if present?() == true { return }
        pending = true
        // 开窗是异步的：这里只负责把窗叫回来，等它落地再摊开。
        AppActivation.openMain?()
        waitForWindow(attempts: 20)
    }

    /// 窗口从「关着」到「能摊 sheet」之间隔着好几帧（场景重建、视图装配）。
    /// 与其猜一个延迟，不如隔一会儿问一句——问到了就把记的那一笔划掉，免得
    /// 窗口下次出现时又莫名其妙弹一次。
    private static func waitForWindow(attempts: Int) {
        guard attempts > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            // 这笔账已经被兑现（或撤掉）了就别再问——同一次请求只摊一次。
            guard pending else { return }
            if present?() == true {
                pending = false
                return
            }
            waitForWindow(attempts: attempts - 1)
        }
    }

    /// 窗口出现了：该摊开的摊开。取用即清——同一次请求不该摊两次。
    static func consume() -> Bool {
        defer { pending = false }
        return pending
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

    /// 右键 Dock 图标那一下：系统默认只给「显示所有窗口」与窗口列表。
    /// 手上没有窗口的人，第一反应就是右键找一个能开的入口——所以这里补一条
    /// 「新建窗口」，与 ⌘N 同一个实现。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let new = NSMenuItem(
            title: t("New Window", "新建窗口"),
            action: #selector(newWindowFromDock),
            keyEquivalent: "n"
        )
        new.keyEquivalentModifierMask = .command
        new.target = self
        menu.addItem(new)

        let settings = NSMenuItem(
            title: t("Settings…", "设置…"),
            action: #selector(openSettingsFromDock),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        return menu
    }

    @objc private func newWindowFromDock() {
        // 先激活应用：Dock 菜单选完，焦点可能还在别处，新窗口会在后台开出来。
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let newWindow = AppActivation.newWindow {
            newWindow()
            return
        }
        // 窗口通道还没装好（理论上不会）时退回主窗，总比什么都不做强。
        AppActivation.openMain?()
    }

    @objc private func openSettingsFromDock() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        SettingsWindow.open()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppActivation.remember(NSApplication.shared.keyWindow)
        AppActivation.ensureKeyWindow()
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }
}
