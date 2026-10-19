import SwiftUI

@main
struct wtmdApp: App {
    /// 应用级的一份：设置、账本、最近文件。
    @StateObject private var shared: SharedAppEnvironment
    /// 窗口表：谁是主窗口，命令该落在谁身上，下一扇窗口从哪儿开。
    @StateObject private var coordinator: WindowCoordinator

    init() {
        let shared = SharedAppEnvironment()
        let coordinator = WindowCoordinator(shared: shared)
        _shared = StateObject(wrappedValue: shared)
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        WindowGroup(id: WindowScene.main) {
            WindowRoot(model: coordinator.primary, coordinator: coordinator)
        }
        .commands {
            AppMenus(shared: shared, coordinator: coordinator)
        }

        // 第二扇窗口：按 id 开，内容从窗口表里取。表里没有（系统恢复下来的旧窗口）
        // 就什么都不给——它没有会话可恢复，空白比错乱好。
        WindowGroup(id: WindowScene.extra, for: UUID.self) { id in
            if let id = id.wrappedValue, let model = coordinator.model(for: id) {
                WindowRoot(model: model, coordinator: coordinator)
            }
        }

        Settings {
            TabView {
                ThemeSettingsView()
                    .tabItem { Label(t("Theme", "主题"), systemImage: "paintpalette") }
                ShortcutSettingsView()
                    .tabItem { Label(t("Shortcuts", "快捷键"), systemImage: "keyboard") }
            }
            .environmentObject(shared.themeManager)
            .environmentObject(shared.writing)
            .environmentObject(shared.typesetting)
            .environmentObject(shared.printing)
            .environmentObject(shared.overrides)
        }
    }
}

/// 菜单只声明结构（槽位与分隔线），标题、快捷键、可用性、动作全部来自
/// `CommandCatalog` / `CommandRuntime`——菜单与 ⌘K 面板因此不可能走岔。
struct AppMenus: Commands {
    let shared: SharedAppEnvironment
    let coordinator: WindowCoordinator

    /// 前台窗口。取不到（欢迎页、刚启动还没有焦点）时回退主窗口。
    @FocusedValue(\.windowModel) private var focused

    private var active: WindowModel { coordinator.activeModel(focused: focused) }

    var body: some Commands {
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
            Button(t("Command Palette…", "命令面板…")) { active.paletteVisible = true }
                .keyboardShortcut("k", modifiers: .command)
        }
    }

    @ViewBuilder
    private func menuItem(_ kind: CommandKind) -> some View {
        if let command = CommandCatalog.command(
            for: kind, themes: shared.themeManager.themes, overrides: shared.overrides.overrides
        ) {
            let runtime = CommandRuntime(
                store: active.store,
                workspace: active.workspace,
                writing: shared.writing,
                updates: shared.updates,
                windows: coordinator
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
