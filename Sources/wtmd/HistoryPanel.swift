import AppKit
import SwiftUI

// MARK: - 分组

/// 版本按「今天 / 昨天 / 更早」分堆。
///
/// 不按具体日期分组：一篇稿子的历史通常只跨几天，读者找的是「上午那一版」，
/// 不是「十月十七日那一版」。再早的用一个「更早」兜住，行里仍带日期。
enum HistoryDay: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case earlier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return t("Today", "今天")
        case .yesterday: return t("Yesterday", "昨天")
        case .earlier: return t("Earlier", "更早")
        }
    }

    init(date: Date, now: Date = Date(), calendar: Calendar = .current) {
        if calendar.isDate(date, inSameDayAs: now) {
            self = .today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            self = .yesterday
        } else {
            self = .earlier
        }
    }
}

/// 面板左侧的一堆。`id` 用「天」，同一堆里的版本按时间倒序。
struct HistoryGroup: Identifiable {
    let day: HistoryDay
    let entries: [HistoryEntry]

    var id: HistoryDay { day }

    /// 把一串版本（已按时间倒序）分堆，空的堆不出现。
    static func sections(
        of entries: [HistoryEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HistoryGroup] {
        var buckets: [HistoryDay: [HistoryEntry]] = [:]
        for entry in entries {
            let day = HistoryDay(date: entry.savedAt, now: now, calendar: calendar)
            buckets[day, default: []].append(entry)
        }
        return HistoryDay.allCases.compactMap { day in
            guard let items = buckets[day], !items.isEmpty else { return nil }
            return HistoryGroup(day: day, entries: items)
        }
    }
}

// MARK: - 面板

/// 版本历史：左边翻，右边看，底下取回。
///
/// 它是一叠稿纸，不是一场对话——旧版已经在那儿了，这里只提供「看一看 / 取回 /
/// 删掉」三个动作，随时可以关掉走人。预览是**只读的源码**：读者要判断的是
/// 「这是不是我要找的那一版」，原样的字比排版后的样子更贴近这个判断。
struct HistoryPanel: View {
    let documentName: String
    let entries: [HistoryEntry]
    /// 历史所在的文件夹（测试里是临时目录，正式运行时是 `Application Support`）。
    let folder: URL?
    let restore: (HistoryEntry) -> Void
    let delete: (HistoryEntry) -> Void
    let clearAll: () -> Void
    let close: () -> Void

    @State private var selection: HistoryEntry.ID?
    @State private var pending: PendingAction?

    private enum PendingAction: Identifiable {
        case delete(HistoryEntry)
        case clearAll

        var id: String {
            switch self {
            case .delete(let entry): return "delete-\(entry.id.absoluteString)"
            case .clearAll: return "clear"
            }
        }
    }

    private var selectedEntry: HistoryEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if entries.isEmpty {
                empty
            } else {
                HSplitView {
                    browser
                        .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
                    preview
                        .frame(minWidth: 380, maxWidth: .infinity)
                }
            }

