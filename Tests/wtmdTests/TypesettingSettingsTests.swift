import Foundation
import Testing
@testable import wtmd

// MARK: - 版式偏好

/// 每个用例一份临时 suite：测试绝不写读者的真实 preferences。
@MainActor
private func makeSettings() -> (TypesettingSettings, UserDefaults, String) {
    let suite = "wtmd.tests.typeset.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (TypesettingSettings(defaults: defaults), defaults, suite)
}

@MainActor
@Test func freshInstallUsesTheOldHardcodedLayout() throws {
    let (settings, defaults, suite) = makeSettings()
    defer { defaults.removePersistentDomain(forName: suite) }

    // 默认值 = v0.8 之前写死在样式表里的那三个数
    #expect(settings.measure == 760)
    #expect(settings.fontSize == 16)
    #expect(settings.lineHeight == 1.75)
}

@MainActor
@Test func cssCarriesTheThreeVariables() throws {
    let (settings, defaults, suite) = makeSettings()
    defer { defaults.removePersistentDomain(forName: suite) }

    settings.measure = 620
    settings.fontSize = 18
    settings.lineHeight = 1.9

    let css = settings.css
    #expect(css.contains("--wtmd-measure: 620px;"))
    #expect(css.contains("--wtmd-font-size: 18px;"))
    #expect(css.contains("--wtmd-line-height: 1.90;"))
}

/// 手改过的 defaults 或旧版本遗留值不该把版面撑坏：越界一律收敛。
@MainActor
@Test func outOfRangeValuesAreClampedInTheCSS() throws {
    let (settings, defaults, suite) = makeSettings()
    defer { defaults.removePersistentDomain(forName: suite) }

    settings.measure = 5_000
    settings.fontSize = 3
    settings.lineHeight = 9

    let css = settings.css
    #expect(css.contains("--wtmd-measure: 1100px;"))
    #expect(css.contains("--wtmd-font-size: 14px;"))
    #expect(css.contains("--wtmd-line-height: 2.20;"))
}

@MainActor
@Test func valuesSurviveARelaunch() throws {
    let suite = "wtmd.tests.typeset.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = TypesettingSettings(defaults: defaults)
    first.measure = 900
    first.fontSize = 20
    first.lineHeight = 2.0

    let second = TypesettingSettings(defaults: defaults)
    #expect(second.measure == 900)
    #expect(second.fontSize == 20)
    #expect(second.lineHeight == 2.0)
}

@MainActor
@Test func resetGoesBackToTheOldLayout() throws {
    let (settings, defaults, suite) = makeSettings()
    defer { defaults.removePersistentDomain(forName: suite) }

    settings.measure = 1_000
    settings.fontSize = 22
    settings.lineHeight = 1.4
    settings.reset()

    #expect(settings.measure == 760)
    #expect(settings.fontSize == 16)
    #expect(settings.lineHeight == 1.75)
}

// MARK: - 样式层

/// 版式层只在给了 CSS 时出现；导出（不传 layoutCSS）的文档与从前逐字一致。
@Test func layoutLayerIsOnlyEmittedWhenItHasContent() {
    let withLayout = StyleSheet.fullDocument(
        title: "t", body: "<p>x</p>", themeCSS: ":root{}", includeScript: false,
        layoutCSS: ":root{--wtmd-measure:600px}"
    )
    #expect(withLayout.contains("<style id=\"wtmd-layout\">"))
    #expect(withLayout.contains("--wtmd-measure:600px"))

    let without = StyleSheet.fullDocument(
        title: "t", body: "<p>x</p>", themeCSS: ":root{}", includeScript: false
    )
    #expect(!without.contains("wtmd-layout"))
}

/// 三个常量必须真的走变量——否则读者拖滑块不会有任何动静。
@Test func baseCSSTakesTheVariablesWithTheOldDefaults() {
    #expect(StyleSheet.baseCSS.contains("font-size: var(--wtmd-font-size, 16px)"))
    #expect(StyleSheet.baseCSS.contains("line-height: var(--wtmd-line-height, 1.75)"))
    #expect(StyleSheet.baseCSS.contains("max-width: var(--wtmd-measure, 760px)"))
}
