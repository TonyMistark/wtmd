import AppKit
import SwiftUI
import WTMarkdownKit

struct ContentView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var workspace: WorkspaceStore
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var writing: WritingSettings
    @EnvironmentObject var typesetting: TypesettingSettings
    @EnvironmentObject var printing: PrintSettings
    @EnvironmentObject var updates: UpdateChecker
    @EnvironmentObject var overrides: ShortcutOverrides
    /// 设置窗口只能从 SwiftUI 的环境里打开：AppKit 的 `showSettingsWindow:`
    /// 在命令层并不可靠（面板点「设置…」没反应就是这么来的）。
    @Environment(\.openSettings) private var openSettings
    /// Owned by the app so the menu bar can open the palette too.
    @Binding var paletteVisible: Bool
    /// 窗口表：⌘N 要从这里开新窗口。为 nil 时退回本窗口新建（测试、离线视图）。
    var coordinator: WindowCoordinator? = nil

    /// 冲突副本清单是否展开。
    @State private var conflictListVisible = false
    /// 功能中心是否摊开。它是窗口内的一层浮面，不是 sheet——点一下就收，
    /// 不打断正在写的那一段。
    @State private var controlCenterVisible: Bool

    init(
        paletteVisible: Binding<Bool>,
        coordinator: WindowCoordinator? = nil,
        controlCenterInitiallyVisible: Bool = false
    ) {
        _paletteVisible = paletteVisible
        self.coordinator = coordinator
        // 测试与探针的口子：从「已经摊开」的状态开始，不必模拟一次工具栏点击。
        _controlCenterVisible = State(initialValue: controlCenterInitiallyVisible)
    }
    /// 分栏两侧的联动账本：谁动了、动到第几行、另一边该跟到哪。
    @StateObject private var splitSync = SplitSyncController()


    var body: some View {
        NavigationSplitView(
            columnVisibility: Binding(
                get: { store.sidebarVisible ? .automatic : .detailOnly },
                set: { store.sidebarVisible = $0 != .detailOnly }
            )
        ) {
            sidebar
                .frame(minWidth: 200)
        } detail: {
            detail
        }
        .navigationTitle(store.windowTitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $conflictListVisible) {
            ConflictArchiveView(
                entries: store.archivedConflicts,
                folder: store.conflictFolder,
                recover: { entry in
                    store.recoverArchivedConflict(entry)
                    conflictListVisible = false
                },
                discard: { store.discardArchivedConflict($0) },
                reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0.fileURL]) },
                close: { conflictListVisible = false }
            )
        }
        // 版本历史：写过的每一版都在这里，翻得回去、取得回来
        .sheet(isPresented: $store.historyVisible) {
            HistoryPanel(
                documentName: store.displayName,
                entries: store.historyEntries,
                folder: store.historyFolder,
                restore: { store.restoreHistory($0) },
                delete: { store.discardHistory($0) },
                clearAll: { store.clearHistory() },
                close: { store.historyVisible = false }
            )
        }
        // 写作日历：一年里每天的净增，一眼看完
        .sheet(isPresented: $store.calendarVisible) {
            WritingCalendarPanel(
                days: calendarDays,
                goal: writing.dailyGoal,
                close: { store.calendarVisible = false }
            )
        }
        // 上次崩了（或读者点了「报告问题」）：说清楚发生了什么，给一条去 GitHub 的路
        .sheet(isPresented: $store.crashVisible) {
            CrashPanel(
                report: store.crashReport,
                extraCount: store.crashExtraCount,
                copy: { store.copyCrashReport($0) },
                reveal: { store.revealCrashReport($0) },
                openIssue: { store.openCrashIssue($0) },
                dismiss: { store.dismissCrashPrompt() }
            )
        }
        // 每天最多查一次新版本；失败静默，绝不打断写作
        .task { await updates.checkIfDue() }
        // 文档从任何入口打开（⌘O、最近文件、标题栏）后，工作区树跟上高亮
        .onChange(of: store.fileURL) { _, newValue in
            guard let newValue else { return }
            workspace.reveal(newValue)
        }
        // 未命名文档另存时默认落到当前工作区，省掉一次从「文稿」导航过去
        .onChange(of: workspace.root) { _, newValue in
            store.preferredSaveDirectory = newValue
        }
        .onAppear {
            store.preferredSaveDirectory = workspace.root
            // 把「开设置」这件事交给命令层：菜单、⌘K、功能中心走的是同一条路，
            // 它们都拿不到视图环境，只有这里能。
            SettingsWindow.install { openSettings() }
        }
        .overlay {
            ZStack {
                // ⌘/ 切换模式（快捷键可以被改派，跟着生效值走）
                Button("") { store.toggleMode() }
                    .keyboardShortcut(
                        overrides.effectiveShortcut(for: .toggleMode)
                            ?? KeyboardShortcut("/", modifiers: .command)
                    )
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)

                // ⌘K 命令面板
                Button("") { paletteVisible.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)

                if store.workspaceSearch.isVisible {
                    WorkspaceSearchPanel(
                        search: store.workspaceSearch,
                        onOpen: { hit in
                            store.workspaceSearch.dismiss()
                            store.openSearchHit(hit)
                        },
                        onDismiss: { store.workspaceSearch.dismiss() }
                    )
                    .transition(.opacity)
                }

                if paletteVisible {
                    CommandPalette(
                        commands: CommandCatalog.commands(
                            themes: themeManager.themes,
                            recentFiles: store.recentFiles.urls,
                            overrides: overrides.overrides
                        ),
                        runtime: commandRuntime,
                        isPresented: $paletteVisible
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: paletteVisible)
        }
        // 功能中心：从工具栏那个按钮下面摊开的一层。点击别处就收。
        .overlay(alignment: .topTrailing) {
            if controlCenterVisible {
                controlCenterLayer
            }
        }
        .animation(.easeOut(duration: 0.14), value: controlCenterVisible)
    }

    // MARK: - 功能中心

    private var controlCenterLayer: some View {
        ZStack(alignment: .topTrailing) {
            // 一块几乎透明的挡板，接住「点别处」这一下。用 0.001 而不是 clear：
            // 完全透明的东西收不到点击。
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { controlCenterVisible = false }

            ControlCenterPanel(coordinator: coordinator) {
                controlCenterVisible = false
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
            .padding(.top, 6)
            .padding(.trailing, 12)
            .transition(.opacity.combined(with: .offset(y: -8)))
        }
    }

    // MARK: - 命令

    /// The single runtime behind the toolbar, the menus and the palette, so a
    /// command behaves identically wherever it is invoked from.
    private var commandRuntime: CommandRuntime {
        CommandRuntime(
            store: store, workspace: workspace, writing: writing, updates: updates,
            windows: coordinator
        )
    }

    private func isEnabled(_ kind: CommandKind) -> Bool {
        guard let command = CommandCatalog.command(for: kind, themes: themeManager.themes) else {
            return true
        }
        return commandRuntime.isEnabled(command)
    }

    // MARK: - 侧栏

    @ViewBuilder
    private var sidebar: some View {
        List {
            if workspace.isOpen {
                WorkspaceTreeView()
            }

            Section(t("Outline", "大纲")) {
                if store.outline.isEmpty {
                    Text(t("No headings yet — type # to start the first one", "思绪尚未成章 —— 输入 # 开始第一个标题"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(store.outline) { item in
                        outlineRow(item)
                    }
                }
            }

            // 工作区打开时，文件树已经承担了导航职责，最近文件只会让侧栏变长
            if !workspace.isOpen, !store.recentFiles.urls.isEmpty {
                Section(t("Recent Files", "最近文件")) {
                    ForEach(store.recentFiles.urls, id: \.absoluteString) { url in
                        Button {
                            store.open(url: url)
                        } label: {
                            Label(
                                url.deletingPathExtension().lastPathComponent,
                                systemImage: "doc.text"
                            )
                            .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // 系统会在工具栏最左侧自动插一个侧栏开关，右侧已有自己的按钮，同一个动作
        // 两个入口。移除必须挂在侧栏内容上——挂在 NavigationSplitView 外层不生效
        // （实测：加在外面系统项照旧，加在 sidebar 上才真的消失）。
        .toolbar(removing: .sidebarToggle)
    }

    /// 侧栏按钮只有一个，图标不表达开合方向：悬停说清点下去会怎样。
    private var sidebarHint: String {
        store.sidebarVisible
            ? t("Hide the sidebar", "收起侧栏")
            : t("Show the sidebar", "展开侧栏")
    }


    private func outlineRow(_ item: OutlineItem) -> some View {
        Button {
            store.jump(to: item)
        } label: {
            Text(item.text.isEmpty ? t("(untitled)", "（无标题）") : item.text)
                .font(item.level <= 2 ? .callout.weight(.medium) : .callout)
                .lineLimit(1)
                .padding(.leading, CGFloat(item.level - 1) * 11)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            store.currentOutlineSlug == item.slug
                ? Color.accentColor
                : (item.level <= 2 ? Color.primary : Color.secondary)
        )
    }

    // MARK: - 主区域

    @ViewBuilder
    private var detail: some View {
        if store.showsWelcome {
            WelcomeView(
                onNew: { store.newDocument() },
                onOpen: { store.openPanel() },
                onOpenFolder: { workspace.openPanel() }
            )
        } else {
            panes
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                // 相遇的瞬间：思绪与成文切换时的轻柔过渡
                .animation(.easeInOut(duration: 0.18), value: store.mode)
                .transition(.opacity)
                // 两侧联动只在分栏里生效：单栏编辑时预览不在场，让它拽着源码走
                // 是纯粹的打扰（正在打字，视口被搬走）。
                .onAppear { splitSync.isActive = store.mode == .split }
                .onChange(of: store.mode) { _, mode in splitSync.isActive = mode == .split }
                .onChange(of: store.cursorLine) { _, line in splitSync.editorMoved(to: line) }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let change = store.externalChange {
                        ConflictBanner(change: change, fileName: store.displayName) {
                            store.resolveExternalChange($0)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if store.find.isVisible {
                            FindBar(
                                find: store.find,
                                onReplaceCurrent: { store.replaceCurrentMatch() },
                                onReplaceAll: { store.replaceAllMatches() },
                                onClose: { store.hideFind() }
                            )
                        }
                        statusBar
                    }
                }
        }
    }

    @ViewBuilder
    private var panes: some View {
        switch store.mode {
        case .edit:
            editorPane
        case .preview:
            previewPane
        case .split:
            splitPane
        }
    }

    /// 思绪：源码编辑器 + 空文档提示。
    private var editorPane: some View {
        EditorTextView(
            text: Binding(
                get: { store.text },
                set: { store.textDidChange($0) }
            ),
            cursorLine: Binding(
                get: { store.cursorLine },
                set: { store.cursorLine = $0 }
            ),
            pendingImageInsert: Binding(
                get: { store.pendingImageInsert },
                set: { store.pendingImageInsert = $0 }
            ),
            jump: store.editorJump,
            syncReveal: splitSync.editorReveal,
            onImagePaste: { store.handleImagePaste($0) },
            typewriterMode: writing.typewriter,
            focusMode: writing.focusMode,
            positionMemory: store.positionMemory,
            generation: store.renderGeneration,
            findMatches: store.find.matches,
            findCurrent: store.find.currentMatch,
            findSeekToken: store.find.seekToken,
            replaceRequest: store.replaceRequest,
            onReplaceApplied: { store.consumeReplaceRequest() }
        )
        .overlay(alignment: .topLeading) {
            if store.text.isEmpty {
                Text(t("Start writing — press ⌘/ to watch it become a document", "落笔即成文 —— 输入第一行思绪，⌘/ 见证它成为文档"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
                    .padding(.leading, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 成文：渲染后的预览。
    private var previewPane: some View {
        PreviewView(
            html: Binding(get: { store.previewHTML }, set: { _ in }),
            currentSlug: Binding(
                get: { store.currentSlug },
                set: { store.currentSlug = $0 }
            ),
            themeCSS: themeManager.currentThemeCSS,
            layoutCSS: typesetting.css,
            diff: store.pendingDiff,
            jump: store.previewJump,
            generation: store.renderGeneration,
            documentTitle: store.displayName,
            baseURL: store.fileURL?.deletingLastPathComponent(),
            positionMemory: store.positionMemory,
            scrollLine: splitSync.previewScroll,
            onLineChange: { line in splitSync.previewMoved(to: line) },
            blockLines: store.blockLines
        )
    }

    /// 对照：左思绪、右成文，中间可拖动。
    ///
    /// 窄窗口退回源码单栏——这是写作工具，先保住能写字的那一边；
    /// 想看结果按 `⌘/` 一次就到。窗口拉宽后自动回到分栏。
    private var splitPane: some View {
        GeometryReader { proxy in
            if SplitLayout.showsTwoPanes(contentWidth: proxy.size.width) {
                HSplitView {
                    editorPane
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    previewPane
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                editorPane
            }
        }
    }

    /// 状态栏：字数 / 词数 / 阅读时长 —— 写作者的距离感。
    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(t("\(store.statistics.characters) characters", "\(store.statistics.characters) 字"))
            Text(t("\(store.statistics.words) words", "\(store.statistics.words) 词"))
            if store.statistics.readingMinutes > 0 {
                Text(t("~\(store.statistics.readingMinutes) min read", "约 \(store.statistics.readingMinutes) 分钟读完"))
            }
            if let stats = store.writingStats, writing.dailyGoal > 0 {
                dailyGoalBadge(total: stats.today)
            }
            Spacer()
            if let notice = store.archiveNotice {
                Text(notice)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if !store.archivedConflicts.isEmpty {
                Button {
                    conflictListVisible = true
                } label: {
                    Label(
                        t("\(store.archivedConflicts.count) unmerged local copies", "\(store.archivedConflicts.count) 份未合并的本地版本"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t("Local copies kept when a conflict was left unresolved. Open to recover or discard them.", "冲突未解决时切走留下的本地版本，点开可取回或丢弃"))
            }
            updateBadge
            writingModeToggles
            Text(store.fileURL?.lastPathComponent ?? t("Draft", "草稿"))
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    /// 今日净增与目标。达成只换一条进度条的颜色——不弹窗、不庆祝、不打断。
    /// 点开是这一年：这里说「今天」，那里说「每天都写了多少」。
    private func dailyGoalBadge(total: Int) -> some View {
        let goal = writing.dailyGoal
        let reached = WritingGoal.isReached(total: total, goal: goal)
        return Button {
            store.showCalendar()
        } label: {
            HStack(spacing: 6) {
                Text(t(
                    "Today \(total.formatted()) / \(goal.formatted()) characters",
                    "今日 \(total.formatted()) / \(goal.formatted()) 字"
                ))
                .monospacedDigit()
                goalBar(fraction: WritingGoal.fraction(total: total, goal: goal), reached: reached)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t(
            "Net characters written today — deleting takes them back off. Click for the whole year; the goal is under Settings › Theme › Writing.",
            "今天净增的字数，删字会扣回去。点开看这一年。目标在「设置 › 主题 › 写作」里改。"
        ))
    }

    /// 最近一年逐日净增。面板每次打开算一遍——365 次字典查找，不值得缓存。
    private var calendarDays: [WritingCalendar.Day] {
        guard let stats = store.writingStats else { return [] }
        return WritingCalendar.days(endingAt: Date(), count: 365, calendar: .current) {
            stats.total(on: $0)
        }
    }

    private func goalBar(fraction: Double, reached: Bool) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(reached ? Color.accentColor : Color.secondary.opacity(0.55))
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(width: 46, height: 4)
    }

    /// 更新提示：有新版时是可点的徽标，其余反馈（已是最新 / 失败）短暂停留后自己消失。
    @ViewBuilder
    private var updateBadge: some View {
        switch updates.status {
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
                .help(t("Checking for updates…", "正在检查更新…"))
        case .available(let version, let url):
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(t("v\(version) available", "v\(version) 可用"), systemImage: "arrow.down.circle")
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t("Open the download page: \(url.absoluteString)", "打开下载页：\(url.absoluteString)"))
        case .upToDate(let version):
            Text(t("v\(version) is up to date", "v\(version) 已是最新"))
                .foregroundStyle(.tertiary)
        case .failed:
            Text(t("Update check failed", "检查更新失败"))
                .foregroundStyle(.tertiary)
        case .idle:
            EmptyView()
        }
    }

    /// 两个写作模式的开关：界面越安静，越容易待在里面。
    private var writingModeToggles: some View {
        HStack(spacing: 10) {
            modeToggle(
                symbol: "align.vertical.center",
                isOn: writing.typewriter,
                help: t("Typewriter mode: keep the caret line centred (⌥⌘T)", "打字机模式：光标行停在屏幕中部（⌥⌘T）")
            ) { writing.typewriter.toggle() }

            modeToggle(
                symbol: "scope",
                isOn: writing.focusMode,
                help: t("Focus mode: dim everything but the current paragraph (⌥⌘F)", "专注模式：当前段落之外退成浅灰（⌥⌘F）")
            ) { writing.focusMode.toggle() }
        }
    }

    private func modeToggle(
        symbol: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // 三种视图是同一个位置的状态，不是三个并列的功能：一个按钮转一圈，
            // 图标说明现在在哪，悬停说明点下去去哪。
            Button {
                store.cycleMode()
            } label: {
                // 图标收进固定格子：三个符号原始尺寸不同，不收就会在切换时把
                // 按钮和旁边的工具栏项一起推来推去。
                Image(systemName: store.mode.symbol)
                    .frame(width: ViewMode.iconSize.width, height: ViewMode.iconSize.height)
                    // 工具栏里的 `.help` 到不了 AppKit，toolTip 由这个锚点写进宿主视图
                    .background(ToolbarTip(text: store.mode.cycleHint))
            }
            .help(store.mode.cycleHint)
            .accessibilityLabel(t("View mode", "视图模式"))
            .accessibilityValue(store.mode.label)
            .accessibilityHint(store.mode.cycleHint)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.openPanel()
            } label: {
                Label(t("Open Folder", "打开文件夹"), systemImage: "folder.badge.plus")
            }
            .help(t("Open a folder as the workspace (⌘⇧O)", "把文件夹作为工作区打开（⌘⇧O）"))

            Button {
                store.sidebarVisible.toggle()
            } label: {
                Label(t("Sidebar", "侧栏"), systemImage: "sidebar.left")
                    // 工具栏里的 `.help` 到不了 AppKit，提示由锚点写进宿主视图
                    .background(ToolbarTip(text: sidebarHint))
            }
            .help(sidebarHint)
            .accessibilityLabel(t("Sidebar", "侧栏"))
            .accessibilityValue(store.sidebarVisible
                ? t("Shown", "已展开")
                : t("Hidden", "已收起"))

            Menu {
                Button(t("Export HTML…", "导出 HTML…")) { store.exportHTML() }
                Button(t("Print / Save as PDF…", "打印 / 存为 PDF…")) { store.exportPDF() }
            } label: {
                Label(t("Export", "导出"), systemImage: "square.and.arrow.up")
            }

            Button {
                store.save()
            } label: {
                Label(t("Save", "保存"), systemImage: "square.and.arrow.down")
            }
            .disabled(!isEnabled(.save))

            // 一处门：日历、历史、主题、版式、设置、更新、报告问题都在里面。
            // 主题菜单原先在工具栏上，现在收进去了——那是一条入口，不是一条命令。
            Button {
                controlCenterVisible.toggle()
            } label: {
                Label(t("Control Center", "功能中心"), systemImage: "slider.horizontal.3")
                    .background(ToolbarTip(text: controlCenterHint))
            }
            .help(controlCenterHint)
            .accessibilityLabel(t("Control Center", "功能中心"))
            .accessibilityValue(controlCenterVisible
                ? t("Open", "已展开")
                : t("Closed", "已收起"))
        }
    }

    private var controlCenterHint: String {
        t(
            "Writing calendar, version history, theme, layout, settings — everything in one panel",
            "写作日历、版本历史、主题、版式、设置——都收在这一块里"
        )
    }
}

// MARK: - 欢迎页

/// 相遇的隐喻：左侧虚线是纷飞的思绪，流经 wtmd，右侧化作沉稳的实线成文。
struct WelcomeView: View {
    var onNew: () -> Void
    var onOpen: () -> Void
    var onOpenFolder: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            HStack(spacing: 20) {
                thoughtLine
                Text("wtmd")
                    .font(.system(size: 56, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                documentLine
            }

            Text("Where Thoughts Meet Documents")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(t("The moment a thought lands, the document is already taking shape", "思绪落下的一刻，成文已然成型"))
                .font(.callout)
                .foregroundStyle(.tertiary)

            HStack(spacing: 16) {
                Button(action: onNew) {
                    Label(t("Start Writing", "记下思绪"), systemImage: "character.cursor.ibeam")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .help(t("New document (⌘N)", "新建一篇文档（⌘N）"))

                Button(action: onOpen) {
                    Label(t("Open File", "打开文档"), systemImage: "folder")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .help(t("Open a Markdown file (⌘O)", "打开 Markdown 文件（⌘O）"))

                Button(action: onOpenFolder) {
                    Label(t("Open Folder", "打开文件夹"), systemImage: "folder.badge.plus")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .help(t("Open a folder as the workspace (⌘⇧O)", "把文件夹作为工作区打开（⌘⇧O）"))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 思绪：断续、漂浮的虚线
    private var thoughtLine: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 10))
            p.addLine(to: CGPoint(x: 130, y: 10))
        }
        .stroke(
            .tertiary,
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [1, 7])
        )
        .frame(width: 130, height: 20)
        .opacity(0.85)
    }

    /// 成文：连续、沉稳的实线
    private var documentLine: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 10))
            p.addLine(to: CGPoint(x: 130, y: 10))
        }
        .stroke(.tertiary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        .frame(width: 130, height: 20)
    }
}
