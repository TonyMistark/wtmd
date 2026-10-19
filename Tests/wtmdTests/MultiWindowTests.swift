import AppKit
import Foundation
import Testing

@testable import wtmd

// MARK: - 会话：一次性 vs 可恢复

/// 第二扇窗口的会话不读也不写：读会把主窗口的记录认成自己的，写会把它盖掉。
@MainActor
@Test func aTemporarySessionNeitherReadsNorWrites() throws {
    let name = "wtmd.tests.session.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    let stored = Session(defaults: defaults)
    stored.setWorkspace(URL(fileURLWithPath: "/tmp/room"))
    stored.setOpenFile(URL(fileURLWithPath: "/tmp/room/a.md"))

    let temporary = Session(persist: false, defaults: defaults)
    #expect(temporary.workspaceURL == nil)
    #expect(temporary.openFileURL == nil)

    temporary.setWorkspace(URL(fileURLWithPath: "/tmp/elsewhere"))
    temporary.setOpenFile(URL(fileURLWithPath: "/tmp/elsewhere/b.md"))

    // 落盘的还是主窗口那一份。
    let reread = Session(defaults: defaults)
    #expect(reread.workspaceURL?.path == "/tmp/room")
    #expect(reread.openFileURL?.path == "/tmp/room/a.md")
}

/// 可恢复的那一档照旧写盘——别把「临时」做成一种默认。
@MainActor
@Test func aPersistentSessionStillWrites() throws {
    let name = "wtmd.tests.session.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    Session(defaults: defaults).setWorkspace(URL(fileURLWithPath: "/tmp/room"))
    #expect(Session(defaults: defaults).workspaceURL?.path == "/tmp/room")
}

// MARK: - 两扇窗口

@MainActor
@Test func twoWindowsKeepTheirOwnDocuments() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let first = rig.newWindow()
    let second = rig.newWindow()

    first.store.textDidChange("# 第一篇\n\n第一张桌子")
    #expect(second.store.text.isEmpty)
    #expect(first.store.text.contains("第一张桌子"))
}

/// ⌘N 开出来的是一张白纸：不是欢迎页，也不是主窗口那篇。
@MainActor
@Test func aNewWindowStartsBlank() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let window = rig.newWindow()

    #expect(window.store.text.isEmpty)
    #expect(window.store.fileURL == nil)
    #expect(!window.store.showsWelcome)
}

/// 两扇窗口各写自己的 draft.md：写在同一处，谁最后落盘谁赢。
@MainActor
@Test func everyWindowContributesItsOwnDraftDirectory() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let first = rig.newWindow()
    let second = rig.newWindow()

    #expect(rig.draftDirectory(of: first) != rig.draftDirectory(of: second))
    first.store.textDidChange("只有这一扇窗的字")
    first.store.flushPendingSave()

    let firstDraft = try String(contentsOf: rig.draftDirectory(of: first).appendingPathComponent("draft.md"), encoding: .utf8)
    #expect(firstDraft.contains("只有这一扇窗的字"))
}

/// 新窗口接着用同一间书房，但打开的是自己的稿子。
@MainActor
@Test func aNewWindowCanBorrowTheFolderAndNothingElse() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let folder = try rig.makeFolder(named: "书房")
    try "# 别人的稿子\n".write(
        to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8
    )
    rig.primary.workspace.open(folder)

    let window = rig.newWindow(inheriting: rig.primary.workspace.root)

    #expect(window.workspace.root != nil)
    #expect(PathKey.isSame(try #require(window.workspace.root), folder))
    #expect(window.store.fileURL == nil)
    #expect(window.store.text.isEmpty)
}

/// 同一个文件夹、两扇窗、两篇不同的稿子：各开各的，谁也不把谁顶掉。
@MainActor
@Test func twoWindowsCanHoldDifferentFilesOfOneFolder() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let folder = try rig.makeFolder(named: "书房")
    let a = folder.appendingPathComponent("a.md")
    let b = folder.appendingPathComponent("b.md")
    try "# 甲\n".write(to: a, atomically: true, encoding: .utf8)
    try "# 乙\n".write(to: b, atomically: true, encoding: .utf8)

    let first = rig.newWindow(inheriting: folder)
    let second = rig.newWindow(inheriting: folder)
    first.store.open(url: a)
    second.store.open(url: b)

    #expect(PathKey.isSame(try #require(first.store.fileURL), a))
    #expect(PathKey.isSame(try #require(second.store.fileURL), b))
    #expect(first.store.text.contains("甲"))
    #expect(second.store.text.contains("乙"))
}