            Divider()
            footer
        }
        .frame(width: 780, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { syncSelection(preferring: entries.first?.id) }
        .onChange(of: entries) { _, new in
            // 删掉的那一版可能正被选中：退到最近的一版，别让右边空着。
            if !new.contains(where: { $0.id == selection }) {
                syncSelection(preferring: new.first?.id)
            }
        }
        .alert(
            t("Delete this version?", "删掉这一版？"),
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { action in
            switch action {
            case .delete(let entry):
                Button(t("Delete", "删除"), role: .destructive) {
                    delete(entry)
                    pending = nil
                }
            case .clearAll:
                Button(t("Clear All History", "清空全部历史"), role: .destructive) {
                    clearAll()
                    pending = nil
                }
            }
            Button(t("Cancel", "取消"), role: .cancel) { pending = nil }
        } message: { action in
            switch action {
            case .delete:
                Text(t("This version will be gone for good. The text cannot be recovered.", "这一版会被永久删除，内容找不回来。"))
            case .clearAll:
                Text(t("Every kept version of this document will be removed.", "这篇稿子的所有旧版都会被删掉。"))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Version History", "版本历史"))
                .font(.headline)
            Text(t(
                "Every saved version of “\(documentName)”. Pick one to look at it, then put it back in the editor if it is the one you want.",
                "「\(documentName)」写过的每一版都在这里。点开看一眼，是想要的那版就装回编辑器。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(t("No versions kept yet.", "还没有留下旧版。"))
                .font(.callout)
                .foregroundStyle(.tertiary)
            Text(t("A version is kept when you open the file, after a save, and when you leave it.", "打开这篇、每次存盘之后、以及离开它的时候，都会留一版。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var browser: some View {
        List(selection: $selection) {
            ForEach(HistoryGroup.sections(of: entries)) { group in
                Section(group.day.title) {
                    ForEach(group.entries) { entry in
                        row(entry)
                            .tag(entry.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.rowLabel(for: entry))
                    .font(.callout)
                    .monospacedDigit()
                Text(Self.sizeLabel(entry.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(Self.accessibilityLabel(for: entry))
    }

    @ViewBuilder
    private var preview: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(Self.stampFormatter.string(from: entry.savedAt))
                        .font(.callout.weight(.medium))
                    Text(Self.sizeLabel(entry.bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(t("Read-only", "只读"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()

                ScrollView {
                    Text(Self.content(of: entry) ?? t("This version can no longer be read.", "这一版已经读不出来了。"))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        } else {
            Text(t("Choose a version on the left.", "在左边选一版。"))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(t("Open Folder in Finder", "在访达中打开文件夹")) {
                if let folder { NSWorkspace.shared.open(folder) }
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(folder == nil)

            Button(t("Clear All History…", "清空全部历史…")) {
                pending = .clearAll
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(entries.isEmpty)

            Spacer()

            Button(t("Delete…", "删除…")) {
                if let entry = selectedEntry { pending = .delete(entry) }
            }
            .controlSize(.small)
            .disabled(selectedEntry == nil)

            Button(t("Put This Version Back", "装回这一版")) {
                if let entry = selectedEntry { restore(entry) }
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedEntry == nil)
            .help(t("Replaces the editor's text with this version; the current text is kept in the history first", "用这一版替换编辑器里的内容；当前这一版会先存进历史"))

            Button(t("Close", "关闭"), action: close)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func syncSelection(preferring id: HistoryEntry.ID?) {
        if let selection, entries.contains(where: { $0.id == selection }) { return }
        selection = id
    }

    // MARK: - 文案与读取

    private static func content(of entry: HistoryEntry) -> String? {
        try? String(contentsOf: entry.fileURL, encoding: .utf8)
    }

    static func sizeLabel(_ bytes: Int) -> String {
        bytes < 1024
            ? t("\(bytes) bytes", "\(bytes) 字节")
            : t(
                String(format: "%.1f KB", Double(bytes) / 1024),
                String(format: "%.1f KB", Double(bytes) / 1024)
            )
    }

    private static func accessibilityLabel(for entry: HistoryEntry) -> String {
        "\(stampFormatter.string(from: entry.savedAt)), \(sizeLabel(entry.bytes))"
    }

    /// 行首的时间：今天的只报时刻，往前的要带日期——「更早」堆里
    /// 光一个 22:41:52 说不清是哪天的 22 点。
    private static func rowLabel(for entry: HistoryEntry) -> String {
        Calendar.current.isDateInToday(entry.savedAt)
            ? timeFormatter.string(from: entry.savedAt)
            : stampFormatter.string(from: entry.savedAt)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.isChinese ? "zh_CN" : "en_US")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.isChinese ? "zh_CN" : "en_US")
        formatter.dateFormat = L10n.isChinese ? "M月d日 HH:mm:ss" : "MMM d, HH:mm:ss"
        return formatter
    }()
}
