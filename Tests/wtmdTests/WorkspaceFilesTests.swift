import Foundation
import Testing
@testable import wtmd

// MARK: - 新建

/// 连按两次「新建」，第二篇不能把第一篇吃掉。
@Test func creatingDocumentsNumbersInsteadOfOverwriting() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try WorkspaceFiles.createDocument(in: root)
    let second = try WorkspaceFiles.createDocument(in: root)

    #expect(first.lastPathComponent == "未命名.md")
    #expect(second.lastPathComponent == "未命名 2.md")
    #expect(try String(contentsOf: first, encoding: .utf8).isEmpty)
    #expect(try String(contentsOf: second, encoding: .utf8).isEmpty)
}

@Test func creatingFoldersNumbersToo() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try WorkspaceFiles.createFolder(in: root)
    let second = try WorkspaceFiles.createFolder(in: root)

    #expect(first.lastPathComponent == "新建文件夹")
    #expect(second.lastPathComponent == "新建文件夹 2")
    #expect(WorkspaceScanner.isDirectory(first))
    #expect(WorkspaceScanner.isDirectory(second))
}

// MARK: - 改名

@Test func renamingKeepsTheExtensionAndTheContent() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root, content: "# 原文")

    let renamed = try WorkspaceFiles.rename(file, to: "第一章")

    #expect(renamed.lastPathComponent == "第一章.md")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try String(contentsOf: renamed, encoding: .utf8) == "# 原文")
}

/// 读者顺手写了个别的后缀也不换身份：真改成 `.txt`，这篇文档当场从树里消失。
@Test func renamingWithAnotherExtensionStillKeepsMarkdown() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root)

    let renamed = try WorkspaceFiles.rename(file, to: "note.txt")

    #expect(renamed.lastPathComponent == "note.md")
}

@Test func renamingRejectsNamesThatCannotBeFileNames() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root)

    #expect(throws: FileOperationError.emptyName) {
        try WorkspaceFiles.rename(file, to: "   ")
    }
    #expect(throws: FileOperationError.nameContainsSeparator) {
        try WorkspaceFiles.rename(file, to: "a/b")
    }
    #expect(throws: FileOperationError.hiddenName) {
        try WorkspaceFiles.rename(file, to: ".hidden")
    }
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func renamingOntoAnExistingNameIsRejected() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try write("a.md", in: root, content: "A")
    let b = try write("b.md", in: root, content: "B")

    #expect(throws: FileOperationError.alreadyExists("b.md")) {
        try WorkspaceFiles.rename(a, to: "b")
    }
    // 两份都还在、内容都没动：拒绝必须是无副作用的
    #expect(try String(contentsOf: a, encoding: .utf8) == "A")
    #expect(try String(contentsOf: b, encoding: .utf8) == "B")
}

@Test func renamingToTheSameNameChangesNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root)

    let renamed = try WorkspaceFiles.rename(file, to: "a")

    #expect(renamed.standardizedFileURL.path == file.standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

/// 只改大小写：目标路径在大小写不敏感的文件系统上就是源文件自己，
/// 直着挪会被判成「已存在」。这一条守着临时名那一跳。
@Test func renamingOnlyTheCaseWorks() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root, content: "正文")

    let renamed = try WorkspaceFiles.rename(file, to: "A")

    #expect(renamed.lastPathComponent == "A.md")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["A.md"])
    #expect(try String(contentsOf: renamed, encoding: .utf8) == "正文")
}

// MARK: - 辅助

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ name: String, in directory: URL, content: String = "# 文档") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}
