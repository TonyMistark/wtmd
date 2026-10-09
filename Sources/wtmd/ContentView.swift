import SwiftUI
import WTMarkdownKit

struct ContentView: View {
    @EnvironmentObject var store: DocumentStore

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

            if !store.recentFiles.urls.isEmpty {
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
        if store.text.isEmpty && store.fileURL == nil {
            WelcomeView(
                onNew: { store.newDocument() },
                onOpen: { store.openPanel() }
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
                        jump: store.editorJump
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
                store.sidebarVisible.toggle()
            } label: {
                Label("大纲", systemImage: "sidebar.left")
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
