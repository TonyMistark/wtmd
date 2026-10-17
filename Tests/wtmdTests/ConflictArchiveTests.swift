import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 冲突副本

/// 冲突没解决就切走时，本地那份不该跟着消失。这组用例守两件事：
/// **副本是普通 Markdown（内容一个字都不少）**，以及**切文档不会被拦住**。

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ content: String, to url: URL) throws {
    try content.write(to: url, atomically: true, encoding: .utf8)
}

private func contents(of url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private func clock(at date: Date) -> () -> Date {
    { date }
}

private func makeIsolatedSession() -> (session: Session, suite: String) {
    let suite = "wtmd.tests.archive.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (Session(defaults: defaults), suite)
}

/// `open(url:)` 会写「最近文件」，用完把原值放回去。
private func preserveRecentFiles() -> () -> Void {
    let key = "wtmd.recentFiles"
    let original = UserDefaults.standard.stringArray(forKey: key)
    return {
        if let original { UserDefaults.standard.set(original, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

// MARK: - 目录本身

@Test func aCopyIsPlainMarkdownWithTheOriginalName() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let archive = ConflictArchive(directory: dir)
    let original = URL(fileURLWithPath: "/tmp/书稿/第三章.md")
    let entry = try #require(archive.archive("# 我的改动\n第二行", originalURL: original))

    // 副本要能被人直接用别的编辑器打开：正文就是正文，不夹带元信息
    #expect(contents(of: entry.fileURL) == "# 我的改动\n第二行")
    #expect(entry.originalName == "第三章.md")
    #expect(entry.originalPath == "/tmp/书稿/第三章.md")
    #expect(entry.fileURL.lastPathComponent.hasPrefix("第三章-"))
    #expect(entry.fileURL.pathExtension == "md")
}

@Test func theListSurvivesARestart() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let when = Date(timeIntervalSince1970: 1_700_000_000)

    let first = ConflictArchive(directory: dir, clock: clock(at: when))
    let entry = try #require(
        first.archive("内容", originalURL: URL(fileURLWithPath: "/tmp/稿.md"))
    )

    // 关掉应用再打开：账本要能从磁盘读回来
    let reopened = ConflictArchive(directory: dir)
    let listed = try #require(reopened.entries().first)
    #expect(listed.fileURL == entry.fileURL)
    #expect(listed.originalName == "稿.md")
    #expect(abs(listed.savedAt.timeIntervalSince(when)) < 0.001)
}

/// 连着切两次文档、同一秒里存两份同名副本：后一份不能盖掉前一份。
@Test func twoCopiesInTheSameSecondDoNotCollide() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = ConflictArchive(
        directory: dir, clock: clock(at: Date(timeIntervalSince1970: 1_700_000_000))
    )
    let original = URL(fileURLWithPath: "/tmp/稿.md")

    let a = try #require(archive.archive("第一份", originalURL: original))
    let b = try #require(archive.archive("第二份", originalURL: original))

    #expect(a.fileURL != b.fileURL)
    #expect(contents(of: a.fileURL) == "第一份")
    #expect(contents(of: b.fileURL) == "第二份")
    #expect(archive.entries().count == 2)
}

@Test func newerCopiesComeFirst() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = URL(fileURLWithPath: "/tmp/稿.md")

    let old = ConflictArchive(directory: dir, clock: clock(at: Date(timeIntervalSince1970: 1_600_000_000)))
    try #require(old.archive("旧", originalURL: original))
    let fresh = ConflictArchive(directory: dir, clock: clock(at: Date(timeIntervalSince1970: 1_700_000_000)))
    try #require(fresh.archive("新", originalURL: original))

    #expect(fresh.entries().map { contents(of: $0.fileURL) } == ["新", "旧"])
}

@Test func removingACopyDeletesItsFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = ConflictArchive(directory: dir)
    let entry = try #require(
        archive.archive("内容", originalURL: URL(fileURLWithPath: "/tmp/稿.md"))
    )

    archive.remove(entry)

    #expect(!FileManager.default.fileExists(atPath: entry.fileURL.path))
    #expect(archive.entries().isEmpty)
}

