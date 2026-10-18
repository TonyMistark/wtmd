import Foundation
import Testing
@testable import wtmd

/// 双语开关本身：override 说了算，不设则测试进程固定中文——
/// 这样对界面文案的断言不随 CI 机器的系统语言漂。
@Test func l10nPicksTheLanguageAndFallsBackForTests() {
    L10n.override = "en"
    defer { L10n.override = nil }
    #expect(t("Open", "打开") == "Open")
    #expect(!L10n.isChinese)

    L10n.override = "zh"
    #expect(t("Open", "打开") == "打开")
    #expect(L10n.isChinese)

    // 不设 override：测试进程固定中文，断言才稳。
    L10n.override = nil
    #expect(L10n.isChinese)
    #expect(t("Open", "打开") == "打开")
}
