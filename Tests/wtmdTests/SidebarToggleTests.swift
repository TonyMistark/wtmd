import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 侧栏开关只有一个入口

/// 两条装配测试各自开一扇窗口。窗口、工具栏都由 AppKit 在主线程装配，并行跑会
/// 互相踩（CI 上 macOS 26 就撞过：一边还在等工具栏，另一边已经断言完了）。
@MainActor
@Suite(.serialized)
struct SidebarToggleTests {
    /// 系统会在工具栏最左侧自动插一个侧栏开关，右侧已有自己的按钮，同一个动作两个
    /// 入口。移除挂在**侧栏内容**上才生效：挂在 `NavigationSplitView` 外层（实测）
    /// 系统项照旧留在工具栏里。
    @Test func theSystemSidebarToggleIsGoneFromTheToolbar() async {
        let probe = SidebarProbe(removingSystemToggle: true)

        let identifiers = await probe.toolbarIdentifiers()

        #expect(!identifiers.isEmpty, "工具栏没建起来，这条断言就没有意义")
        #expect(!identifiers.contains(where: isSystemSidebarToggle), "工具栏里还有：\(identifiers)")
    }

    /// 反向验证：不写 `.toolbar(removing:)` 时系统项确实在。少了这条，上一条可能在
    /// 系统哪天不再插这个默认项之后永远空转。
    @Test func withoutTheRemovalTheSystemToggleIsStillThere() async {
        let probe = SidebarProbe(removingSystemToggle: false)

        let identifiers = await probe.toolbarIdentifiers()

        #expect(!identifiers.isEmpty, "工具栏没建起来，这条断言就没有意义")
        #expect(identifiers.contains(where: isSystemSidebarToggle), "工具栏里只有：\(identifiers)")
    }
}

/// 上面的测试验的是「这么摆 SwiftUI 会不会撤掉系统项」，验不到「我们真的这么摆」。
/// 少了这条，`ContentView` 里的 modifier 被谁顺手删了也没人喊。
@Test func theRemovalSitsInsideTheSidebarContent() throws {
    let source = try String(contentsOf: contentViewSourceURL, encoding: .utf8)

    let body = try #require(sidebarBody(in: source), "ContentView 里找不到 sidebar 内容")
    #expect(body.contains(".toolbar(removing: .sidebarToggle)"))
}

// MARK: - 辅助

/// 系统默认项的身份：`com.apple.SwiftUI.navigationSplitView.toggleSidebar`。
/// 按小写子串认，免得跟着 SwiftUI 改前缀。
private func isSystemSidebarToggle(_ identifier: String) -> Bool {
    identifier.lowercased().contains("togglesidebar")
}

private var contentViewSourceURL: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // wtmdTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 仓库根
        .appendingPathComponent("Sources/wtmd/ContentView.swift")
}

/// 花括号配平，取出 `private var sidebar: some View` 的整个函数体。
private func sidebarBody(in source: String) -> String? {
    guard let start = source.range(of: "private var sidebar: some View {") else { return nil }
    var depth = 0
    var index = start.upperBound
    var body = ""
    while index < source.endIndex {
        let character = source[index]
        body.append(character)
        if character == "{" {
            depth += 1
        } else if character == "}" {
            if depth == 0 { return body }
            depth -= 1
        }
        index = source.index(after: index)
    }
    return nil
}

/// 一扇真实窗口里的 `NavigationSplitView`：工具栏由 SwiftUI 在窗口挂上之后才装配，
/// 所以只能轮询，不能固定等一下就去取。CI 上机器忙，给足十秒。
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
        window.makeKeyAndOrderFront(nil)
    }

    func toolbarIdentifiers(timeout: TimeInterval = 10) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let items = window.toolbar?.items, !items.isEmpty {
                return items.map(\.itemIdentifier.rawValue)
            }
            // 催一次布局：窗口不一定有屏幕可显示，但工具栏该装还得装
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return []
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
