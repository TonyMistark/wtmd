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
        #expect(code.contains("sidebarSectionHeader(t(\"Workspaces\")"), "侧栏缺「工作区」分类头")
    }

    @Test("工作区与大纲的分类头都带展开/收起开关")
    func sectionHeadersAreCollapsible() {
        let code = Self.code(of: Self.contentViewURL)
        // 分类头必须是整行可点的 Button——离屏渲染实测过，HStack 挂手势的
        // 版本整行都收不到点击，只有真 Button（plain / 自定义按压样式）吃命中。
        #expect(code.contains("sidebarSectionHeader(t(\"Workspaces\")"), "侧栏缺「工作区」分类头")
        #expect(code.contains("sidebarSectionHeader(t(\"Outline\")"), "侧栏缺「大纲」分类头")
        #expect(code.contains("Button(action: action)"), "分类头不是按钮，整行点不动")
        #expect(code.contains(".buttonStyle(SidebarRowButtonStyle())"), "分类头缺按压样式")
        #expect(code.contains("if workspace.sectionExpanded {"), "「工作区」内容没有接上收放状态")
        #expect(code.contains("if outlineExpanded {"), "「大纲」内容没有接上收放状态")
        #expect(code.contains("chevron.right"), "分类头缺展开箭头")
        #expect(code.contains("rotationEffect(.degrees(isExpanded ? 90 : 0))"), "箭头没有随开合旋转")
    }

    @Test("macOS 26 侧栏顶边用软边缘，不画硬横线")
    func sidebarTopEdgeIsSoft() {
        let code = Self.code(of: Self.contentViewURL)
        #expect(code.contains("SidebarTopEdgeEffect"), "侧栏没接滚动边缘修正")
        #expect(code.contains("scrollEdgeEffectStyle(.soft, for: .top)"), "顶边不是软边缘——硬边缘的横线会压在红绿灯那一行")
        #expect(code.contains("#available(macOS 26.0, *)"), "旧系统上要原样返回")
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
