import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 预览推着源码滚（不改光标）

/// 联动里最容易被写坏的一条：预览滚到哪，源码**只滚**，光标不许动。
/// 光标一被搬走，读者回到左边继续写时就得重新找地方——比不联动还烦。
@MainActor
private final class RevealProbe {
    let coordinator: EditorTextView.Coordinator
    let window: NSWindow

    init(text: String) {
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
        coordinator.textView.selectedRange = NSRange(location: 0, length: 0)

        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = coordinator.scrollView
        window.layoutIfNeeded()
    }

    var selection: NSRange { coordinator.textView.selectedRange() }
    var scrollY: CGFloat { coordinator.clipView.bounds.origin.y }
}

private let revealDocument = (0..<200)
    .map { "第 \($0) 行，用来撑出足够长的可滚动篇幅。" }
    .joined(separator: "\n")

@Test @MainActor func revealingALineScrollsThereWithoutMovingTheCaret() {
    let probe = RevealProbe(text: revealDocument)
    let caret = NSRange(location: 12, length: 0)
    probe.coordinator.textView.setSelectedRange(caret)

    probe.coordinator.revealLine(150)

    #expect(probe.scrollY > 100)
    #expect(probe.selection == caret)
}

@Test @MainActor func revealingALaterLineScrollsFurtherDown() {
    let probe = RevealProbe(text: revealDocument)

    probe.coordinator.revealLine(60)
    let shallow = probe.scrollY
    probe.coordinator.revealLine(180)
    let deep = probe.scrollY

    #expect(deep > shallow)
    #expect(shallow > 0)
}

/// 越界的行号（文档刚被删短、换算出来的行落在末尾之外）不能崩，也不能乱滚。
@Test @MainActor func revealingAnImpossibleLineIsANoOp() {
    let probe = RevealProbe(text: revealDocument)
    probe.coordinator.revealLine(80)
    let before = probe.scrollY

    probe.coordinator.revealLine(99_999)
    #expect(probe.scrollY == before)
    probe.coordinator.revealLine(-1)
    #expect(probe.scrollY == before)
}

/// 一行就够短文档：滚不动，也不该报错或者把视口弹来弹去。
@Test @MainActor func revealingInsideAShortDocumentStaysPut() {
    let probe = RevealProbe(text: "只有一行。")
    probe.coordinator.revealLine(0)
    #expect(probe.scrollY == 0)
    #expect(probe.selection == NSRange(location: 0, length: 0))
}
