import AppKit
import SwiftUI

// MARK: - Keyboard

/// Key codes the palette cares about. Raw values are AppKit's `keyCode`.
enum PaletteKey {
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let `return`: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
}

/// Keyboard handling for the palette, kept as pure functions.
///
/// The palette lives or dies by the arrow keys working, so the mapping is
/// tested directly rather than through the view.
enum PaletteKeyboard {
    enum Action: Equatable {
        case move(Int)
        case execute
        case dismiss
    }

    /// Key code to action. Returns nil for keys we do not handle, so the event
    /// keeps travelling to the text field.
    static func action(forKeyCode code: UInt16) -> Action? {
        switch code {
        case PaletteKey.upArrow: return .move(-1)
        case PaletteKey.downArrow: return .move(1)
        case PaletteKey.return, PaletteKey.keypadEnter: return .execute
        case PaletteKey.escape: return .dismiss
        default: return nil
        }
    }

    /// Move the selection, wrapping at both ends — repeatedly holding one arrow
    /// key should cycle rather than get stuck.
    static func advance(_ current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let next = (current + delta) % count
        return next < 0 ? next + count : next
    }
}

// MARK: - Shortcut labels

/// Renders a shortcut the way a menu does: ⌥⌘T.
enum ShortcutFormatter {
    static func label(_ shortcut: KeyboardShortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        text += keyLabel(shortcut.key)
        return text
    }

    private static func keyLabel(_ key: KeyEquivalent) -> String {
        switch key {
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .return: return "↩"
        case .escape: return "⎋"
        case .tab: return "⇥"
        case .space: return t("Space")
        case .delete: return "⌫"
        default: return String(key.character).uppercased()
        }
    }
}

// MARK: - Palette

/// ⌘K 的那张面板：命令、文件、正文放在同一个框里。
///
/// 三段共用一个输入框，是因为读者心里只有「我要找它」这一件事——先分类
/// 再开始找，等于让人先做一次决定，再打字。分类留给前缀（`>` `@` `#`）与
/// 那三个小胶囊：想收窄的人一秒就能收窄，不想收窄的人不必知道它们存在。
struct CommandPalette: View {
    let commands: [AppCommand]
    let runtime: CommandRuntime
    /// 工作区里所有 Markdown 文件（已摊平、已算好相对路径）。
    let files: [PaletteFileHit]
    /// 工作区根目录。没有工作区就只有命令——正文搜索无处可搜。
    let root: URL?
    /// 正在编辑的那一篇：磁盘可能落后一次自动保存，搜盘会漏掉刚写的词。
    var liveDocument: (() -> (url: URL, text: String)?)?
    @ObservedObject var history: PaletteHistory

    var onOpenFile: (URL) -> Void
    var onOpenTextHit: (WorkspaceHit) -> Void
    /// 正文结果太多：把词带进 ⌘⇧F 的完整面板。
    var onSeeAll: (String) -> Void

    @Binding var isPresented: Bool

    /// 打开时预填的词。从别处带着词进来（比如「在工作区中查看全部」返回）
    /// 时用得上；`nil` 就是一张干净的面板。
    var initialQuery: String?

    @State private var query: String
    @State private var selection = 0
    @State private var keyMonitor: Any?
    @StateObject private var textSearch = PaletteTextSearch()
    @FocusState private var searchFocused: Bool

    /// `@State` 的初值得自己装：预填的词要么在第一帧就在输入框里，
    /// 要么就赶不上第一次的正文搜索。
    init(
        commands: [AppCommand],
        runtime: CommandRuntime,
        files: [PaletteFileHit],
        root: URL?,
        liveDocument: (() -> (url: URL, text: String)?)? = nil,
        history: PaletteHistory,
        onOpenFile: @escaping (URL) -> Void,
        onOpenTextHit: @escaping (WorkspaceHit) -> Void,
        onSeeAll: @escaping (String) -> Void,
        isPresented: Binding<Bool>,
        initialQuery: String? = nil
    ) {
        self.commands = commands
        self.runtime = runtime
        self.files = files
        self.root = root
        self.liveDocument = liveDocument
        self.history = history
        self.onOpenFile = onOpenFile
        self.onOpenTextHit = onOpenTextHit
        self.onSeeAll = onSeeAll
        _isPresented = isPresented
        _query = State(initialValue: initialQuery ?? "")
    }

    // MARK: - 结果

    private var parsed: PaletteQuery { PaletteQuery.parse(query) }

    private var commandResults: [CommandSearch.Result] {
        let scope = parsed.scope
        guard scope == .all || scope == .commands else { return [] }
        return CommandSearch.filter(parsed.trimmedNeedle, in: commands)
    }

