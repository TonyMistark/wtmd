import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 扫描器

/// 工作区只认识 Markdown：其余格式、隐藏文件都不该出现在树里。
@Test func scannerKeepsOnlyMarkdown() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root)
    try write("b.markdown", in: root)
    try write("c.txt", in: root)
    try write("d.pdf", in: root)
    try write(".hidden.md", in: root)

    let node = try #require(WorkspaceScanner.scan(root: root))
    #expect(node.children.map(\.name) == ["a.md", "b.markdown"])
}

/// 空目录要留一行：v0.7 起树里能新建文件夹，建完当场消失等于没建成。
/// 只装非 Markdown 文件的目录仍然不进树 —— 它们只会让写作现场变吵。
@Test func scannerShowsEmptyFoldersButDropsFoldersOfOtherFiles() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try makeDirectory("空目录", in: root)
    let textOnly = try makeDirectory("只有文本", in: root)
    try write("note.txt", in: textOnly)
    try write("readme.md", in: root)

    let node = try #require(WorkspaceScanner.scan(root: root))
    #expect(node.children.map(\.name) == ["空目录", "readme.md"])
}

/// 依赖与构建产物不进树：一个 `node_modules` 就能把每篇笔记埋掉。
@Test func scannerSkipsNoiseDirectories() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let modules = try makeDirectory("node_modules", in: root)
    try write("readme.md", in: modules)
    let build = try makeDirectory(".build", in: root)
    try write("artifact.md", in: build)
    try write("note.md", in: root)

    let node = try #require(WorkspaceScanner.scan(root: root))
    #expect(node.children.map(\.name) == ["note.md"])
}

/// 目录在前，同类按 Finder 的自然顺序（doc2 在 doc10 之前）。
@Test func scannerNestsFoldersAndSortsThemFirst() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("doc10.md", in: root)
    try write("doc2.md", in: root)
    let sub = try makeDirectory("notes", in: root)
    try write("inner.md", in: sub)

    let node = try #require(WorkspaceScanner.scan(root: root))
    #expect(node.children.map(\.name) == ["notes", "doc2.md", "doc10.md"])
    #expect(node.children.first?.children.map(\.name) == ["inner.md"])
}

@Test func scannerReturnsNilWhenRootIsNotADirectory() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("only.md", in: dir)

    #expect(WorkspaceScanner.scan(root: file) == nil)
    #expect(WorkspaceScanner.scan(root: dir.appendingPathComponent("does-not-exist")) == nil)
}

// MARK: - 工作区状态

@MainActor
@Test func openingAWorkspaceBuildsTheTree() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root)

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)

    #expect(workspace.isOpen)
    #expect(workspace.rootName == root.lastPathComponent)
    #expect(workspace.tree?.children.map(\.name) == ["a.md"])
}

/// 外部（Finder）新建的文件，重扫后必须出现。
@MainActor
@Test func reloadPicksUpFilesCreatedOutside() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    #expect(workspace.tree?.children.isEmpty == true)

    try write("新写的.md", in: root)
    workspace.reload()

    #expect(workspace.tree?.children.map(\.name) == ["新写的.md"])
}

/// 从别处（⌘O、最近文件）打开工作区内的文件时，树要展开到它并高亮。
@MainActor
@Test func revealExpandsAncestorsAndHighlights() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = try makeDirectory("drafts", in: root)
    let file = try write("a.md", in: drafts)

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    #expect(!workspace.isExpanded(drafts))

    workspace.reveal(file)

    #expect(workspace.isExpanded(drafts))
    #expect(workspace.selection == file)
}

@MainActor
@Test func revealIgnoresFilesOutsideTheWorkspace() throws {
    let root = try makeTempDirectory()
    let outside = try makeTempDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let stranger = try write("stranger.md", in: outside)

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)

    workspace.reveal(stranger)

    #expect(workspace.selection == nil)
}

/// 被删除的文件不能继续高亮。
@MainActor
@Test func reloadForgetsSelectionThatNoLongerExists() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root)

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    workspace.select(file)

    try FileManager.default.removeItem(at: file)
    workspace.reload()

    #expect(workspace.selection == nil)
    #expect(workspace.tree?.children.isEmpty == true)
}

@MainActor
@Test func closingResetsEverything() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root)
    let workspace = WorkspaceStore()
    workspace.open(root)
    workspace.select(file)

    workspace.close()

    #expect(!workspace.isOpen)
    #expect(workspace.tree == nil)
    #expect(workspace.selection == nil)
    #expect(workspace.expandedPaths.isEmpty)
}

