import SwiftUI

@main
struct wtmdApp: App {
    @StateObject private var store = DocumentStore()
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var writing = WritingSettings()
    @State private var paletteVisible = false

    var body: some Scene {
        WindowGroup {
            ContentView(paletteVisible: $paletteVisible)
                .environmentObject(store)
                .environmentObject(workspace)
                .environmentObject(writing)
                .environmentObject(store.themeManager)
                .frame(minWidth: 760, minHeight: 500)
        }
        Settings {
            ThemeSettingsView()
                .environmentObject(store.themeManager)
                .environmentObject(writing)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                menuItem(.newDocument)
            }
            CommandGroup(replacing: .saveItem) {
                menuItem(.openDocument)
                menuItem(.openFolder)
                menuItem(.save)
                Divider()
                menuItem(.exportHTML)
                menuItem(.exportPDF)
            }
            CommandGroup(after: .sidebar) {
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
            let runtime = CommandRuntime(store: store, workspace: workspace, writing: writing)
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
