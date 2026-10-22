import Foundation
import SwiftUI

// MARK: - 快捷键的持久化形态

/// 一条用户自定义的快捷键：主键 + 修饰键。
///
/// `KeyboardShortcut` 不是 `Codable` 的，落盘前先拆成「字符 + 修饰键」两个字段；
/// 修饰键用字符串数组而不是位标志，账目读得懂、改得动。
struct RecordedShortcut: Codable, Equatable {
    /// 主键，单个小写字符。
    var key: String
    /// `command` / `option` / `shift` / `control`，顺序无关。
    var modifiers: [String]

    init(key: String, modifiers: [String]) {
        self.key = key.lowercased()
        self.modifiers = Array(Set(modifiers)).sorted()
    }

    /// 从目录里现有的 `KeyboardShortcut` 取一份拷贝（重置回默认时要能读出它长什么样）。
    init?(_ shortcut: KeyboardShortcut) {
        let key = String(shortcut.key.character).lowercased()
        guard key.count == 1, Self.isPrintable(key.first!) else { return nil }
        self.key = key
        var names: [String] = []
        if shortcut.modifiers.contains(.command) { names.append("command") }
        if shortcut.modifiers.contains(.option) { names.append("option") }
        if shortcut.modifiers.contains(.shift) { names.append("shift") }
        if shortcut.modifiers.contains(.control) { names.append("control") }
        self.modifiers = names.sorted()
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if modifiersContain("command") { modifiers.insert(.command) }
        if modifiersContain("option") { modifiers.insert(.option) }
        if modifiersContain("shift") { modifiers.insert(.shift) }
        if modifiersContain("control") { modifiers.insert(.control) }
        return modifiers
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let character = key.first else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: eventModifiers)
    }

    private func modifiersContain(_ name: String) -> Bool {
        modifiers.contains(name)
    }

    /// 界面上的样子：⌃⌥⇧⌘ 固定顺序，主键大写。
    var label: String {
        var text = ""
        if modifiersContain("control") { text += "⌃" }
        if modifiersContain("option") { text += "⌥" }
        if modifiersContain("shift") { text += "⇧" }
        if modifiersContain("command") { text += "⌘" }
        return text + key.uppercased()
    }

    /// 冲突判定的钥匙：同一把钥匙只能给一条命令。
    var chordKey: String {
        (modifiers + [key]).sorted().joined(separator: "+")
    }

    /// 命令面板的 ⌘K 是界面里写死的隐藏按钮，不参与分配。
    static let reservedChords: Set<String> = ["command+k"]

    /// 录制器按下的一个键。只收可打印的单个字符——方向键、F 功能键留给系统。
    ///
    /// 拆开收「字符 + 修饰键」而不是收 `KeyPress`：`KeyPress` 没有公开的构造器，
    /// 这样拆开才测得动。
    static func from(key: Character, modifiers: EventModifiers) -> RecordedShortcut? {
        guard isPrintable(key),
              !key.isWhitespace,
              !key.isNewline
        else { return nil }
        var names: [String] = []
        if modifiers.contains(.command) { names.append("command") }
        if modifiers.contains(.option) { names.append("option") }
        if modifiers.contains(.shift) { names.append("shift") }
        if modifiers.contains(.control) { names.append("control") }
        return RecordedShortcut(key: String(key), modifiers: names)
    }

    /// `Character` 没有 `isPrintable`：可打印 = 不在控制区、不在我们拿来当功能键
    /// 的私有区（方向键等 NSEvent 功能键落在 0xF700–0xF8FF）。
    private static func isPrintable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20
                && scalar.value != 0x7F
                && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}

// MARK: - 覆盖层

/// 用户对命令快捷键的改派。
///
/// 目录里那条是出厂值，这里存的是「用户改成了什么」；查找顺序永远是
/// **覆盖 → 出厂**，删掉覆盖就回到出厂。落在 `UserDefaults` 的一个 JSON 里。
@MainActor
final class ShortcutOverrides: ObservableObject {
    static let storageKey = "wtmd.shortcutOverrides"

