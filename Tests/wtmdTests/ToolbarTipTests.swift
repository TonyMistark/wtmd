import AppKit
import Testing
@testable import wtmd

// MARK: - 工具栏提示

/// `.help` 在工具栏项上不落地，toolTip 必须写到工具栏项自己的视图上。
@MainActor
@Test func tipLandsOnTheViewTheToolbarItemOwns() {
    let rig = makeToolbar(with: "思绪 · 只有源码，专心写。点击切到成文")

    rig.anchor.attach()

    #expect(rig.container.toolTip == "思绪 · 只有源码，专心写。点击切到成文")
}

/// 换模式时提示要跟着换，而不用等工具栏重建。
@MainActor
@Test func rewritingTheHintUpdatesTheSameHost() {
    let rig = makeToolbar(with: "旧提示")

    rig.anchor.text = "成文 · 只读成文。点击切到对照"
    rig.anchor.attach()

    #expect(rig.container.toolTip == "成文 · 只读成文。点击切到对照")
}

/// 悬停点常落在按钮内部的子视图上：整棵子树都得带同一句话。
@MainActor
@Test func everyViewInsideTheButtonCarriesTheTip() {
    let rig = makeToolbar(with: "提示")

    rig.anchor.attach()

    #expect(rig.icon.toolTip == "提示")
}

/// 预览面板、快照测试之类的地方会单独摆一个按钮：没有工具栏时安静地什么都不做。
@MainActor
@Test func withoutAToolbarTheAnchorStaysQuiet() {
    let anchor = ToolbarTip.Anchor()
    anchor.text = "提示"

    anchor.attach()

    #expect(anchor.toolTip == nil)
    #expect(anchor.text == "提示")
}

/// 三个图标必须都装得进同一个格子，否则切换时按钮还会变宽变窄。
@Test func everyModeSymbolFitsTheSharedSlot() throws {
    for mode in ViewMode.allCases {
        let image = try #require(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil))
        #expect(image.size.width <= ViewMode.iconSize.width)
        #expect(image.size.height <= ViewMode.iconSize.height)
    }
}

// MARK: - 辅助

/// 一扇带工具栏的真实窗口：工具栏项自己持有一个容器，锚点放在容器里。
///
/// `NSToolbar.delegate` 是弱引用，supplier 必须由测试自己攥着——所以一并返回。
@MainActor
private struct ToolbarRig {
    let window: NSWindow
    let container: NSView
    /// 站在「图标」位置的子视图：悬停点实际落在这里。
    let icon: NSView
    let anchor: ToolbarTip.Anchor
    let supplier: TestToolbarSupplier
}

@MainActor
private func makeToolbar(with text: String) -> ToolbarRig {
    _ = NSApplication.shared

    let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("wtmd.test.mode"))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 18))
    item.view = container

    let icon = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 18))
    container.addSubview(icon)

    let anchor = ToolbarTip.Anchor()
    anchor.text = text
    icon.addSubview(anchor)

    let toolbar = NSToolbar(identifier: "wtmd.test.toolbar")
    let supplier = TestToolbarSupplier(item: item)
    toolbar.delegate = supplier
    toolbar.insertItem(withItemIdentifier: item.itemIdentifier, at: 0)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.toolbar = toolbar
    // 真实窗口里由 NSToolbarItemViewer 把项的视图挂进窗口；测试窗口不显示工具栏，
    // 这里手动补上这条连接——要验的是「认不认得出项自己的视图」，不是工具栏布局。
    window.contentView?.addSubview(container)

    return ToolbarRig(window: window, container: container, icon: icon, anchor: anchor, supplier: supplier)
}

/// `NSToolbar` 只认 delegate 给的项。
private final class TestToolbarSupplier: NSObject, NSToolbarDelegate {
    let item: NSToolbarItem

    init(item: NSToolbarItem) {
        self.item = item
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [item.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [item.itemIdentifier]
    }
}
