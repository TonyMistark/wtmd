import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 侧栏开关只有一个入口

/// 系统会在工具栏最左侧自动插一个侧栏开关，右侧已有自己的按钮，同一个动作两个
/// 入口。移除挂在**侧栏内容**上才生效：挂在 `NavigationSplitView` 外层（实测）
/// 系统项照旧留在工具栏里。
///
/// 这条测试守的是那个摆放位置——换成外层，下面第一条会红。
@MainActor
@Test func theSystemSidebarToggleIsGoneFromTheToolbar() async {
    let probe = SidebarProbe(removingSystemToggle: true)

    let identifiers = await probe.toolbarIdentifiers()

    #expect(!identifiers.isEmpty, "工具栏没建起来，这条断言就没有意义")
    #expect(!identifiers.contains(where: isSystemSidebarToggle))
}

/// 反向验证：不写 `.toolbar(removing:)` 时系统项确实在。少了这条，上一条可能在
/// 系统哪天不再插这个默认项之后永远空转。
@MainActor
@Test func withoutTheRemovalTheSystemToggleIsStillThere() async {
    let probe = SidebarProbe(removingSystemToggle: false)

    let identifiers = await probe.toolbarIdentifiers()

    #expect(identifiers.contains(where: isSystemSidebarToggle))
}

/// 系统默认项的身份：`com.apple.SwiftUI.navigationSplitView.toggleSidebar`。
/// 按小写子串认，免得跟着 SwiftUI 改前缀。
private func isSystemSidebarToggle(_ identifier: String) -> Bool {
    identifier.lowercased().contains("togglesidebar")
}

// MARK: - 辅助

/// 一扇真实窗口里的 `NavigationSplitView`：工具栏由 SwiftUI 在窗口挂上之后才装配，
/// 所以只能轮询，不能固定等一下就去取。
@MainActor
private final class SidebarProbe {
    private let window: NSWindow

    init(removingSystemToggle: Bool) {
        _ = NSApplication.shared

        let host = NSHostingView(rootView: SidebarProbeView(removingSystemToggle: removingSystemToggle))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
    }

    func toolbarIdentifiers(timeout: TimeInterval = 3) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var identifiers: [String] = []
        while Date() < deadline {
            identifiers = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            if !identifiers.isEmpty { return identifiers }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return identifiers
    }
}

/// 与 `ContentView` 同构的最小装配：侧栏内容 + 详图 + 右侧一个自己的侧栏按钮。
private struct SidebarProbeView: View {
    let removingSystemToggle: Bool

    @State private var visible = true

    var body: some View {
        NavigationSplitView(
            columnVisibility: Binding(
                get: { visible ? .automatic : .detailOnly },
                set: { visible = $0 != .detailOnly }
            )
        ) {
            sidebar
        } detail: {
            Text("detail")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Sidebar") { visible.toggle() }
                    }
                }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if removingSystemToggle {
            Text("sidebar")
                .frame(minWidth: 200)
                .toolbar(removing: .sidebarToggle)
        } else {
            Text("sidebar")
                .frame(minWidth: 200)
        }
    }
}
