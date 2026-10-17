import SwiftUI

@main
struct wtmdApp: App {
    @StateObject private var store: DocumentStore
    @StateObject private var workspace: WorkspaceStore
    @StateObject private var writing = WritingSettings()
    @StateObject private var updates = UpdateChecker()
    @State private var paletteVisible = false

    /// One session record shared by the document and the folder around it: both
    /// write to the same blob, and a restore has to bring them back together.
    init() {
        let session = Session()
        _store = StateObject(wrappedValue: DocumentStore(session: session))
        _workspace = StateObject(wrappedValue: WorkspaceStore(session: session))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(paletteVisible: $paletteVisible)
                .environmentObject(store)
                .environmentObject(workspace)
                .environmentObject(writing)
                .environmentObject(updates)
                .environmentObject(store.themeManager)
                .frame(minWidth: 760, minHeight: 500)
        }
        Settings {
            ThemeSettingsView()
                .environmentObject(store.themeManager)
                .environmentObject(writing)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                menuItem(.checkForUpdates)
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                menuItem(.newDocument)
            }
            CommandGroup(replacing: .saveItem) {
                menuItem(.openDocument)
                menuItem(.openFolder)
                menuItem(.save)
                Divider()
                menuItem(.exportHTML)
                menuItem(.exportWord)
                menuItem(.exportPDF)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                menuItem(.toggleSplit)
                Divider()
                menuItem(.toggleTypewriter)
                menuItem(.toggleFocus)
                Divider()
                Button("命令面板…") { paletteVisible = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }

    /// Menu items take their title, shortcut, availability and action from
    /// `CommandCatalog` — the same definitions the palette uses, so the two can
    /// never drift apart. The menus only declare structure: slots and dividers.
    @ViewBuilder
    private func menuItem(_ kind: CommandKind) -> some View {
        if let command = CommandCatalog.command(for: kind, themes: store.themeManager.themes) {
            let runtime = CommandRuntime(
                store: store, workspace: workspace, writing: writing, updates: updates
            )
            if let isOn = runtime.isOn(command) {
                Toggle(command.title, isOn: Binding(get: { isOn }, set: { _ in runtime.run(command) }))
                    .keyboardShortcut(command.shortcut)
            } else {
                Button(command.title) { runtime.run(command) }
                    .keyboardShortcut(command.shortcut)
                    .disabled(!runtime.isEnabled(command))
            }
        }
    }
}
