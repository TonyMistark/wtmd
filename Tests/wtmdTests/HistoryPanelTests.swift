import Foundation
import Testing
@testable import wtmd

// MARK: - 面板背后的账

/// 面板只负责显示与收集动作，真正要守住的是 `DocumentStore` 的这一层：
/// 清单跟着文档走、恢复先留当前版、恢复后还是同一篇、删版当场生效。

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-history-panel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ content: String, to url: URL) throws {
    try content.write(to: url, atomically: true, encoding: .utf8)
}

private func contents(of url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

private func newestContent(_ history: DocumentHistory, _ url: URL) -> String? {
    history.entries(for: url).first.flatMap { history.content(of: $0) }
}

/// 按正文找一版。两版落在同一秒里时不该靠「第几个」来认——那是排序的细节，
/// 不是这条用例要说的事。
private func version(
    _ history: DocumentHistory, in entries: [HistoryEntry], with text: String
) -> HistoryEntry? {
    entries.first { history.content(of: $0) == text }
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

/// 一扇窗 + 一篇有历史的稿子。
@MainActor
private struct PanelRig {
    let root: URL
    let file: URL
    let history: DocumentHistory
    let store: DocumentStore

    init(root: URL, file: URL, history: DocumentHistory, store: DocumentStore) {
        self.root = root
        self.file = file
        self.history = history
        self.store = store
    }
}

@MainActor
private func makeRig(autoSaveDelay: UInt64 = 600_000_000_000) throws -> PanelRig {
    let root = try makeTempDirectory()
    let file = root.appendingPathComponent("稿.md")
    try write("# 第一版\n初稿", to: file)
    let history = DocumentHistory(
        directory: root.appendingPathComponent("history"), minimumInterval: 0
    )
    let store = DocumentStore(
        draftDirectory: root, autoSaveDelay: autoSaveDelay, history: history
    )
    store.open(url: file)
    return PanelRig(root: root, file: file, history: history, store: store)
}

// MARK: - 清单跟着文档走

@MainActor
@Test func theListFollowsTheOpenDocument() throws {
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }
    let rig = try makeRig()
    defer { try? FileManager.default.removeItem(at: rig.root) }

    #expect(rig.store.historyEntries.count == 1)
    #expect(rig.store.canBrowseHistory)

    // 换成一页白纸：旧稿的版本不该留在新稿的面板里
    rig.store.newDocument()
    #expect(rig.store.historyEntries.isEmpty)
    #expect(!rig.store.canBrowseHistory)
}

/// 面板打开的那一刻会先刷新一次：读者可能刚在访达里删过历史文件。
@MainActor
@Test func showingThePanelPicksUpChangesMadeOutside() throws {
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }
    let rig = try makeRig()
    defer { try? FileManager.default.removeItem(at: rig.root) }

    #expect(rig.store.historyEntries.count == 1)
    try FileManager.default.removeItem(at: rig.history.entries(for: rig.file)[0].fileURL)
    // 磁盘上没了，但 store 还不知道
    #expect(rig.store.historyEntries.count == 1)

    rig.store.showHistory()
    #expect(rig.store.historyEntries.isEmpty)
    #expect(rig.store.historyVisible)
}

// MARK: - 恢复

@MainActor
@Test func restoringPutsTheOldTextBackAndClosesThePanel() throws {
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }
    let rig = try makeRig()
    defer { try? FileManager.default.removeItem(at: rig.root) }

    rig.store.textDidChange("# 第二版\n改过了")
    rig.store.flushPendingSave()
    let first = try #require(
        version(rig.history, in: rig.store.historyEntries, with: "# 第一版\n初稿")
    )

    rig.store.showHistory()
    rig.store.restoreHistory(first)

    #expect(rig.store.text == "# 第一版\n初稿")
    #expect(!rig.store.historyVisible)
}

/// 恢复之前先把「现在这一版」留一份：否则取回旧版这个动作本身就把读者
/// 刚写的那一段变成了唯一没存过的内容——想反悔时已经没得翻了。
@MainActor
@Test func restoringKeepsTheVersionItReplaced() throws {
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }
    let rig = try makeRig()
    defer { try? FileManager.default.removeItem(at: rig.root) }

    // 刚敲的字：还没到自动保存的 1.2 秒，所以磁盘与历史里都还没有它
    rig.store.textDidChange("# 第二版\n改过了")
    let first = try #require(
        version(rig.history, in: rig.store.historyEntries, with: "# 第一版\n初稿")
    )

    rig.store.restoreHistory(first)

    // 只有「恢复前先留一份」这一条路，能让刚敲的这段字活下来
    #expect(newestContent(rig.history, rig.file) == "# 第二版\n改过了")
    // 并且清单里立刻看得见
    #expect(rig.store.historyEntries.first == rig.history.entries(for: rig.file).first)
}

