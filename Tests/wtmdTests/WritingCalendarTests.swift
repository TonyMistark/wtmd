import Foundation
import Testing
@testable import wtmd

// MARK: - 写作日历

/// 账本本身早在 v0.8 就记起来了，这组用例守的是「怎么读」：
/// 空白天补齐、档位分得对、连续天数不被半天的今天误断、一周一列不串行。
/// 全部是纯函数，所以钟点固定在某一刻，跨天不用等明天。

/// 上海时区、周一起始——`firstWeekday` 写死，周排布才有确定的期望值。
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.firstWeekday = 2
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    return calendar.date(from: components)!
}

private let end = date(2026, 10, 20)

private func day(_ date: Date, _ total: Int) -> WritingCalendar.Day {
    WritingCalendar.Day(date: calendar.startOfDay(for: date), total: total)
}

/// 账本 → 取数闭包。键走生产代码那一份 `WritingDayKey`，口径不会两处漂。
private func totals(_ ledger: [Date: Int]) -> (Date) -> Int {
    let table = Dictionary(
        uniqueKeysWithValues: ledger.map { (WritingDayKey.string(for: $0.key, calendar: calendar), $0.value) }
    )
    return { table[WritingDayKey.string(for: $0, calendar: calendar)] ?? 0 }
}

@Suite("写作日历")
struct WritingCalendarTests {
    // MARK: 逐日序列

    @Test("最近 N 天从旧到新，没记账的日子补 0")
    func daysArePaddedAndOrdered() {
        let series = WritingCalendar.days(
            endingAt: end, count: 5, calendar: calendar,
            total: totals([date(2026, 10, 18): 300, end: 1200])
        )

        #expect(series.count == 5)
        #expect(series.map(\.total) == [0, 0, 300, 0, 1200])
        #expect(series.first?.date == calendar.startOfDay(for: date(2026, 10, 16)))
        #expect(series.last?.date == calendar.startOfDay(for: end))
    }

    @Test("取 365 天，首尾不多不少")
    func yearWindowIsExact() {
        let series = WritingCalendar.days(
            endingAt: end, count: 365, calendar: calendar, total: { _ in 0 }
        )

        #expect(series.count == 365)
        #expect(series.first?.date == calendar.startOfDay(for: date(2025, 10, 21)))
        #expect(series.last?.date == calendar.startOfDay(for: end))
    }

    @Test("count 为 0 时没有一天")
    func emptyWindow() {
        let series = WritingCalendar.days(endingAt: end, count: 0, calendar: calendar, total: { _ in 0 })
        #expect(series.isEmpty)
        #expect(WritingCalendar.streak(in: series) == 0)
        #expect(WritingCalendar.weeks(series, calendar: calendar).isEmpty)
    }

    // MARK: 档位

    @Test("设了目标：按目标比例分四档")
    func levelFollowsGoal() {
        let goal = 1000
        #expect(WritingCalendar.level(total: 0, goal: goal) == 0)
        #expect(WritingCalendar.level(total: 499, goal: goal) == 1)
        #expect(WritingCalendar.level(total: 500, goal: goal) == 2)
        #expect(WritingCalendar.level(total: 999, goal: goal) == 2)
        #expect(WritingCalendar.level(total: 1000, goal: goal) == 3)
        #expect(WritingCalendar.level(total: 1999, goal: goal) == 3)
        #expect(WritingCalendar.level(total: 2000, goal: goal) == 4)
        #expect(WritingCalendar.level(total: 99_999, goal: goal) == 4)
    }

    @Test("没设目标：按绝对字数分档")
    func levelFallsBackToAbsoluteSteps() {
        #expect(WritingCalendar.level(total: 1, goal: 0) == 1)
        #expect(WritingCalendar.level(total: 499, goal: 0) == 1)
        #expect(WritingCalendar.level(total: 500, goal: 0) == 2)
        #expect(WritingCalendar.level(total: 999, goal: 0) == 2)
        #expect(WritingCalendar.level(total: 1000, goal: 0) == 3)
        #expect(WritingCalendar.level(total: 1999, goal: 0) == 3)
        #expect(WritingCalendar.level(total: 2000, goal: 0) == 4)
        #expect(WritingCalendar.level(total: 4000, goal: 0) == 4)
    }

    @Test("删掉字的那天：档位为 0，但认得出是删过字")
    func deletionDayIsMarked() {
        let day = WritingCalendar.Day(date: end, total: -320)
        #expect(WritingCalendar.level(total: day.total, goal: 0) == 0)
        #expect(day.isDeletion)
        #expect(!WritingCalendar.Day(date: end, total: 0).isDeletion)
    }

    // MARK: 连续

    @Test("今天写了：连续把今天算进去")
    func streakCountsToday() {
        let series = [
            day(date(2026, 10, 18), 100),
            day(date(2026, 10, 19), 200),
            day(end, 300),
        ]
        #expect(WritingCalendar.streak(in: series) == 3)
    }

    @Test("今天还没写：从昨天算，不因为一天没过完就先断")
    func streakFallsBackToYesterday() {
        let series = [
            day(date(2026, 10, 18), 100),
            day(date(2026, 10, 19), 200),
            day(end, 0),
        ]
        #expect(WritingCalendar.streak(in: series) == 2)
    }

