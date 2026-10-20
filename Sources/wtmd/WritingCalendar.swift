import Foundation

// MARK: - 日期键

/// 「日期 → 账」这件事只该有一种写法。
///
/// 账本键（`yyyy-MM-dd`）原来藏在 `WritingStats` 里，日历要按同一天去翻账，
/// 两处各写一遍迟早会漂（时区、日历标识、补零位数）。提到这里，两边共用。
enum WritingDayKey {
    static func string(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }
}

// MARK: - 写作日历

/// 把「日期 → 净增」整理成能画的样子：逐日序列、深浅档位、连续天数、一周一列。
///
/// 全是纯函数：输入日期与取数闭包，输出数据；不读 defaults、不问 `Date()`，
/// 所以测试不用等明天也能验跨天与连续。视图只负责把 `level` 换成颜色。
enum WritingCalendar {
    /// 一天。`total` 是净增——删掉的字照样扣，所以可能是负数。
    struct Day: Identifiable, Equatable {
        let date: Date
        let total: Int

        var id: Date { date }
        /// 这一天净减了字数。删字也是写过的一天，不能在格子上假装不存在。
        var isDeletion: Bool { total < 0 }
    }

    struct Summary: Equatable {
        /// 当前连续写作天数（今天还没写时从昨天算）。
        let streak: Int
        /// 窗口里真正写了字的天数。
        let writingDays: Int
        /// 窗口净增合计。
        let total: Int
        /// 写得最多的一天；平手取更近的那天。一天没写时为 nil。
        let best: Day?
        /// 结束那天所在月份 / 年份的净增。
        let monthTotal: Int
        let yearTotal: Int
    }

    /// 颜色档位数：0（没写）到 4（写得最多）。
    static let levels = 5

    /// 没设每日目标时的绝对档下限：1 / 500 / 1000 / 2000，到 4000 封顶。
    static let absoluteSteps = [500, 1000, 2000, 4000]

    /// 最近 `count` 天逐日，从旧到新；缺的日子补 0。
    ///
    /// 空白天在数据层就补齐，视图里不用到处判空。
    static func days(
        endingAt end: Date,
        count: Int,
        calendar: Calendar,
        total: (Date) -> Int
    ) -> [Day] {
        guard count > 0 else { return [] }
        let last = calendar.startOfDay(for: end)
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: last) else {
                return nil
            }
            return Day(date: date, total: total(date))
        }
    }

    /// 一天的深浅。设了目标按目标比例，没设目标按绝对字数。
    static func level(total: Int, goal: Int) -> Int {
        guard total > 0 else { return 0 }
        if goal > 0 {
            if total * 2 < goal { return 1 }
            if total < goal { return 2 }
            if total < goal * 2 { return 3 }
            return 4
        }
        if total < absoluteSteps[0] { return 1 }
        if total < absoluteSteps[1] { return 2 }
        if total < absoluteSteps[2] { return 3 }
        return 4
    }

    /// 连续写了多少天。
    ///
    /// 今天还没写不算断——一天才过了一半，先按昨天算；中间空一天才真的断。
    static func streak(in days: [Day]) -> Int {
        guard !days.isEmpty else { return 0 }
        var index = days.count - 1
        if days[index].total <= 0 { index -= 1 }
        var count = 0
        while index >= 0, days[index].total > 0 {
            count += 1
            index -= 1
        }
        return count
    }

    static func summary(in days: [Day], endingAt end: Date, calendar: Calendar) -> Summary {
        var writingDays = 0
        var total = 0
        var best: Day?
        let month = calendar.component(.month, from: end)
        let year = calendar.component(.year, from: end)
        var monthTotal = 0
        var yearTotal = 0

        for day in days {
            total += day.total
            guard day.total > 0 else { continue }
            writingDays += 1
            // 平手取更近的那天：说「最近一次写到这么多」比「第一次」有用。
            if best == nil || day.total >= best!.total { best = day }
            let dayYear = calendar.component(.year, from: day.date)
            if dayYear == year {
                yearTotal += day.total
                if calendar.component(.month, from: day.date) == month {
                    monthTotal += day.total
                }
            }
        }

        return Summary(
            streak: streak(in: days),
            writingDays: writingDays,
            total: total,
            best: best,
            monthTotal: monthTotal,
            yearTotal: yearTotal
        )
    }

    /// 一天在一周里的位置：0 是这周第一天（跟着日历的 `firstWeekday` 走）。
    static func weekdayIndex(for date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        let first = calendar.firstWeekday
        return (weekday - first + 7) % 7
    }

    /// 把连续的逐日序列切成一周一列，每列恰好 7 格；首列前置空位、末列后置空位。
    ///
    /// `days` 必须是连续的（`days(endingAt:count:calendar:total:)` 的产物）。
    static func weeks(_ days: [Day], calendar: Calendar) -> [[Day?]] {
        guard let first = days.first else { return [] }
        var current: [Day?] = Array(
            repeating: nil, count: weekdayIndex(for: first.date, calendar: calendar)
        )
        var columns: [[Day?]] = []

        for day in days {
            current.append(day)
            if current.count == 7 {
                columns.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            current.append(contentsOf: Array(repeating: nil, count: 7 - current.count))
            columns.append(current)
        }
        return columns
    }
}
