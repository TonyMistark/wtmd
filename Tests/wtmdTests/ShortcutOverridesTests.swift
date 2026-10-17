import AppKit
import Foundation
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 自定义快捷键

/// 目录里那条是出厂值，用户改派存覆盖层。这组用例守三件事：
/// **覆盖优先于出厂、删掉就回出厂**；**一把钥匙只能给一条命令**；
/// **命令面板的 ⌘K 与光杆字母谁也拿不走**。

private func makeIsolatedDefaults() -> UserDefaults {
    let suite = "wtmd.tests.shortcuts.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
@Test func anOverrideSurvivesARestart() {
    let defaults = makeIsolatedDefaults()
    let first = ShortcutOverrides(defaults: defaults)
    let result = first.assign(
        RecordedShortcut(key: "g", modifiers: ["command"]),
        for: .exportWord
    )
    #expect(result == .assigned)

    // 关掉应用再打开
    let reopened = ShortcutOverrides(defaults: defaults)
    let shortcut = reopened.effectiveShortcut(for: .exportWord)
    #expect(shortcut?.key == "g")
    #expect(shortcut?.modifiers.contains(.command) == true)
}

@MainActor
@Test func effectiveFallsBackToTheFactoryShortcut() {
    let overrides = ShortcutOverrides(defaults: makeIsolatedDefaults())
    let shortcut = overrides.effectiveShortcut(for: .find)
    #expect(shortcut?.key == "f")
    #expect(shortcut?.modifiers == .command)
}

@MainActor
@Test func clearingAnOverrideReturnsToTheFactory() {
    let overrides = ShortcutOverrides(defaults: makeIsolatedDefaults())
    overrides.assign(RecordedShortcut(key: "g", modifiers: ["command"]), for: .find)

    overrides.assign(nil, for: .find)

    #expect(overrides.overrides.isEmpty)
    #expect(overrides.effectiveShortcut(for: .find)?.key == "f")
}

@MainActor
@Test func aChordOwnedByAnotherCommandIsRejected() {
    let overrides = ShortcutOverrides(defaults: makeIsolatedDefaults())
    #expect(
        overrides.assign(RecordedShortcut(key: "g", modifiers: ["command"]), for: .exportWord)
            == .assigned
    )

    // ⌘G 已经给了导出 Word，保存不能也拿走它
    let result = overrides.assign(RecordedShortcut(key: "g", modifiers: ["command"]), for: .save)
    guard case .rejected(let reason) = result else {
        Issue.record("应当被拒绝")
        return
    }
    #expect(reason.contains("导出 Word"))
    #expect(overrides.effectiveShortcut(for: .save)?.key == "s")
}

/// 反向守门：改派冲突判定要认「生效中」的键位——出厂值没动过的命令同样不能被撞。
@MainActor
@Test func aFactoryShortcutOfAnotherCommandIsStillProtected() {
    let overrides = ShortcutOverrides(defaults: makeIsolatedDefaults())
    let result = overrides.assign(
        RecordedShortcut(key: "o", modifiers: ["command"]), for: .save
    )
    guard case .rejected = result else {
        Issue.record("⌘O 属于「打开…」，应当被拒绝")
        return
    }
}

@MainActor
@Test func thePaletteChordIsReserved() {
    let overrides = ShortcutOverrides(defaults: makeIsolatedDefaults())
    let result = overrides.assign(RecordedShortcut(key: "k", modifiers: ["command"]), for: .find)
    guard case .rejected(let reason) = result else {
        Issue.record("⌘K 应当被拒绝")
        return
    }
    #expect(reason.contains("命令面板"))
}

@MainActor
@Test func aBareLetterNeedsAModifier() {
    let overrides = ShortcutOverrides(defaults: makeIsolatedDefaults())
    #expect(
        overrides.assign(RecordedShortcut(key: "g", modifiers: []), for: .exportWord)
            == .rejected("快捷键至少要带上 ⌘、⌥ 或 ⌃ 中的一个")
    )
    // 只有 shift 也不行——那是打字
    #expect(
        overrides.assign(RecordedShortcut(key: "g", modifiers: ["shift"]), for: .exportWord)
            != .assigned
    )
}

/// 把出厂键位原样录回去不是改派，不该留下一条空覆盖。
@MainActor
@Test func selfAssignmentLeavesNoDust() {
    let overrides = ShortcutOverrides(defaults: makeIsolatedDefaults())
    let result = overrides.assign(RecordedShortcut(key: "f", modifiers: ["command"]), for: .find)
    #expect(result == .assigned)
    #expect(overrides.overrides.isEmpty)
}

// MARK: - 目录查找要套上覆盖

@MainActor
@Test func catalogLookupAppliesTheOverride() {
    let overrides = ShortcutOverrides(defaults: makeIsolatedDefaults())
    overrides.assign(RecordedShortcut(key: "g", modifiers: ["command"]), for: .exportWord)
    let table = overrides.overrides

    let command = CommandCatalog.command(for: .exportWord, overrides: table)
    #expect(command?.shortcut?.key == "g")

    let all = CommandCatalog.commands(themes: [], recentFiles: [], overrides: table)
    #expect(all.first { $0.kind == .exportWord }?.shortcut?.key == "g")
    // 没被改派的命令原样不动
    #expect(all.first { $0.kind == .save }?.shortcut?.key == "s")
}

// MARK: - 录制

@Test func aKeyboardShortcutRoundTripsThroughTheRecordedForm() {
    let original = KeyboardShortcut("t", modifiers: [.command, .option])
    let recorded = RecordedShortcut(original)
    #expect(recorded?.label == "⌥⌘T")
    #expect(recorded?.chordKey == "command+option+t")

    let restored = recorded?.keyboardShortcut
    #expect(restored?.key == original.key)
    #expect(restored?.modifiers == original.modifiers)
}

@Test func keyPressesMapToRecordedShortcuts() {
    #expect(
        RecordedShortcut.from(key: "g", modifiers: [.command, .shift])
            == RecordedShortcut(key: "g", modifiers: ["command", "shift"])
    )
    // 大小写归一：⌘G 与 ⌘g 是同一把钥匙
    #expect(
        RecordedShortcut.from(key: "G", modifiers: [.command])
            == RecordedShortcut(key: "g", modifiers: ["command"])
    )
    // 功能键（方向键等私有区字符）不收
    #expect(RecordedShortcut.from(key: Character("\u{F702}"), modifiers: [.command]) == nil)
    #expect(RecordedShortcut.from(key: " ", modifiers: [.command]) == nil)
}
