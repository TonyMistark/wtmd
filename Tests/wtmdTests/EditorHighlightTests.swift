import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 高亮不能动光标

/// 回归「在第一行敲回车，光标瞬移到文档末尾」。
///
/// 根因在 `highlight`：它曾经把整串属性构建到副本上，再用
/// `NSTextStorage.setAttributedString` 发布。那是**替换整个字符区间**，
/// TextKit 会把落在被替换区间里的光标映射到替换区间的末尾——也就是文档末尾。
/// 在高亮重建之后，光标就站在文末了；打字机模式再把它居中，整篇文档滚到底。
///
/// 属性编辑不改变字符长度，光标原地不动。
@MainActor
@Test func highlightPreservesTheCaret() {
    let harness = EditorHarness(text: longDocument())
    let textView = harness.textView
    let length = (harness.text as NSString).length

    for caret in [0, 1, 252, length] {
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        EditorTextView.highlight(textView)
        #expect(textView.selectedRange().location == caret, "光标 \(caret) 被高亮挪到了 \(textView.selectedRange().location)")
    }
}

/// 高亮仍要真的上色——别为了不动光标把这一步做成空操作。
@MainActor
@Test func highlightStillAppliesAttributes() {
    let harness = EditorHarness(text: "# 标题\n\n正文")

    EditorTextView.highlight(harness.textView)

    let font = harness.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect((font?.pointSize ?? 0) > 13.5, "标题行应当比正文更大")
    #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
}

/// 列表 marker 的高亮必须落在**这一行**：`firstMatch` 给的是行内偏移，
/// 少了行首 base 就会去染文档开头——以前只有第一行能染对，其余行全在染别处。
@MainActor
@Test func listMarkersOnLaterLinesAreColouredInPlace() {
    let harness = EditorHarness(text: "- 第一项\n- 第二项\n\n> 引用\n> 第二行引用")

    let storage = harness.textView.textStorage
    let secondMarker = storage?.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor
    #expect(secondMarker == NSColor.systemOrange, "第二行的 marker 没染上")

    // 第一行的正文不该被误染成 marker 色
    let firstContent = storage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
    #expect(firstContent == NSColor.labelColor)

    // 引用行的 `>` 也走同一个 base：位置 18 是第二行引用的 `>`
    let quoteMarker = storage?.attribute(.foregroundColor, at: 18, effectiveRange: nil) as? NSColor
    #expect(quoteMarker != NSColor.labelColor)
}

// MARK: - 用户报的场景

/// 文档第一行敲回车：光标应留在刚插入的换行之后，视口不该整篇滚到底。
@MainActor
@Test func typingOnTheFirstLineKeepsTheCaretAndTheViewport() {
    let harness = EditorHarness(text: longDocument(), typewriter: true)
    harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
    harness.coordinator.recenter()

    harness.type("\n", at: 0)

    #expect(harness.textView.selectedRange().location == 1)
    #expect(harness.text == "\n" + longDocument())
    #expect(harness.clipView.bounds.origin.y < 100, "视口被带到了 \(harness.clipView.bounds.origin.y)")
}

/// 文档中段打字：这是「在已有内容上方编辑」的一般情形，光标同样不能跑去文末。
@MainActor
@Test func typingMidDocumentKeepsTheCaret() {
    let harness = EditorHarness(text: longDocument(), typewriter: true)
    let mid = (harness.text as NSString).range(of: "第 40 行").location
    harness.textView.setSelectedRange(NSRange(location: mid, length: 0))

    harness.type("x", at: mid)

    #expect(harness.textView.selectedRange().location == mid + 1)
}

/// 压暗层要扛得住高亮的属性编辑：开着专注模式打字，段外仍应是压暗的。
///
/// 高亮现在**就地**改属性，而不是整串替换，两者与临时属性的关系不同，这条守的是
/// 它们叠在一起时的用户可见结果。
@MainActor
@Test func typingKeepsTheFocusDimming() throws {
    let harness = EditorHarness(text: "甲\n\n乙\n\n丙", focusMode: true)
    harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
    harness.coordinator.applyFocusFull()

    harness.type("着", at: 1)

    let layoutManager = try #require(harness.textView.layoutManager)
    // 光标所在段（"甲着"）：不压暗
    #expect(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil) == nil)
    // 段外的 "乙"：压暗
    #expect(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: 4, effectiveRange: nil) != nil)
}

// MARK: - 测试用的编辑器栈

/// 真实的编辑器栈（scroll view + 自绘 clip view + NSTextView），不走 SwiftUI 更新。
@MainActor
private final class EditorHarness {
    /// SwiftUI 绑定要有个可变的落脚点。
    private final class Box {
        var text: String
        var cursorLine = 0
        var pendingImage: String?
        init(text: String) { self.text = text }
    }

    private let box: Box
    let coordinator: EditorTextView.Coordinator

    init(text: String, typewriter: Bool = false, focusMode: Bool = false) {
        let box = Box(text: text)
        self.box = box
        let editor = EditorTextView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            cursorLine: Binding(get: { box.cursorLine }, set: { box.cursorLine = $0 }),
            pendingImageInsert: Binding(get: { box.pendingImage }, set: { box.pendingImage = $0 }),
            jump: nil,
            onImagePaste: nil,
            typewriterMode: typewriter,
            focusMode: focusMode
        )
        coordinator = editor.makeCoordinator()
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        coordinator.scrollView.layoutSubtreeIfNeeded()

