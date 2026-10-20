import AppKit
import SwiftUI

// MARK: - 面板

/// 功能中心：主界面上的一处门，所有「应用级」的东西都从这里进。
///
/// 它不是第二套命令系统——每一行都指向 `CommandCatalog` 里的一条命令，
/// 走的还是 `CommandRuntime`。面板只多做一件菜单做不到的事：**把状态写在
/// 行尾**（今天写了多少、存了几个版本、现在是哪个主题），于是不必点进去
/// 才知道里面有什么。
struct ControlCenterPanel: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var workspace: WorkspaceStore
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var writing: WritingSettings
    @EnvironmentObject var typesetting: TypesettingSettings
    @EnvironmentObject var printing: PrintSettings
    @EnvironmentObject var updates: UpdateChecker
    @EnvironmentObject var overrides: ShortcutOverrides
    var coordinator: WindowCoordinator? = nil

    /// 收起面板。动作执行前先收——有一半命令要开 sheet。
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 { Divider().opacity(0.5) }
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 560)
        }
        .frame(width: 360)
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t("Control Center", "功能中心"))
                .font(.headline)
            Text(t(
                "Writing, appearance, settings — all of it in this window.",
                "写作、外观、设置——都在这扇窗里。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 分组

    private func sectionView(_ section: ControlCenterSection) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .padding(.bottom, 3)
            ForEach(section.rows) { row in
                rowView(row)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ControlCenterRow) -> some View {
        switch row.action {
        case .themes:
            ThemeRow(
                row: row,
                themes: themeManager.themes,
                currentID: themeManager.currentThemeID,
                select: { themeManager.select($0) },
                openFolder: { themeManager.openThemesFolder() },
                rescan: { themeManager.reload() }
            )
        default:
            Button {
                perform(row)
            } label: {
                ControlRowLabel(row: row)
            }
            .buttonStyle(ControlRowButtonStyle())
            .disabled(!row.isEnabled)
            .help(row.title)
        }
    }

    // MARK: 状态

    private var context: ControlCenterContext {
        ControlCenterContext(
            hasDocument: store.fileURL != nil,
            todayNet: store.writingStats.map { $0.today },
            goal: writing.dailyGoal,
            historyCount: store.historyEntries.count,
            themeName: themeManager.currentTheme.name,
            measure: typesetting.measure,
            fontSize: typesetting.fontSize,
            marginMM: printing.marginMM,
            pageNumbers: printing.pageNumbers,
            update: updates.status,
            hasCrashReports: store.hasCrashReports,
            reassignedShortcuts: overrides.overrides.count
        )
    }

    private var sections: [ControlCenterSection] {
        ControlCenterCatalog.sections(
            context,
            commands: CommandCatalog.commands(
                themes: themeManager.themes,
                recentFiles: [],
                overrides: overrides.overrides
            )
        )
    }

    // MARK: 动作

    private func perform(_ row: ControlCenterRow) {
        switch row.action {
        case .command(let kind):
            guard let command = CommandCatalog.command(
                for: kind, themes: themeManager.themes, overrides: overrides.overrides
            ) else { return }
            let runtime = CommandRuntime(
                store: store, workspace: workspace, writing: writing,
                updates: updates, windows: coordinator
            )
            // 先收起面板，下一拍再执行：日历、历史、崩溃都是 sheet，
            // 面板还挂在那儿的时候弹不出来。
            close()
            Task { @MainActor in runtime.run(command) }

        case .settings(let tab):
            // 和 `.command` 同一条规矩：浮层正在拆的时候开窗，视图环境还没稳下来，
            // 环境动作会找不到落点——下一拍再来。
            close()
            Task { @MainActor in SettingsWindow.open(tab) }

        case .crashFolder:
            guard let folder = store.crashFolder else { return }
            close()
            NSWorkspace.shared.open(folder)

        case .themes:
            break
        }
    }
}

// MARK: - 一行

/// 一行的样子：图标、标题、行尾的状态与快捷键。
///
/// 三项都是同一种排布，抽出来是因为菜单行要复用它的 `label`——`Menu` 的
/// 按钮部分长得必须和普通按钮一模一样，否则面板看起来像拼错了。
struct ControlRowLabel: View {
    let row: ControlCenterRow
    /// 主题行在行尾画一枚箭头：展开朝下，收起朝右。
    var trailingChevron: Bool = false
    var chevronExpanded: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: row.symbol)
                .font(.system(size: 12))
                // Menu 的 label 会把支持多色的符号画成彩色，面板里必须统一成单色
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(row.isEnabled ? Color.primary : Color.secondary)
                    .lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if let shortcut = row.shortcut {
                Text(ShortcutFormatter.label(shortcut))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if trailingChevron {
                Image(systemName: chevronExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 悬停才亮、按下会暗：popover 里没有系统自带的按钮底，靠这一层给出反馈。
private struct ControlRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                )
                .opacity(configuration.isPressed ? 0.55 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// 主题那一行展开一块就地的小列表：换完还留在面板里，可以接着改别的。
///
/// 试过 `Menu`——它的 label 不吃自定义宽度，图标还会被画成彩色，
/// 和面板里其余的行对不齐。展开列表反而是面板自己的语言。
struct ThemeRow: View {
    let row: ControlCenterRow
    let themes: [Theme]
    let currentID: String
    let select: (String) -> Void
    let openFolder: () -> Void
    let rescan: () -> Void
    /// 探针与测试用：直接从展开态开始，不必模拟一次点击。
    var initiallyExpanded: Bool = false

    @State private var expanded: Bool

    init(
        row: ControlCenterRow, themes: [Theme], currentID: String,
        select: @escaping (String) -> Void,
        openFolder: @escaping () -> Void, rescan: @escaping () -> Void,
        initiallyExpanded: Bool = false
    ) {
        self.row = row
        self.themes = themes
        self.currentID = currentID
        self.select = select
        self.openFolder = openFolder
        self.rescan = rescan
        self.initiallyExpanded = initiallyExpanded
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(spacing: 1) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
            } label: {
                ControlRowLabel(row: row, trailingChevron: true, chevronExpanded: expanded)
            }
            .buttonStyle(ControlRowButtonStyle())
            .help(t("Switch the preview theme", "换一个成文主题"))

            if expanded {
                ForEach(themes) { theme in
                    Button {
                        select(theme.id)
                    } label: {
                        HStack(spacing: 9) {
                            Color.clear.frame(width: 18)
                            Text(theme.name)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.id == currentID ? Color.primary : Color.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if theme.id == currentID {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(minHeight: 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ControlRowButtonStyle())

                }
                Divider()
                    .opacity(0.4)
                    .padding(.leading, 36)
                    .padding(.vertical, 4)
                themeAction(t("Open Themes Folder…", "打开主题文件夹…"), action: openFolder)
                themeAction(t("Rescan Themes", "重新扫描主题"), action: rescan)
            }
        }
    }

    private func themeAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 9) {
                Color.clear.frame(width: 18)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlRowButtonStyle())
    }
}
