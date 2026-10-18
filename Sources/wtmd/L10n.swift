import Foundation

/// UI copy: English first, Chinese fallback on Chinese systems.
///
/// A two-language table instead of `.strings` machinery: wtmd ships exactly
/// two languages, SPM has no first-class string-catalog story, and a function
/// call keeps every call site greppable. Code comments stay Chinese — this
/// layer only covers what the reader sees.
///
/// Deliberately **not** main-actor-bound: error strings produced by pure,
/// nonisolated layers (`WorkspaceFiles`, `FindEngine`) are part of the UI too.
/// The two things `t()` reads are safe to touch from anywhere: the system's
/// preferred languages are a thread-safe class property, and `override` is
/// only ever written from test setup on the main thread.
enum L10n {
    /// Test hook: pin the language ("en" / "zh") regardless of the system.
    nonisolated(unsafe) static var override: String?

    /// A test runner always sees the Chinese copy, so assertions on UI text do
    /// not depend on the CI machine's locale. `override` wins when set — that
    /// is how the English branch gets covered.
    private static let isTestProcess: Bool = {
        NSClassFromString("XCTestCase") != nil
            || Bundle.main.bundleURL.pathExtension == "xctest"
    }()

    static var isChinese: Bool {
        if let override { return override.hasPrefix("zh") }
        if isTestProcess { return true }
        return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }

    /// Picks the copy for the current language: `t("Open", "打开")`.
    static func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }

    /// Filename prefix for pasted screenshots.
    static var screenshotPrefix: String { t("screenshot", "截图") }
}

/// Unqualified convenience so call sites read like copy, not like plumbing.
func t(_ en: String, _ zh: String) -> String {
    L10n.t(en, zh)
}