    private var rows: [PaletteRow] {
        var input = PaletteRows.Input(
            query: parsed,
            commands: commandResults,
            files: files,
            textHits: textSearch.hits,
            textTotal: textSearch.hasMore ? textSearch.hits.count + 1 : textSearch.hits.count
        )
        if parsed.isEmpty {
            input.recentCommands = history.recentCommands(from: commands)
            input.recentSearches = history.searches
        }
        return PaletteRows.build(input)
    }

    /// 方向键停的地方：小标题不算。
    private var selectable: [PaletteRow] { rows.filter(\.isSelectable) }

    private var selectedRow: PaletteRow? {
        selectable.indices.contains(selection) ? selectable[selection] : nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Click outside to dismiss. Also swallows clicks meant for the
            // editor underneath.
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            card
                .padding(.top, 84)
        }
        .onAppear {
            installKeyMonitor()
            searchFocused = true
            refreshTextSearch()
        }
        .onDisappear {
            removeKeyMonitor()
            textSearch.clear()
            // Hand the keyboard back to the editor, otherwise Esc leaves the
            // app with nothing focused and typing goes nowhere.
            DispatchQueue.main.async { CommandPalette.restoreEditorFocus() }
        }
        .onChange(of: query) { _, _ in
            selection = 0
            refreshTextSearch()
        }
        .onChange(of: textSearch.hits) { _, _ in clampSelection() }
        .onChange(of: rows.count) { _, _ in clampSelection() }
    }

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                resultList
            }
            Divider()
            footer
        }
        .frame(width: 620)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }

    // MARK: - 输入

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(t("Search commands, files, text…"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)

            if textSearch.isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
            }

            ForEach(PaletteScope.allCases.filter { $0 != .all }) { scope in
                scopeChip(scope)
            }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(t("Clear"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// 三个小胶囊就是前缀的另一种写法：点一下把 `@` 放到词前面，再点一下
    /// 拿掉。它和打字前缀读的是同一个值，所以两者永远一致。
    private func scopeChip(_ scope: PaletteScope) -> some View {
        let isOn = parsed.scope == scope
        return Button {
            toggle(scope)
        } label: {
            Text(scope.prefix.map(String.init) ?? "")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(t("Only {}", scope.title))
    }

    private func toggle(_ scope: PaletteScope) {
        let needle = parsed.scope == .all ? parsed.needle : parsed.needle
        if parsed.scope == scope {
            query = needle.trimmingCharacters(in: .whitespaces)
        } else if let prefix = scope.prefix {
            query = "\(prefix)\(needle.trimmingCharacters(in: .whitespaces))"
        }
        searchFocused = true
    }

    // MARK: - 结果

    private var emptyState: some View {
        VStack(spacing: 5) {
            Text(emptyTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(t("Try \"export\", \"@chapter\", \"#measure\""))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var emptyTitle: String {
        guard !parsed.isEmpty else { return t("No commands to run") }
        if parsed.scope == .text && root == nil {
            return t("Open a folder to search its text")
        }
        return t("Nothing found for \"{}\"", parsed.trimmedNeedle)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 不是 LazyVStack：它报不出自己的理想高度，卡片会撑满整扇窗。
                // 三十几行的布局成本可以忽略，换一个「贴着内容」的卡片值得。
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { _, _ in
                guard let id = selectedRow?.id else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: PaletteRow) -> some View {
        switch row {
        case .header(let group):
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 3)

        case .command(let result):
            commandRow(result)

        case .file(let hit):
            fileRow(hit)

        case .text(let hit):
            textRow(hit)

        case .search(let term):
            searchRow(term)

        case .seeAll:
            seeAllRow
        }
    }

    // MARK: - 各行

    private func commandRow(_ result: CommandSearch.Result) -> some View {
        let isSelected = selectedRow?.id == result.id
        let isEnabled = runtime.isEnabled(result.command)

        return Button {
            execute(result.command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: result.command.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    highlightedTitle(result)
                    if let subtitle = result.command.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                    }
                }

                Spacer(minLength: 8)

                if let isOn = runtime.isOn(result.command), isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                }
                if let shortcut = result.command.shortcut {
                    Text(ShortcutFormatter.label(shortcut))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .id(result.id)
    }

    private func fileRow(_ hit: PaletteFileHit) -> some View {
        let isSelected = selectedRow?.id == "file.\(hit.id)"

        return Button {
            openFile(hit)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Text(hit.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(hit.relativePath)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id("file.\(hit.id)")
    }

    private func textRow(_ hit: WorkspaceHit) -> some View {
        let isSelected = selectedRow?.id == "text.\(hit.id)"

        return Button {
            openTextHit(hit)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.alignleft")
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.lineText)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    Text("\(relativePath(for: hit.fileURL)):\(hit.line + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id("text.\(hit.id)")
    }

    private func searchRow(_ term: String) -> some View {
        let isSelected = selectedRow?.id == "search.\(term)"

        return Button {
            query = term
            searchFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Text(term)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id("search.\(term)")
    }

    private var seeAllRow: some View {
        let isSelected = selectedRow?.id == "seeAll"

        return Button {
            seeAll()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right.square")
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Text(t("See all matches in the workspace"))
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 8)
                Text("⇧⌘F")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id("seeAll")
    }

    /// The title with matched characters in bold — the visible feedback of a
    /// search matters more than its score.
    private func highlightedTitle(_ result: CommandSearch.Result) -> Text {
        let title = result.command.title
        guard !result.titleHits.isEmpty else {
            return Text(title).font(.system(size: 13))
        }
        let hits = Set(result.titleHits)
        var attributed = AttributedString()
        for (index, character) in Array(title).enumerated() {
            var piece = AttributedString(String(character))
            if hits.contains(index) {
                piece.font = .system(size: 13, weight: .bold)
            }
            attributed += piece
        }
        return Text(attributed).font(.system(size: 13))
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 10) {
            Text(t("› commands   @ files   # text"))
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.tertiary)

            Spacer()

            if parsed.scope != .files, !textSearch.isSearching {
                Text(summary)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var summary: String {
        var parts: [String] = []
        if !commandResults.isEmpty {
            parts.append(t("{} commands", commandResults.count))
        }
        if parsed.scope == .all || parsed.scope == .files {
            let count = PaletteFileSearch.filter(
                parsed.trimmedNeedle, in: files, limit: PaletteRows.fileLimit
            ).count
            if count > 0 { parts.append(t("{} files", count)) }
        }
        if !textSearch.hits.isEmpty {
            parts.append(t("{}+ matches", textSearch.hits.count))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 执行

    private func run(_ row: PaletteRow) {
        switch row {
        case .header:
            break
        case .command(let result):
            execute(result.command)
        case .file(let hit):
            openFile(hit)
        case .text(let hit):
            openTextHit(hit)
        case .search(let term):
            query = term
            searchFocused = true
        case .seeAll:
            seeAll()
        }
    }

    private func execute(_ command: AppCommand) {
        guard runtime.isEnabled(command) else { return }
        history.rememberCommand(command.id)
        history.rememberSearch(parsed.trimmedNeedle)
        // Dismiss first: a command may open a panel or change the view, and the
        // palette should be gone by then.
        dismiss()
        runtime.run(command)
    }

    private func openFile(_ hit: PaletteFileHit) {
        history.rememberSearch(parsed.trimmedNeedle)
        dismiss()
        onOpenFile(hit.url)
    }

    private func openTextHit(_ hit: WorkspaceHit) {
        history.rememberSearch(parsed.trimmedNeedle)
        dismiss()
        onOpenTextHit(hit)
    }

    private func seeAll() {
        history.rememberSearch(parsed.trimmedNeedle)
        let term = parsed.trimmedNeedle
        dismiss()
        onSeeAll(term)
    }

    private func dismiss() {
        isPresented = false
    }

    // MARK: - 正文搜索

    private func refreshTextSearch() {
        let scope = parsed.scope
        guard scope == .all || scope == .text else {
            textSearch.clear()
            return
        }
        var overlay: [URL: String] = [:]
        if let live = liveDocument?() { overlay[live.url] = live.text }
        textSearch.search(root: root, query: parsed.needle, overlay: overlay)
    }

    private func clampSelection() {
        guard !selectable.isEmpty else {
            selection = 0
            return
        }
        if selection >= selectable.count { selection = selectable.count - 1 }
    }

    private func relativePath(for url: URL) -> String {
        guard let root else { return url.lastPathComponent }
        return WorkspaceSearch.relativePath(of: url, under: root)
    }

    // MARK: - Key monitor

    /// A local monitor instead of SwiftUI's `onKeyPress`: whether a focused
    /// single-line `NSTextField` lets arrow keys bubble up is not something the
    /// palette can afford to be unsure about.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = PaletteKeyboard.action(forKeyCode: event.keyCode) else { return event }
            switch action {
            case .move(let delta):
                selection = PaletteKeyboard.advance(selection, by: delta, count: selectable.count)
            case .execute:
                if let row = selectedRow { run(row) }
            case .dismiss:
                dismiss()
            }
            return nil  // handled: do not pass it on to the search field
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    // MARK: - Focus

    /// Give keyboard focus back to the source editor.
    static func restoreEditorFocus() {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return }
        if let editor = firstEditableTextView(in: content) {
            window.makeFirstResponder(editor)
        }
    }

    private static func firstEditableTextView(in view: NSView) -> NSTextView? {
        // `isFieldEditor` filters out the text field we just closed.
        if let textView = view as? NSTextView, textView.isEditable, !textView.isFieldEditor {
            return textView
        }
        for subview in view.subviews {
            if let found = firstEditableTextView(in: subview) { return found }
        }
        return nil
    }
}
