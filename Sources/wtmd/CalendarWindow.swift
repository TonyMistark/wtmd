import AppKit
import SwiftUI

/// 写作日历自己一扇小窗，不再挂在某扇写作窗上当 sheet。
///
/// sheet 挂在谁身上，谁就得跟着往前提：从设置里点「打开写作日历」，主窗会被
/// 顶到设置前面——人明明是从设置出发的，回来却连设置都找不着了；而且为了摊
/// 一页只读的账，还得先替它挑一扇「主人」（#175 那一串麻烦就是这么来的）。
///
/// 一扇自己的窗谁都不碰：开在最前面，下面原来是什么还是什么。
@MainActor
enum CalendarWindow {
    /// 只留一扇：再点一次是把已有那扇拿到前面，顺带换上最新数据。
    private static var controller: NSWindowController?

    /// 面板本来就是照一整年 53 列留的尺寸。
    static let contentSize = NSSize(width: 780, height: 420)

    /// 这扇窗的身份。激活逻辑靠它把日历从「主窗候选人」里排掉——
    /// 点 Dock 图标该回来的是写作窗口，不是一张只读的账。
    static let windowIdentifier = NSUserInterfaceItemIdentifier("wtmd.calendar.window")

    /// 现在开着吗？（测试与「要不要重开」看它）
    static var isVisible: Bool { controller?.window?.isVisible ?? false }

    /// 那扇窗本身。测试要拿它验「同一扇」与前后次序。
    static var window: NSWindow? { controller?.window }

    /// 现在这扇日历读的是哪本账。弱引用：窗口关掉之后不能拽着 store 不放。
    private(set) static weak var source: DocumentStore?

    /// 开着，而且摊的正是这本账。
    static func isShowing(store: DocumentStore) -> Bool {
        isVisible && source === store
    }

    static func show(store: DocumentStore, goal: Int) {
        let window = controller?.window ?? makeWindow()
        source = store
        window.title = t("Writing Calendar")
        window.contentViewController = NSHostingController(
            rootView: panel(hosting: window, store: store, goal: goal)
        )
        window.setContentSize(contentSize)
        if controller == nil {
            window.center()
            controller = NSWindowController(window: window)
        }
        AppActivation.bringToFront(window)
    }

    /// 关掉（测试收尾用）。
    static func close() { controller?.window?.close() }

    // MARK: - 内部

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // 关掉之后还能开回同一扇：重建会丢掉人摆好的位置。
        window.isReleasedWhenClosed = false
        window.identifier = windowIdentifier
        window.setFrameAutosaveName("wtmd.calendar.window")
        return window
    }

    private static func panel(
        hosting window: NSWindow,
        store: DocumentStore,
        goal: Int
    ) -> some View {
        WritingCalendarPanel(
            days: days(from: store),
            goal: goal,
            close: { [weak window] in window?.close() }
        )
        // Esc 关窗：与它当 sheet 时的习惯一致。
        .onExitCommand { [weak window] in window?.close() }
    }

    /// 过去一年逐日净增。打开时算一遍——365 次字典查找，不值得缓存。
    static func days(from store: DocumentStore) -> [WritingCalendar.Day] {
        guard let stats = store.writingStats else { return [] }
        return WritingCalendar.days(endingAt: Date(), count: 365, calendar: .current) {
            stats.total(on: $0)
        }
    }
}
