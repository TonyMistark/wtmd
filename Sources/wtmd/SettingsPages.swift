import SwiftUI

// MARK: - 设置的几页

/// 设置窗口的五页尺寸统一：切页不跳窗。原来两页（460×760 / 480×520）
/// 一切换整扇窗就变个大小，眼睛得重新找一遍。
enum SettingsPage {
    static let width: CGFloat = 480
    static let height: CGFloat = 520
}

/// 写作：打字机、专注、每日字数目标。
///
/// 这三项原本挤在「主题」页的下半截，得往下滚才看得见——功能中心点了
/// 「每日目标」却落在最上面，读者只会以为没反应。一页一件事，点了就看得见。
struct WritingSettingsView: View {
    @EnvironmentObject var writing: WritingSettings

    var body: some View {
        Form {
            Section(t("Writing", "写作")) {
                Toggle(t("Typewriter Mode", "打字机模式"), isOn: $writing.typewriter)
                Toggle(t("Focus Mode", "专注模式"), isOn: $writing.focusMode)
                Toggle(t("Daily character goal", "每日字数目标"), isOn: goalEnabled)
                if writing.dailyGoal > 0 {
                    Stepper(value: $writing.dailyGoal, in: 100...10_000, step: 100) {
                        Text(t(
                            "\(writing.dailyGoal.formatted()) characters a day",
                            "每天 \(writing.dailyGoal.formatted()) 字"
                        ))
                        .monospacedDigit()
                    }
                }
                Text(t(
                    "Typewriter keeps the caret line centred; focus dims everything outside the current paragraph. Both can be on at once.",
                    "打字机让光标行停在屏幕中部；专注把当前段落之外的内容退成浅灰。两者可同时开启。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(t(
                    "The goal counts net characters: deleting takes them back off. It shows up in the status bar only once a goal is set.",
                    "目标算的是净增：删字会扣回去。设了目标之后，状态栏才会出现今日进度。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsPage.width, height: SettingsPage.height)
    }

    /// 开关与数字写在同一个值上：0 就是关。省掉「开了但没填」这种半吊子状态。
    private var goalEnabled: Binding<Bool> {
        Binding(
            get: { writing.dailyGoal > 0 },
            set: { writing.dailyGoal = $0 ? 800 : 0 }
        )
    }
}

/// 版式：版心、字号、行距——只影响预览，颜色与字体仍由主题决定。
struct LayoutSettingsView: View {
    @EnvironmentObject var typesetting: TypesettingSettings

    var body: some View {
        Form {
            Section(t("Reading Layout", "阅读版式")) {
                LayoutSliderRow(
                    title: t("Measure", "版心宽度"),
                    value: "\(typesetting.measure) px",
                    binding: Binding(
                        get: { Double(typesetting.measure) },
                        set: { typesetting.measure = Int($0) }
                    ),
                    range: 480...1_100,
                    step: 20
                )
                LayoutSliderRow(
                    title: t("Text size", "正文字号"),
                    value: "\(typesetting.fontSize) px",
                    binding: Binding(
                        get: { Double(typesetting.fontSize) },
                        set: { typesetting.fontSize = Int($0) }
                    ),
                    range: 14...22,
                    step: 1
                )
                LayoutSliderRow(
                    title: t("Line height", "行距"),
                    value: String(format: "%.2f", typesetting.lineHeight),
                    binding: $typesetting.lineHeight,
                    range: 1.4...2.2,
                    step: 0.05
                )
                HStack {
                    Text(t(
                        "Preview only: colours and fonts still come from the theme.",
                        "只影响预览；颜色与字体仍由主题决定。"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Restore Defaults", "恢复默认")) { typesetting.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsPage.width, height: SettingsPage.height)
    }
}

/// 打印：页边距、页码、第一页印文档名。
struct PrintingSettingsView: View {
    @EnvironmentObject var printing: PrintSettings

    var body: some View {
        Form {
            Section(t("Printing", "打印")) {
                LayoutSliderRow(
                    title: t("Page margin", "页边距"),
                    value: String(format: "%.0f mm", printing.marginMM),
                    binding: $printing.marginMM,
                    range: PrintLayout.marginRange,
                    step: 1
                )
                Toggle(t("Page numbers", "页码"), isOn: $printing.pageNumbers)
                Toggle(t("Document title on the first page", "第一页印文档名"), isOn: $printing.showTitle)
                Text(t(
                    "Applies to Print / Save as PDF. Text size and line height follow the reading layout; the measure narrows to the page width.",
                    "作用于「打印 / 存为 PDF」。字号与行距沿用阅读版式，版心按页宽归一。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsPage.width, height: SettingsPage.height)
    }
}

/// 一行「标题 + 滑块 + 当前值」：几个版式值长得一样，就不各写一遍。
struct LayoutSliderRow: View {
    let title: String
    let value: String
    let binding: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: binding, in: range, step: step)
                    .frame(width: 160)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}
