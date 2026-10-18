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
    harness.coordinator.recenter(animated: false)

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