/// 读者自己在访达里把副本删了：账上那条也要跟着消失，不能留一个点开就空的条目。
@Test func aCopyDeletedOutsideDisappearsFromTheList() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = ConflictArchive(directory: dir)
    let entry = try #require(
        archive.archive("内容", originalURL: URL(fileURLWithPath: "/tmp/稿.md"))
    )

    try FileManager.default.removeItem(at: entry.fileURL)

    #expect(archive.entries().isEmpty)
}

// MARK: - 切文档时存档

@MainActor
private func conflictedStore(
    in dir: URL,
    archive: ConflictArchive
) throws -> (store: DocumentStore, file: URL, cleanup: () -> Void) {
    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)
    let store = DocumentStore(
        draftDirectory: dir, autoSaveDelay: 600_000_000_000, conflicts: archive
    )
    store.open(url: file)
    try write("别人的版本", to: file)
    store.textDidChange("我的改动")
    store.flushPendingSave()
    #expect(store.externalChange == .modified)
    return (store, file, {})
}

/// 核心用例：冲突还亮着就切走，磁盘不动、本地那份进副本、编辑器换成新的那篇。
@MainActor
@Test func switchingAwayArchivesTheUnresolvedLocalVersion() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let archive = ConflictArchive(directory: dir.appendingPathComponent("conflicts"))
    let (store, file, _) = try conflictedStore(in: dir, archive: archive)

    let other = dir.appendingPathComponent("另一篇.md")
    try write("另一篇的内容", to: other)
    store.open(url: other)

    // 磁盘还是别人的版本，本地那份在副本里，一个字都没少
    #expect(contents(of: file) == "别人的版本")
    #expect(store.text == "另一篇的内容")
    #expect(store.externalChange == nil)
    let entry = try #require(store.archivedConflicts.first)
    #expect(archive.content(of: entry) == "我的改动")
    #expect(entry.originalName == "稿.md")
    // 存档不能是无声的
    #expect(store.archiveNotice?.contains("稿.md") == true)
}

@MainActor
@Test func creatingANewDocumentAlsoArchivesTheLocalVersion() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let archive = ConflictArchive(directory: dir.appendingPathComponent("conflicts"))
    let (store, file, _) = try conflictedStore(in: dir, archive: archive)

    store.newDocument()

    #expect(contents(of: file) == "别人的版本")
    #expect(store.text.isEmpty)
    let entry = try #require(store.archivedConflicts.first)
    #expect(archive.content(of: entry) == "我的改动")
}

/// 没有冲突时切文档不该凭空多出副本——副本是「丢过东西」的证据，不能变成噪音。
@MainActor
@Test func switchingWithNoConflictArchivesNothing() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)
    let archive = ConflictArchive(directory: dir.appendingPathComponent("conflicts"))
    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 0, conflicts: archive)
    store.open(url: file)
    store.textDidChange("我的改动")
    store.flushPendingSave()

    let other = dir.appendingPathComponent("另一篇.md")
    try write("另一篇", to: other)
    store.open(url: other)

    #expect(store.archivedConflicts.isEmpty)
    #expect(store.archiveNotice == nil)
}

/// 取回：作为未命名文档进编辑器（原文件是别人的版本，不该被悄悄盖掉），
/// 副本随即从清单里消失——它已经回到读者手里了。
@MainActor
@Test func anArchivedCopyComesBackAsAnUntitledDocument() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let archive = ConflictArchive(directory: dir.appendingPathComponent("conflicts"))
    let (store, file, _) = try conflictedStore(in: dir, archive: archive)
    let other = dir.appendingPathComponent("另一篇.md")
    try write("另一篇", to: other)
    store.open(url: other)

    let entry = try #require(store.archivedConflicts.first)
    store.recoverArchivedConflict(entry)

    #expect(store.text == "我的改动")
    #expect(store.fileURL == nil)
    #expect(store.isDirty)
    #expect(store.archivedConflicts.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: entry.fileURL.path))
    #expect(contents(of: file) == "别人的版本")
}

@MainActor
@Test func discardingACopyJustDeletesIt() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let archive = ConflictArchive(directory: dir.appendingPathComponent("conflicts"))
    let (store, _, _) = try conflictedStore(in: dir, archive: archive)
    let other = dir.appendingPathComponent("另一篇.md")
    try write("另一篇", to: other)
    store.open(url: other)

    let entry = try #require(store.archivedConflicts.first)
    store.discardArchivedConflict(entry)

    #expect(store.archivedConflicts.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: entry.fileURL.path))
}