// MARK: - 自动保存（文件夹工作区的前置行为）

/// 文件模式下的编辑要自己落盘：在工作区里点来点去时，没人会记得按 ⌘S。
@MainActor
@Test func editingAFileAutosavesAfterDebounce() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("doc.md", in: dir, content: "# 初稿")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 30_000_000)
    store.open(url: file)
    store.textDidChange("# 初稿\n\n补了一行")

    await waitUntil("编辑落盘") {
        (try? String(contentsOf: file, encoding: .utf8)) == "# 初稿\n\n补了一行"
    }
    #expect(!store.isDirty)
}

/// 未命名文档仍然写草稿（v0.2 行为不变）。
@MainActor
@Test func editingAnUntitledDocumentAutosavesDraft() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 30_000_000)
    store.newDocument()
    store.textDidChange("未命名的思绪")

    let draft = dir.appendingPathComponent("draft.md")
    await waitUntil("草稿落盘") {
        (try? String(contentsOf: draft, encoding: .utf8)) == "未命名的思绪"
    }
}

/// 关键回归：防抖窗口内切换文档，前一篇的修改不能丢。
///
/// 自动保存的防抖间隔被刻意设得极长，这样只有「切换前立即落盘」这一条路径
/// 能救回内容；把 `flushPendingSave()` 摘掉，这条用例就会变红。
@MainActor
@Test func switchingDocumentsFlushesPendingEdit() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = try write("a.md", in: dir, content: "A 原文")
    let second = try write("b.md", in: dir, content: "B 原文")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: first)
    store.textDidChange("A 改过了")
    store.open(url: second)

    #expect(try String(contentsOf: first, encoding: .utf8) == "A 改过了")
    #expect(store.text == "B 原文")
    #expect(store.fileURL == second)
}

/// 新建文档同样要走一次落盘，否则「刚写两句就按 ⌘N」会丢内容。
@MainActor
@Test func newDocumentFlushesPendingEdit() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("a.md", in: dir, content: "A 原文")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: file)
    store.textDidChange("A 改过了")
    store.newDocument()

    #expect(try String(contentsOf: file, encoding: .utf8) == "A 改过了")
}

/// 点击树里已经打开的那个文件，不该重载文档（会吞掉预览滚动位置）。
@MainActor
@Test func reopeningTheSameFileIsIgnored() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("a.md", in: dir, content: "A 原文")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: file)
    store.textDidChange("A 改过了")
    let generation = store.renderGeneration

    store.open(url: file)

    #expect(store.text == "A 改过了")
    #expect(store.renderGeneration == generation)
}

// MARK: - 收尾落盘（退出 / 关窗）

/// 退出应用时的最后一笔不能丢：⌘Q 会连同防抖任务一起把进程带走。
///
/// 摘掉 `observeExitForPendingEdits()`，这条与下一条都会变红。
@MainActor
@Test func quittingTheAppFlushesPendingEdit() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("a.md", in: dir, content: "A 原文")

    // 防抖设得极长：只有「退出时落盘」这一条路径能救回内容。
    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: file)
    store.textDidChange("退出前刚写的一句")

    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

    await waitUntil("退出时落盘") {
        (try? String(contentsOf: file, encoding: .utf8)) == "退出前刚写的一句"
    }
    #expect(!store.isDirty)
}

/// 关掉窗口同理会带走防抖任务（应用可能仍驻留在菜单栏）。
@MainActor
@Test func closingAWindowFlushesPendingEdit() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("a.md", in: dir, content: "A 原文")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: file)
    store.textDidChange("关窗前刚写的一句")

    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nil)

    await waitUntil("关窗时落盘") {
        (try? String(contentsOf: file, encoding: .utf8)) == "关窗前刚写的一句"
    }
}

// MARK: - 辅助

/// 轮询等待条件成立，而不是睡一个固定时长。
///
/// 自动保存的防抖跑在主 actor 的 `Task` 上，而同批次里的 WebKit 端到端用例会
/// 长时间占住主 actor —— 固定等待就是赌主 actor 恰好空闲，轮询不是。
@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 15,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("等待超时（\(Int(timeout))s）：\(description)")
}

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-workspace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func makeDirectory(_ name: String, in parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ name: String, in directory: URL, content: String = "# 文档") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}
