import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置的几页

/// 每一页都铺满右侧的内容区：窗口尺寸固定，切页不跳窗，也不该在右下角
/// 留一块空白。表单自己会滚动，长内容不会被截掉。
private extension View {
    func settingsPage() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 个人信息

/// 昵称与头像。只存本地——这页上那句话是承诺，不是装饰。
struct ProfileSettingsView: View {
    @EnvironmentObject var profile: ProfileStore
    /// 选中的文件读不出来时给一句人话，而不是静悄悄什么都不发生。
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    ProfileAvatar(image: profile.avatar, initial: profile.initial, size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button(t("Choose Picture…", "选择图片…")) { choosePicture() }
                            if profile.avatar != nil {
                                Button(t("Remove", "移除")) { profile.clearAvatar() }
                            }
                        }
                        Text(t(
                            "PNG, JPEG or HEIC. Kept on this Mac, never uploaded.",
                            "PNG、JPEG 或 HEIC。只留在这台 Mac 上，不会上传。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let failure {
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.vertical, 4)

                TextField(
                    t("Nickname", "昵称"),
                    text: $profile.nickname,
                    prompt: Text(t("What should we call you?", "怎么称呼你？"))
                )
                .textFieldStyle(.roundedBorder)
            }

            Section {
                Text(t(
                    "Your name and picture stay in this app's own folder. They never leave the machine and are not written into any document.",
                    "昵称与头像只存在这个应用自己的文件夹里，不离开这台机器，也不会写进任何文档。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .settingsPage()
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = t("Choose", "选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if profile.setAvatar(from: url) {
            failure = nil
        } else {
            failure = t("That file could not be read as a picture.", "这个文件读不成图片。")
        }
    }
}

// MARK: - 写作

/// 写作：打字机、专注、每日字数目标。
///
/// 这三项原本挤在「主题」页的下半截，得往下滚才看得见——从工具栏点
/// 「每日目标」却落在最上面，读者只会以为没反应。一页一件事，点了就看得见。
struct WritingSettingsView: View {
    @EnvironmentObject var writing: WritingSettings

    var body: some View {
        Form {
            Section {
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
        .settingsPage()
    }

    /// 开关与数字写在同一个值上：0 就是关。省掉「开了但没填」这种半吊子状态。
    private var goalEnabled: Binding<Bool> {
        Binding(
            get: { writing.dailyGoal > 0 },
            set: { writing.dailyGoal = $0 ? 800 : 0 }
        )
    }
}

// MARK: - 版式

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
        .settingsPage()
    }
}

// MARK: - 打印

/// 打印：页边距、页码、第一页印文档名。
struct PrintingSettingsView: View {
    @EnvironmentObject var printing: PrintSettings

    var body: some View {
        Form {
            Section {
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
        .settingsPage()
    }
}

// MARK: - 应用

/// 应用：版本、更新、关于、崩溃报告去哪找。
///
/// 原来这些是功能中心里的几行，点一下开 sheet。进了设置页之后，它们是
/// **看得见状态**的：现在是什么版本、上次检查结果如何、报告存在哪。
struct AppSettingsView: View {
    @EnvironmentObject var updates: UpdateChecker
    @EnvironmentObject var crashes: CrashStore

    var body: some View {
        Form {
            Section(t("Version", "版本")) {
                LabeledContent(t("wtmd", "wtmd"), value: updates.currentVersion)
                LabeledContent(t("System", "系统"), value: CrashEnvironment.systemDescription)
                HStack {
                    Text(updates.status.summary ?? t("Not checked yet", "还没检查过"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(updates.isChecking ? t("Checking…", "正在检查…") : t("Check Now", "立即检查")) {
                        Task { await updates.check(force: true) }
                    }
                    .disabled(updates.isChecking)
                }
            }

            Section(t("About", "关于")) {
                Button(t("About wtmd", "关于 wtmd")) { AboutPanel.show() }
                Button(t("Show Crash Reports", "打开崩溃报告文件夹")) {
                    NSWorkspace.shared.open(crashes.directory)
                }
                Text(t(
                    "Reports are kept on this Mac. Nothing is sent unless you press the button that opens an issue.",
                    "报告只存在这台 Mac 上。除非你按下那个开 issue 的按钮，否则不会被发出去。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .settingsPage()
    }
}

// MARK: - 关于面板

/// 系统标准「关于」面板。App 菜单、⌘K、设置里的「应用」页三处共用一个实现。
@MainActor
enum AboutPanel {
    static func show() {
        let repository = "https://github.com/TonyMistark/wtmd"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let credits = NSMutableAttributedString(
            string: t(
                "A local-first Markdown writing and reading tool for macOS.\n",
                "本地优先的 macOS Markdown 写作与阅读工具。\n"
            ) + "github.com/TonyMistark/wtmd",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        credits.addAttribute(
            .link, value: repository,
            range: (credits.string as NSString).range(of: "github.com/TonyMistark/wtmd")
        )
        NSApp?.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp?.activate(ignoringOtherApps: true)
    }
}

// MARK: - 一行控件

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
