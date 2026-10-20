import AppKit
import Testing
@testable import wtmd

/// 预览的右键菜单由 WebKit 自己弹，它不走 `NSView.menu(for:)`——覆写那个方法拦不住
///（真机实测：菜单照弹，覆写一次都没被调用）。能挂钩的只有「菜单开始跟踪」。
/// 这里守的是「哪一份该撤」这条判据：只撤空白处那份只剩「重新载入」的。
@Suite("预览右键菜单")
@MainActor
struct PreviewContextMenuTests {
    @Test("空白处那份：只剩一项「重新载入」，认得出来")
    func bareReloadMenuIsRecognised() {
        let menu = menu([webKitItem("Reload"), .separator()])
        #expect(PreviewContextMenu.isBareReloadMenu(menu))
    }

    @Test("判据是 selector 不是标题：中文标题一样撤")
    func titleDoesNotMatter() {
        let menu = menu([webKitItem("重新载入"), .separator()])
        #expect(PreviewContextMenu.isBareReloadMenu(menu))
    }

    @Test("选中文字那份不碰：项目多得很")
    func richMenuIsLeftAlone() {
        let menu = menu([
            webKitItem("Look Up “hello”"),
            .separator(),
            webKitItem("Copy"),
        ])
        #expect(!PreviewContextMenu.isBareReloadMenu(menu))
    }

    @Test("带子菜单的那一项不算「只剩一项」")
    func itemWithSubmenuIsLeftAlone() {
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Start Speaking", action: nil, keyEquivalent: ""))
        let menu = menu([webKitItem("Speech", submenu: submenu), .separator()])
        #expect(!PreviewContextMenu.isBareReloadMenu(menu))
    }

    @Test("普通菜单（拷贝 / 全选）不碰")
    func ordinaryMenuIsLeftAlone() {
        let menu = menu([
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        #expect(!PreviewContextMenu.isBareReloadMenu(menu))
    }

    @Test("空菜单不碰——那不是 WebKit 的东西")
    func emptyMenuIsLeftAlone() {
        #expect(!PreviewContextMenu.isBareReloadMenu(menu([])))
        #expect(!PreviewContextMenu.isBareReloadMenu(menu([.separator()])))
    }

    @Test("装两次也只挂一个观察者")
    func installIsIdempotent() {
        PreviewContextMenu.install()
        PreviewContextMenu.install()
        #expect(PreviewContextMenu.isInstalled)
    }

    // MARK: 辅助

    private func webKitItem(_ title: String, submenu: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: NSSelectorFromString("forwardContextMenuAction:"),
            keyEquivalent: ""
        )
        item.submenu = submenu
        return item
    }

    private func menu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        return menu
    }
}

/// 判据写得再准，预览没装它也白搭。
@Suite("预览右键菜单装配")
struct PreviewContextMenuAssemblyTests {
    @Test func thePreviewInstallsTheGuard() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/wtmd/PreviewView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("PreviewContextMenu.install()"), "预览没有装右键菜单守卫")
    }
}
