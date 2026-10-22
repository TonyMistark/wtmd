import Foundation
import Testing
@testable import wtmd

/// 侧栏可见性守卫：状态必须是唯一事实来源。
///
/// ⌃L / ⌥S 两次「改派的快捷键无效」，真正的根因不在快捷键——命令、菜单项、
/// 按键派发全链路都是通的（真机探针实证：菜单项带着键、`performKeyEquivalent`
/// 触发了命令、侧栏真的收放了）。卡住的是 `NavigationSplitView(columnVisibility:)`
/// 的绑定：get 返回 `.automatic`，窗口不够宽时系统自作主张把侧栏折起来，
/// `store.sidebarVisible` 却还是 true。于是按快捷键 true→false→true，
/// 画面一个像素都不动——用户看到的就是「自定义快捷键不支持」。
@MainActor
struct SidebarVisibilityTests {
    @Test("侧栏绑定是显式两态，不用 .automatic")
    func theSidebarBindingIsExplicit() throws {
        // 只看代码：注释里写着「别用 .automatic」是好事，不该因此判红。
        let content = try strippingComments(source("ContentView.swift"))

        #expect(
            !content.contains(".automatic"),
            "columnVisibility 又用 .automatic 了——窗口一窄系统就把侧栏折起来，sidebarVisible 却还是 true，快捷键按了像没按"
        )
        #expect(
            content.contains("store.sidebarVisible ? .all : .detailOnly"),
            "侧栏绑定不再是显式两态（.all / .detailOnly），状态和画面会脱节"
        )
    }

    // MARK: - 从源码里抓事实

    /// 剥掉行注释。守卫判的是代码，注释里提到 `.automatic` 是在解释为什么不能用
    /// 它——MenuPlacementTests 第一版就是被这样的注释绊红的。
    private func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let cut = line.range(of: "//") else { return String(line) }
                return String(line[..<cut.lowerBound])
            }
            .joined(separator: "\n")
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
