import Foundation
import Testing
@testable import wtmd

/// 窗口环境装配守卫。
///
/// `ContentView` 的依赖全靠 `@EnvironmentObject`——而缺一个就是 **SIGTRAP 级别的
/// 硬崩**（SwiftUI 对取不到的 EnvironmentObject 直接 `assertionFailure`），
/// #181 那次：`installer` 只注进了 Settings 场景，`WindowRoot` 漏了它，
/// 更新徽标一出现（`status == .available` 才会读 `installer.phase`）应用就崩。
/// 崩得还很刁：装新版时（已是最新）不崩，等下一个版本发布才崩。
///
/// 这几条把「声明 ⇒ 注入」钉死：以后给 `ContentView` 加任何依赖，忘了在
/// `WindowRoot` 里注入，测试当场红，不用等下一次线上 SIGTRAP。
@MainActor
struct WindowEnvironmentTests {
    @Test("ContentView 声明的每个 EnvironmentObject，WindowRoot 都注入了")
    func windowRootInjectsEverythingContentViewReads() throws {
        let content = try source("ContentView.swift")
        let root = try source("WindowRoot.swift")

        let declared = try declarations(in: content)
        let injected = try injections(in: root)

        let missing = declared.subtracting(injected).sorted()
        #expect(
            missing.isEmpty,
            "ContentView 依赖 \(missing)，但 WindowRoot 没注入——这些视图一渲染就是 SIGTRAP（#181）"
        )
    }

    @Test("WindowRoot 注入的都是 ContentView 真正读的（没有死注入）")
    func windowRootDoesNotInjectAnythingDead() throws {
        let content = try source("ContentView.swift")
        let root = try source("WindowRoot.swift")

        let declared = try declarations(in: content)
        let injected = try injections(in: root)

        let dead = injected.subtracting(declared).sorted()
        #expect(
            dead.isEmpty,
            "WindowRoot 注入了 \(dead)，但 ContentView 不读它们——要么是漏删的尸体，要么注错了宿主"
        )
    }

    // MARK: - 从源码里抓事实

    /// `@EnvironmentObject var xxx: SomeType` 里的 `xxx`。
    private func declarations(in text: String) throws -> Set<String> {
        try matches(in: text, pattern: "@EnvironmentObject\\s+var\\s+(\\w+)")
    }

    /// `.environmentObject(...)` 参数里路径的**最后一段**——`model.shared.installer`
    /// 记作 `installer`，正好对上声明处的变量名。
    private func injections(in text: String) throws -> Set<String> {
        let names = try matches(in: text, pattern: "\\.environmentObject\\(([^)]+)\\)")
        return Set(names.map { $0.split(separator: ".").last.map(String.init) ?? $0 })
    }

    private func matches(in text: String, pattern: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/wtmd/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
