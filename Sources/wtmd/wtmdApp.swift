import SwiftUI

@main
struct wtmdApp: App {
    @StateObject private var store: DocumentStore
    @StateObject private var workspace: WorkspaceStore
    @StateObject private var writing = WritingSettings()
    @StateObject private var typesetting: TypesettingSettings
    @StateObject private var printing: PrintSettings
    @StateObject private var updates = UpdateChecker()
    @StateObject private var overrides = ShortcutOverrides()
    @State private var paletteVisible = false

    /// One session record shared by the document and the folder around it: both
    /// write to the same blob, and a restore has to bring them back together.
    init() {
        let session = Session()
        // 冲突副本落在 Application Support/wtmd/conflicts：切文档时救下来的本地版本
        let documentStore = DocumentStore(
            session: session,
            conflicts: ConflictArchive(),
            writingStats: WritingStats()
        )
        let workspaceStore = WorkspaceStore(session: session)
        // 树里改名/删除之后，当前文档得跟着磁盘走——两个 store 各自独立，
        // 这条线只走一个协议，谁也不拥有谁。
        workspaceStore.fileEvents = documentStore
        // 导出 PDF 要同时知道「屏幕上的字号行距」和「纸上的页边距页码」：
        // 这两个设置归视图层，store 只借来用一次。
        let typesettingSettings = TypesettingSettings()
        let printSettings = PrintSettings()
        documentStore.typesetting = typesettingSettings
        documentStore.printSettings = printSettings
        _store = StateObject(wrappedValue: documentStore)
        _workspace = StateObject(wrappedValue: workspaceStore)
        _typesetting = StateObject(wrappedValue: typesettingSettings)
        _printing = StateObject(wrappedValue: printSettings)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(paletteVisible: $paletteVisible)
                .environmentObject(store)
                .environmentObject(workspace)
                .environmentObject(writing)
                .environmentObject(typesetting)
                .environmentObject(updates)
                .environmentObject(overrides)
                .environmentObject(store.themeManager)
                .frame(minWidth: 760, minHeight: 500)
        }
        Settings {
            TabView {
                ThemeSettingsView()
                    .tabItem { Label(t("Theme", "主题"), systemImage: "paintpalette") }
                ShortcutSettingsView()
                    .tabItem { Label(t("Shortcuts", "快捷键"), systemImage: "keyboard") }
            }
            .environmentObject(store.themeManager)
            .environmentObject(writing)
            .environmentObject(typesetting)
            .environmentObject(printing)
            .environmentObject(overrides)
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
            CommandGroup(after: .pasteboard) {
                menuItem(.find)
                menuItem(.findReplace)
                Divider()
                menuItem(.searchWorkspace)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                menuItem(.toggleSplit)
                Divider()
                menuItem(.toggleTypewriter)
                menuItem(.toggleFocus)
                Divider()
                Button(t("Command Palette…", "命令面板…")) { paletteVisible = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }

    /// Menu items take their title, shortcut, availability and action from
    /// `CommandCatalog` — the same definitions the palette uses, so the two can
    /// never drift apart. The menus only declare structure: slots and dividers.
    @ViewBuilder
    private func menuItem(_ kind: CommandKind) -> some View {
        if let command = CommandCatalog.command(
            for: kind, themes: store.themeManager.themes, overrides: overrides.overrides
        ) {
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
