import AppKit
import Foundation
import Testing

@testable import wtmd

// MARK: - 一次启动

/// 一台机器上的「桌面」：一本账、一个草稿根、一份共享设置。
///
/// `launch()` 造的是**这一次启动**的窗口表——同一个 `UserDefaults` suite，
/// 换一份进程内存。测试因此能真的演一遍「退出、再打开」。
@MainActor
private final class Desk {
    let defaults: UserDefaults
    let defaultsName: String
    let root: URL
    let shared: SharedAppEnvironment
    var opened: [UUID] = []

    init() throws {
        defaultsName = "wtmd.tests.relaunch.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        shared = SharedAppEnvironment(
            writingStats: WritingStats(defaults: defaults),
            recentFiles: RecentFiles(userDefaults: defaults),
            conflicts: ConflictArchive(directory: root.appendingPathComponent("conflicts"))
        )
    }

    func launch(
        screens: [CGRect] = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    ) -> WindowCoordinator {
        opened = []
        let coordinator = WindowCoordinator(
            shared: shared,
            primary: WindowModel(
                session: Session(defaults: defaults),
                shared: shared,
                draftDirectory: root.appendingPathComponent("primary", isDirectory: true),
                startsBlank: true
            ),
            draftRoot: root,
            defaults: defaults
        )
        // 测试进程没有显示器：屏幕区域得给一个。
        coordinator.screenFrames = { screens }
        coordinator.attach { [weak self] id in self?.opened.append(id) }
        return coordinator
    }

    func draftDirectory(of id: UUID) -> URL {
        WindowCoordinator.temporaryDraftDirectory(for: id, root: root)
    }

    func makeFolder(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - 恢复

/// 退出时开着两扇，下次启动还是两扇，各是各的稿子。
@MainActor
@Test func everyOpenWindowComesBackAfterARelaunch() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let first = desk.launch()
    let a = try #require(first.openNewWindow(inheriting: nil))
    let b = try #require(first.openNewWindow(inheriting: nil))
    #expect(desk.opened == [a, b])

    let aStore = try #require(first.windows[a]?.store)
    let bStore = try #require(first.windows[b]?.store)
    aStore.textDidChange("# 甲\n\n第一张桌子")
    aStore.flushPendingSave()
    bStore.textDidChange("# 乙\n\n第二张桌子")
    bStore.flushPendingSave()

    let second = desk.launch()

    #expect(desk.opened == [a, b])
    #expect(second.windows[a]?.store.text.contains("第一张桌子") == true)
    #expect(second.windows[b]?.store.text.contains("第二张桌子") == true)
    // 各是各的，不是把一份复制两遍
    #expect(second.windows[a]?.store.text.contains("第二张桌子") == false)
}

/// 恢复的不只是字：工作区、当前文件、光标位置都跟着回来。
@MainActor
@Test func aRestoredWindowBringsBackItsFolderFileAndPosition() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let folder = try desk.makeFolder(named: "书房")
    let file = folder.appendingPathComponent("a.md")
    try "# 甲\n\n正文\n".write(to: file, atomically: true, encoding: .utf8)

    let first = desk.launch()
    let id = try #require(first.openNewWindow(inheriting: folder))
    let store = try #require(first.windows[id]?.store)
    store.open(url: file)
    // 编辑器在跑的时候由滚动回调记位置；测试里直接写进这扇窗的会话，
    // 验的是「恢复时它被交回给位置账本」。
    Session(window: id, defaults: desk.defaults).record(
        Session.Position(
            selectionLocation: 5, selectionLength: 0,
            scrollX: 0, scrollY: 42,
            blockIndex: 2, blockOffset: 8, modifiedAt: nil
        ),
        for: file
    )

    let second = desk.launch()
    let restored = try #require(second.windows[id])

    #expect(restored.store.fileURL.map { PathKey.isSame($0, file) } == true)
    #expect(restored.store.text.contains("正文"))
    #expect(restored.workspace.root.map { PathKey.isSame($0, folder) } == true)
    #expect(Session(window: id, defaults: desk.defaults).position(for: file) != nil)

    // 位置在视图建起来那一刻回填：文档换了代数，账本里就该是这篇的旧位置。
    restored.store.positionMemory.startSession(generation: restored.store.renderGeneration)
    #expect(restored.store.positionMemory.editorPosition?.scrollOrigin.y == 42)
    #expect(restored.store.positionMemory.previewAnchor?.blockIndex == 2)
}

/// 窗口站回它上次站的地方，而且那个位置只能用一次——之后拖到哪儿由读者说了算。
@MainActor
@Test func restoredWindowsStandWhereTheyStood() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let first = desk.launch()
    let id = try #require(first.openNewWindow(inheriting: nil))
    let frame = CGRect(x: 200, y: 120, width: 900, height: 700)
    first.rememberFrame(frame, for: id)

    let second = desk.launch()

    #expect(second.windows[id] != nil)
    #expect(second.takePendingFrame(for: id) == frame)
    #expect(second.takePendingFrame(for: id) == nil)
}

/// 记下的位置落在了拔掉的那块屏上：窗还得回来，只是位置按新窗处理。
@MainActor
@Test func aWindowThatLandedOffScreenComesBackVisible() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let first = desk.launch()
    let id = try #require(first.openNewWindow(inheriting: nil))
    first.rememberFrame(CGRect(x: 9000, y: 4000, width: 900, height: 700), for: id)

    let second = desk.launch(screens: [CGRect(x: 0, y: 0, width: 1440, height: 900)])

    #expect(second.windows[id] != nil)
    #expect(second.takePendingFrame(for: id) == nil)
}

