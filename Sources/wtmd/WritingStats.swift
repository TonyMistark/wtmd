import Combine
import Foundation

/// 每日净增字数：写作这件事，只有跨天看才看得见。
///
/// 口径是**净增**——同一天里删掉的字照样扣。账本是一份「日期 → 字数」的表，
/// JSON 落在 UserDefaults 里：它比一篇文档小得多，不值得单开一个文件，也不该
/// 跟着工作区搬来搬去。
///
/// 增量平时只留在内存（`pending`），`settle()` 才落账落盘。每敲一个字写一次
/// defaults 是拿磁盘换一个没人看的数字；一天里结算几次，最多丢一个防抖窗口
/// 的字——而切文档与退出前都会先按正文补报一次，连这半秒也补上。
///
/// The store is injectable (defaults + clock) so tests never touch the user's
/// real preferences and can move across midnight without waiting for it.
@MainActor
final class WritingStats: ObservableObject {
    private enum Key {
        static let ledger = "wtmd.writingStats.ledger"
    }

    /// 超过这个天数的记录会在落盘时清掉：一年的日记够回头看，再往前没人翻。
    private static let retentionDays = 365

    /// 今天净增了多少字。状态栏直接读它。
    @Published private(set) var today: Int = 0

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    /// 日期 → 净增字数。键是 `yyyy-MM-dd`，字典序即时间序。
    private var ledger: [String: Int]
    /// 每篇上一次报的字数。
    ///
    /// 单窗口时只要记「上一篇」就够；多窗口下两扇窗会交替报数，只记一篇等于
    /// 每换一次窗口就把另一篇的基线冲掉——那边再敲的字会被当成「换了个地方」，
    /// 一笔都不入账。所以基线按文档分开存。
    private var baselines: [String: Int] = [:]
    /// `baselines` 的最近使用顺序（老的在前面），裁剪时从这里丢。
    private var baselineOrder: [String] = []
    /// 基线表的上限：一天里真开过的文档不会超过这个数，再往前也没人回去改。
    static let baselineLimit = 64
    /// 还没落账的增量，和它属于哪一天（跨天时不能把昨天的算到今天头上）。
    private var pending = 0
    private var pendingDay: String?
    private var dirty = false

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        ledger = Self.decode(defaults.string(forKey: Key.ledger))
        prune()
        refreshToday()
    }

    // MARK: - 记账

    /// 报一次「这一篇现在有多少字」。
    ///
    /// 同一篇报两次，差就是这段时间的净增；某一篇第一次出现只立基线，不记账——
    /// 打开一篇旧稿不代表今天写了那么多。两扇窗各写各的时，两篇的基线同时在，
    /// 交替报数各记各的差。
    func observe(document: String, characters: Int) {
        rolloverIfNeeded()

        guard let previous = baselines[document] else {
            remember(characters, for: document)
            refreshToday()
            return
        }

        remember(characters, for: document)
        let delta = characters - previous
        guard delta != 0 else { return }
        if pendingDay == nil { pendingDay = todayKey }
        pending += delta
        refreshToday()
    }

    /// 把内存里的增量记进账本并落盘。切文档、新建、退出各一次。
    func settle() {
        foldPending()
        persist()
        refreshToday()
    }

    /// 某一天的净增字数（测试与将来的统计页都要用）。
    func total(on date: Date) -> Int {
        let key = dayKey(for: date)
        return (ledger[key] ?? 0) + (pendingDay == key ? pending : 0)
    }

    // MARK: - 内部

    /// 记下这一篇的字数，并把它挪到「最近用过」那一端。
    private func remember(_ characters: Int, for document: String) {
        baselines[document] = characters
        baselineOrder.removeAll { $0 == document }
        baselineOrder.append(document)
        guard baselineOrder.count > Self.baselineLimit else { return }
        let dropped = baselineOrder.count - Self.baselineLimit
        for key in baselineOrder.prefix(dropped) {
            baselines[key] = nil
        }
        baselineOrder.removeFirst(dropped)
    }

    /// 测试用：现在记着几篇的基线。
    var trackedDocuments: Int { baselines.count }

    private func foldPending() {
        guard let day = pendingDay, pending != 0 else { return }
        ledger[day, default: 0] += pending
        pending = 0
        pendingDay = nil
        dirty = true
    }

    /// 跨过午夜：昨天没落账的增量归昨天，今天从零开始。
    private func rolloverIfNeeded() {
        guard let day = pendingDay, day != todayKey else { return }
        foldPending()
        persist()
    }

    private func refreshToday() {
        let key = todayKey
        let value = (ledger[key] ?? 0) + (pendingDay == key ? pending : 0)
        if value != today { today = value }
    }

    private func persist() {
        guard dirty else { return }
        prune()
        let data = try? JSONEncoder().encode(ledger)
        defaults.set(data.flatMap { String(data: $0, encoding: .utf8) }, forKey: Key.ledger)
        dirty = false
    }

    private func prune() {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now()) else {
            return
        }
        let limit = dayKey(for: cutoff)
        ledger = ledger.filter { $0.key >= limit }
    }

    private var todayKey: String { dayKey(for: now()) }

    private func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    private static func decode(_ raw: String?) -> [String: Int] {
        guard let raw, let data = raw.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }
}

// MARK: - 目标

/// 状态栏那条细进度条要的两个数。纯函数，视图里不再算一遍。
enum WritingGoal {
    /// 0…1。没设目标（`goal <= 0`）与负增长都停在 0；超额不把条画到外面去。
    static func fraction(total: Int, goal: Int) -> Double {
        guard goal > 0, total > 0 else { return 0 }
        return min(Double(total) / Double(goal), 1)
    }

    static func isReached(total: Int, goal: Int) -> Bool {
        goal > 0 && total >= goal
    }
}
