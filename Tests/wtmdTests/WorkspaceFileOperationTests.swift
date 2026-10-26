import Foundation
import Testing
@testable import wtmd

/// 记录「工作区通知了文档层什么」。
@MainActor
private final class Recorder: WorkspaceFileEvents {
    var moves: [(from: URL, to: URL)] = []
    var trashed: [URL] = []

    func documentDidMove(from old: URL, to new: URL) {
        moves.append((old, new))
    }

    func documentWasTrashed(at url: URL) {
        trashed.append(url)
    }
}

// MARK: - 新建

@MainActor
@Test func creatingADocumentSelectsItAndAsksForAName() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)

    let url = try #require(workspace.createDocument())

    #expect(workspace.tree?.children.map(\.name) == ["未命名.md"])
    #expect(workspace.selection == url)
    // 新建的下一步永远是起名字：界面拿到这个值就把那一行变成输入框
    #expect(workspace.pendingRename == url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@MainActor
@Test func creatingInsideACollapsedFolderExpandsIt() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = try makeDirectory("drafts", in: root)
    try write("a.md", in: drafts)

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    #expect(!workspace.isExpanded(drafts))

    let url = try #require(workspace.createDocument(in: drafts))

    #expect(workspace.isExpanded(drafts))
    #expect(url.deletingLastPathComponent().standardizedFileURL.path
        == drafts.standardizedFileURL.path)
}

@MainActor
@Test func aNewFolderStaysVisibleInTheTree() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)

    let url = try #require(workspace.createFolder())

    #expect(workspace.tree?.children.map(\.name) == ["新建文件夹"])
    #expect(workspace.tree?.children.first?.url.standardizedFileURL.path
        == url.standardizedFileURL.path)
}

// MARK: - 改名

@MainActor
@Test func renamingAFileRemapsSelectionAndTellsTheDocumentLayer() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root)
    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    workspace.select(file)
    let recorder = Recorder()
    workspace.fileEvents = recorder

    #expect(workspace.rename(file, to: "第一章") == nil)

    let renamed = root.appendingPathComponent("第一章.md")
    #expect(workspace.selection?.standardizedFileURL.path == renamed.standardizedFileURL.path)
    #expect(recorder.moves.count == 1)
    #expect(recorder.moves.first?.to.standardizedFileURL.path == renamed.standardizedFileURL.path)
    #expect(workspace.tree?.children.map(\.name) == ["第一章.md"])
}

/// 改名一个目录，展开状态、高亮、会话里的路径都要跟着搬——漏一条，
/// 下次启动就会去开一个已经不存在的路径。
@MainActor
@Test func renamingAFolderRemapsExpandedPathsAndSession() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = try makeDirectory("drafts", in: root)
    let inner = try makeDirectory("inner", in: drafts)
    let file = try write("a.md", in: inner)

    let (session, suite) = makeIsolatedSession()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    let workspace = WorkspaceStore(session: session)
    defer { workspace.close() }
    workspace.open(root)
    workspace.reveal(file)
    session.setOpenFile(file)
    session.record(
        Session.Position(
            selectionLocation: 3, selectionLength: 0,
            scrollX: 0, scrollY: 12, blockIndex: 0, blockOffset: 0, modifiedAt: nil
        ),
        for: file
    )

    #expect(workspace.rename(drafts, to: "草稿") == nil)

    let renamedDrafts = root.appendingPathComponent("草稿")
    let renamedFile = renamedDrafts
        .appendingPathComponent("inner")
        .appendingPathComponent("a.md")
    #expect(workspace.isExpanded(renamedDrafts))
    #expect(workspace.isExpanded(renamedDrafts.appendingPathComponent("inner")))
    #expect(workspace.selection?.standardizedFileURL.path == renamedFile.standardizedFileURL.path)
    #expect(session.openFileURL?.standardizedFileURL.path == renamedFile.standardizedFileURL.path)
    #expect(session.position(for: renamedFile)?.scrollY == 12)
    #expect(session.position(for: file) == nil)
}

@MainActor
@Test func aRejectedRenameLeavesTheTreeAndDiskAlone() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try write("a.md", in: root, content: "A")
    let b = try write("b.md", in: root, content: "B")
    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    workspace.select(a)
    let recorder = Recorder()
    workspace.fileEvents = recorder

    let error = workspace.rename(a, to: "b")

    #expect(error == .alreadyExists("b.md"))
    #expect(workspace.selection?.standardizedFileURL.path == a.standardizedFileURL.path)
    #expect(workspace.tree?.children.map(\.name) == ["a.md", "b.md"])
    #expect(recorder.moves.isEmpty)
    #expect(try String(contentsOf: a, encoding: .utf8) == "A")
}

// MARK: - 辅助

private func makeIsolatedSession() -> (Session, String) {
    let suite = "wtmd.tests.fileops.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (Session(defaults: defaults), suite)
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-fileops-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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
