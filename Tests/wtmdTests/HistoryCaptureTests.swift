import Foundation
import Testing
@testable import wtmd

// MARK: - 三个留存的时刻

/// `DocumentHistory` 自己会去重、会看清间隔；这组用例守的是**什么时候叫它**：
/// 打开读到盘之后、真正写盘之后、离开这一篇之后。少一处，「过去」就断一截。

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-history-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ content: String, to url: URL) throws {
    try content.write(to: url, atomically: true, encoding: .utf8)
}

private func contents(of url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

/// 最新一版的正文。写成函数而不是把 `#require` 套进 `contents(of:)` 里：
/// 后者会让泛型参数先从外层实参推成 `URL`，可选值反而对不上。
private func newestContent(_ history: DocumentHistory, _ url: URL) -> String? {
    history.entries(for: url).first.flatMap { history.content(of: $0) }
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

/// 打开一篇已有的稿子：盘上那一版就是历史的第一版。
@MainActor
@Test func openingAFileLeavesItsFirstVersion() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("# 打开时\n正文", to: file)

    let history = DocumentHistory(directory: dir.appendingPathComponent("history"))
    let store = DocumentStore(
        draftDirectory: dir, autoSaveDelay: 600_000_000_000, history: history
    )
    store.open(url: file)

    let entries = history.entries(for: file)
    #expect(entries.count == 1)
    #expect(newestContent(history, file) == "# 打开时\n正文")
}

/// 自动保存写完盘，历史才跟着长一版——写盘是唯一的触发点，不是按键。
@MainActor
@Test func anEditIsKeptRightAfterItReachesTheDisk() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let history = DocumentHistory(
        directory: dir.appendingPathComponent("history"), minimumInterval: 0
    )
    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 20_000_000, history: history)
    store.open(url: file)
    #expect(history.entries(for: file).count == 1)

    store.textDidChange("改过的正文")
    await waitUntil("自动保存之后历史多一版") { history.entries(for: file).count == 2 }

    #expect(newestContent(history, file) == "改过的正文")
}

/// 写完立刻切走 / 关窗：间隔还没到，最后这一版也得留下——否则「这次写到哪儿」
/// 要等下一次打开才想得起来，而它正是读者最想找回的那一版。
@MainActor
@Test func leavingKeepsTheLastVersionEvenInsideTheInterval() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let history = DocumentHistory(
        directory: dir.appendingPathComponent("history"), minimumInterval: 3_600
    )
    let store = DocumentStore(
        draftDirectory: dir, autoSaveDelay: 600_000_000_000, history: history
    )
    store.open(url: file)
    store.textDidChange("刚写到一半的一句")
    // 切文档、关窗、退出都走这一条
    store.flushPendingSave()

    let entries = history.entries(for: file)
    #expect(entries.count == 2)
    #expect(newestContent(history, file) == "刚写到一半的一句")
    #expect(contents(of: file) == "刚写到一半的一句")
}

/// 没有名字的草稿不进历史：草稿目录自己就是它的一版，而它没有稳定身份，
/// 换个窗口就是另一份。
@MainActor
@Test func anUntitledDocumentNeverGetsHistory() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let historyRoot = dir.appendingPathComponent("history")
    let history = DocumentHistory(directory: historyRoot)
    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 0, history: history)

    store.newDocument()
    store.textDidChange("# 没名字的思绪")
    store.flushPendingSave()

    #expect(!FileManager.default.fileExists(atPath: historyRoot.path))
    // 字没丢：它还在草稿里
    #expect(contents(of: dir.appendingPathComponent("draft.md")) == "# 没名字的思绪")
}

/// 另存为也走 `writeFile` 这条唯一的出口：新落点第一次写进去就该有一版，
/// 否则「刚存成的那一版」反而成了历史里最旧的一页。
@MainActor
@Test func savingToANewPathStartsWithItsOwnHistory() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let history = DocumentHistory(directory: dir.appendingPathComponent("history"))
    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 600_000_000_000, history: history)

    store.newDocument()
    store.textDidChange("# 新稿")
    let target = dir.appendingPathComponent("新稿.md")
    #expect(store.save(to: target))

    #expect(history.entries(for: target).count == 1)
    #expect(newestContent(history, target) == "# 新稿")
}
