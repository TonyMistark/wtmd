import AppKit
import Foundation
import Testing

@testable import wtmd

/// 窗口标题跟着文档走，不走 SwiftUI 的缓存（#287）。
///
/// 用户报的现象：先开 aa.md，标题正常；关掉窗口；再开 bb.md——内容是 bb 的，
/// 标题栏还是 aa.md。store 在所有打开路径里都是对的（内容证明这一点），坏在
/// SwiftUI 对同场景重建窗口的标题管理：沿用旧窗缓存、不再推送变化。所以标题
/// 由 `WindowTitleSync` 直接经 AppKit 写 `NSWindow.title`，这里的测试守住两条：
/// 挂上就校准（含旧缓存），文档换了标题跟着换。
@Suite("窗口标题同步", .serialized)
@MainActor
struct WindowTitleSyncTests {
    /// 订阅跟着实例活：实例一释放订阅就取消，标题就不跟了。
    /// 每个测试里用局部 `let` 持有同步对象，活到测试结束。

    private func makeDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-title-sync-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ name: String, in root: URL, content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeWindow(title: String) -> NSWindow {
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

    private func makeStore(root: URL) -> DocumentStore {
        DocumentStore(
            draftDirectory: root,
            autoSaveDelay: 600_000_000_000,
            history: DocumentHistory(directory: root.appendingPathComponent("history"))
        )
    }

    @Test("关掉旧窗再开新文件：挂上同步就校准，不留上一篇的缓存标题")
    func startCorrectsAStaleCachedTitle() throws {
        let root = try makeDirectory("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let aa = try write("aa.md", in: root, content: "AAA")
        let bb = try write("bb.md", in: root, content: "BBB")
        let store = makeStore(root: root)
        store.open(url: aa)

        // 重建的窗口带着上一篇的缓存标题——正是用户看到的那块。
        let window = makeWindow(title: "aa.md")
        defer { window.close() }

        // store 已经换到 bb（OpenRequest 先开文件、窗口后出来的次序，或反过来都一样）。
        store.open(url: bb)
        let sync = WindowTitleSync(window: window, store: store)
        sync.start()

        #expect(window.title == "bb.md", "标题必须跟 store 走，不能停在缓存")
    }

    @Test("窗口活着换文档：标题跟着换")
    func titleFollowsTheDocumentWhileTheWindowLives() throws {
        let root = try makeDirectory("switch")
        defer { try? FileManager.default.removeItem(at: root) }
        let aa = try write("aa.md", in: root, content: "AAA")
        let bb = try write("bb.md", in: root, content: "BBB")
        let store = makeStore(root: root)
        let window = makeWindow(title: "welcome")
        defer { window.close() }

        let sync = WindowTitleSync(window: window, store: store)
        sync.start()
        store.open(url: aa)
        #expect(window.title == "aa.md")

        store.open(url: bb)
        #expect(window.title == "bb.md")

        store.newDocument()
        #expect(window.title == t("Untitled.md"), "没有名字的稿子回到未命名")
    }

    @Test("编辑点亮脏圆点，保存落地后圆点消失")
    func dirtyDotAppearsAndClears() throws {
        let root = try makeDirectory("dirty")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("aa.md", in: root, content: "AAA")
        let store = makeStore(root: root)
        let window = makeWindow(title: "")
        defer { window.close() }

        let sync = WindowTitleSync(window: window, store: store)
        sync.start()
        store.open(url: file)
        #expect(window.title == "aa.md")

        store.text = "AAA edited"
        #expect(window.title == "● aa.md", "没落盘的字要点亮圆点")

        store.save()
        #expect(window.title == "aa.md", "保存之后圆点该消失")
    }
}