/// 主题、帐本、最近文件是「这个人怎么写字」，所有窗口一份。
@MainActor
@Test func windowsShareTheApplicationSettings() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let first = rig.newWindow()
    let second = rig.newWindow()

    #expect(first.store.themeManager === second.store.themeManager)
    #expect(first.shared === second.shared)
    #expect(first.store.recentFiles === second.store.recentFiles)
    #expect(first.store.writingStats === rig.shared.writingStats)
}

// MARK: - 命令落在哪扇窗

@MainActor
@Test func commandsFollowTheFocusedWindow() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let extra = rig.coordinator.makeExtraWindow(inheriting: nil)

    #expect(rig.coordinator.activeModel(focused: extra) === extra)
    #expect(rig.coordinator.activeModel(focused: nil) === rig.primary)
}

/// 前台窗口靠 `NSWindow` 身份认回来：菜单展开时焦点可能不在任何控件上。
@MainActor
@Test func theFrontWindowIsRecognisedByItsWindow() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let extra = rig.coordinator.makeExtraWindow(inheriting: nil)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    rig.coordinator.register(window: window, for: extra)

    #expect(rig.coordinator.model(for: window) === extra)
    #expect(rig.coordinator.activeModel(focused: nil) === rig.primary)
}

// MARK: - 开窗与关窗

/// 没有 `openWindow` 可用时（测试、无人值守的视图）不许留下半个窗口：
/// 调用方要能干脆地退回「在本窗口新建」。
@MainActor
@Test func openingAWindowWithoutAChannelChangesNothing() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    #expect(rig.coordinator.openNewWindow(inheriting: nil) == nil)
    #expect(rig.coordinator.windows.count == 1)
}

/// 窗口关掉就该结束：监听停掉，模型从表里划掉。
@MainActor
@Test func closingAWindowEndsIt() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let extra = rig.coordinator.makeExtraWindow(inheriting: nil)
    #expect(rig.coordinator.windows.count == 2)

    rig.coordinator.windowDidClose(extra)
    #expect(rig.coordinator.windows.count == 1)
}

/// 主窗口不在清理之列：它的会话要留给下次启动，`workspace.close()` 会把
/// 「上次打开的文件夹」一并抹掉。
@MainActor
@Test func closingThePrimaryWindowKeepsItsSession() throws {
    let rig = try WindowRig()
    defer { rig.cleanup() }

    let folder = try rig.makeFolder(named: "留着")
    rig.primary.workspace.open(folder)

    rig.coordinator.windowDidClose(rig.primary)

    #expect(rig.coordinator.windows.count == 1)
    #expect(rig.primary.workspace.isOpen)
}

// MARK: - 装配

/// 一个只在测试里存在的窗口装配：临时会话、临时草稿目录、临时冲突库。
@MainActor
private struct WindowRig {
    let defaults: UserDefaults
    let defaultsName: String
    let root: URL
    let shared: SharedAppEnvironment
    let coordinator: WindowCoordinator

    var primary: WindowModel { coordinator.primary }

    init() throws {
        defaultsName = "wtmd.tests.windows.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        shared = SharedAppEnvironment(
            writingStats: WritingStats(defaults: defaults),
            recentFiles: RecentFiles(userDefaults: defaults),
            conflicts: ConflictArchive(directory: root.appendingPathComponent("conflicts"))
        )
        coordinator = WindowCoordinator(
            shared: shared,
            primary: WindowModel(
                session: Session(persist: false, defaults: defaults),
                shared: shared,
                draftDirectory: root.appendingPathComponent("primary", isDirectory: true),
                startsBlank: true
            ),
            draftRoot: root,
            // 账本和每扇窗的会话都写在这个临时 suite 里：测试不该碰真实记录。
            defaults: defaults
        )
    }

    /// 造一扇「⌘N 开的」窗口，但不真的开窗——`openWindow` 只在运行中的 App 里有。
    func newWindow(inheriting folder: URL? = nil) -> WindowModel {
        coordinator.makeExtraWindow(inheriting: folder)
    }

    func draftDirectory(of model: WindowModel) -> URL {
        WindowCoordinator.temporaryDraftDirectory(for: model.id, root: root)
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