/// 恢复的是「这篇的某一版」，不是「另存为一篇」：标题不该变成未命名。
@MainActor
@Test func restoringStaysOnTheSameDocumentAndWritesThrough() async throws {
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }
    let rig = try makeRig(autoSaveDelay: 20_000_000)
    defer { try? FileManager.default.removeItem(at: rig.root) }

    rig.store.textDidChange("# 第二版\n改过了")
    rig.store.flushPendingSave()
    let first = try #require(
        version(rig.history, in: rig.store.historyEntries, with: "# 第一版\n初稿")
    )

    rig.store.restoreHistory(first)

    #expect(rig.store.fileURL == rig.file)
    #expect(rig.store.displayName == "稿.md")
    #expect(rig.store.isDirty)

    // 写盘交给自动保存：不另开一条路，冲突与多窗占用那三道口照旧
    await waitUntil("恢复后的内容落盘") { contents(of: rig.file) == "# 第一版\n初稿" }
}

// MARK: - 删除

@MainActor
@Test func deletingAVersionRemovesItFromTheListAndDisk() throws {
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }
    let rig = try makeRig()
    defer { try? FileManager.default.removeItem(at: rig.root) }

    rig.store.textDidChange("# 第二版\n改过了")
    rig.store.flushPendingSave()
    let newest = try #require(rig.store.historyEntries.first)
    #expect(rig.store.historyEntries.count == 2)

    rig.store.discardHistory(newest)

    #expect(rig.store.historyEntries.count == 1)
    #expect(!FileManager.default.fileExists(atPath: newest.fileURL.path))
}

@MainActor
@Test func clearingTheHistoryEmptiesBothTheListAndTheFolder() throws {
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }
    let rig = try makeRig()
    defer { try? FileManager.default.removeItem(at: rig.root) }

    rig.store.textDidChange("# 第二版\n改过了")
    rig.store.flushPendingSave()
    rig.store.clearHistory()

    #expect(rig.store.historyEntries.isEmpty)
    #expect(!rig.store.canBrowseHistory)
    #expect(!FileManager.default.fileExists(atPath: rig.history.folder(for: rig.file).path))
}

// MARK: - 多窗口

/// 历史是应用级一份：另一扇窗写下的版本，这扇窗的面板里立刻看得见——
/// 否则读者会以为「刚才在那扇窗里存的那一版」没留下。
@MainActor
@Test func anotherWindowsVersionShowsUpHere() throws {
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }
    let rig = try makeRig()
    defer { try? FileManager.default.removeItem(at: rig.root) }

    // 第二扇窗：同一个历史目录，另一份 store（`openDocuments` 不设防）
    let other = DocumentStore(
        draftDirectory: rig.root, autoSaveDelay: 600_000_000_000, history: rig.history
    )
    other.open(url: rig.file)
    #expect(rig.store.historyEntries.count == 1)

    other.textDidChange("# 从另一扇窗写下的")
    other.flushPendingSave()

    #expect(rig.store.historyEntries.count == 2)
    #expect(
        version(rig.history, in: rig.store.historyEntries, with: "# 从另一扇窗写下的") != nil,
        "另一扇窗写下的那一版要出现在这扇窗的清单里"
    )
}

// MARK: - 分组

@Test func versionsAreGroupedByDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let lastWeek = calendar.date(byAdding: .day, value: -7, to: now)!

    let entries = [now, yesterday, lastWeek].enumerated().map { index, date in
        HistoryEntry(
            fileURL: URL(fileURLWithPath: "/tmp/v\(index).md"), savedAt: date, bytes: 10
        )
    }

    let sections = HistoryGroup.sections(of: entries, now: now, calendar: calendar)
    #expect(sections.map(\.day) == [.today, .yesterday, .earlier])
    #expect(sections.map(\.entries.count) == [1, 1, 1])
}

@Test func anEmptyDayDoesNotGetASection() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let lastWeek = calendar.date(byAdding: .day, value: -7, to: now)!

    let entry = HistoryEntry(fileURL: URL(fileURLWithPath: "/tmp/old.md"), savedAt: lastWeek, bytes: 1)
    let sections = HistoryGroup.sections(of: [entry], now: now, calendar: calendar)
    #expect(sections.map(\.day) == [.earlier])
}
