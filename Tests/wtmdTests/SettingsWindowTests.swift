import Foundation
import Testing
@testable import wtmd

// MARK: - 设置窗口的入口

/// 「点了没反应」是这类 bug 里最难查的一种：动作发出去了，没人接。
/// 这里守的是**那个接的人真的被叫到**——视图环境给的 opener 优先，
/// 没有它才回退 AppKit。
@Suite("设置窗口的入口", .serialized)
@MainActor
struct SettingsWindowTests {
    private static let storageKey = SettingsTab.storageKey

    /// 测试动的是真 defaults，跑完必须还回去——否则读者下次打开设置
    /// 会停在一页他从没选过的标签。
    private func withRestoredDefaults(_ body: () throws -> Void) rethrows {
        let original = UserDefaults.standard.string(forKey: Self.storageKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: Self.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.storageKey)
            }
            SettingsWindow.install(nil)
        }
        try body()
    }

    @Test("有 opener 就交给它，同时把要开的那一页记下来")
    func openHandsOverToTheInjectedOpener() {
        withRestoredDefaults {
            var opened = 0
            SettingsWindow.install { opened += 1 }

            SettingsWindow.open(.shortcuts)

            #expect(opened == 1)
            #expect(UserDefaults.standard.string(forKey: Self.storageKey) == "shortcuts")
        }
    }

    @Test("没给页时打开上次停留的那一页")
    func openWithoutATabUsesTheRememberedOne() {
        withRestoredDefaults {
            UserDefaults.standard.set(SettingsTab.shortcuts.rawValue, forKey: Self.storageKey)
            var opened = 0
            SettingsWindow.install { opened += 1 }

            SettingsWindow.open()

            #expect(opened == 1)
            #expect(UserDefaults.standard.string(forKey: Self.storageKey) == "shortcuts")
        }
    }

    @Test("记下来的值坏了（或第一次打开）就落到个人信息页，不崩")
    func openWithAGarbageTabFallsBackToProfile() {
        withRestoredDefaults {
            UserDefaults.standard.set("no-such-tab", forKey: Self.storageKey)
            var opened = 0
            SettingsWindow.install { opened += 1 }

            SettingsWindow.open()

            #expect(opened == 1)
            #expect(UserDefaults.standard.string(forKey: Self.storageKey) == "profile")
        }
    }

    @Test("没有 opener 时不崩：回退 AppKit 的动作，页还是照样记")
    func openWithoutAnOpenerFallsBack() {
        withRestoredDefaults {
            SettingsWindow.install(nil)

            SettingsWindow.open(.theme)

            #expect(UserDefaults.standard.string(forKey: Self.storageKey) == "theme")
        }
    }
}
