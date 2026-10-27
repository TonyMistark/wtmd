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
    @EnvironmentObject var installer: UpdateInstaller
    @EnvironmentObject var overrides: ShortcutOverrides
    /// 工具栏那颗头像：有昵称就写上，没有就只画一枚圆。
    @EnvironmentObject var profile: ProfileStore
    /// 设置窗口只能从 SwiftUI 的环境里打开：AppKit 的 `showSettingsWindow:`
    /// 在命令层并不可靠（面板点「设置…」没反应就是这么来的）。
    @Environment(\.openSettings) private var openSettings
    /// Owned by the app so the menu bar can open the palette too.
    @Binding var paletteVisible: Bool
    /// 窗口表：⌘N 要从这里开新窗口。为 nil 时退回本窗口新建（测试、离线视图）。
    var coordinator: WindowCoordinator? = nil

    /// 冲突副本清单是否展开。
    @State private var conflictListVisible = false
    /// 侧栏「大纲」分类是否展开。收起工作区后大纲要能顶到最上面，
    /// 所以两个分类都得各自能收。
    @State private var outlineExpanded = true
    init(paletteVisible: Binding<Bool>, coordinator: WindowCoordinator? = nil) {
        _paletteVisible = paletteVisible
        self.coordinator = coordinator
    }
    /// 分栏两侧的联动账本：谁动了、动到第几行、另一边该跟到哪。
    @StateObject private var splitSync = SplitSyncController()

    /// 面板自己的记忆：最近搜过的词、最近用过的命令。写 UserDefaults，
    /// 关掉应用也还在——这两件事的价值全在「下次打开」。
    @StateObject private var paletteHistory = PaletteHistory()

    /// 工作区里所有文件，供面板的 `@` 那一段用。树已经是现成的，摊平一次
    /// 比重扫一遍磁盘便宜得多。
    private var paletteFiles: [PaletteFileHit] {
        PaletteFileSearch.flatten(workspace.tree, root: workspace.root)
    }


    var body: some View {
        NavigationSplitView(
            columnVisibility: Binding(
                // 别用 `.automatic`：窗口不够宽时系统会自作主张把侧栏折起来，
                // 但 `sidebarVisible` 仍是 true——菜单打着勾、快捷键按下去
                // true→false→true，画面一个像素都不动（⌃L / ⌥S 那两次「改派无效」
                // 其实都是它）。状态必须是唯一事实来源：开就显式展开（`.all`），
                // 关才收起。
                get: { store.sidebarVisible ? .all : .detailOnly },
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
            // 把「开设置」这件事交给命令层：菜单、⌘K、设置窗口走的是同一条路，
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

                // ⌘K 命令面板。与工具栏那枚放大镜同一个状态：开着再按一次也不关，
                // 关它只有 Esc 与点空白处——两个入口不该互相打断。
                Button("") { paletteVisible = true }
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
                        files: paletteFiles,
                        root: workspace.root,
                        liveDocument: { [weak store] in
                            guard let store, let url = store.fileURL else { return nil }
                            return (url, store.text)
                        },
                        history: paletteHistory,
                        onOpenFile: { store.open(url: $0) },
                        onOpenTextHit: { hit in
                            store.workspaceSearch.dismiss()
                            store.openSearchHit(hit)
                        },
                        onSeeAll: { term in
                            store.workspaceSearch.query = term
                            store.workspaceSearch.present(root: workspace.root)
                        },
                        isPresented: $paletteVisible
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: paletteVisible)
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
            // 「工作区」是分类头：下面这片都是用户 add 进来的工作区，
            // 与「大纲」「最近文件」同一套侧栏节头。分类头带展开/收起开关，
            // 收起后整组（含文件夹标题行）都不占位，大纲顶到最上面。
            // 真正的分区头（文件夹名、右键菜单）仍由 WorkspaceTreeView 自己的
            // Section 承担。
            if workspace.isOpen {
                Section(isExpanded: $workspace.sectionExpanded) {
                    WorkspaceTreeView()
                } header: {
                    sidebarSectionHeader(t("Workspaces"), isExpanded: workspace.sectionExpanded) {
                        withAnimation(.easeOut(duration: 0.18)) { workspace.sectionExpanded.toggle() }
                    }
                }
            }

            Section(isExpanded: $outlineExpanded) {
                if store.outline.isEmpty {
                    Text(t("No headings yet — type # to start the first one"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(store.outline) { item in
                        outlineRow(item)
                    }
                }
            } header: {
                sidebarSectionHeader(t("Outline"), isExpanded: outlineExpanded) {
                    withAnimation(.easeOut(duration: 0.18)) { outlineExpanded.toggle() }
                }
            }

            // 工作区打开时，文件树已经承担了导航职责，最近文件只会让侧栏变长
            if !workspace.isOpen, !store.recentFiles.urls.isEmpty {
                Section(t("Recent Files")) {
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
                        .buttonStyle(SidebarRowButtonStyle())
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
            ? t("Hide the sidebar")
            : t("Show the sidebar")
    }


    /// 侧栏分类头：一颗箭头 + 标题，整行都是开关。点一下收起/放出这一组，
    /// 收起后箭头向右、内容整组消失——大纲、工作区共用同一套。
    private func sidebarSectionHeader(
        _ title: String,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .pressFeedback()
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.15), value: isExpanded)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(t("Collapse or expand this section"))
    }

    private func outlineRow(_ item: OutlineItem) -> some View {
        Button {
            store.jump(to: item)
        } label: {
            Text(item.text.isEmpty ? t("(untitled)") : item.text)
                .font(item.level <= 2 ? .callout.weight(.medium) : .callout)
                .lineLimit(1)
                .padding(.leading, CGFloat(item.level - 1) * 11)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SidebarRowButtonStyle())
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
            onReplaceApplied: { store.consumeReplaceRequest() },
            editorTheme: EditorThemeStyle(theme: themeManager.currentTheme)
        )
        .overlay(alignment: .topLeading) {
            if store.text.isEmpty {
                Text(t("Start writing — press ⌘/ to watch it become a document"))
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
            Text(t("{} characters", store.statistics.characters))
            Text(t("{} words", store.statistics.words))
            if store.statistics.readingMinutes > 0 {
                Text(t("~{} min read", store.statistics.readingMinutes))
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
                        t("{} unmerged local copies", store.archivedConflicts.count),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t("Local copies kept when a conflict was left unresolved. Open to recover or discard them."))
            }
            updateBadge
            writingModeToggles
            fileLocationBadge
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

    /// 状态栏右下角的文件名：悬停看得到它在哪儿，点一下 Finder 就亮出它。
    /// 草稿还没有落盘，只是个名字。
    @ViewBuilder
    private var fileLocationBadge: some View {
        if let url = store.fileURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text(url.lastPathComponent)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(t("Full path: {}", (url.path as NSString).abbreviatingWithTildeInPath))
        } else {
            Text(t("Draft"))
                .foregroundStyle(.tertiary)
        }
    }

    /// 今日净增与目标。达成只换一条进度条的颜色——不弹窗、不庆祝、不打断。
    /// 点开是这一年：这里说「今天」，那里说「每天都写了多少」。
    private func dailyGoalBadge(total: Int) -> some View {
        let goal = writing.dailyGoal
        let reached = WritingGoal.isReached(total: total, goal: goal)
        return Button {
            CalendarWindow.show(store: store, goal: goal)
        } label: {
            HStack(spacing: 6) {
                Text(t("Today {} / {} characters", total.formatted(), goal.formatted()))
                .monospacedDigit()
                goalBar(fraction: WritingGoal.fraction(total: total, goal: goal), reached: reached)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t("Net characters written today — deleting takes them back off. Click for the whole year; the goal is under Settings › Theme › Writing."))
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

    /// 更新提示：有新版时点一下就是整个更新（下载 → 挂载 → 装配 → 重启），
    /// 其余反馈（已是最新 / 失败）短暂停留后自己消失。
    @ViewBuilder
    private var updateBadge: some View {
        switch updates.status {
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
                .help(t("Checking for updates…"))
        case .available(let version, let sources):
            updateAvailableBadge(version: version, sources: sources)
        case .upToDate(let version):
            Text(t("v{} is up to date", version))
                .foregroundStyle(.tertiary)
        case .failed:
            Text(t("Update check failed"))
                .foregroundStyle(.tertiary)
        case .idle:
            EmptyView()
        }
    }

    /// 有新版时的那枚徽标。点一下用首选源一键装；长按出菜单挑下载源——
    /// GitHub 抽风或国内网络差的时候，还有 Gitee 那条路。
    @ViewBuilder
    private func updateAvailableBadge(version: String, sources: [UpdateSource]) -> some View {
        switch installer.phase {
        case .downloading(let fraction):
            Text(t("Downloading {}%", Int(fraction * 100)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(t("Downloading the update"))
        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Text(t("Installing…"))
                    .foregroundStyle(.secondary)
            }
            .help(t("Swapping the new app into /Applications"))
        case .failed(let reason):
            Button {
                if let primary = sources.first { NSWorkspace.shared.open(primary.releaseURL) }
            } label: {
                Label(t("Update failed"), systemImage: "exclamationmark.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t("Retry from the release page. {}", reason))
        case .idle:
            updateSourceMenu(version: version, sources: sources)
        }
    }

    /// 一键装 + 换源菜单。点徽标本体 = 首选源；菜单里每个源两条路：
    /// 直接下载安装，或打开它的 release 页自己拖。
    @ViewBuilder
    private func updateSourceMenu(version: String, sources: [UpdateSource]) -> some View {
        let primary = sources.first
        Menu {
            ForEach(sources, id: \.name) { source in
                if source.asset != nil {
                    Button(t("Download from {}", source.name)) {
                        startUpdate(source: source, version: version)
                    }
                }
                Button(t("Open {} release page", source.name)) {
                    NSWorkspace.shared.open(source.releaseURL)
                }
            }
        } label: {
            Label(t("v{} available", version), systemImage: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
        } primaryAction: {
            if let primary {
                startUpdate(source: primary, version: version)
            }
        }
        .menuStyle(.borderlessButton)
        .help(updateHelp(version: version, primary: primary))
    }

    private func updateHelp(version: String, primary: UpdateSource?) -> String {
        guard let primary else { return t("v{} available", version) }
        return primary.asset == nil
            ? t("Open the download page: {}", primary.releaseURL.absoluteString)
            : t("Download and install v{}, then relaunch", version)
    }

    /// 有 dmg 就一键装；没有（Release 没挂附件）就退回打开下载页。
    private func startUpdate(source: UpdateSource, version: String) {
        guard let asset = source.asset else {
            NSWorkspace.shared.open(source.releaseURL)
            return
        }
        Task { await installer.run(asset: asset, version: version, releaseURL: source.releaseURL) }
    }

    /// 两个写作模式的开关：界面越安静，越容易待在里面。
    private var writingModeToggles: some View {
        HStack(spacing: 10) {
            modeToggle(
                symbol: "align.vertical.center",
                isOn: writing.typewriter,
                help: t("Typewriter mode: keep the caret line centred (⌥⌘T)")
            ) { writing.typewriter.toggle() }

            modeToggle(
                symbol: "scope",
                isOn: writing.focusMode,
                help: t("Focus mode: dim everything but the current paragraph (⌥⌘F)")
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
            .accessibilityLabel(t("View mode"))
            .accessibilityValue(store.mode.label)
            .accessibilityHint(store.mode.cycleHint)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // 命令面板不能只活在键盘上：⌘K 之外，也得有一条给鼠标的路。
            // 同一张面板、同一个状态——按钮只是把「有没有开」翻过来。
            Button {
                paletteVisible = true
            } label: {
                Label(t("Search Commands"), systemImage: "magnifyingglass")
                    .background(ToolbarTip(text: paletteHint))
            }
            .help(paletteHint)
            .accessibilityLabel(t("Search Commands"))

            Button {
                workspace.openPanel()
            } label: {
                Label(t("Open Folder"), systemImage: "folder.badge.plus")
            }
            .help(t("Open a folder as the workspace (⌘⇧O)"))

            Button {
                store.sidebarVisible.toggle()
            } label: {
                Label(t("Sidebar"), systemImage: "sidebar.left")
                    // 工具栏里的 `.help` 到不了 AppKit，提示由锚点写进宿主视图
                    .background(ToolbarTip(text: sidebarHint))
            }
            .help(sidebarHint)
            .accessibilityLabel(t("Sidebar"))
            .accessibilityValue(store.sidebarVisible
                ? t("Shown")
                : t("Hidden"))

            Menu {
                Button(t("Export HTML…")) { store.exportHTML() }
                Button(t("Print / Save as PDF…")) { store.exportPDF() }
            } label: {
                Label(t("Export"), systemImage: "square.and.arrow.up")
            }

            // 一处门：写作、外观、应用与帮助全在设置窗口里，从这枚头像进去。
            // 头像就是「我是谁」——设了图片就画图片，没设就画昵称首字。
            Button {
                SettingsWindow.open(.profile)
            } label: {
                HStack(spacing: 6) {
                    ProfileAvatar(image: profile.avatar, initial: profile.initial, size: 20)
                    if profile.hasNickname {
                        Text(profile.nickname)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                }
                .background(ToolbarTip(text: settingsHint))
            }
            .buttonStyle(.plain)
            .help(settingsHint)
            .accessibilityLabel(t("Settings"))
            .accessibilityValue(profile.displayName)
        }
    }

    private var settingsHint: String {
        t("Settings — profile, writing, appearance, updates")
    }

    /// 说的是这张面板**能干什么**，而不是它的名字：第一次点开的人靠这句话
    /// 判断「这里能不能找到我要的东西」。
    private var paletteHint: String {
        t("Search commands — run an action without hunting the menus (⌘K)")
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

            Text(t("The moment a thought lands, the document is already taking shape"))
                .font(.callout)
                .foregroundStyle(.tertiary)

            HStack(spacing: 16) {
                Button(action: onNew) {
                    Label(t("Start Writing"), systemImage: "character.cursor.ibeam")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .help(t("New document (⌘N)"))

                Button(action: onOpen) {
                    Label(t("Open File"), systemImage: "folder")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .help(t("Open a Markdown file (⌘O)"))

                Button(action: onOpenFolder) {
                    Label(t("Open Folder"), systemImage: "folder.badge.plus")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .help(t("Open a folder as the workspace (⌘⇧O)"))
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
