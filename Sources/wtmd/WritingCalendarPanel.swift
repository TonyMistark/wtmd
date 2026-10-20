import SwiftUI

// MARK: - 热力格几何

/// 网格怎么摆、点到哪一格——纯算术，视图和测试共用一份。
///
/// 放在视图外面是因为「点歪一格」这种事最难靠肉眼发现：格子只有十来个点宽，
/// 差一个 `step` 就是另一天。这里给的是可测的换算，画和点都走它。
enum WritingHeatmapLayout {
    static let cell: CGFloat = 10
    static let gap: CGFloat = 3
    static let rows = 7

    static var step: CGFloat { cell + gap }

    static func origin(column: Int, row: Int) -> CGPoint {
        CGPoint(x: CGFloat(column) * step, y: CGFloat(row) * step)
    }

    static func size(columns: Int) -> CGSize {
        CGSize(
            width: CGFloat(max(columns, 1)) * step - gap,
            height: CGFloat(rows) * step - gap
        )
    }

    /// 点在哪一格。落在格与格之间的缝里也算最近的那一格——
    /// 缝只有 3 点宽，苛求点准只会让人点空。
    static func hit(at point: CGPoint, columns: Int) -> (column: Int, row: Int)? {
        guard point.x >= 0, point.y >= 0, columns > 0 else { return nil }
        let column = Int(point.x / step)
        let row = Int(point.y / step)
        guard column < columns, row < rows else { return nil }
        return (column, row)
    }
}

// MARK: - 文案

/// 数字与日期的写法。单独拎出来是因为它们要能被断言——
/// 「+1,240」和「+1240」在面板上是两种观感，靠肉眼守不住。
enum WritingCalendarText {
    /// 千分位。自己数，不用 `formatted()`：后者的分组符跟着系统语言走，
    /// 中文系统给「1,240」、德语给「1.240」，测试没法写死。
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out
    }

    /// 带符号的净增：正数带 `+`，负数用真正的减号（不是连字符）。
    static func signed(_ value: Int) -> String {
        if value > 0 { return "+" + grouped(value) }
        if value < 0 { return "−" + grouped(value) }
        return "0"
    }

    static func dayLabel(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.isChinese ? "zh_CN" : "en_US")
        formatter.dateFormat = L10n.isChinese ? "M 月 d 日" : "MMM d"
        return formatter
    }()
}

// MARK: - 面板

/// 写作日历：一年一眼看完。
///
/// 数据全来自 `WritingStats` 那本账——这版不新增任何存储。面板只做三件事：
/// 把摘要摆出来、把一年画成格子、点开某天看看那天写了多少。
struct WritingCalendarPanel: View {
    let days: [WritingCalendar.Day]
    let goal: Int
    let close: () -> Void

    @State private var selected: WritingCalendar.Day?

