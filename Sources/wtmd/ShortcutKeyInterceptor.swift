import AppKit

// MARK: - Option 组合改派的最后一道

/// ⌥ 组合的改派键不能指望菜单派发——真机探针实证（#201）：编辑器聚焦时，
/// 合成的 ⌥S 走 `NSApp.sendEvent`，「ß」直接打进正文，命令一次都没跑到。
/// 文本视图在响应链上时，Option-only 的 key equivalent 到不了菜单（AppKit
/// 对带 ⌘ 的组合按 `charactersIgnoringModifiers` 匹配，对 Option-only 却
/// 拿产出字符比——「s」自然比不过「ß」）；不聚焦时又时灵时不灵。
///
/// 解法是在事件进派发**之前**拦：本地监视器里认「改派表里的 Option 组合」，
/// 命中就执行命令并吞掉事件。菜单项上的 ⌥S 显示照旧——那是给人看的。
/// 只接**改派过**的 Option 组合：⌘/⌃ 系菜单一直接得住，出厂没改派的
/// ⌥ 组合（比如 ⌥S 本身打「ß」）一个都不碰。
@MainActor
enum ShortcutKeyInterceptor {
    private static var monitor: Any?

    static func install(shared: SharedAppEnvironment, coordinator: WindowCoordinator) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if intercept(event, shared: shared, coordinator: coordinator) { return nil }
                return event
            }
        }
    }

    /// 返回 true = 这个键是改派过的命令：已执行，事件吞掉（与菜单键等价
    /// 语义一致——按下就算数，即使命令此刻不可用也不该把「ß」漏进正文）。
    static func intercept(_ event: NSEvent, shared: SharedAppEnvironment, coordinator: WindowCoordinator) -> Bool {
        guard let command = match(
            key: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            themes: shared.themeManager.themes,
            overrides: shared.overrides.overrides
        ) else { return false }
        let model = coordinator.activeModel(focused: nil)
        let runtime = CommandRuntime(
            store: model.store,
            workspace: model.workspace,
            writing: shared.writing,
            updates: shared.updates,
            windows: coordinator
        )
        runtime.run(command)
        return true
    }

    /// 纯匹配：这个键位命中改派表里的哪条命令。nil = 不归我管，放行。
    static func match(
        key: String?,
        modifiers: NSEvent.ModifierFlags,
        themes: [Theme],
        overrides: [String: RecordedShortcut]
    ) -> AppCommand? {
        let flags = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        // 只管 Option 系（可带 ⇧）；⌘/⌃ 组合走菜单，那里不出岔子。
        guard flags.contains(.option), !flags.contains(.command), !flags.contains(.control) else { return nil }
        guard let key, key.count == 1, let main = key.lowercased().first else { return nil }

        var names = ["option"]
        if flags.contains(.shift) { names.append("shift") }
        let candidate = RecordedShortcut(key: String(main), modifiers: names)

        // 有效键位 = 出厂值套上改派，与菜单/面板同源——改派一变，这里跟着变。
        for command in CommandCatalog.commands(themes: themes, recentFiles: [], overrides: overrides) {
            guard let shortcut = command.shortcut,
                  let recorded = RecordedShortcut(shortcut),
                  recorded == candidate
            else { continue }
            return command
        }
        return nil
    }
}
