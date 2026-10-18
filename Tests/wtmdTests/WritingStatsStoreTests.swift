import Foundation
import Testing
@testable import wtmd

// MARK: - 账本接在文档上

/// 走真实 store：确认换文档、新建这两处真的会结算，而不是只在纯函数里正确。
///
/// 账本用临时 suite，草稿目录也是临时的——测试绝不碰读者的真实数据。
@MainActor
private func makeStore(
    in directory: URL
) -> (DocumentStore, WritingStats, UserDefaults, String) {
    let suite = "wtmd.tests.writing.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let stats = WritingStats(defaults: defaults)
    let store = DocumentStore(draftDirectory: directory, writingStats: stats)
    return (store, stats, defaults, suite)
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-writing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `open(url:)` 会往「最近文件」里写一条——用完把原值放回去。
private func preservingRecentFiles(_ body: () throws -> Void) rethrows {
    let key = "wtmd.recentFiles"
    let original = UserDefaults.standard.stringArray(forKey: key)
    defer {
        if let original { UserDefaults.standard.set(original, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    try body()
}

/// 换一篇不该被算成写作：两边的字数差是「换了个地方」，不是写出来的。
@MainActor
@Test func openingAnotherDocumentDoesNotCountTheLengthDifference() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let short = dir.appendingPathComponent("short.md")
    let long = dir.appendingPathComponent("long.md")
    try "短".write(to: short, atomically: true, encoding: .utf8)
    try String(repeating: "很长的一段话。", count: 200)
        .write(to: long, atomically: true, encoding: .utf8)

    let (store, stats, defaults, suite) = makeStore(in: dir)
    defer { defaults.removePersistentDomain(forName: suite) }

    preservingRecentFiles {
        store.open(url: short)
        #expect(stats.today == 0)

        // 防抖还没到点就切走：结算要按正文补报，这一个词不能丢
        store.textDidChange(store.text + "abc")
        store.open(url: long)

        #expect(store.fileURL == long)
        #expect(stats.today == 1)
    }
}

/// 新建文档 = 清空正文。若只看路径，这一步会被记成「删了一篇的字」。
@MainActor
@Test func startingANewDocumentDoesNotCountAsDeleting() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (store, stats, defaults, suite) = makeStore(in: dir)
    defer { defaults.removePersistentDomain(forName: suite) }

    let baseline = store.statistics.characters
    #expect(stats.today == 0)

    store.textDidChange(store.text + "后来")
    store.newDocument()

    #expect(store.text.isEmpty)
    #expect(stats.today == 2)
    #expect(baseline > 0)
}

/// 退出与切文档都会 flush：结算必须是幂等的，不能一 flush 就把同一段字记两遍。
@MainActor
@Test func flushingTwiceCountsTheSameTextOnce() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (store, stats, defaults, suite) = makeStore(in: dir)
    defer { defaults.removePersistentDomain(forName: suite) }

    store.textDidChange(store.text + "再写一句")
    store.flushPendingSave()
    #expect(stats.today == 4)

    store.flushPendingSave()
    #expect(stats.today == 4)
}

/// 退出后重新启动：今天的数字要还在。
@MainActor
@Test func todaysTotalSurvivesARelaunch() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let suite = "wtmd.tests.writing.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = DocumentStore(
        draftDirectory: dir,
        writingStats: WritingStats(defaults: defaults)
    )
    first.textDidChange(first.text + "写下去")
    first.flushPendingSave()

    let second = DocumentStore(
        draftDirectory: dir,
        writingStats: WritingStats(defaults: defaults)
    )
    #expect(second.writingStats?.today == 3)
}
