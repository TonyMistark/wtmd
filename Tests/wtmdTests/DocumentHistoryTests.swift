import Combine
import Foundation
import Testing
@testable import wtmd

// MARK: - 版本历史本身

/// 自动保存保的是「此刻」，这组用例守的是「过去」：写过的每一版都得留下，
/// 留得住的才叫历史。三个边界反复验：**同样的内容不留第二遍**、**间隔内不留**、
/// **超出去的要清掉**。

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func contents(of url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

/// 最新一版的正文。写成函数而不是把 `#require` 套进 `contents(of:)` 里：
/// 后者会让泛型参数先从外层实参推成 `URL`，可选值反而对不上。
private func newestContent(_ history: DocumentHistory, _ url: URL) -> String? {
    history.entries(for: url).first.flatMap { history.content(of: $0) }
}

/// 可拨的钟：留存间隔与「三十天之外」都得能在一瞬间走到。
private final class TestClock {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@Test func aCaptureKeepsAPlainMarkdownCopy() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let history = DocumentHistory(directory: root)
    let article = URL(fileURLWithPath: "/tmp/书稿/第一章.md")
    let entry = try #require(history.capture("# 第一版\n正文还在", for: article, force: true))

    // 历史里的每一版都是普通 Markdown：别的编辑器打得开，人也读得懂
    #expect(entry.fileURL.pathExtension == "md")
    #expect(contents(of: entry.fileURL) == "# 第一版\n正文还在")
    #expect(history.entries(for: article).count == 1)
    // 目录能被人直接打开翻：meta 记着「这一屋子旧稿原来是谁」
    #expect(history.meta(for: article)?.name == "第一章.md")
    #expect(history.meta(for: article)?.path.hasSuffix("/书稿/第一章.md") == true)
}

@Test func theSameContentIsNotStoredTwice() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let history = DocumentHistory(directory: root)
    let article = URL(fileURLWithPath: "/tmp/稿.md")
    #expect(history.capture("同一段字", for: article, force: true) != nil)
    // 打开同一篇十次不是十版
    #expect(history.capture("同一段字", for: article, force: true) == nil)
    #expect(history.entries(for: article).count == 1)
}

@Test func capturesInsideTheIntervalAreSkippedUnlessForced() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock()
    let history = DocumentHistory(directory: root, clock: { clock.now }, minimumInterval: 300)
    let article = URL(fileURLWithPath: "/tmp/稿.md")

    #expect(history.capture("第一版", for: article, force: true) != nil)
    clock.advance(60)
    // 一分钟后又改了：自动保存会写盘，但历史不该跟着长
    #expect(history.capture("第二版", for: article) == nil)
    #expect(history.entries(for: article).count == 1)

    // 「离开这一篇」是另一个时刻，越过间隔
    #expect(history.capture("第二版", for: article, force: true) != nil)
    #expect(history.entries(for: article).count == 2)
    #expect(newestContent(history, article) == "第二版")

    clock.advance(301)
    #expect(history.capture("第三版", for: article) != nil)
    #expect(history.entries(for: article).count == 3)
}

@Test func emptyContentIsNotHistory() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let history = DocumentHistory(directory: root)
    let article = URL(fileURLWithPath: "/tmp/稿.md")

    // 清空一篇稿子不该留一版空白：那只会把有用的旧版往前挤
    #expect(history.capture("", for: article, force: true) == nil)
    #expect(history.capture("  \n\t\n", for: article, force: true) == nil)
    #expect(history.entries(for: article).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: history.folder(for: article).path))
}

@Test func onlyTheNewestVersionsSurviveTheCountLimit() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock()
    let history = DocumentHistory(directory: root, clock: { clock.now }, minimumInterval: 0, maxCount: 3)
    let article = URL(fileURLWithPath: "/tmp/稿.md")

    for index in 1...5 {
        #expect(history.capture("第 \(index) 版", for: article, force: true) != nil)
        clock.advance(60)
    }

    let entries = history.entries(for: article)
    #expect(entries.count == 3)
    #expect(entries.compactMap { contents(of: $0.fileURL) } == ["第 5 版", "第 4 版", "第 3 版"])
}

@Test func versionsOlderThanTheWindowAreDropped() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock()
    let history = DocumentHistory(
        directory: root, clock: { clock.now }, minimumInterval: 0, maxAge: 86_400
    )
    let article = URL(fileURLWithPath: "/tmp/稿.md")

    #expect(history.capture("昨天", for: article, force: true) != nil)
    clock.advance(2 * 86_400)
    #expect(history.capture("今天", for: article, force: true) != nil)

    #expect(history.entries(for: article).count == 1)
    #expect(newestContent(history, article) == "今天")
}

