import AppKit
import Testing
@testable import wtmd

/// 改派之后，菜单里的键位得跟着变——否则设置里写着「立即生效」，
/// 用户按下去还是没反应（⌃L 侧栏那次就是这么被发现的）。
///
/// SwiftUI 的命令菜单只在启动时建一次：`Commands` 里加 `@ObservedObject`、
/// 甚至让 App 自己 `@StateObject` 观察改派表，改完键位还是旧的（两条都实测过）。
/// 所以由 `ShortcutMenuSync` 直接把 `NSMenuItem.keyEquivalent` 改掉。
@MainActor
struct ShortcutMenuSyncTests {
    /// 侧栏出厂没有快捷键：改派成 ⌃L 之后，菜单项得立刻带上它。
    @Test("改派过的命令，菜单项的键位跟着变")
    func anOverrideLandsOnTheMenuItem() {
        let menu = makeMenu(titled: ["侧栏"])
        let overrides = ["view.toggleSidebar": RecordedShortcut(key: "l", modifiers: ["control"])]

        ShortcutMenuSync.apply(overrides: overrides, in: menu)

        let item = menu.items[0]
        #expect(item.keyEquivalent == "l")
        #expect(item.keyEquivalentModifierMask == .control)
    }

    /// 恢复出厂：没有覆盖时回到目录里的值（这条命令本来就没有快捷键，于是清空）。
    @Test("恢复出厂后，菜单项回到出厂键位")
    func resetRestoresTheFactoryChord() {
        let menu = makeMenu(titled: ["侧栏", "保存"])
        let overrides = ["view.toggleSidebar": RecordedShortcut(key: "l", modifiers: ["control"])]
        ShortcutMenuSync.apply(overrides: overrides, in: menu)

        ShortcutMenuSync.apply(overrides: [:], in: menu)

        #expect(menu.items[0].keyEquivalent.isEmpty, "侧栏出厂没有快捷键")
        #expect(menu.items[1].keyEquivalent == "s", "保存的出厂键位是 ⌘S")
        #expect(menu.items[1].keyEquivalentModifierMask == .command)
    }

    /// 不相干的菜单项——系统项、别人的项——一个字都不该被改。
    @Test("不认识的菜单项不碰")
    func unknownItemsAreLeftAlone() {
        let menu = NSMenu()
        let hide = NSMenuItem(title: "Hide wtmd", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = .command
        menu.addItem(hide)

        ShortcutMenuSync.apply(overrides: ["view.toggleSidebar": RecordedShortcut(key: "l", modifiers: ["control"])], in: menu)

        #expect(hide.keyEquivalent == "h")
        #expect(hide.keyEquivalentModifierMask == .command)
    }

    /// 子菜单里的项也要扫到（命令分组可能被系统塞进子菜单）。
    @Test("子菜单里的命令也认")
    func nestedItemsAreReached() {
        let menu = NSMenu()
        let parent = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(commandItem(titled: "侧栏"))
        parent.submenu = submenu
        menu.addItem(parent)

        ShortcutMenuSync.apply(overrides: ["view.toggleSidebar": RecordedShortcut(key: "l", modifiers: ["control"])], in: menu)

        #expect(submenu.items[0].keyEquivalent == "l")
    }

    // MARK: - 辅助

    /// 上面几条验的是「写回菜单」这件事本身。少了这一条，`persist()` 里那句调用被
    /// 谁顺手删了也没人喊——改派又变回「下次启动才生效」。
    @Test("改派落盘时确实调了写回")
    func persistingSyncsTheMenu() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/wtmd/ShortcutOverrides.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.contains("ShortcutMenuSync.apply(overrides: overrides)"))
    }

    /// 按标题造一组「我们的」菜单项：action 用 SwiftUI 那个选择子，`ShortcutMenuSync`
    /// 就是靠它认出命令项的。
    private func makeMenu(titled titles: [String]) -> NSMenu {
        let menu = NSMenu()
        for title in titles { menu.addItem(commandItem(titled: title)) }
        return menu
    }

    private func commandItem(titled title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(("menuAction:")), keyEquivalent: "")
        // 标题得是真目录里的文字，`t()` 在测试进程里固定中文。
        #expect(
            CommandCatalog.staticCommands.contains { $0.title == title },
            "\(title) 不在命令目录里，这条用例就测不到东西"
        )
        return item
    }
}
