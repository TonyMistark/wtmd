import AppKit
import SwiftUI

/// 把改派过的键位写回菜单项。
///
/// SwiftUI 的命令菜单**只在启动时建一次**：`Commands` 里放 `@ObservedObject`、
/// 甚至让 App 自己 `@StateObject` 观察改派表，改完一次键位还是旧的（两条都实测过）。
/// 于是「设置里改完立即生效」只能自己做——菜单项是 NSMenuItem，`keyEquivalent`
/// 可以直接改，改完 AppKit 立刻按新键派发。
///
/// 认哪一项是我们的命令：SwiftUI 给命令项挂的都是 `menuAction:`，标题来自
/// `CommandCatalog`（同一个 `t()`，与菜单一致）。两条都对上才动，别碰系统项。
@MainActor
enum ShortcutMenuSync {
    /// 菜单项的 action：SwiftUI 的 `MenuItemCallback` 全走这个选择子。
    private static let commandAction = "menuAction:"

    /// 按改派表刷新整份菜单。`menu` 留给测试传一份自己搭的菜单。
    static func apply(
        overrides: [String: RecordedShortcut],
        in menu: NSMenu? = NSApplication.shared.mainMenu
    ) {
        guard let menu else { return }
        let kinds = kindsByTitle()
        forEachItem(in: menu) { item in
            guard let action = item.action.map({ NSStringFromSelector($0) }),
                  action == commandAction,
                  let kind = kinds[item.title]
            else { return }
            guard let shortcut = effective(kind, overrides: overrides) else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                return
            }
            item.keyEquivalent = String(shortcut.key.character)
            item.keyEquivalentModifierMask = modifiers(of: shortcut)
        }
    }

    private static func effective(
        _ kind: CommandKind,
        overrides: [String: RecordedShortcut]
    ) -> KeyboardShortcut? {
        if let override = overrides[kind.id], let shortcut = override.keyboardShortcut {
            return shortcut
        }
        return CommandCatalog.staticCommands.first { $0.kind == kind }?.shortcut
    }

    /// 标题 → 命令。标题来自同一份目录，所以菜单项的文字与它逐字相同。
    private static func kindsByTitle() -> [String: CommandKind] {
        var table: [String: CommandKind] = [:]
        for command in CommandCatalog.staticCommands {
            table[command.title] = command.kind
        }
        return table
    }

    private static func modifiers(of shortcut: KeyboardShortcut) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// 菜单项可能嵌在子菜单里。
    private static func forEachItem(in menu: NSMenu, _ body: (NSMenuItem) -> Void) {
        for item in menu.items {
            body(item)
            if let submenu = item.submenu { forEachItem(in: submenu, body) }
        }
    }
}
