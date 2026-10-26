import Foundation
import Testing
@testable import wtmd

/// 工作区标题行的装配守卫：收放走整行双击，关闭走右键菜单加二次确认，
/// ✕ 按钮不得再现——它紧挨收放区又一键让整棵树消失，读起来就是「删除」。
@Suite("Workspace Header Gestures")
struct WorkspaceHeaderTests {
    static let treeViewURL = sourceURL("WorkspaceTreeView.swift")
    static let workspaceURL = sourceURL("Workspace.swift")

    private static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // wtmdTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/wtmd")
            .appendingPathComponent(name)
    }

    /// 守卫扫源码前剥掉 `//` 行注释——否则注释里的字样会绊红禁用断言。
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

    @Test("标题行不再有 ✕ 按钮")
    func noCloseButton() {
        let code = Self.code(of: Self.treeViewURL)
        #expect(!code.contains("xmark.circle.fill"), "标题行的 ✕ 按钮又回来了")
    }

    @Test("整行双击切换：工作区分组与文件夹行都接上了")
    func doubleClickToggles() {
        let code = Self.code(of: Self.treeViewURL)
        #expect(code.contains("Section(isExpanded: $workspace.sectionExpanded)"), "工作区分组没有接上展开状态")
        // 标题行一处、文件夹行一处，都是开关。
        #expect(code.contains("onTapGesture(count: 2) { workspace.sectionExpanded.toggle() }"), "标题行的双击切换不见了")
        #expect(code.contains("workspace.setExpanded(node.url, to: !workspace.isExpanded(node.url))"), "文件夹行的双击切换不见了")
    }

    @Test("关闭工作区要过右键菜单与二次确认")
    func closeAsksForConfirmation() {
        let code = Self.code(of: Self.treeViewURL)
        #expect(code.contains("func confirmCloseWorkspace()"), "没有二次确认入口")
        #expect(code.contains("NSAlert()"), "确认没用弹窗")
        #expect(code.contains("No files will be deleted"), "确认弹窗没把「不删文件」说清楚")
        #expect(code.contains("Close Workspace…"), "右键菜单里没有关闭入口")
    }

    @Test("分组展开状态住在 WorkspaceStore 里，重建树不弹回")
    func storeHoldsSectionState() {
        let code = Self.code(of: Self.workspaceURL)
        #expect(code.contains("@Published var sectionExpanded = true"), "分组展开状态没有住在 WorkspaceStore 里")
    }
}
