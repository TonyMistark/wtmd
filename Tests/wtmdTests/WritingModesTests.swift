import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 当前段落（纯函数）

/// 光标在段内：只认这一段。
@Test func focusParagraphCoversOnlyTheCaretParagraph() {
    let text = NSString(string: "第一段\n\n第二段\n\n第三段")

    #expect(text.substring(with: FocusParagraph.range(in: text, caret: 0)) == "第一段")
    #expect(text.substring(with: FocusParagraph.range(in: text, caret: 6)) == "第二段")
    #expect(text.substring(with: FocusParagraph.range(in: text, caret: 12)) == "第三段")
}

/// 连续几行（中间没有空行）在 Markdown 里是同一段。
@Test func focusParagraphTreatsConsecutiveLinesAsOneParagraph() {
    let text = NSString(string: "第一行\n第二行\n\n下一段")

    // 与光标落在这两行的哪一行无关：整段都是它
    #expect(text.substring(with: FocusParagraph.range(in: text, caret: 0)) == "第一行\n第二行")
    #expect(text.substring(with: FocusParagraph.range(in: text, caret: 5)) == "第一行\n第二行")
    // 空行把下面那段隔开了
    #expect(FocusParagraph.range(in: text, caret: 0) == NSRange(location: 0, length: 7))
}

/// 光标落在空行上时归入**前一段**。
///
/// 不然敲两个回车准备写新段落的那一瞬间，整篇会突然全暗 —— 而那正是写作者
/// 盯着看的地方。
@Test func focusParagraphFoldsBlankLinesIntoThePrecedingParagraph() {
    let text = NSString(string: "甲\n\n乙")

    // 索引 2 是分隔两段的那一行空行
    #expect(FocusParagraph.range(in: text, caret: 2) == NSRange(location: 0, length: 3))
}

/// 光标停在文末：属于最后一段，而不是那个凭空多出来的空行。
@Test func focusParagraphPutsACaretAtTheEndInTheLastParagraph() {
    let text = NSString(string: "甲\n\n乙")

    #expect(FocusParagraph.range(in: text, caret: 4) == NSRange(location: 3, length: 1))
}

/// 文档开头就是空行：没有段落可归属，就点亮这片空行本身。
@Test func focusParagraphFallsBackToTheBlankRun() {
    let text = NSString(string: "\n\n")

    #expect(FocusParagraph.range(in: text, caret: 1) == NSRange(location: 0, length: 2))
}

@Test func focusParagraphHandlesAnEmptyDocument() {
    #expect(FocusParagraph.range(in: NSString(string: ""), caret: 0) == NSRange(location: 0, length: 0))
}

// MARK: - 居中偏移（纯函数）

@Test func typewriterCentersACaretLine() {
    let offset = TypewriterGeometry.centeredOffset(caretMidY: 1000, viewportHeight: 800, contentHeight: 5000)

    #expect(offset == 600)
}

@Test func typewriterStopsAtTheEdges() {
    // 第一行：贴着顶，不滚
    #expect(TypewriterGeometry.centeredOffset(caretMidY: 100, viewportHeight: 800, contentHeight: 5000) == 0)
    // 末尾几行：受可滚动高度限制（内容 5000 - 视口 800）
    #expect(TypewriterGeometry.centeredOffset(caretMidY: 4950, viewportHeight: 800, contentHeight: 5000) == 4200)
    // 内容比视口还短：怎么都不滚
    #expect(TypewriterGeometry.centeredOffset(caretMidY: 100, viewportHeight: 800, contentHeight: 300) == 0)
    // 还没布局出高度：不滚
    #expect(TypewriterGeometry.centeredOffset(caretMidY: 100, viewportHeight: 0, contentHeight: 5000) == 0)
}

/// 打字机模式下滚动范围要比内容多出半屏，文档末尾那行才停得进屏幕中间。
@Test func typewriterClipViewScrollsHalfAScreenPastTheEnd() {
    let clip = EditorTextView.TypewriterClipView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
    clip.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 5000))
    let beyond = NSRect(x: 0, y: 9999, width: 400, height: 800)

    clip.centersCaret = false
    #expect(clip.constrainBoundsRect(beyond).origin.y == 4200)

    clip.centersCaret = true
    #expect(clip.constrainBoundsRect(beyond).origin.y == 4600)
}

// MARK: - 开关持久化

@MainActor
@Test func writingSettingsRoundTripThroughDefaults() throws {
    let name = "wtmd-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    let first = WritingSettings(defaults: defaults)
    // 新用户默认两个模式都关着：界面先安静下来，模式由用户自己请进来
    #expect(!first.typewriter)
    #expect(!first.focusMode)

    first.typewriter = true
    first.focusMode = true

    let restored = WritingSettings(defaults: defaults)
    #expect(restored.typewriter)
    #expect(restored.focusMode)

    restored.focusMode = false
    #expect(!WritingSettings(defaults: defaults).focusMode)
}

// MARK: - 专注模式（真实 NSTextView）

/// 专注模式挂在 layout manager 的临时属性上：段外压暗、段内不动、文本本身不变。
@MainActor
@Test func focusModeDimsEverythingOutsideTheCaretParagraph() throws {
    let coordinator = makeEditor(focusMode: true).makeCoordinator()
    coordinator.textView.string = "甲\n\n乙"
    coordinator.textView.setSelectedRange(NSRange(location: 0, length: 0))
    coordinator.applyFocusFull()

    let layoutManager = try #require(coordinator.textView.layoutManager)
    #expect(dimmed(layoutManager, at: 0) == nil)
    #expect(dimmed(layoutManager, at: 3) != nil)
    #expect(coordinator.textView.string == "甲\n\n乙")
}

/// 光标移到别段：新段点亮、旧段压暗。按键之间走的是这条增量路径，
/// 全量重铺（O(文档长度)）做不起。
@MainActor
@Test func focusModeFollowsTheCaretIncrementally() throws {
    let coordinator = makeEditor(focusMode: true).makeCoordinator()
    coordinator.textView.string = "甲\n\n乙"
    coordinator.textView.setSelectedRange(NSRange(location: 0, length: 0))
    coordinator.applyFocusFull()

    coordinator.textView.setSelectedRange(NSRange(location: 3, length: 0))
    coordinator.applyFocusIncremental()

    let layoutManager = try #require(coordinator.textView.layoutManager)
    #expect(dimmed(layoutManager, at: 3) == nil)
    #expect(dimmed(layoutManager, at: 0) != nil)
}

/// 关掉开关：一个字都不该被压暗。
@MainActor
@Test func focusModeOffLeavesEveryRangeAlone() throws {
    let coordinator = makeEditor(focusMode: false).makeCoordinator()
    coordinator.textView.string = "甲\n\n乙"
    coordinator.textView.setSelectedRange(NSRange(location: 0, length: 0))
    coordinator.applyFocusFull()

    let layoutManager = try #require(coordinator.textView.layoutManager)
    #expect(dimmed(layoutManager, at: 0) == nil)
    #expect(dimmed(layoutManager, at: 3) == nil)
}

// MARK: - 辅助

/// 某个位置是否被压暗（临时前景色存在即为压暗）。
private func dimmed(_ layoutManager: NSLayoutManager, at index: Int) -> Any? {
    layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil)
}

@MainActor
private func makeEditor(focusMode: Bool = false, typewriterMode: Bool = false) -> EditorTextView {
    EditorTextView(
        text: .constant(""),
        cursorLine: .constant(0),
        pendingImageInsert: .constant(nil),
        jump: nil,
        onImagePaste: nil,
        typewriterMode: typewriterMode,
        focusMode: focusMode
    )
}