    private var calendar: Calendar { .current }
    private var columns: [[WritingCalendar.Day?]] {
        WritingCalendar.weeks(days, calendar: calendar)
    }
    private var summary: WritingCalendar.Summary {
        WritingCalendar.summary(in: days, endingAt: days.last?.date ?? Date(), calendar: calendar)
    }
    private var hasAnyWriting: Bool { summary.writingDays > 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if hasAnyWriting {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summaryRow
                        heatmap
                        footnote
                    }
                    .padding(16)
                }
            } else {
                empty
            }

            Divider()
            footer
        }
        .frame(width: 780, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Writing Calendar", "写作日历"))
                .font(.headline)
            Text(t(
                "How much you added each day over the past year. Deletions count against the day too — some days are bound to go down.",
                "过去一年里，每一天净增了多少字。删掉的字照样扣，所以有的日子是往下走的。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 摘要

    private var summaryRow: some View {
        HStack(spacing: 10) {
            summaryCard(
                title: t("Streak", "连续"),
                value: t("\(summary.streak) days", "\(summary.streak) 天"),
                detail: summary.streak > 0
                    ? t("today counts", "今天也算进去了")
                    : t("start again today", "今天起重新算")
            )
            summaryCard(
                title: t("This Month", "本月"),
                value: WritingCalendarText.signed(summary.monthTotal),
                detail: t("net characters", "净增字数")
            )
            summaryCard(
                title: t("This Year", "今年"),
                value: WritingCalendarText.signed(summary.yearTotal),
                detail: t("net characters", "净增字数")
            )
            summaryCard(
                title: t("Best Day", "最高单日"),
                value: summary.best.map { WritingCalendarText.signed($0.total) } ?? "0",
                detail: summary.best.map { WritingCalendarText.dayLabel($0.date) } ?? t("no data yet", "还没有")
            )
        }
    }

    private func summaryCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.045))
        )
    }

    // MARK: 热力格

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                Canvas { context, _ in
                    for (columnIndex, column) in columns.enumerated() {
                        for (rowIndex, day) in column.enumerated() {
                            guard let day else { continue }
                            let rect = CGRect(
                                origin: WritingHeatmapLayout.origin(column: columnIndex, row: rowIndex),
                                size: CGSize(
                                    width: WritingHeatmapLayout.cell,
                                    height: WritingHeatmapLayout.cell
                                )
                            )
                            let path = Path(roundedRect: rect, cornerRadius: 2)
                            if day.isDeletion {
                                // 删字的那天：空心的格子。它不是「没写」，
                                // 只是这一天是往下走的——不填色，但也不许消失。
                                context.stroke(
                                    path,
                                    with: .color(Color.secondary.opacity(0.55)),
                                    lineWidth: 1
                                )
                            } else {
                                let level = WritingCalendar.level(total: day.total, goal: goal)
                                context.fill(path, with: .color(color(for: level)))
                            }
                            if day.id == selected?.id || isToday(day) {
                                context.stroke(
                                    path,
                                    with: .color(Color.primary.opacity(0.55)),
                                    lineWidth: 1
                                )
                            }
                        }
                    }
                }
                .frame(
                    width: WritingHeatmapLayout.size(columns: columns.count).width,
                    height: WritingHeatmapLayout.size(columns: columns.count).height
                )
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        guard let hit = WritingHeatmapLayout.hit(
                            at: value.location, columns: columns.count
                        ) else {
                            selected = nil
                            return
                        }
                        selected = columns[hit.column][hit.row]
                    }
                )
            }

            HStack(spacing: 8) {
                Text(selected.map { selectedLabel($0) }
                    ?? t("Click a square to see that day.", "点一个格子，看看那天。"))
                .font(.caption)
                .foregroundStyle(selected == nil ? .tertiary : .secondary)
                .monospacedDigit()

                Spacer()

                legend
            }
        }
    }

    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: WritingHeatmapLayout.gap) {
            ForEach(0..<WritingHeatmapLayout.rows, id: \.self) { row in
                Text(weekdayLabel(row))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(height: WritingHeatmapLayout.cell, alignment: .center)
            }
        }
        .frame(width: 22, alignment: .trailing)
        .padding(.top, 0)
    }

    /// 隔行标一个：七个标签全标太吵，隔行也照样看得出周界。
    private func weekdayLabel(_ row: Int) -> String {
        guard row % 2 == 0 else { return "" }
        let names = L10n.isChinese
            ? ["一", "二", "三", "四", "五", "六", "日"]
            : ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return names[row]
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text(t("Less", "少"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(0..<WritingCalendar.levels, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: level))
                    .frame(width: 9, height: 9)
            }
            Text(t("More", "多"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var footnote: some View {
        Text(t(
            "Kept on this Mac for the last 365 days. Nothing leaves the machine.",
            "账本存在这台 Mac 上，只留最近 365 天，不上传任何地方。"
        ))
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(t("Nothing recorded yet.", "还没有记账。"))
                .font(.callout)
                .foregroundStyle(.tertiary)
            Text(t("Write for a few days and this fills up on its own.", "写上几天，这里自然就有了。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: 脚部

    private var footer: some View {
        HStack {
            if goal > 0 {
                Text(t("Shades follow your daily goal of \(goal).", "深浅跟着每日目标 \(goal) 字走。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(t("Set a daily goal and the shades will follow it.", "设了每日目标，深浅就跟着目标走。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(t("Close", "关闭"), action: close)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: 细节

    private func color(for level: Int) -> Color {
        switch level {
        case 0: return Color.secondary.opacity(0.12)
        case 1: return Color.accentColor.opacity(0.28)
        case 2: return Color.accentColor.opacity(0.50)
        case 3: return Color.accentColor.opacity(0.74)
        default: return Color.accentColor
        }
    }

    private func isToday(_ day: WritingCalendar.Day) -> Bool {
        calendar.isDateInToday(day.date)
    }

    private func selectedLabel(_ day: WritingCalendar.Day) -> String {
        let amount = WritingCalendarText.signed(day.total)
        return t(
            "\(WritingCalendarText.dayLabel(day.date)) · \(amount) characters",
            "\(WritingCalendarText.dayLabel(day.date)) · \(amount) 字"
        )
    }
}
