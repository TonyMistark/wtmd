import SwiftUI

@main
struct wtmdApp: App {
    @StateObject private var store = DocumentStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.themeManager)
                .frame(minWidth: 760, minHeight: 500)
        }
        Settings {
            ThemeSettingsView()
                .environmentObject(store.themeManager)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建文档") { store.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("打开…") { store.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("保存") { store.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("导出 HTML…") { store.exportHTML() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("打印 / 存为 PDF…") { store.exportPDF() }
                    .keyboardShortcut("p", modifiers: .command)
            }
        }
    }
}
