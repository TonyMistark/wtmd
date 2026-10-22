import Foundation
import Testing
@testable import wtmd

/// 取词与语言解析：override 说了算，用户偏好次之，没有偏好就是出厂值中文——
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

        // 不设 override：从没选过语言，出厂值就是中文，断言才稳。
        L10n.override = nil
        L10n.userPreference = nil
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

    /// 解析本身是纯函数，各种组合直接喂参数——不去动全局 UserDefaults，
    /// 并行跑的测试套件就不会互相污染。
    @Test func preferenceResolutionKeepsDefaultAndFollowSystemApart() {
        // 从没选过：出厂值中文，不管系统是什么语言。
        #expect(L10n.defaultLanguage == .chinese)
        #expect(L10n.resolve(preference: nil, systemLanguage: .english) == .chinese)
        #expect(L10n.resolve(preference: nil, systemLanguage: .chinese) == .chinese)

        // 显式选了一种语言：说它是什么就是什么。
        #expect(L10n.resolve(preference: "en", systemLanguage: .chinese) == .english)
        #expect(L10n.resolve(preference: "zh", systemLanguage: .english) == .chinese)

        // 显式选「跟随系统」：存的是空串，必须真的跟系统走。
        #expect(L10n.resolve(preference: "", systemLanguage: .english) == .english)
        #expect(L10n.resolve(preference: "", systemLanguage: .chinese) == .chinese)

        // 脏值（旧版本遗留、手改 plist）不当机，退回出厂值中文。
        #expect(L10n.resolve(preference: "xx", systemLanguage: .english) == .chinese)
    }

    @Test func localeDetectionMatchesTheSystemPreference() {
        let expected = Locale.preferredLanguages
            .compactMap { Language.match($0) }
            .first ?? L10n.defaultLanguage
        #expect(L10n.detectedSystemLanguage == expected)
    }

    @Test func userPreferenceWinsOverTheDefault() {
        UserDefaults.standard.removeObject(forKey: "wtmd.language")
        defer { UserDefaults.standard.removeObject(forKey: "wtmd.language") }

        // 解析顺序：override > 用户偏好 > 出厂值中文。
        #expect(L10n.current == .chinese)

        L10n.userPreference = "en"
        #expect(L10n.current == .english)
        L10n.userPreference = nil
        #expect(L10n.current == .chinese)

        // 不认识的值不挡路，退回出厂值。
        L10n.userPreference = "xx"
        #expect(L10n.current == .chinese)
        L10n.userPreference = nil
    }
}
