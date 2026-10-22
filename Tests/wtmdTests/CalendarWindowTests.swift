import AppKit
import Foundation
import Testing

@testable import wtmd

/// 写作日历是一扇自己的窗，不再挂在主窗上当 sheet。
///
/// 用户报的现象：从设置里点「打开写作日历」，回来的层次是
/// 「日历 → 主窗 → 设置」——人明明是从设置出发的，设置却被顶到了最底下。
/// 原因是 sheet 必须挂在某扇窗上，那扇窗就得跟着往前提。日历独立成窗之后，
/// 顺序只该是「日历 → 设置 → 主窗」：原来在前的还在前。
@Suite("写作日历那扇窗", .serialized)
@MainActor
struct CalendarWindowTests {
    private func makeStore(root: URL) -> DocumentStore {
        DocumentStore(
            draftDirectory: root,
            autoSaveDelay: 600_000_000_000,
            history: DocumentHistory(directory: root.appendingPathComponent("history"))
        )
    }

    private func makeWindow(_ title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("开一次就是一扇：再点是把同一扇拿到前面，尺寸贴合面板")
    func showKeepsASingleWindow() throws {
        defer { CalendarWindow.close() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-calendar-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        CalendarWindow.show(store: store, goal: 500)
        let first = try #require(CalendarWindow.window)
        #expect(CalendarWindow.isVisible)
        #expect(CalendarWindow.isShowing(store: store))
        #expect(first.contentLayoutRect.size == CalendarWindow.contentSize)

        CalendarWindow.show(store: store, goal: 500)
        #expect(CalendarWindow.window === first, "第二次点该复用同一扇，不是又开一扇")
    }

    @Test("开日历不动别的窗：原来在前面的还在前面")
    func showingKeepsTheOtherWindowsInOrder() throws {
        defer { CalendarWindow.close() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-calendar-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let main = makeWindow("main")
        let settings = makeWindow("settings")
        defer {
            main.close()
            settings.close()
        }
        main.orderFront(nil)
        // 设置压在写作窗上面：这正是人点按钮那一刻的样子。
        settings.orderFront(nil)

        CalendarWindow.show(store: store, goal: 500)
        let calendar = try #require(CalendarWindow.window)

        let order = NSApplication.shared.orderedWindows
        let calendarIndex = try #require(order.firstIndex(of: calendar), "日历没进窗口列表")
        let settingsIndex = try #require(order.firstIndex(of: settings), "设置窗不见了")
        let mainIndex = try #require(order.firstIndex(of: main), "主窗不见了")

        #expect(calendarIndex < settingsIndex, "日历该在最前面")
        #expect(
            settingsIndex < mainIndex,
            "设置不该被顶到主窗下面——用户是从设置出发的（#177 反馈）"
        )
    }


    @Test("日历窗不当主窗：点 Dock 图标该举的是写作窗口")
    func theCalendarIsNotAMainWindow() throws {
        defer { CalendarWindow.close() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-calendar-aux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        CalendarWindow.show(store: makeStore(root: root), goal: 500)
        let calendar = try #require(CalendarWindow.window)

        let info = AppActivation.info(calendar)
        #expect(info.isAuxiliary, "日历窗得被标成附属窗")

        // 只剩它一扇：pick 挑不出人，调用方会去开一扇写作窗——而不是把账本举上来。
        #expect(AppActivation.pick(from: [info]) == nil)
        #expect(!AppActivation.defersToSystem([info]), "账本缩不了，也不该挡住「全缩着」的判断")
    }
}