/// 每扇窗的桥都会来报到一次：重复报到不能把窗口开两遍。
@MainActor
@Test func reportingTheChannelTwiceDoesNotOpenTwice() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let first = desk.launch()
    let id = try #require(first.openNewWindow(inheriting: nil))
    #expect(first.ledger.ids == [id])
    first.rememberFrame(CGRect(x: 100, y: 100, width: 900, height: 700), for: id)

    let second = desk.launch()
    #expect(desk.opened.count == 1)

    second.attach { [weak desk] id in desk?.opened.append(id) }
    #expect(desk.opened.count == 1)
}

/// 打开过又什么都没写的窗，回来后是白纸——不是欢迎页。
@MainActor
@Test func anEmptyWindowComesBackBlank() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let first = desk.launch()
    let id = try #require(first.openNewWindow(inheriting: nil))

    let second = desk.launch()
    let restored = try #require(second.windows[id])

    #expect(restored.store.text.isEmpty)
    #expect(!restored.store.showsWelcome)
}

/// 同一篇被两条记录指着的旧账（升级前就开着两扇窗、或有人手工改过 defaults）：
/// 启动时只在先到的那扇里打开，后来的那扇退回白纸，并且不再记着这篇。
@MainActor
@Test func twoWindowsRecordedWithTheSameFileOnlyOneKeepsIt() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let folder = try desk.makeFolder(named: "书房")
    let file = folder.appendingPathComponent("a.md")
    try "# 同一篇\n\n谁也别写两遍\n".write(to: file, atomically: true, encoding: .utf8)

    let a = UUID()
    let b = UUID()
    let book = WindowLedger(defaults: desk.defaults)
    book.add(a)
    book.add(b)
    Session(window: a, defaults: desk.defaults).setOpenFile(file)
    Session(window: b, defaults: desk.defaults).setOpenFile(file)

    let coordinator = desk.launch()
    let aHasIt = coordinator.windows[a]?.store.fileURL != nil
    let bHasIt = coordinator.windows[b]?.store.fileURL != nil

    #expect(aHasIt != bHasIt, "同一篇只能落在其中一扇窗里")
    let yielded = aHasIt ? b : a
    let kept = try #require(coordinator.windows[yielded])
    #expect(kept.store.fileURL == nil)
    #expect(kept.store.text.isEmpty, "让出去的那扇是白纸，不是把同一篇复制一遍")
    #expect(
        Session(window: yielded, defaults: desk.defaults).openFileURL == nil,
        "让出去的那扇不该继续记着这篇，否则下次启动还要再分一次"
    )
}

// MARK: - 关窗即结束

/// 关掉一扇存过盘的窗：账、会话、草稿目录一起结束，重启不再回来。
@MainActor
@Test func closingAWindowEndsItsRecord() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let folder = try desk.makeFolder(named: "书房")
    let file = folder.appendingPathComponent("a.md")
    try "# 甲\n".write(to: file, atomically: true, encoding: .utf8)

    let first = desk.launch()
    let id = try #require(first.openNewWindow(inheriting: folder))
    let model = try #require(first.windows[id])
    model.store.open(url: file)

    first.windowDidClose(model)

    #expect(first.ledger.entry(for: id) == nil)
    #expect(Session(window: id, defaults: desk.defaults).openFileURL == nil)
    #expect(!FileManager.default.fileExists(atPath: desk.draftDirectory(of: id).path))

    let second = desk.launch()
    #expect(desk.opened.isEmpty)
    #expect(second.windows[id] == nil)
}

/// 无名稿不陪窗口一起消失：第一次关窗只留一手，下次启动把它放回原处。
/// 再关一次就真的关掉——第二次关窗意味着「我已经看见它了」。
@MainActor
@Test func anUnnamedDraftSurvivesOneClose() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let first = desk.launch()
    let id = try #require(first.openNewWindow(inheriting: nil))
    let store = try #require(first.windows[id]?.store)
    store.textDidChange("# 还没起名\n\n只有这一扇窗有")
    store.flushPendingSave()

    first.windowDidClose(try #require(first.windows[id]))

    #expect(first.ledger.entry(for: id)?.parked == true)
    #expect(first.windows[id] == nil)

    let second = desk.launch()
    #expect(desk.opened == [id])
    let restored = try #require(second.windows[id])
    #expect(restored.store.text.contains("只有这一扇窗有"))

    // 第二次关窗：这次是真的
    second.windowDidClose(restored)

    #expect(second.ledger.entry(for: id) == nil)
    #expect(!FileManager.default.fileExists(atPath: desk.draftDirectory(of: id).path))
    #expect(desk.launch().windows[id] == nil)
}

/// 主窗口的记录不受第二扇窗开关的影响。
@MainActor
@Test func closingAnExtraWindowLeavesThePrimarySessionAlone() throws {
    let desk = try Desk()
    defer { desk.cleanup() }

    let folder = try desk.makeFolder(named: "主桌的书房")
    let first = desk.launch()
    first.primary.workspace.open(folder)

    let id = try #require(first.openNewWindow(inheriting: nil))
    first.windowDidClose(try #require(first.windows[id]))

    #expect(first.primary.workspace.isOpen)
    #expect(Session(defaults: desk.defaults).workspaceURL.map { PathKey.isSame($0, folder) } == true)
}
