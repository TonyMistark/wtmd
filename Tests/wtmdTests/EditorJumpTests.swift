import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 行 + 列跳转

/// 大纲只要求「跳到第几行」，工作区搜索还要求「第几行第几个字」。
/// 两者共用同一个 `JumpRequest`，落点由编辑器算。
@MainActor
private final class JumpProbe {
    let coordinator: EditorTextView.Coordinator
    let window: NSWindow
    let originalText: String

    init(text: String) {
        originalText = text
        var value = text
        let bindable = Binding(get: { value }, set: { value = $0 })
        let view = EditorTextView(
            text: bindable,
            cursorLine: .constant(0),
            pendingImageInsert: .constant(nil)
        )
        coordinator = view.makeCoordinator()
        coordinator.textView.string = text
        coordinator.rebuildLineStarts()

        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = coordinator.scrollView
        window.layoutIfNeeded()
        window.makeFirstResponder(coordinator.textView)
    }

    var textView: NSTextView { coordinator.textView }

    func selectionText() -> String {
        let range = textView.selectedRange()
        return (textView.string as NSString).substring(with: range)
    }
}

@Test @MainActor func jumpingToALineAndColumnSelectsTheHit() {
    let probe = JumpProbe(text: "第一行\n第二行 alpha 后面\n第三行")
    let expected = ("第一行\n第二行 alpha 后面\n第三行" as NSString).range(of: "alpha")
    #expect(expected.location == 8)

    probe.coordinator.jump(toLine: 1, column: 4, length: 5)

    #expect(probe.textView.selectedRange() == expected)
    #expect(probe.selectionText() == "alpha")
    #expect(probe.textView.string == probe.originalText)
}

/// 大纲跳转还是老样子：行首、只放光标。
@Test @MainActor func jumpingToALineOnlyPutsTheCaretAtItsStart() {
    let probe = JumpProbe(text: "第一行\n第二行\n第三行")

    probe.coordinator.jump(toLine: 2)

    #expect(probe.textView.selectedRange() == NSRange(location: 8, length: 0))
}

/// 命中的列超出那一行（文件在搜索之后被改短了）时夹住，不要落到下一行去。
@Test @MainActor func anOutOfRangeColumnIsClampedToTheLineEnd() {
    let probe = JumpProbe(text: "短行\n第二行")

    probe.coordinator.jump(toLine: 0, column: 99, length: 4)

    #expect(probe.textView.selectedRange() == NSRange(location: 2, length: 0))
}

/// 越界的行号直接不理，不能让编辑器把光标放到乱七八糟的地方。
@Test @MainActor func aLineNumberPastTheEndIsIgnored() {
    let probe = JumpProbe(text: "只有一行")
    probe.textView.setSelectedRange(NSRange(location: 0, length: 0))

    probe.coordinator.jump(toLine: 42, column: 0, length: 1)

    #expect(probe.textView.selectedRange() == NSRange(location: 0, length: 0))
}