    @Published private(set) var overrides: [String: RecordedShortcut] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: RecordedShortcut].self, from: data) {
            overrides = decoded
        }
    }

    /// 改派的结果：成功、因冲突被拒（附原因），还是没变。
    enum AssignmentResult: Equatable {
        case assigned
        case rejected(String)
    }

    /// 把一个键位派给一条命令。`nil` 表示清除覆盖、回到出厂。
    func assign(_ shortcut: RecordedShortcut?, for kind: CommandKind) -> AssignmentResult {
        guard let shortcut else {
            overrides[kind.id] = nil
            persist()
            return .assigned
        }

        // 系统级的角落不让碰：命令面板的 ⌘K 是写死在界面里的隐藏按钮
        guard !RecordedShortcut.reservedChords.contains(shortcut.chordKey) else {
            return .rejected(t("⌘K belongs to the command palette and cannot be reassigned"))
        }
        // 没有菜单项的命令，键位按下去了没人接——与其存一个哑键，不如当场说清楚
        guard CommandCatalog.menuCarriedKinds.contains(kind) else {
            let title = CommandCatalog.command(for: kind)?.title ?? kind.id
            return .rejected(t("{} has no menu item, so a shortcut would do nothing", title))
        }
        // 至少要有一个真正的修饰键：光杆字母用来打字
        guard shortcut.modifiers.contains(where: { $0 != "shift" }) else {
            return .rejected(t("A shortcut must include at least one of ⌘, ⌥ or ⌃"))
        }
        // 自己派给自己就是「恢复现状」
        if let current = effectiveShortcut(for: kind), let currentRecorded = RecordedShortcut(current),
           currentRecorded == shortcut {
            return .assigned
        }
        // 别的命令正握着这把钥匙：先挪走再来
        if let owner = command(owningChord: shortcut.chordKey), owner != kind.id,
           let ownerKind = CommandKind(ownerID: owner) {
            let title = CommandCatalog.command(for: ownerKind)?.title ?? owner
            return .rejected(t("{} is already assigned to {} — release it first", shortcut.label, title))
        }

        overrides[kind.id] = shortcut
        persist()
        return .assigned
    }

    /// 生效中的快捷键：覆盖优先，没有就回目录里的出厂值。
    func effectiveShortcut(for kind: CommandKind) -> KeyboardShortcut? {
        if let override = overrides[kind.id], let shortcut = override.keyboardShortcut {
            return shortcut
        }
        return CommandCatalog.staticCommands.first { $0.kind == kind }?.shortcut
    }

    /// 这把钥匙现在在谁手里（按生效中的快捷键算，含覆盖）。
    func command(owningChord chord: String) -> String? {
        for command in CommandCatalog.staticCommands {
            if let shortcut = effectiveShortcut(for: command.kind),
               let recorded = RecordedShortcut(shortcut),
               recorded.chordKey == chord {
                return command.kind.id
            }
        }
        return nil
    }

    func resetAll() {
        overrides = [:]
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: Self.storageKey)
        // SwiftUI 不会因为这张表变了就重建菜单（实测），改完得自己写回菜单项，
        // 否则「立即生效」是一句空话——得等下次启动。
        ShortcutMenuSync.apply(overrides: overrides)
    }
}

/// 从 `id` 反查 `CommandKind`：只为报错文案里叫得出那条命令的名字。
/// `selectTheme` / `openRecent` 这类带参数的命令不参与快捷键，不在表里。
extension CommandKind {
    init?(ownerID id: String) {
        let table: [String: CommandKind] = [
            CommandKind.newDocument.id: .newDocument,
            CommandKind.openDocument.id: .openDocument,
            CommandKind.openFolder.id: .openFolder,
            CommandKind.save.id: .save,
            CommandKind.exportHTML.id: .exportHTML,
            CommandKind.exportWord.id: .exportWord,
            CommandKind.exportPDF.id: .exportPDF,
            CommandKind.find.id: .find,
            CommandKind.findReplace.id: .findReplace,
            CommandKind.searchWorkspace.id: .searchWorkspace,
            CommandKind.toggleMode.id: .toggleMode,
            CommandKind.toggleSplit.id: .toggleSplit,
            CommandKind.toggleSidebar.id: .toggleSidebar,
            CommandKind.closeWorkspace.id: .closeWorkspace,
            CommandKind.toggleTypewriter.id: .toggleTypewriter,
            CommandKind.toggleFocus.id: .toggleFocus,
            CommandKind.openThemesFolder.id: .openThemesFolder,
            CommandKind.rescanThemes.id: .rescanThemes,
            CommandKind.checkForUpdates.id: .checkForUpdates,
        ]
        guard let kind = table[id] else { return nil }
        self = kind
    }
}