        coordinator.textView.string = text
        EditorTextView.highlight(coordinator.textView)
        coordinator.rebuildLineStarts()

        // `updateNSView` 里的开关联动：测试不走 SwiftUI 更新，手动对齐
        coordinator.appliedTypewriterMode = typewriter
        coordinator.appliedFocusMode = focusMode
        coordinator.clipView.centersCaret = typewriter
    }

    var text: String { box.text }
    var textView: NSTextView { coordinator.textView }
    var clipView: EditorTextView.TypewriterClipView { coordinator.clipView }

    /// 模拟一次按键：插入文本，再走 AppKit 在编辑后调用的那条 delegate 回调。
    func type(_ snippet: String, at location: Int) {
        let textView = coordinator.textView
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.insertText(snippet, replacementRange: NSRange(location: location, length: 0))
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )
    }
}

/// 够长、能滚起来的文档：短文档里视口根本不会动，问题看不出来。
private func longDocument() -> String {
    (1...80).map { "第 \($0) 行内容" }.joined(separator: "\n")
}

// MARK: - 落笔（即写即现）

/// 落笔只改属性不动字符：标记退成浅灰，内容本身的样式（加粗/斜体）还在，
/// 光标一个都不挪。
@MainActor
@Test func liveModeFadesMarkersAndKeepsContentStyles() {
    let harness = EditorHarness(text: "## 标题\n\n**加粗的话**\n`code`")
    let length = (harness.text as NSString).length
    harness.coordinator.liveDecorations = true

    for caret in [0, 4, length] {
        harness.textView.setSelectedRange(NSRange(location: caret, length: 0))
        EditorTextView.highlight(harness.textView, live: true)
        #expect(harness.textView.selectedRange().location == caret)
    }

    let storage = harness.textView.textStorage
    // `##` 标记（0-2）退成浅灰，标题文字（3 起）保持主题色
    let marker = storage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(marker == NSColor.tertiaryLabelColor, "落笔时 `##` 应当退成浅灰")
    let heading = storage?.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
    #expect(heading == NSColor.controlAccentColor, "标题文字保持主题色")
    // 标题字号还是放大的（渲染感来自这里，不是颜色）
    let headingFont = storage?.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    #expect((headingFont?.pointSize ?? 0) > 13.5)

    // `**`（8-9）退灰，加粗内容（10 起）保持加粗字体
    let boldMarker = storage?.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor
    #expect(boldMarker == NSColor.tertiaryLabelColor)
    let boldFont = storage?.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
    #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true, "加粗内容字体不变")
}

/// 落笔收集块区间：围栏代码块（含两侧围栏行）与引用块，交给布局管理器。
@MainActor
@Test func liveModeCollectsFenceQuoteAndRuleBlocks() {
    let text = "前言\n\n```swift\nlet x = 1\n```\n\n> 引用一\n> 引用二\n\n---\n\n后记"
    let harness = EditorHarness(text: text)
    harness.coordinator.liveDecorations = true
    EditorTextView.highlight(harness.textView, live: true)

    let manager = harness.textView.layoutManager as? LiveDecorationLayoutManager
    let blocks = manager?.blocks ?? []
    let kinds = blocks.map(\.kind)

    #expect(kinds.contains(.code), "围栏代码块要收集成一块")
    #expect(kinds.contains(.quote), "引用块要收集成一块")
    #expect(kinds.contains(.rule), "分隔线要收集")

    // 代码块从开围栏到闭围栏整块（行内偏移手算：前言\n\n=5，围栏 9 行 8 格…直接按内容定位）
    let ns = text as NSString
    let openFence = ns.range(of: "```swift").location
    let closeFence = ns.range(of: "```", options: [], range: NSRange(location: openFence + 1, length: ns.length - openFence - 1)).location
    let code = blocks.first { $0.kind == .code }
    #expect(code?.range.location == openFence, "代码块从开围栏开始")
    #expect(NSMaxRange(code?.range ?? NSRange()) > closeFence, "代码块包住闭围栏")

    // 普通编辑模式不收集：同一个文档回到思绪模式，blocks 清空
    EditorTextView.highlight(harness.textView, live: false)
    #expect((harness.textView.layoutManager as? LiveDecorationLayoutManager)?.blocks.isEmpty == true)
}

/// 引用块的侧条区间要覆盖连续多行：两行引用是一块，不是两块。
@MainActor
@Test func consecutiveQuoteLinesFormOneBlock() {
    let text = "> 一\n> 二\n\n正文"
    let harness = EditorHarness(text: text)
    harness.coordinator.liveDecorations = true
    EditorTextView.highlight(harness.textView, live: true)

    let blocks = (harness.textView.layoutManager as? LiveDecorationLayoutManager)?.blocks ?? []
    let quotes = blocks.filter { $0.kind == .quote }
    #expect(quotes.count == 1, "连续引用行是一块：\(blocks)")
    let ns = text as NSString
    #expect(quotes.first?.range.location == 0)
    // 块到第二行引用的内容末尾（不含结尾换行）
    #expect(NSMaxRange(quotes.first?.range ?? NSRange()) == ns.range(of: "> 一\n> 二").upperBound)
}

