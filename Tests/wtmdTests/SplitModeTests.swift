import Foundation
import Testing
import WTMarkdownKit
@testable import wtmd

// MARK: - 对照模式（三种视图模式的规则）

/// `⌘/` 仍然只在思绪 ⇄ 成文之间走；从对照按下去回到**思绪**——
/// 单视图里最想回到的是能打字的那一边。
@MainActor
@Test func toggleFromSplitReturnsToTheSourceView() throws {
    let dir = try makeTemporaryDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)

    store.setMode(.split)
    store.toggleMode()

    #expect(store.mode == .edit)
}

@MainActor
@Test func toggleModeStillFlipsBetweenSourceAndPreview() throws {
    let dir = try makeTemporaryDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)

    #expect(store.mode == .edit)
    store.toggleMode()
    #expect(store.mode == .preview)
    store.toggleMode()
    #expect(store.mode == .edit)
}

@MainActor
@Test func toggleSplitEntersAndLeavesTheSplitView() throws {
    let dir = try makeTemporaryDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)

    store.toggleSplit()
    #expect(store.mode == .split)

    store.toggleSplit()
    #expect(store.mode == .edit)
}

/// 对照模式下点大纲，两侧都要走：左边落到那一行，右边滚到那个标题。
@MainActor
@Test func jumpingInSplitDrivesBothPanes() throws {
    let dir = try makeTemporaryDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)
    store.textDidChange("# 第一章\n\n正文\n\n## 第二节\n\n正文")
    store.setMode(.split)

    let item = try #require(store.outline.last)
    store.jump(to: item)

    #expect(store.editorJump?.slug == item.slug)
    #expect(store.previewJump?.slug == item.slug)
}

/// 单视图里仍然只驱动一侧——分栏不能把原有的跳转语义改宽。
@MainActor
@Test func jumpingInSourceViewOnlyMovesTheEditor() throws {
    let dir = try makeTemporaryDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)
    store.textDidChange("# 第一章\n\n正文")
    store.setMode(.edit)

    let item = try #require(store.outline.first)
    store.jump(to: item)

    #expect(store.editorJump != nil)
    #expect(store.previewJump == nil)
}

/// 对照模式下光标停在源码里，大纲高亮跟光标走（比跟预览滚动更贴近「我在哪一段」）。
@MainActor
@Test func splitModeHighlightsTheOutlineByCaret() throws {
    let dir = try makeTemporaryDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)
    store.textDidChange("# 第一章\n\n正文\n\n## 第二节\n\n正文")
    store.setMode(.split)
    #expect(store.outline.count == 2)

    store.cursorLine = 0
    #expect(store.currentOutlineSlug == store.outline[0].slug)

    store.cursorLine = 4
    #expect(store.currentOutlineSlug == store.outline[1].slug)
}

// MARK: - 窄窗口降级

/// 宽够就分两栏。
@Test func wideContentShowsTwoPanes() {
    #expect(SplitLayout.showsTwoPanes(contentWidth: 900))
    #expect(SplitLayout.showsTwoPanes(contentWidth: SplitLayout.minimumContentWidth))
}

/// 窄了先保写作：两栏各不到 320pt 时源码会折得没法读。
@Test func narrowContentFallsBackToASinglePane() {
    #expect(!SplitLayout.showsTwoPanes(contentWidth: 520))
    #expect(!SplitLayout.showsTwoPanes(contentWidth: 0))
}

// MARK: - 命令注册

/// 菜单与命令面板同源：这条命令必须注册在视图分组，且带 ⌘⇧\ 快捷键。
@Test func splitCommandIsRegisteredInTheViewSection() throws {
    let command = try #require(CommandCatalog.command(for: .toggleSplit))

    #expect(command.section == .view)
    #expect(command.kind.id == "view.toggleSplit")
    #expect(command.shortcut?.key.character == "\\")
    #expect(command.shortcut?.modifiers.contains(.command) == true)
    #expect(command.shortcut?.modifiers.contains(.shift) == true)
    // 面板里能用英文别名搜到
    #expect(CommandSearch.filter("split", in: [command]).count == 1)
}

// MARK: - 辅助

private func makeTemporaryDraftDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-split-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
