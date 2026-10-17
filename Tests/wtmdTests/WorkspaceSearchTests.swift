import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 扫描

/// 命中要带上「哪一篇、第几行、行内第几个字」——面板点下去靠的正是这三样。
@Test func findsHitsAcrossFilesWithLineAndColumn() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "第一行\n第二行有 needle\n第三行")
    let nested = try makeDirectory("notes", in: root)
    try write("b.md", in: nested, content: "开头\nneedle 在中间\n结尾")

    let report = WorkspaceSearch.run(root: root, query: "needle", options: [])

    #expect(report.hitCount == 2)
    #expect(report.groups.map(\.relativePath) == ["a.md", "notes/b.md"])
    #expect(report.scannedFiles == 2)

    let first = try #require(report.groups.first?.hits.first)
    #expect(first.line == 1)
    #expect(first.column == 5)          // 「第二行有 」占五个字符
    #expect(first.length == 6)
    #expect(first.lineText == "第二行有 needle")

    let second = try #require(report.groups.last?.hits.first)
    #expect(second.line == 1)
    #expect(second.column == 0)
}

/// 同一个词在一篇里出现三次，就是三条命中，不是一条。
@Test func everyOccurrenceOnALineBecomesItsOwnHit() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "needle needle\nneedle")

    let report = WorkspaceSearch.run(root: root, query: "needle", options: [])

    #expect(report.hitCount == 3)
    #expect(report.hits.map(\.line) == [0, 0, 1])
    #expect(report.hits.map(\.column) == [0, 7, 0])
}

/// 写作工作区里不该出现的东西：隐藏目录、依赖目录、别的格式。
@Test func skipsHiddenDependencyAndNonMarkdownFiles() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("real.md", in: root, content: "needle")
    try write("notes.txt", in: root, content: "needle")

    let git = try makeDirectory(".git", in: root)
    try write("index.md", in: git, content: "needle")
    let modules = try makeDirectory("node_modules", in: root)
    try write("readme.md", in: modules, content: "needle")
    let pods = try makeDirectory("Pods", in: root)
    try write("pod.md", in: pods, content: "needle")

    let report = WorkspaceSearch.run(root: root, query: "needle", options: [])

    #expect(report.groups.map(\.relativePath) == ["real.md"])
    #expect(report.hitCount == 1)
}

/// 上限到了要如实说「已截断」，而不是假装整间书房只有 200 句。
@Test func stopsAtTheHitLimitAndSaysSo() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lines = (1...250).map { "needle \($0)" }.joined(separator: "\n")
    try write("big.md", in: root, content: lines)

    let report = WorkspaceSearch.run(root: root, query: "needle", options: [], limit: 200)

    #expect(report.hitCount == 200)
    #expect(report.truncated)
}

/// 巨型文件跳过并计数：读它一遍会让「输入即搜」变成「输入即卡」。
@Test func skipsFilesAboveTheSizeLimit() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("huge.md", in: root, content: String(repeating: "needle\n", count: 40))
    try write("small.md", in: root, content: "needle")

    let report = WorkspaceSearch.run(root: root, query: "needle", options: [], sizeLimit: 64)

    #expect(report.skippedFiles == 1)
    #expect(report.groups.map(\.relativePath) == ["small.md"])
}

/// 空查询不扫盘：按下 ⌘⇧F 就把整个文件夹读一遍是最没必要的 I/O。
@Test func emptyQueryTouchesNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "needle")

    let report = WorkspaceSearch.run(root: root, query: "", options: [])

    #expect(report.isEmpty)
    #expect(report.scannedFiles == 0)
}

/// 选项与文档内查找共用一套语义：`Aa` 区分大小写，正则走 ICU。
@Test func optionsMeanTheSameAsInsideOneDocument() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "Alpha alpha")

    #expect(WorkspaceSearch.run(root: root, query: "alpha", options: []).hitCount == 2)
    #expect(
        WorkspaceSearch.run(root: root, query: "alpha", options: [.caseSensitive]).hitCount == 1
    )
    #expect(
        WorkspaceSearch.run(root: root, query: "a\\w+a", options: [.regex]).hitCount == 2
    )
}

/// 正在编辑的那一篇以内存内容参与搜索：磁盘副本可能还停在上一次自动保存，
/// 刚敲下的词搜不到是唯一不能接受的答案。
@Test func liveTextOverridesTheDiskCopy() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root, content: "磁盘上的旧版本")

    #expect(WorkspaceSearch.run(root: root, query: "刚写的", options: []).isEmpty)

    let report = WorkspaceSearch.run(
        root: root,
        query: "刚写的",
        options: [],
        overlay: [file: "磁盘上的旧版本\n刚写的一句"]
    )

    #expect(report.hitCount == 1)
    #expect(report.hits.first?.line == 1)
}

/// 一行几千字时只截命中周围那一段，两端补省略号；命中位置要跟着重新算。
@Test func longLinesAreCutAroundTheHit() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let line = String(repeating: "前", count: 300) + "needle" + String(repeating: "后", count: 300)
    try write("a.md", in: root, content: line)

    let hit = try #require(WorkspaceSearch.run(root: root, query: "needle", options: []).hits.first)

    #expect(hit.column == 300)
    #expect(hit.lineText.hasPrefix("…"))
    #expect(hit.lineText.hasSuffix("…"))
    let shown = hit.lineText as NSString
    #expect(
        shown.substring(with: NSRange(location: hit.highlightStart, length: hit.highlightLength))
            == "needle",
        "裁剪之后高亮区间必须仍然指向命中词"
    )
}

/// CRLF 的行尾不能把 `\r` 带进结果行里（会在界面上显示成方块）。
@Test func carriageReturnsAreTrimmedFromTheShownLine() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "第一行\r\nneedle 在这儿\r\n")

    let hit = try #require(WorkspaceSearch.run(root: root, query: "needle", options: []).hits.first)

    #expect(hit.line == 1)
    #expect(hit.lineText == "needle 在这儿")
}

/// 面板关掉（或改了查询词）就取消：`shouldContinue` 一旦为假，整轮立刻收手。
@Test func cancellationStopsTheSweep() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "needle")

    let report = WorkspaceSearch.run(
        root: root, query: "needle", options: [], shouldContinue: { false }
    )

    #expect(report.isEmpty)
    #expect(report.scannedFiles == 0)
}

/// 行下标查找：命中落在行首、行中、文末都要对得上。
@Test func lineIndexFindsTheLineContainingAnOffset() {
    let content = "ab\n\ncd" as NSString
    let starts = WorkspaceSearch.lineStarts(of: content)

    #expect(starts == [0, 3, 4])
    #expect(WorkspaceSearch.lineIndex(for: 0, in: starts) == 0)
    #expect(WorkspaceSearch.lineIndex(for: 2, in: starts) == 0)   // 换行符算上一行
    #expect(WorkspaceSearch.lineIndex(for: 3, in: starts) == 1)
    #expect(WorkspaceSearch.lineIndex(for: 4, in: starts) == 2)
}

// MARK: - 辅助

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-search-\(UUID().uuidString)", isDirectory: true)
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
private func write(_ name: String, in directory: URL, content: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}
