import Foundation
import Testing
@testable import wtmd

// MARK: - 每日净增

/// 一天里的时钟要能往前走，跨天用例才不用等到明天。
@MainActor
private final class Clock {
    var now: Date

    init(_ now: Date) { self.now = now }

    func advance(days: Int) {
        now = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: now)!
    }
}

private let shanghai = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

/// 2026-10-18 10:00（上海）。写死一个钟点，跨天用例才有确定的日子可数。
private let noon: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 10
    components.day = 18
    components.hour = 10
    return shanghai.date(from: components)!
}()

/// 一份临时偏好设置：每个用例自己的 suite，绝不动真实的 preferences。
@MainActor
private func makeStats(clock: Clock) -> (WritingStats, UserDefaults, String) {
    let suite = "wtmd.tests.writing.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let stats = WritingStats(
        defaults: defaults,
        calendar: shanghai,
        now: { clock.now }
    )
    return (stats, defaults, suite)
}

private func cleanUp(_ defaults: UserDefaults, _ suite: String) {
    defaults.removePersistentDomain(forName: suite)
}

@MainActor
@Test func firstObservationOnlySetsTheBaseline() throws {
    let clock = Clock(noon)
    let (stats, defaults, suite) = makeStats(clock: clock)
    defer { cleanUp(defaults, suite) }

    stats.observe(document: "a", characters: 500)

    // 打开一篇五千字的旧稿，不代表今天写了五千字
    #expect(stats.today == 0)
}

@MainActor
@Test func netGrowthCountsAndDeletionSubtracts() throws {
    let clock = Clock(noon)
    let (stats, defaults, suite) = makeStats(clock: clock)
    defer { cleanUp(defaults, suite) }

    stats.observe(document: "a", characters: 100)
    stats.observe(document: "a", characters: 380)
    #expect(stats.today == 280)

    // 删掉一段：净增跟着退回去
    stats.observe(document: "a", characters: 300)
    #expect(stats.today == 200)
}

@MainActor
@Test func reportingTheSameCountAgainChangesNothing() throws {
    let clock = Clock(noon)
    let (stats, defaults, suite) = makeStats(clock: clock)
    defer { cleanUp(defaults, suite) }

    stats.observe(document: "a", characters: 100)
    stats.observe(document: "a", characters: 140)
    stats.observe(document: "a", characters: 140)
    stats.observe(document: "a", characters: 140)

    #expect(stats.today == 40)
}

/// 换一篇不是「写了多少」，只是换了个地方——两边的字数差不能记成写作。
@MainActor
@Test func switchingDocumentsResetsTheBaselineInsteadOfCountingTheJump() throws {
    let clock = Clock(noon)
    let (stats, defaults, suite) = makeStats(clock: clock)
    defer { cleanUp(defaults, suite) }

    stats.observe(document: "a", characters: 100)
    stats.observe(document: "a", characters: 160)

    stats.observe(document: "b", characters: 4_000)
    #expect(stats.today == 60)

    // 新的一篇照样按自己的基线往下记
    stats.observe(document: "b", characters: 4_010)
    #expect(stats.today == 70)

    // 换回来也不补记那 3940 字的差
    stats.observe(document: "a", characters: 160)
    #expect(stats.today == 70)
}

@MainActor
@Test func pendingIsNotPersistedUntilSettle() throws {
    let clock = Clock(noon)
    let (stats, defaults, suite) = makeStats(clock: clock)
    defer { cleanUp(defaults, suite) }

    stats.observe(document: "a", characters: 0)
    stats.observe(document: "a", characters: 250)

    // 内存里已经有了，磁盘上还没写
    #expect(stats.today == 250)
    #expect(defaults.string(forKey: "wtmd.writingStats.ledger") == nil)

    stats.settle()
    #expect(defaults.string(forKey: "wtmd.writingStats.ledger") != nil)
}

@MainActor
@Test func settleWritesTheLedgerAndASecondInstanceReadsItBack() throws {
    let clock = Clock(noon)
    let (stats, defaults, suite) = makeStats(clock: clock)
    defer { cleanUp(defaults, suite) }

    stats.observe(document: "a", characters: 0)
    stats.observe(document: "a", characters: 640)
    stats.settle()

    let reopened = WritingStats(defaults: defaults, calendar: shanghai, now: { clock.now })
    #expect(reopened.today == 640)
    #expect(reopened.total(on: noon) == 640)
}

/// 过了午夜，昨天没落账的那一段仍归昨天。
@MainActor
@Test func crossingMidnightLeavesYesterdaysDeltaOnYesterday() throws {
    let clock = Clock(noon)
    let (stats, defaults, suite) = makeStats(clock: clock)
    defer { cleanUp(defaults, suite) }

    stats.observe(document: "a", characters: 0)
    stats.observe(document: "a", characters: 300)
    #expect(stats.today == 300)

    clock.advance(days: 1)

    // 第二天打开新的一篇：昨天的增量落账，今天从零开始
    stats.observe(document: "b", characters: 0)
    #expect(stats.today == 0)
    #expect(stats.total(on: noon) == 300)

    stats.observe(document: "b", characters: 90)
    #expect(stats.today == 90)
    #expect(stats.total(on: noon) == 300)
}

/// 账本只留一年：再往前没人翻，也不该一直长胖。
@MainActor
@Test func ledgerDropsEntriesOlderThanAYear() throws {
    let clock = Clock(noon)
    let suite = "wtmd.tests.writing.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { cleanUp(defaults, suite) }

    let kept = shanghai.date(byAdding: .day, value: -300, to: noon)!
    let dropped = shanghai.date(byAdding: .day, value: -500, to: noon)!
    let ledger = [dayKey(dropped): 1_000, dayKey(kept): 500, dayKey(noon): 42]
    let data = try JSONEncoder().encode(ledger)
    defaults.set(String(data: data, encoding: .utf8), forKey: "wtmd.writingStats.ledger")

    let stats = WritingStats(defaults: defaults, calendar: shanghai, now: { clock.now })

    #expect(stats.today == 42)
    #expect(stats.total(on: kept) == 500)
    #expect(stats.total(on: dropped) == 0)
}

private func dayKey(_ date: Date) -> String {
    let parts = shanghai.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}

// MARK: - 目标

@Test func goalFractionStaysBetweenZeroAndOne() {
    #expect(WritingGoal.fraction(total: 0, goal: 800) == 0)
    #expect(WritingGoal.fraction(total: 400, goal: 800) == 0.5)
    #expect(WritingGoal.fraction(total: 900, goal: 800) == 1)
    // 没设目标、或者今天净删了字：条停在起点，不反向画
    #expect(WritingGoal.fraction(total: 400, goal: 0) == 0)
    #expect(WritingGoal.fraction(total: -120, goal: 800) == 0)
}

@Test func goalIsReachedOnlyWithAGoal() {
    #expect(WritingGoal.isReached(total: 800, goal: 800))
    #expect(WritingGoal.isReached(total: 1_200, goal: 800))
    #expect(!WritingGoal.isReached(total: 799, goal: 800))
    #expect(!WritingGoal.isReached(total: 800, goal: 0))
}
