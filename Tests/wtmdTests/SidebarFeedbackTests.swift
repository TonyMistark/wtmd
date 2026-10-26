import Foundation
import Testing
@testable import wtmd

/// Sidebar assembly guards: the "Workspaces" category header and press
/// feedback on every clickable row. Clicks used to be dead-flat — no visual
/// response between mouse-down and mouse-up — which reads as "nothing
/// happened" on a slow open. These scans pin the wiring in place.
@Suite("Sidebar Feedback Guards")
struct SidebarFeedbackTests {
    static let contentViewURL = sourceURL("ContentView.swift")
    static let treeViewURL = sourceURL("WorkspaceTreeView.swift")
    static let feedbackURL = sourceURL("SidebarFeedback.swift")

    private static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // wtmdTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/wtmd")
            .appendingPathComponent(name)
    }

    /// Strip `//` line comments before scanning — words in comments must not
    /// trip the assertions.
    private static func code(of url: URL) -> String {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return raw
            .components(separatedBy: "\n")
            .map { line in
                if let range = line.range(of: "//") { return String(line[..<range.lowerBound]) }
                return line
            }
            .joined(separator: "\n")
    }

    @Test("工作区树包在「Workspaces」分类头里")
    func workspacesCategoryHeader() {
        let code = Self.code(of: Self.contentViewURL)
        #expect(code.contains("Section(t(\"Workspaces\"))"), "侧栏缺「工作区」分类头")
    }

    @Test("树行、标题行都接了按压反馈")
    func treeRowsHavePressFeedback() {
        let code = Self.code(of: Self.treeViewURL)
        // Header, folder row, file row — three call sites.
        let count = code.components(separatedBy: ".pressFeedback()").count - 1
        #expect(count >= 3, "按压反馈的接线点少了（应有标题行、文件夹行、文件行三处），当前 \(count)")
    }

    @Test("Button 行用按压样式，不再用 plain")
    func buttonRowsUsePressStyle() {
        let code = Self.code(of: Self.contentViewURL)
        let count = code.components(separatedBy: "SidebarRowButtonStyle()").count - 1
        #expect(count >= 2, "大纲行与最近文件行都应挂按压样式，当前 \(count)")
    }

    @Test("按压反馈组件存在且两套都齐")
    func feedbackComponentExists() {
        let code = Self.code(of: Self.feedbackURL)
        #expect(code.contains("struct SidebarRowButtonStyle: ButtonStyle"), "Button 行的按压样式缺失")
        #expect(code.contains("onPressingChanged"), "tap 行的按压信号缺失")
        #expect(code.contains("isPressed ? 0.1 : 0"), "按压高亮的透明度分档缺失")
    }
}
