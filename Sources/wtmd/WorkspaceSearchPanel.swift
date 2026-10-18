import AppKit
import SwiftUI

/// 工作区全文搜索面板。
///
/// 复用命令面板（⌘K）的骨架——输入即搜、↑↓ 选择、↩ 打开、esc 关闭——因为两者
/// 解决的是同一件事：「我不记得它在哪，让我用键盘找」。材质与圆角也照抄，
/// 免得同一个应用里出现两种「浮起来的卡片」。
struct WorkspaceSearchPanel: View {
    @ObservedObject var search: WorkspaceSearchController
    var onOpen: (WorkspaceHit) -> Void
    var onDismiss: () -> Void

    @State private var keyMonitor: Any?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            card
                .padding(.top, 84)
        }
        .onAppear {
            installKeyMonitor()
            fieldFocused = true
        }
        .onDisappear {
            removeKeyMonitor()
            // 关掉面板后把键盘还给编辑器，否则 esc 之后打字没有落点
            DispatchQueue.main.async { CommandPalette.restoreEditorFocus() }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            content
        }
        .frame(width: 640)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }

    // MARK: - 搜索行

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(t("Search the whole workspace…", "在整个工作区里搜索…"), text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .onSubmit { openSelected() }

            if search.isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
            }

            Text(search.statusText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            optionChip("Aa", on: search.options.contains(.caseSensitive), help: t("Match case", "区分大小写")) {
                toggle(.caseSensitive)
            }
            optionChip(".*", on: search.options.contains(.regex), help: t("Regular expression", "正则表达式")) {
                toggle(.regex)
            }

            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(t("Clear", "清空"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - 结果

    @ViewBuilder
    private var content: some View {
        if search.root == nil {
            hint(t("Open a folder first (⌘⇧O) — the search runs inside it", "先打开一个文件夹（⌘⇧O），搜索会在这个文件夹里进行"))
        } else if !search.hasQuery {
            hint(t("Type a keyword to sweep the whole workspace", "输入关键词，把整个工作区翻一遍"))
        } else if search.hits.isEmpty {
            hint(search.isSearching ? t("Searching…", "正在搜索…") : t("Nothing found for \(search.trimmedQuery)", "没有找到「\(search.trimmedQuery)」"))
        } else {
            resultList
        }
    }

    private var resultList: some View {
        let hits = search.hits
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        if index == 0 || hits[index - 1].fileURL != hit.fileURL {
                            fileHeader(hit, count: count(of: hit.fileURL))
                        }
                        row(hit, index: index)
                            .id(hit.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 400)
            .onChange(of: search.selectedIndex) { _, _ in
                guard let hit = search.selectedHit else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(hit.id, anchor: .center)
                }
            }
        }
    }

    private func fileHeader(_ hit: WorkspaceHit, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(search.relativePath(for: hit.fileURL))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(t("\(count) matches", "\(count) 处"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private func row(_ hit: WorkspaceHit, index: Int) -> some View {
        let isSelected = index == search.selectedIndex
        return Button {
            onOpen(hit)
        } label: {
            HStack(spacing: 10) {
                Text("\(hit.line + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                    .frame(width: 36, alignment: .trailing)

                lineLabel(hit, isSelected: isSelected)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 命中词加重、换色——一眼看见「这一行为什么出现」。
    private func lineLabel(_ hit: WorkspaceHit, isSelected: Bool) -> Text {
        let line = hit.lineText as NSString
        let start = hit.highlightStart
        let length = hit.highlightLength
        let base: Color = isSelected ? .white.opacity(0.9) : .primary

        guard length > 0, start >= 0, start + length <= line.length else {
            return Text(hit.lineText).foregroundColor(base)
        }
        let pre = line.substring(to: start)
        let mid = line.substring(with: NSRange(location: start, length: length))
        let post = line.substring(from: start + length)
        return Text(pre).foregroundColor(base)
            + Text(mid).bold().foregroundColor(isSelected ? .white : .accentColor)
            + Text(post).foregroundColor(base)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func count(of url: URL) -> Int {
        search.hits.filter { $0.fileURL == url }.count
    }

    // MARK: - 小件

    private func optionChip(
        _ label: String,
        on: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(on ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggle(_ option: FindOptions) {
        search.options.formSymmetricDifference(option)
    }

    // MARK: - 键盘

    private func openSelected() {
        guard let hit = search.selectedHit else { return }
        onOpen(hit)
    }

    /// 与命令面板同样的做法：用本地事件监视器，不赌焦点在哪个控件上时
    /// 方向键会不会冒泡。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = PaletteKeyboard.action(forKeyCode: event.keyCode) else { return event }
            switch action {
            case .move(let delta):
                search.moveSelection(by: delta)
            case .execute:
                openSelected()
            case .dismiss:
                onDismiss()
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}
