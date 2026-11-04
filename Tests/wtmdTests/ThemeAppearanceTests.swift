import AppKit
import Foundation
import Testing
@testable import wtmd

/// 换主题换的是整个 app 的明暗，不是只有正文那块纸（#283）。
///
/// 单外观主题（base16 浅色方案、终端一类）把外壳钉到它那一侧；双外观主题
/// 自己会跟系统变，外壳也就跟随系统。这里只测「要什么外观」与「有没有交出去」，
/// 真正改 `NSApp` 的那一下归 `wtmdApp` 管——测试进程不该被顺手改了外观。
@MainActor
@Suite("ThemeAppearance：外壳跟着主题走")
struct ThemeAppearanceTests {

    private func builtIn(_ id: String) throws -> Theme {
        try #require(Theme.builtIns.first { $0.id == id })
    }

    private func fixture(light: String?, dark: String?) -> Theme {
        Theme(id: "test.\(UUID().uuidString)", name: "t", author: "", isBuiltIn: false,
              light: light, dark: dark)
    }

    // MARK: - 映射

    @Test func singleVariantThemesPinTheWholeAppToTheirSide() throws {
        // base16 浅色方案：只有 light 层 → 整个 app 变浅
        let lightOnly = try builtIn("builtin.base16.atelier-cave-light")
        #expect(ThemeAppearance.mode(for: lightOnly) == .light)
        #expect(ThemeAppearance.nsAppearance(for: lightOnly)?.name == .aqua)

        // 终端：常暗 → 整个 app 变深
        let darkOnly = try builtIn("builtin.terminal")
        #expect(ThemeAppearance.mode(for: darkOnly) == .dark)
        #expect(ThemeAppearance.nsAppearance(for: darkOnly)?.name == .darkAqua)
    }

    @Test func dualVariantThemeFollowsTheSystem() throws {
        let both = try builtIn(Theme.defaultID)
        #expect(ThemeAppearance.mode(for: both) == .system)
        #expect(ThemeAppearance.nsAppearance(for: both) == nil, "跟系统就是别管 NSApp.appearance")
    }

    /// 主题文件坏到两层都空时按「跟系统」办：正文会回落默认主题（双外观），
    /// 外壳跟着系统才不会和正文唱反调。
    @Test func brokenThemeFallsBackToSystem() {
        let empty = fixture(light: "  \n", dark: nil)
        #expect(ThemeAppearance.mode(for: empty) == .system)
    }

    /// 守卫：内置主题要么两侧都有（跟系统），要么明确钉一侧。没有第三种情况——
    /// 一旦有人加了「只在某某外观下可用」的主题，这里会先炸。
    @Test func everyBuiltInThemeHasADefiniteShell() {
        for theme in Theme.builtIns {
            let mode = ThemeAppearance.mode(for: theme)
            if mode == .system {
                #expect(theme.hasLight && theme.hasDark, "\(theme.name) 缺一侧却说要跟系统")
            } else {
                #expect(theme.hasLight != theme.hasDark, "\(theme.name) 两侧都有却钉了一侧")
            }
        }
    }

    // MARK: - 交出去

    /// 选主题 → 外壳外观立刻交出去；换回双外观主题 → 交回「跟随系统」。
    @Test func selectingAThemeHandsItsShellOver() throws {
        let manager = ThemeManager()
        var handed: [String] = []
        manager.applyAppearance = { appearance in
            handed.append(appearance?.name.rawValue ?? "system")
        }

        manager.select("builtin.base16.atelier-cave-light")
        #expect(handed.last == NSAppearance.Name.aqua.rawValue)

        manager.select("builtin.terminal")
        #expect(handed.last == NSAppearance.Name.darkAqua.rawValue)

        manager.select(Theme.defaultID)
        #expect(handed.last == "system", "双外观主题必须把外观交还给系统")
    }

    /// 重扫主题后要再交一次：用户刚编辑了主题文件（比如把 dark 层删了），
    /// 外壳得跟着新覆盖范围走，不能停在上一次的外观上。
    @Test func rescanningThemesHandsTheShellOverAgain() {
        let manager = ThemeManager()
        var handed: [String] = []
        manager.applyAppearance = { appearance in
            handed.append(appearance?.name.rawValue ?? "system")
        }

        manager.reload()
        #expect(handed.count == 1)
        #expect(handed[0] == manager.appearanceOverride?.name.rawValue ?? "system")
    }
}