    @Test("今天在删字：也算还没写，从昨天数")
    func streakIgnoresDeletionToday() {
        let series = [
            day(date(2026, 10, 19), 200),
            day(end, -80),
        ]
        #expect(WritingCalendar.streak(in: series) == 1)
    }

    @Test("中间空一天，连续就断在那里")
    func streakBreaksOnGap() {
        let series = [
            day(date(2026, 10, 16), 100),
            day(date(2026, 10, 17), 100),
            day(date(2026, 10, 18), 0),
            day(date(2026, 10, 19), 100),
            day(end, 100),
        ]
        #expect(WritingCalendar.streak(in: series) == 2)
    }

    @Test("一天没写：连续为 0")
    func streakEmptyWhenNothingWritten() {
        let series = (0..<5).map { _ in day(end, 0) }
        #expect(WritingCalendar.streak(in: series) == 0)
    }

    // MARK: 摘要

    @Test("摘要：写作天数、合计、最高单日、本月与今年")
    func summaryAggregates() {
        // 窗口四十天（9/11–10/20），跨月的数据才分得开 monthTotal 与 yearTotal。
        let series = WritingCalendar.days(
            endingAt: end, count: 40, calendar: calendar,
            total: totals([
                date(2026, 9, 30): 900,
                date(2026, 10, 18): 300,
                date(2026, 10, 19): 1200,
                end: 800,
            ])
        )
        let summary = WritingCalendar.summary(in: series, endingAt: end, calendar: calendar)

        #expect(summary.writingDays == 4)
        #expect(summary.total == 3200)
        #expect(summary.best?.total == 1200)
        #expect(summary.best?.date == calendar.startOfDay(for: date(2026, 10, 19)))
        #expect(summary.streak == 3)
        #expect(summary.monthTotal == 2300)
        #expect(summary.yearTotal == 3200)
    }

    @Test("最高单日平手：取更近的那天")
    func bestPrefersMostRecentTie() {
        let series = [
            day(date(2026, 10, 18), 800),
            day(date(2026, 10, 19), 800),
        ]
        let summary = WritingCalendar.summary(in: series, endingAt: end, calendar: calendar)
        #expect(summary.best?.date == calendar.startOfDay(for: date(2026, 10, 19)))
    }

    @Test("一天没写的窗口：摘要不炸，最高单日为空")
    func summaryOnEmptyLedger() {
        let series = WritingCalendar.days(endingAt: end, count: 7, calendar: calendar, total: { _ in 0 })
        let summary = WritingCalendar.summary(in: series, endingAt: end, calendar: calendar)

        #expect(summary.streak == 0)
        #expect(summary.writingDays == 0)
        #expect(summary.total == 0)
        #expect(summary.best == nil)
        #expect(summary.monthTotal == 0)
        #expect(summary.yearTotal == 0)
    }

    // MARK: 周排布

    @Test("从周一起连续两周：两列、每列七格、没有空位")
    func fortnightFillsTwoColumns() {
        // 先落到本周周一，再取从这天起的十四天——首日一定是周首，不该有空位。
        let monday = calendar.date(
            byAdding: .day,
            value: -WritingCalendar.weekdayIndex(for: end, calendar: calendar),
            to: calendar.startOfDay(for: end)
        )!
        let last = calendar.date(byAdding: .day, value: 13, to: monday)!
        let series = WritingCalendar.days(
            endingAt: last, count: 14, calendar: calendar,
            total: totals([monday: 100])
        )
        let columns = WritingCalendar.weeks(series, calendar: calendar)

        #expect(columns.count == 2)
        #expect(columns.allSatisfy { $0.count == 7 && $0.allSatisfy { $0 != nil } })
        #expect(columns[0][0]?.date == calendar.startOfDay(for: monday))
    }

    @Test("首列前面的空位按星期对齐，末尾补满七格")
    func firstColumnIsPadded() {
        let series = WritingCalendar.days(
            endingAt: end, count: 1, calendar: calendar, total: { _ in 0 }
        )
        let columns = WritingCalendar.weeks(series, calendar: calendar)
        let lead = WritingCalendar.weekdayIndex(for: series[0].date, calendar: calendar)

        #expect(columns.count == 1)
        #expect(columns[0].count == 7)
        #expect(columns[0].prefix(lead).allSatisfy { $0 == nil })
        #expect(columns[0][lead]?.date == series[0].date)
        #expect(columns[0].suffix(6 - lead).allSatisfy { $0 == nil })
    }

    @Test("日期顺序不串行：第 n 列第 m 格就是序列里该位置那一天")
    func columnsPreserveOrder() {
        let series = WritingCalendar.days(
            endingAt: end, count: 40, calendar: calendar, total: { _ in 0 }
        )
        let columns = WritingCalendar.weeks(series, calendar: calendar)
        let flattened = columns.flatMap { $0 }.compactMap { $0 }

        #expect(flattened.map(\.date) == series.map(\.date))
        #expect(columns.allSatisfy { $0.count == 7 })
    }
}
