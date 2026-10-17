import Foundation
import Testing
@testable import wtmd

// MARK: - 改名

/// 改名没有改变任何一个字符：文本、脏标记、渲染代数都不该动——
/// 重渲染会把读者的滚动位置和光标一起吞掉。
@MainActor
@Test func renamingTheOpenFileKeepsEverythingButThePath() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("a.md", in: dir, content: "# 原文")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: file)
    store.textDidChange("# 原文\n\n改过的一句")
    let generation = store.renderGeneration

    let renamed = dir.appendingPathComponent("第一章.md")
    try FileManager.default.moveItem(at: file, to: renamed)
    store.documentDidMove(from: file, to: renamed)

    #expect(store.fileURL?.standardizedFileURL.path == renamed.standardizedFileURL.path)
    #expect(store.text == "# 原文\n\n改过的一句")
    #expect(store.isDirty)
    #expect(store.renderGeneration == generation)

    // 基线刷到了新路径：下一次写盘不该被误判成「磁盘被别人改过」
    store.flushPendingSave()
    #expect(try String(contentsOf: renamed, encoding: .utf8) == "# 原文\n\n改过的一句")
    #expect(!store.isDirty)
}

/// 改的是它所在的目录：文件路径按同一段后缀跟过去。
@MainActor
@Test func renamingTheFolderAboveTheOpenFileFollows() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let drafts = dir.appendingPathComponent("drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
    let file = try write("a.md", in: drafts, content: "# 在草稿里")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: file)

    let renamedFolder = dir.appendingPathComponent("草稿", isDirectory: true)
    try FileManager.default.moveItem(at: drafts, to: renamedFolder)
    store.documentDidMove(from: drafts, to: renamedFolder)

    #expect(store.fileURL?.standardizedFileURL.path
        == renamedFolder.appendingPathComponent("a.md").standardizedFileURL.path)
    #expect(store.text == "# 在草稿里")
    #expect(!store.isDirty)
}

@MainActor
@Test func renamingAnotherFileLeavesTheOpenDocumentAlone() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let open = try write("a.md", in: dir, content: "A")
    let other = try write("b.md", in: dir, content: "B")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: open)

    let renamed = dir.appendingPathComponent("b-改.md")
    store.documentDidMove(from: other, to: renamed)

    #expect(store.fileURL?.standardizedFileURL.path == open.standardizedFileURL.path)
    #expect(store.text == "A")
}

// MARK: - 删除

/// 当前这一篇被删掉：字留在编辑器里，文档转成未命名草稿。
/// **绝不先 flush**——那等于把内容写回一个刚被丢掉的文件，在废纸篓里复活一份。
@MainActor
@Test func trashingTheOpenFileKeepsTheTextAsADraft() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("a.md", in: dir, content: "# 原文")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: file)
    store.textDidChange("# 原文\n\n删掉之前写的最后一句")

    try FileManager.default.removeItem(at: file)
    store.documentWasTrashed(at: file)

    #expect(store.fileURL == nil)
    #expect(store.text == "# 原文\n\n删掉之前写的最后一句")
    #expect(store.isDirty)
    // 草稿盘上已经有一份：⌘Q 之后还在
    let draft = dir.appendingPathComponent("draft.md")
    #expect(try String(contentsOf: draft, encoding: .utf8) == "# 原文\n\n删掉之前写的最后一句")

    store.flushPendingSave()
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@MainActor
@Test func trashingAnotherFileLeavesTheOpenDocumentAlone() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let open = try write("a.md", in: dir, content: "A")
    let other = try write("b.md", in: dir, content: "B")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: open)

    try FileManager.default.removeItem(at: other)
    store.documentWasTrashed(at: other)

    #expect(store.fileURL?.standardizedFileURL.path == open.standardizedFileURL.path)
    #expect(store.text == "A")
}

// MARK: - 辅助

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-follow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ name: String, in directory: URL, content: String = "# 文档") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}
