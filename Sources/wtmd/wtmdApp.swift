import SwiftUI

@main
struct wtmdApp: App {
    @StateObject private var store = DocumentStore()
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var writing = WritingSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
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
                Button("新建文档") { store.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("打开…") { store.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("打开文件夹…") { workspace.openPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("保存") { store.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("导出 HTML…") { store.exportHTML() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("打印 / 存为 PDF…") { store.exportPDF() }
                    .keyboardShortcut("p", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Toggle("打字机模式", isOn: $writing.typewriter)
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Toggle("专注模式", isOn: $writing.focusMode)
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }
    }
}
