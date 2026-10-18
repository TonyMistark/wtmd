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
        case .space: return t("Space", "空格")
        case .delete: return "⌫"
        default: return String(key.character).uppercased()
        }
    }
}

// MARK: - Palette

/// The ⌘K command palette: search every command, run it without leaving the
/// keyboard.
struct CommandPalette: View {
    let commands: [AppCommand]
    let runtime: CommandRuntime
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    private var results: [CommandSearch.Result] { CommandSearch.filter(query, in: commands) }
    private var rows: [PaletteRow] { CommandSearch.rows(for: query, results: results) }

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
        }
        .onDisappear {
            removeKeyMonitor()
            // Hand the keyboard back to the editor, otherwise Esc leaves the
            // app with nothing focused and typing goes nowhere.
            DispatchQueue.main.async { CommandPalette.restoreEditorFocus() }
        }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if results.isEmpty {
                emptyState
            } else {
                resultList
            }
        }
        .frame(width: 540)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(t("Type a command…", "输入命令…"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)

            if !query.isEmpty {
                Button {
                    query = ""
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

    private var emptyState: some View {
        VStack(spacing: 5) {
            Text(t("No matching commands", "没有匹配的命令"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(t("Try \"export\", \"focus\", \"theme\"", "试试「导出」「专注」「主题」"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let section):
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 3)
                        case .command(let result):
                            rowView(result)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 340)
            .onChange(of: selection) { _, _ in
                guard let id = currentResultID else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func rowView(_ result: CommandSearch.Result) -> some View {
        let index = results.firstIndex { $0.id == result.id } ?? -1
        let isSelected = index == selection
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

    private var currentResultID: String? {
        guard results.indices.contains(selection) else { return nil }
        return results[selection].id
    }

    // MARK: Actions

    private func execute(_ command: AppCommand) {
        guard runtime.isEnabled(command) else { return }
        // Dismiss first: a command may open a panel or change the view, and the
        // palette should be gone by then.
        dismiss()
        runtime.run(command)
    }

    private func dismiss() {
        isPresented = false
    }

    // MARK: Key monitor

    /// A local monitor instead of SwiftUI's `onKeyPress`: whether a focused
    /// single-line `NSTextField` lets arrow keys bubble up is not something the
    /// palette can afford to be unsure about.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = PaletteKeyboard.action(forKeyCode: event.keyCode) else { return event }
            switch action {
            case .move(let delta):
                selection = PaletteKeyboard.advance(selection, by: delta, count: results.count)
            case .execute:
                if results.indices.contains(selection) {
                    execute(results[selection].command)
                }
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

    // MARK: Focus

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
