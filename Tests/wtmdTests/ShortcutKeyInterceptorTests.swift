import AppKit
import Testing
@testable import wtmd

/// ⌥ 组合改派的后门（#201）：编辑器聚焦时 Option-only 的 key equivalent
/// 到不了菜单，「ß」直接进正文。拦截器在派发前认改派表，命中就执行命令
/// 吞掉事件。这里守匹配规则——哪该接、哪该放。
@Suite("⌥ 组合改派拦截器")
@MainActor
struct ShortcutKeyInterceptorTests {

    private func flags(_ names: String...) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        for name in names {
            switch name {
            case "option": result.insert(.option)
            case "shift": result.insert(.shift)
            case "command": result.insert(.command)
            case "control": result.insert(.control)
            case "capsLock": result.insert(.capsLock)
            default: break
            }
        }
        return result
    }

    private func overrides(_ entries: [(String, String, [String])]) -> [String: RecordedShortcut] {
        Dictionary(entries.map { ($0.0, RecordedShortcut(key: $0.1, modifiers: $0.2)) },
                   uniquingKeysWith: { first, _ in first })
    }

    @Test("改派过的 ⌥S 命中——探针复现过它进正文变成 ß")
    func remappedOptionComboMatches() {
        let hit = ShortcutKeyInterceptor.match(
            key: "s", modifiers: flags("option"), themes: [],
            overrides: overrides([("view.toggleSidebar", "s", ["option"])])
        )
        #expect(hit?.kind == .toggleSidebar)
    }

    @Test("⌘/⌃ 组合不归拦截器管——菜单派发一直接得住")
    func commandAndControlCombosAreLeftAlone() {
        let table = overrides([("view.toggleSidebar", "s", ["option"])])
        #expect(
            ShortcutKeyInterceptor.match(
                key: "s", modifiers: flags("command"), themes: [], overrides: table
            ) == nil
        )
        #expect(
            ShortcutKeyInterceptor.match(
                key: "s", modifiers: flags("control"), themes: [], overrides: table
            ) == nil
        )
    }

    @Test("没改派的 ⌥ 组合放行——⌥S 本来就该打 ß，别多管闲事")
    func unmappedOptionCombosFallThrough() {
        #expect(
            ShortcutKeyInterceptor.match(
                key: "x", modifiers: flags("option"), themes: [], overrides: [:]
            ) == nil
        )
    }

    @Test("⌥⇧S 不冒充 ⌥S——修饰键不同就是不同的键")
    func shiftVariantIsADifferentChord() {
        let hit = ShortcutKeyInterceptor.match(
            key: "s", modifiers: flags("option", "shift"), themes: [],
            overrides: overrides([("view.toggleSidebar", "s", ["option"])])
        )
        #expect(hit == nil)
    }

    @Test("大写锁定不影响识别")
    func capsLockIsIgnored() {
        let hit = ShortcutKeyInterceptor.match(
            key: "s", modifiers: flags("option", "capsLock"), themes: [],
            overrides: overrides([("view.toggleSidebar", "s", ["option"])])
        )
        #expect(hit?.kind == .toggleSidebar)
    }

    @Test("大写主键与小写同键（charactersIgnoringModifiers 给的是原样字符）")
    func uppercasedKeyMatchesTheSameChord() {
        let hit = ShortcutKeyInterceptor.match(
            key: "S", modifiers: flags("option"), themes: [],
            overrides: overrides([("view.toggleSidebar", "s", ["option"])])
        )
        #expect(hit?.kind == .toggleSidebar)
    }

    @Test("多键位改派表里只命中记录相符的那条")
    func onlyTheMatchingEntryWins() {
        let table = overrides([
            ("view.toggleSidebar", "s", ["option"]),
            ("file.new", "n", ["option"]),
        ])
        let sidebar = ShortcutKeyInterceptor.match(
            key: "s", modifiers: flags("option"), themes: [], overrides: table
        )
        #expect(sidebar?.kind == .toggleSidebar)
        let newDocument = ShortcutKeyInterceptor.match(
            key: "n", modifiers: flags("option"), themes: [], overrides: table
        )
        #expect(newDocument?.kind == .newDocument)
    }

    @Test("拦截器在启动时装上了——拆了它 ⌥S 就会回到「时灵时不灵」")
    func theInterceptorIsInstalledAtLaunch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // wtmdTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // 仓库根
            .appendingPathComponent("Sources/wtmd/wtmdApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // 先剥注释再判——注释里提到这个符号不该算数（MenuPlacementTests 的教训）。
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let cut = line.range(of: "//") else { return String(line) }
                return String(line[..<cut.lowerBound])
            }
            .joined(separator: "\n")
        #expect(code.contains("ShortcutKeyInterceptor.install"), "启动时没装 ⌥ 组合拦截器")
    }
}
