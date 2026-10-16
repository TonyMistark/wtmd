import SwiftUI
import WTMarkdownKit

struct ContentView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var workspace: WorkspaceStore
    @EnvironmentObject var themeManager: ThemeManager

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
        // 文档从任何入口打开（⌘O、最近文件、标题栏）后，工作区树跟上高亮
        .onChange(of: store.fileURL) { _, newValue in
            guard let newValue else { return }
            workspace.reveal(newValue)
        }
        .overlay {
            // ⌘/ 切换模式
            Button("") { store.toggleMode() }
                .keyboardShortcut("/", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - 侧栏

    @ViewBuilder
    private var sidebar: some View {
        List {
            if workspace.isOpen {
                workspaceSection
            }

            Section("大纲") {
                if store.outline.isEmpty {
                    Text("思绪尚未成章 —— 输入 # 开始第一个标题")
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
                Section("最近文件") {
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
    }

    // MARK: - 工作区

    @ViewBuilder
    private var workspaceSection: some View {
        Section {
            let nodes = workspace.tree?.children ?? []
            if nodes.isEmpty {
                Text("这个文件夹里还没有 Markdown 文件")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(nodes) { node in
                    treeRow(node)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(workspace.rootName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    workspace.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭工作区")
            }
        }
    }

    /// 文件树的一行：文件夹可折叠，文件点击即打开，当前文档高亮。
    ///
    /// `AnyView` 是必需的：递归视图的返回类型没法用 `some View` 自引用
    /// （编译器会报 `OpaqueTypeInference`）。
    private func treeRow(_ node: WorkspaceNode) -> AnyView {
        if node.isDirectory {
            return AnyView(
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { workspace.isExpanded(node.url) },
                        set: { workspace.setExpanded(node.url, to: $0) }
                    )
                ) {
                    ForEach(node.children) { child in
                        treeRow(child)
                    }
                } label: {
                    Label(node.name, systemImage: "folder")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            )
        }

        return AnyView(
            Button {
                store.open(url: node.url)
            } label: {
                Label(node.name, systemImage: "doc.text")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                workspace.selection == node.url ? Color.accentColor : Color.primary
            )
        )
    }

    private func outlineRow(_ item: OutlineItem) -> some View {
        Button {
            store.jump(to: item)
        } label: {
            Text(item.text.isEmpty ? "（无标题）" : item.text)
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
            Group {
                switch store.mode {
                case .edit:
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
                        onImagePaste: { store.handleImagePaste($0) }
                    )
                    .overlay(alignment: .topLeading) {
                        if store.text.isEmpty {
                            Text("落笔即成文 —— 输入第一行思绪，⌘/ 见证它成为文档")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 16)
                                .padding(.leading, 18)
                                .allowsHitTesting(false)
                        }
                    }
                case .preview:
                    PreviewView(
                        html: Binding(get: { store.previewHTML }, set: { _ in }),
                        currentSlug: Binding(
                            get: { store.currentSlug },
                            set: { store.currentSlug = $0 }
                        ),
                        themeCSS: themeManager.currentThemeCSS,
                        diff: store.pendingDiff,
                        jump: store.previewJump,
                        generation: store.renderGeneration,
                        documentTitle: store.displayName,
                        baseURL: store.fileURL?.deletingLastPathComponent()
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            // 相遇的瞬间：思绪与成文切换时的轻柔过渡
            .animation(.easeInOut(duration: 0.18), value: store.mode)
            .transition(.opacity)
            .safeAreaInset(edge: .bottom) { statusBar }
        }
    }

    /// 状态栏：字数 / 词数 / 阅读时长 —— 写作者的距离感。
    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(store.statistics.characters) 字")
            Text("\(store.statistics.words) 词")
            if store.statistics.readingMinutes > 0 {
                Text("约 \(store.statistics.readingMinutes) 分钟读完")
            }
            Spacer()
            Text(store.fileURL?.lastPathComponent ?? "草稿")
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

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker(
                "模式",
                selection: Binding(
                    get: { store.mode },
                    set: { store.setMode($0) }
                )
            ) {
                Label("思绪", systemImage: "character.cursor.ibeam").tag(ViewMode.edit)
                Label("成文", systemImage: "doc.richtext").tag(ViewMode.preview)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .help("思绪 ⇄ 成文（⌘/）")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.openPanel()
            } label: {
                Label("打开文件夹", systemImage: "folder.badge.plus")
            }
            .help("把文件夹作为工作区打开（⌘⇧O）")

            // 主题：成文的外观（源码模式高亮仍走系统语义色，不受主题影响）
            Menu {
                ForEach(themeManager.themes) { theme in
                    Button {
                        themeManager.select(theme.id)
                    } label: {
                        if theme.id == themeManager.currentThemeID {
                            Label(theme.name, systemImage: "checkmark")
                        } else {
                            Text(theme.name)
                        }
                    }
                }
                Divider()
                Button("打开主题文件夹…") { themeManager.openThemesFolder() }
                Button("重新扫描主题") { themeManager.reload() }
            } label: {
                Label("主题", systemImage: "paintpalette")
            }
            .help("选择成文主题（拖入 .wttheme 文件夹到主题目录即安装）")

            Button {
                store.sidebarVisible.toggle()
            } label: {
                Label("侧栏", systemImage: "sidebar.left")
            }

            Menu {
                Button("导出 HTML…") { store.exportHTML() }
                Button("打印 / 存为 PDF…") { store.exportPDF() }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }

            Button {
                store.save()
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .disabled(!store.isDirty && store.fileURL != nil)
        }
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

            Text("思绪落下的一刻，成文已然成型")
                .font(.callout)
                .foregroundStyle(.tertiary)

            HStack(spacing: 16) {
                Button(action: onNew) {
                    Label("记下思绪", systemImage: "character.cursor.ibeam")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .help("新建一篇文档（⌘N）")

                Button(action: onOpen) {
                    Label("打开文档", systemImage: "folder")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .help("打开 Markdown 文件（⌘O）")

                Button(action: onOpenFolder) {
                    Label("打开文件夹", systemImage: "folder.badge.plus")
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .help("把文件夹作为工作区打开（⌘⇧O）")
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
