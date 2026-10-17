import Foundation
import Testing
import UniformTypeIdentifiers
@testable import wtmd

// MARK: - 纯函数：移动

/// 移动不改名：名字是读者给这份稿子起的，换个抽屉不该顺手改掉。
@Test func movingAFileIntoAFolderKeepsItsNameAndContent() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("第一章.md", in: root, content: "# 第一章")
    let archive = try makeDirectory("archive", in: root)

    let moved = try WorkspaceFiles.move(file, into: archive)

    #expect(moved.lastPathComponent == "第一章.md")
    #expect(moved.deletingLastPathComponent().standardizedFileURL.path
        == archive.standardizedFileURL.path)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try String(contentsOf: moved, encoding: .utf8) == "# 第一章")
}

@Test func movingAFolderTakesItsSubtreeAlong() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = try makeDirectory("drafts", in: root)
    let inner = try makeDirectory("inner", in: drafts)
    try write("a.md", in: inner)
    let archive = try makeDirectory("archive", in: root)

    let moved = try WorkspaceFiles.move(drafts, into: archive)

    #expect(moved.lastPathComponent == "drafts")
    #expect(FileManager.default.fileExists(
        atPath: moved.appendingPathComponent("inner/a.md").path
    ))
    #expect(!FileManager.default.fileExists(atPath: drafts.path))
}

/// 拖拽是容易手滑的手势，手滑不该有删除的后果：重名就报错，两边都不动。
@Test func movingOntoAnExistingNameIsRejected() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("第一章.md", in: root, content: "新的")
    let archive = try makeDirectory("archive", in: root)
    let existing = try write("第一章.md", in: archive, content: "旧的")

    #expect(throws: FileOperationError.alreadyExists("第一章.md")) {
        try WorkspaceFiles.move(file, into: archive)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "新的")
    #expect(try String(contentsOf: existing, encoding: .utf8) == "旧的")
}

/// 把文件夹拖进它自己或自己的子孙，会把整棵子树从树上摘下来。
@Test func movingAFolderIntoItselfIsRejected() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = try makeDirectory("drafts", in: root)
    let inner = try makeDirectory("inner", in: drafts)

    #expect(throws: FileOperationError.moveIntoItself("drafts")) {
        try WorkspaceFiles.move(drafts, into: drafts)
    }
    #expect(throws: FileOperationError.moveIntoItself("drafts")) {
        try WorkspaceFiles.move(drafts, into: inner)
    }
    #expect(FileManager.default.fileExists(atPath: inner.path))
}

/// 落点就是原来的父目录 = 什么都没发生。这条守着「同目录拖放不要报错」。
@Test func droppingAnItemOnItsOwnFolderChangesNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root)

    let moved = try WorkspaceFiles.move(file, into: root)

    #expect(PathKey.isSame(moved, file))
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func movingIntoSomethingThatIsNotAFolderIsRejected() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root, content: "A")
    let other = try write("b.md", in: root, content: "B")

    #expect(throws: FileOperationError.notADirectory("b.md")) {
        try WorkspaceFiles.move(file, into: other)
    }
    #expect(try String(contentsOf: other, encoding: .utf8) == "B")
}

// MARK: - 拖拽载荷

/// 载荷只带路径，而且只认自己这一种类型——访达拖进来的文件一概不接。
@Test func theDragPayloadCarriesThePathAndRefusesForeignTypes() throws {
    let url = URL(fileURLWithPath: "/tmp/书房/第一章.md")

    let roundTripped = try #require(WorkspaceDrag.url(fromPayload: WorkspaceDrag.payload(for: url)))
    #expect(roundTripped.path == url.path)
    #expect(WorkspaceDrag.url(fromPayload: Data()) == nil)

    let provider = WorkspaceDrag.provider(for: url)
    #expect(provider.hasItemConformingToTypeIdentifier(WorkspaceDrag.type.identifier))
    // 拖拽会真的改磁盘：从访达误拖一堆文件进来不该被接受
    #expect(!provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
}

// MARK: - 工作区：移动后的状态迁移

@MainActor
private final class MoveRecorder: WorkspaceFileEvents {
    var moves: [(from: URL, to: URL)] = []
    var trashed: [URL] = []

    func documentDidMove(from old: URL, to new: URL) {
        moves.append((old, new))
    }

    func documentWasTrashed(at url: URL) {
        trashed.append(url)
    }
}

@MainActor
@Test func movingAFileRemapsSelectionAndTellsTheDocumentLayer() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try makeDirectory("archive", in: root)
    try write("旧的.md", in: archive)
    let file = try write("第一章.md", in: root)

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    workspace.select(file)
    let recorder = MoveRecorder()
    workspace.fileEvents = recorder

    #expect(workspace.move(file, into: archive) == nil)

    let moved = archive.appendingPathComponent("第一章.md")
    #expect(workspace.selection?.standardizedFileURL.path == moved.standardizedFileURL.path)
    #expect(recorder.moves.count == 1)
    #expect(recorder.moves.first?.to.standardizedFileURL.path == moved.standardizedFileURL.path)
    let names = workspace.tree?.children.first { $0.name == "archive" }?.children.map(\.name) ?? []
    #expect(names.count == 2)
    #expect(names.contains("第一章.md"))
    #expect(names.contains("旧的.md"))
}

/// 东西移进去了但看不见，和丢了没区别：落点目录必须展开。
@MainActor
@Test func movingIntoACollapsedFolderExpandsIt() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try makeDirectory("archive", in: root)
    try write("旧的.md", in: archive)
    let file = try write("第一章.md", in: root)

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    #expect(!workspace.isExpanded(archive))

    #expect(workspace.move(file, into: archive) == nil)

    #expect(workspace.isExpanded(archive))
}

@MainActor
@Test func aRejectedMoveLeavesTheTreeAndDiskAlone() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try makeDirectory("archive", in: root)
    let occupied = try write("第一章.md", in: archive, content: "旧的")
    let file = try write("第一章.md", in: root, content: "新的")

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    let recorder = MoveRecorder()
    workspace.fileEvents = recorder

    #expect(workspace.move(file, into: archive) == .alreadyExists("第一章.md"))

    #expect(workspace.tree?.children.map(\.name) == ["archive", "第一章.md"])
    #expect(recorder.moves.isEmpty)
    #expect(try String(contentsOf: file, encoding: .utf8) == "新的")
    #expect(try String(contentsOf: occupied, encoding: .utf8) == "旧的")
}

/// 同一目录内的空拖拽不产生任何通知——否则监听方会以为文档换了位置。
@MainActor
@Test func droppingOnTheSameFolderNotifiesNobody() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root)

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    let recorder = MoveRecorder()
    workspace.fileEvents = recorder

    #expect(workspace.move(file, into: root) == nil)
    #expect(recorder.moves.isEmpty)
}

/// 拖到工作区根上 = 从子目录提回顶层。顺带守一条边界：展开状态里不能混进
/// 工作区**外面**的目录（祖先链走多一步就会这样）。
@MainActor
@Test func droppingOnTheRootBringsTheItemBackToTheTopLevel() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = try makeDirectory("drafts", in: root)
    let file = try write("a.md", in: drafts)
    try write("keep.md", in: drafts)

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.open(root)
    workspace.setExpanded(drafts, to: true)

    #expect(workspace.move(file, into: root) == nil)

    #expect(workspace.tree?.children.map(\.name) == ["drafts", "a.md"])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.md").path))
    #expect(!workspace.expandedPaths.contains(root.deletingLastPathComponent().path))
}

// MARK: - 辅助

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-move-\(UUID().uuidString)", isDirectory: true)
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
