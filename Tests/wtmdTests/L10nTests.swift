import Foundation
import Testing
@testable import wtmd

/// 取词与语言解析：override 说了算，用户偏好次之，测试进程固定中文兜底——
/// 这样对界面文案的断言不随 CI 机器的系统语言漂。
/// override 是全局的，套件内必须串行。
@Suite("L10n：取词与语言解析", .serialized)
struct L10nTests {

    @Test func englishIsTheKeyAndChineseComesFromTheTable() {
        L10n.override = "en"
        defer { L10n.override = nil }
        #expect(t("Open") == "Open")
        #expect(!L10n.isChinese)

        L10n.override = "zh"
        #expect(t("Open") == "打开")
        #expect(L10n.isChinese)

        // 不设 override：测试进程固定中文，断言才稳。
        L10n.override = nil
        #expect(L10n.isChinese)
        #expect(t("Open") == "打开")
    }

    @Test func missingTranslationFallsBackToTheKey() {
        L10n.override = "zh"
        defer { L10n.override = nil }
        #expect(t("A key nobody translated") == "A key nobody translated")
    }

    @Test func templatesFillPlaceholdersInOrder() {
        L10n.override = "en"
        defer { L10n.override = nil }
        #expect(t("Found {} items", 3) == "Found 3 items")
        #expect(t("{} + {}", "a", "b") == "a + b")
        // 占位符比实参多：剩下的原样保留，不炸。
        #expect(t("{} and {}", "x") == "x and {}")
        // 实参比占位符多：多余的丢弃。
        #expect(t("{}", "y", "z") == "y")
    }

    @Test func tableLookupHappensBeforeSubstitution() {
        L10n.override = "zh"
        defer { L10n.override = nil }
        // 中文模板可以自行调整措辞，不受英文语序约束。
        #expect(t("Downloading {}%", 42) == "下载中 42%")
    }

    @Test func contextSplitsTheSameEnglishWord() {
        L10n.override = "zh"
        defer { L10n.override = nil }
        #expect(t("Source", context: "mode") == "思绪")
        #expect(t("Source", context: "theme") == "来源")
        L10n.override = "en"
        #expect(t("Source", context: "mode") == "Source")
    }

    @Test func userPreferenceWinsOverTheTestPin() {
        UserDefaults.standard.removeObject(forKey: "wtmd.language")
        defer { UserDefaults.standard.removeObject(forKey: "wtmd.language") }

        // 解析顺序：override > 用户偏好 > 测试进程钉中文 > 跟随系统。
        #expect(L10n.current == .chinese)

        L10n.userPreference = "en"
        #expect(L10n.current == .english)
        L10n.userPreference = nil
        #expect(L10n.current == .chinese)

        // 不认识的值不挡路，退回跟随（测试进程即中文）。
        L10n.userPreference = "xx"
        #expect(L10n.current == .chinese)
        L10n.userPreference = nil
    }
}
