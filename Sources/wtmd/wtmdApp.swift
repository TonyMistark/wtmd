import AppKit
import SwiftUI

@main
struct wtmdApp: App {
    /// 应用级的一份：设置、账本、最近文件。
    @StateObject private var shared: SharedAppEnvironment
    /// 窗口表：谁是主窗口，命令该落在谁身上，下一扇窗口从哪儿开。
    @StateObject private var coordinator: WindowCoordinator

    init() {
        let shared = SharedAppEnvironment()
        // 顺序不能反：先把上次留下的半成品整理成报告（它要读上一次的轨迹），
        // 再装信号处理器——装的时候会清空轨迹文件，那本子是给这一次用的。
        shared.crashes.harvest()
        CrashBreadcrumbs.install(directory: shared.crashes.directory)
        CrashCatcher.install(directory: shared.crashes.directory)
        CrashBreadcrumbs.note("launch wtmd \(CrashEnvironment.appVersion)")

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
            SettingsSheet()
                .environmentObject(shared.themeManager)
                .environmentObject(shared.writing)
                .environmentObject(shared.typesetting)
                .environmentObject(shared.printing)
                .environmentObject(shared.overrides)
        }
    }
}

/// 设置窗口。选中的是哪一页也记在 defaults 里——功能中心里的「每日目标」
/// 「阅读版式」「打印设置」要落在对应的那一页，靠的就是这一个键。
struct SettingsSheet: View {
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.theme.rawValue

    var body: some View {
        TabView(selection: $tab) {
            ThemeSettingsView()
                .tabItem { Label(SettingsTab.theme.title, systemImage: SettingsTab.theme.symbol) }
                .tag(SettingsTab.theme.rawValue)
            WritingSettingsView()
                .tabItem { Label(SettingsTab.writing.title, systemImage: SettingsTab.writing.symbol) }
                .tag(SettingsTab.writing.rawValue)
            LayoutSettingsView()
                .tabItem { Label(SettingsTab.layout.title, systemImage: SettingsTab.layout.symbol) }
                .tag(SettingsTab.layout.rawValue)
            PrintingSettingsView()
                .tabItem { Label(SettingsTab.printing.title, systemImage: SettingsTab.printing.symbol) }
                .tag(SettingsTab.printing.rawValue)
            ShortcutSettingsView()
                .tabItem { Label(SettingsTab.shortcuts.title, systemImage: SettingsTab.shortcuts.symbol) }
                .tag(SettingsTab.shortcuts.rawValue)
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
        // 系统的「关于 wtmd」换成我们自己的那一条：与 ⌘K、功能中心同源。
        CommandGroup(replacing: .appInfo) {
            menuItem(.about)
        }
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
            menuItem(.showHistory)
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
            menuItem(.showCalendar)
            Divider()
            menuItem(.toggleTypewriter)
            menuItem(.toggleFocus)
            Divider()
            Button(t("Command Palette…", "命令面板…")) { active.paletteVisible = true }
                .keyboardShortcut("k", modifiers: .command)
        }
        // 帮助菜单默认只有一项打不开的「wtmd 帮助」。换成真正有用的那个：
        // 崩了、或者哪里不对，从这里把话说到 GitHub 上去。
        CommandGroup(replacing: .help) {
            menuItem(.reportProblem)
            Divider()
            Button(t("Crash Reports Folder", "崩溃报告文件夹")) {
                NSWorkspace.shared.open(shared.crashes.directory)
            }
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
