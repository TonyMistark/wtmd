import Foundation

// MARK: - 语言

/// 支持的语言。新增语言 = 这里加一个 case + 一份翻译表（见 `Translations`），
/// 调用点一个都不用动。
enum Language: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }

    /// 语言的自称：设置里按它本身展示，不经过翻译。
    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    /// 从 BCP-47 标记（`zh-Hans-CN` 之类）取语言主码。
    static func match(_ bcp47: String) -> Language? {
        Language(rawValue: String(bcp47.prefix(2)))
    }
}

// MARK: - 翻译表

/// 各语言的翻译表。键 = 英文原文（调用点里 `t("…")` 的第一个参数）。
///
/// 新增语言三步：`Language` 加 case；建 `Translations+<lang>.swift` 放表；
/// 在 `tables` 里登记一行。`L10nCoverageTests` 会扫源码断言每张表覆盖
/// 全部键，漏翻当场红。
enum Translations {
    /// 语言 → 翻译表。英语不占位置——键本身就是英文。
    static var tables: [Language: [String: String]] {
        [.chinese: zh]
    }
}

// MARK: - 取词

/// UI copy: the English text *is* the lookup key.
///
/// A translation table instead of `.strings` machinery: SPM has no
/// first-class string-catalog story, and a function call keeps every call
/// site greppable. Code comments stay Chinese — this layer only covers what
/// the reader sees.
///
/// Deliberately **not** main-actor-bound: error strings produced by pure,
/// nonisolated layers (`WorkspaceFiles`, `FindEngine`) are part of the UI
/// too. Everything this layer reads is safe to touch from anywhere:
/// `Locale.preferredLanguages` is a thread-safe class property, `override`
/// is only written from test setup, and the user preference goes through
/// `UserDefaults`, which is itself thread-safe.
enum L10n {
    /// Test hook: pin the language ("en" / "zh") regardless of everything else.
    nonisolated(unsafe) static var override: String?

    /// 用户在设置里选的界面语言（`Language.rawValue`；缺省 nil = 跟随系统）。
    /// 菜单文案随 SwiftUI 命令在启动时构建，所以改完要重启才完整生效。
    static var userPreference: String? {
        get { UserDefaults.standard.string(forKey: "wtmd.language") }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: "wtmd.language")
            } else {
                UserDefaults.standard.removeObject(forKey: "wtmd.language")
            }
        }
    }

    /// A test runner always sees the Chinese copy, so assertions on UI text do
    /// not depend on the CI machine's locale. Resolution order:
    /// test override > user preference > test-process pin > system languages.
    ///
    /// Detection has to cover both runners: the XCTest path exposes
    /// `XCTestCase`, but the swift-testing helper is a separate process that
    /// loads **no** XCTest at all — its path (`swiftpm-testing-helper`) is the
    /// only reliable trace it leaves.
    private static let isTestProcess: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        let path = Bundle.main.bundlePath + "/" + (CommandLine.arguments.first ?? "")
        return path.contains("xctest") || path.contains("swiftpm")
    }()

    /// 当前生效的语言。
    static var current: Language {
        if let override, let pinned = Language.match(override) { return pinned }
        if let raw = userPreference, let chosen = Language(rawValue: raw) { return chosen }
        if isTestProcess { return .chinese }
        for preferred in Locale.preferredLanguages {
            if let language = Language.match(preferred) { return language }
        }
        return .english
    }

    static var isChinese: Bool { current == .chinese }

    /// 查表：命中返回译文；未命中（或当前是英语）返回键本身。
    /// 键是英文原文，所以「翻不出来」的兜底就是英文——不会出现空白。
    static func text(_ key: String) -> String {
        guard current != .english else { return key }
        return Translations.tables[current]?[key] ?? key
    }

    /// 同一个英文词在两处语境里该译得不一样时（比如 Source：编辑模式是
    /// 「思绪」，主题页是「来源」），用 context 拆开：表里的键是
    /// `"<context>|<key>"`，界面显示不变，还是那个英文词。
    static func text(_ key: String, context: String) -> String {
        guard current != .english else { return key }
        return Translations.tables[current]?["\(context)|\(key)"] ?? key
    }

    /// 模板查表 + 顺序填充：`t("Downloading {}%", fraction)`。
    /// 查表发生在替换之前，键是带 `{}` 的模板，各语言可自行调整措辞。
    static func text(_ template: String, _ args: any CustomStringConvertible...) -> String {
        var translation = text(template)
        for argument in args {
            guard let range = translation.range(of: "{}") else { break }
            translation.replaceSubrange(range, with: argument.description)
        }
        return translation
    }

    /// Filename prefix for pasted screenshots.
    static var screenshotPrefix: String { t("screenshot") }
}

/// Unqualified convenience so call sites read like copy, not like plumbing.
func t(_ key: String) -> String {
    L10n.text(key)
}

/// 带占位符的版本：`t("Found {} items", count)`。与单参版天然区分，
/// 不会重载歧义。
func t(_ template: String, _ args: any CustomStringConvertible...) -> String {
    L10n.text(template, args)
}

/// 语境限定的版本：`t("Source", context: "mode")`。
func t(_ key: String, context: String) -> String {
    L10n.text(key, context: context)
}
