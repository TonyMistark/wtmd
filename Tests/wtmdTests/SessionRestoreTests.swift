import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 启动恢复

/// 会话恢复的全部用例都注入独立的 defaults suite 与临时目录：
/// 一次「恢复」写错路径，下一次启动就会把用户带到别处去。
private func makeHarness() -> (session: Session, suite: String, root: URL) {
    let suite = "wtmd.tests.restore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-restore-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (Session(defaults: defaults), suite, root)
}

private func cleanup(_ harness: (session: Session, suite: String, root: URL)) {
    UserDefaults(suiteName: harness.suite)?.removePersistentDomain(forName: harness.suite)
    try? FileManager.default.removeItem(at: harness.root)
}

/// `open(url:)` 会写「最近文件」，用完把原值放回去，避免测试污染真实偏好设置。
private func preserveRecentFiles() -> () -> Void {
    let key = "wtmd.recentFiles"
    let original = UserDefaults.standard.stringArray(forKey: key)
    return {
        if let original { UserDefaults.standard.set(original, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

@MainActor
@Test func launchRestoresTheOpenFile() throws {
    let harness = makeHarness()
    defer { cleanup(harness) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = harness.root.appendingPathComponent("第一章.md")
    try "# 上次写到一半\n\n正文。".write(to: file, atomically: true, encoding: .utf8)
    harness.session.setOpenFile(file)

    let store = DocumentStore(draftDirectory: harness.root, session: harness.session)

    #expect(store.fileURL == file)
    #expect(store.text == "# 上次写到一半\n\n正文。")
    #expect(!store.showsWelcome)
    // 恢复出来的是磁盘上的内容，不该被当成「待保存的修改」
    #expect(!store.isDirty)
}

/// 文件在两次启动之间被删了：回到草稿，并且把会话里那条指向死路径的记录清掉，
/// 否则每次启动都要白试一次。
@MainActor
@Test func launchFallsBackToTheDraftWhenTheFileIsGone() throws {
    let harness = makeHarness()
    defer { cleanup(harness) }

    let gone = harness.root.appendingPathComponent("已删除.md")
    try "未命名的思绪".write(
        to: harness.root.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8
    )
    harness.session.setOpenFile(gone)

    let store = DocumentStore(draftDirectory: harness.root, session: harness.session)

    #expect(store.fileURL == nil)
    #expect(store.text == "未命名的思绪")
    #expect(harness.session.openFileURL == nil)
}

/// 会话里有窗口布局之外的「当前文件」：新建文档之后不能还指着上一篇，
/// 否则下次启动会打开读者明确清空过的那个文件。
@MainActor
@Test func newDocumentLeavesNoOpenFileBehind() throws {
    let harness = makeHarness()
    defer { cleanup(harness) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = harness.root.appendingPathComponent("旧文.md")
    try "旧文".write(to: file, atomically: true, encoding: .utf8)

    let store = DocumentStore(draftDirectory: harness.root, session: harness.session)
    store.open(url: file)
    #expect(harness.session.openFileURL == file)

    store.newDocument()
    #expect(harness.session.openFileURL == nil)
}

/// 每篇文档各记各的位置：在文件树里点来点去，回到某一篇应该回到当时读到的地方。
@MainActor
@Test func switchingDocumentsRemembersEachPosition() throws {
    let harness = makeHarness()
    defer { cleanup(harness) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let first = harness.root.appendingPathComponent("甲.md")
    let second = harness.root.appendingPathComponent("乙.md")
    try String(repeating: "甲的行\n", count: 80).write(to: first, atomically: true, encoding: .utf8)
    try "乙".write(to: second, atomically: true, encoding: .utf8)

    let store = DocumentStore(draftDirectory: harness.root, session: harness.session)
    store.open(url: first)

    // 模拟编辑器回报的位置（真实路径由 Coordinator 每帧写进账本）
    store.positionMemory.recordEditorPosition(
        PositionMemory.EditorPosition(
            selection: NSRange(location: 120, length: 0),
            scrollOrigin: CGPoint(x: 0, y: 300)
        )
    )
    store.positionMemory.recordPreviewAnchor(
        PositionMemory.PreviewAnchor(blockIndex: 2, offset: -40)
    )

    // 切到另一篇：旧的那篇应该先落盘
    store.open(url: second)

    let recorded = try #require(harness.session.position(for: first))
    #expect(recorded.selectionLocation == 120)
    #expect(recorded.scrollY == 300)
    #expect(recorded.blockIndex == 2)
    #expect(recorded.blockOffset == -40)
    #expect(harness.session.position(for: second) == nil)
}

@MainActor
@Test func reopeningAFileSeedsItsRememberedPosition() throws {
    let harness = makeHarness()
    defer { cleanup(harness) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let first = harness.root.appendingPathComponent("甲.md")
    let second = harness.root.appendingPathComponent("乙.md")
    try "甲".write(to: first, atomically: true, encoding: .utf8)
    try "乙".write(to: second, atomically: true, encoding: .utf8)

    let store = DocumentStore(draftDirectory: harness.root, session: harness.session)
    store.open(url: first)
    store.positionMemory.recordEditorPosition(
        PositionMemory.EditorPosition(
            selection: NSRange(location: 0, length: 0),
            scrollOrigin: CGPoint(x: 0, y: 210)
        )
    )
    store.open(url: second)

    store.open(url: first)
    // 视图建起来时会 startSession(generation:)，种子在那时才生效
    store.positionMemory.startSession(generation: store.renderGeneration)

    #expect(store.positionMemory.editorPosition?.scrollOrigin.y == 210)
}

/// 退出时排队中的编辑要落盘，位置也要跟着落盘——两条都靠同一个通知。
@MainActor
@Test func quittingRecordsThePosition() async throws {
    let harness = makeHarness()
    defer { cleanup(harness) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = harness.root.appendingPathComponent("甲.md")
    try "甲".write(to: file, atomically: true, encoding: .utf8)

    let store = DocumentStore(
        draftDirectory: harness.root, autoSaveDelay: 10_000_000_000, session: harness.session
    )
    store.open(url: file)
    store.textDidChange("甲\n补一句")
    store.positionMemory.recordEditorPosition(
        PositionMemory.EditorPosition(
            selection: NSRange(location: 3, length: 0),
            scrollOrigin: CGPoint(x: 0, y: 15)
        )
    )

    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

    // 通知是同步派发的，落盘也在同一个调用栈里完成
    let saved = try String(contentsOf: file, encoding: .utf8)
    #expect(saved == "甲\n补一句")
    let recorded = try #require(harness.session.position(for: file))
    #expect(recorded.selectionLocation == 3)
}

// MARK: - 工作区

@MainActor
@Test func workspaceSurvivesRelaunchWithItsExpandedFolders() throws {
    let harness = makeHarness()
    defer { cleanup(harness) }

    let chapter = harness.root.appendingPathComponent("第一卷", isDirectory: true)
    try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
    try "# 一".write(
        to: chapter.appendingPathComponent("一.md"), atomically: true, encoding: .utf8
    )

    let first = WorkspaceStore(session: harness.session)
    first.open(harness.root)
    first.setExpanded(chapter, to: true)
    #expect(harness.session.workspaceURL?.path == harness.root.path)

    // 下一次启动
    let second = WorkspaceStore(session: harness.session)
    #expect(second.isOpen)
    #expect(second.root?.path == harness.root.path)
    #expect(second.isExpanded(chapter))
}

/// 路径没了（移动硬盘拔掉、文件夹被删）：安静地回到「没有工作区」，
/// 不要拿一个错误弹窗迎接刚打开应用的人。
@MainActor
@Test func missingWorkspaceIsForgotten() throws {
    let harness = makeHarness()
    defer { cleanup(harness) }

    harness.session.setWorkspace(harness.root.appendingPathComponent("不存在的目录"))

    let store = WorkspaceStore(session: harness.session)

    #expect(!store.isOpen)
    #expect(harness.session.workspaceURL == nil)
}

@MainActor
@Test func closingTheWorkspaceClearsTheSession() throws {
    let harness = makeHarness()
    defer { cleanup(harness) }

    let store = WorkspaceStore(session: harness.session)
    store.open(harness.root)
    store.close()

    #expect(harness.session.workspaceURL == nil)
    #expect(harness.session.expandedPaths.isEmpty)
}