@Test func entriesComeBackNewestFirst() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock()
    let history = DocumentHistory(directory: root, clock: { clock.now }, minimumInterval: 0)
    let article = URL(fileURLWithPath: "/tmp/稿.md")

    for index in 1...3 {
        history.capture("第 \(index) 版", for: article, force: true)
        clock.advance(600)
    }

    #expect(history.entries(for: article).compactMap { contents(of: $0.fileURL) } == ["第 3 版", "第 2 版", "第 1 版"])
}

@Test func twoDocumentsWithTheSameNameKeepSeparateHistories() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let history = DocumentHistory(directory: root)
    let first = URL(fileURLWithPath: "/tmp/甲/稿.md")
    let second = URL(fileURLWithPath: "/tmp/乙/稿.md")

    history.capture("甲的正文", for: first, force: true)
    history.capture("乙的正文", for: second, force: true)

    #expect(history.entries(for: first).count == 1)
    #expect(history.entries(for: second).count == 1)
    #expect(newestContent(history, first) == "甲的正文")
    #expect(history.folder(for: first) != history.folder(for: second))
}

@Test func bothSpellingsOfAPathShareOneHistory() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let history = DocumentHistory(directory: root)
    // 临时目录在 `/var/folders/…`，解析符号链接之后是 `/private/var/…`：
    // 同一份文件的两个拼法，历史不能分成两屋子。
    let plain = root.appendingPathComponent("稿.md")
    let resolved = plain.resolvingSymlinksInPath()

    history.capture("第一版", for: plain, force: true)
    #expect(history.entries(for: resolved).count == 1)
    #expect(history.folder(for: plain) == history.folder(for: resolved))
}

@Test func foreignFilesInTheFolderAreIgnored() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let history = DocumentHistory(directory: root)
    let article = URL(fileURLWithPath: "/tmp/稿.md")
    history.capture("正文", for: article, force: true)

    // 读者自己往历史目录里丢的东西不该被当成一版
    let folder = history.folder(for: article)
    try "随手记".write(to: folder.appendingPathComponent("笔记.txt"), atomically: true, encoding: .utf8)
    try "随手记".write(to: folder.appendingPathComponent("backup.md"), atomically: true, encoding: .utf8)

    #expect(history.entries(for: article).count == 1)
    #expect(history.hasHistory(for: article))
    #expect(!history.hasHistory(for: URL(fileURLWithPath: "/tmp/别的.md")))
}

@Test func forgettingOneDocumentKeepsTheOthers() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let history = DocumentHistory(directory: root)
    let first = URL(fileURLWithPath: "/tmp/甲/稿.md")
    let second = URL(fileURLWithPath: "/tmp/乙/稿.md")
    history.capture("甲", for: first, force: true)
    history.capture("乙", for: second, force: true)

    history.removeAll(for: first)

    #expect(history.entries(for: first).isEmpty)
    #expect(history.entries(for: second).count == 1)
}

@Test func aSingleVersionCanBeDropped() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock()
    let history = DocumentHistory(directory: root, clock: { clock.now }, minimumInterval: 0)
    let article = URL(fileURLWithPath: "/tmp/稿.md")
    history.capture("第一版", for: article, force: true)
    clock.advance(60)
    history.capture("第二版", for: article, force: true)

    let newest = try #require(history.entries(for: article).first)
    history.remove(newest)

    #expect(history.entries(for: article).compactMap { contents(of: $0.fileURL) } == ["第一版"])
}

/// 面板靠广播刷新：留下一版要说话，删掉一版也要说话。
/// 反过来说，**没有留下**的时候不能说话——否则自动保存每 1.2 秒就抖一次面板。
@Test func everyRealChangeAnnouncesItself() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let clock = TestClock()
    let history = DocumentHistory(directory: root, clock: { clock.now }, minimumInterval: 300)
    let article = URL(fileURLWithPath: "/tmp/稿.md")

    var announcements = 0
    let token = history.objectWillChange.sink { _ in announcements += 1 }
    defer { token.cancel() }

    #expect(history.capture("第一版", for: article, force: true) != nil)
    #expect(announcements == 1)

    // 同样的内容不留第二遍，也就不该惊动面板
    #expect(history.capture("第一版", for: article, force: true) == nil)
    #expect(announcements == 1)

    // 间隔内的普通写盘同样跳过
    #expect(history.capture("第二版", for: article) == nil)
    #expect(announcements == 1)

    #expect(history.capture("第二版", for: article, force: true) != nil)
    #expect(announcements == 2)

    let newest = try #require(history.entries(for: article).first)
    history.remove(newest)
    #expect(announcements == 3)

    history.removeAll(for: article)
    #expect(announcements == 4)
}
