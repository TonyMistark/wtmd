import AppKit
import Testing
@testable import wtmd

// MARK: - 真实编辑器里的按键链路

/// 按键走的是 AppKit 真实入口：`doCommandBy` 返回 true 表示这一下已被我们接管。
@MainActor
private func press(_ probe: IMEProbeWindow, _ key: Selector, at caret: Int) -> Bool {
    probe.textView.setSelectedRange(NSRange(location: caret, length: 0))
    return probe.coordinator.textView(probe.textView, doCommandBy: key)
}

private let returnKey = #selector(NSResponder.insertNewline(_:))
private let tabKey = #selector(NSResponder.insertTab(_:))
private let backtabKey = #selector(NSResponder.insertBacktab(_:))

@MainActor
@Test func returnContinuesTheListInTheRealEditor() {
    let probe = IMEProbeWindow(text: "- 第一项")
    let handled = press(probe, returnKey, at: 5)

    #expect(handled)
    #expect(probe.text == "- 第一项\n- ")
    #expect(probe.textView.selectedRange() == NSRange(location: 8, length: 0))
}

/// 空项回车：marker 清掉，光标留在空行上，可以直接写段落。
@MainActor
@Test func returnOnAnEmptyItemLeavesTheList() {
    let probe = IMEProbeWindow(text: "- 第一项\n- ")
    let handled = press(probe, returnKey, at: 11)

    #expect(handled)
    #expect(probe.text == "- 第一项\n")
    #expect(probe.textView.selectedRange() == NSRange(location: 6, length: 0))
}

/// 代码围栏内按回车：交回系统，文本一个字不动（真实场景由 AppKit 插换行）。
@MainActor
@Test func returnInsideAFenceFallsThrough() {
    let probe = IMEProbeWindow(text: "```\n- 这是代码\n")
    let handled = press(probe, returnKey, at: 10)

    #expect(!handled)
    #expect(probe.text == "```\n- 这是代码\n")
}

/// 普通段落同样交回系统——别把「没有列表」也当成一次编辑。
@MainActor
@Test func returnOnAPlainLineFallsThrough() {
    let probe = IMEProbeWindow(text: "就是一句话")
    #expect(!press(probe, returnKey, at: 5))
    #expect(probe.text == "就是一句话")
}

@MainActor
@Test func tabIndentsTheSelectionThroughTheEditor() {
    let probe = IMEProbeWindow(text: "甲\n乙")
    probe.textView.setSelectedRange(NSRange(location: 0, length: 3))
    let handled = probe.coordinator.textView(probe.textView, doCommandBy: tabKey)

    #expect(handled)
    #expect(probe.text == "  甲\n  乙")
    // 整块保持选中：接着按 Tab 能继续往里推
    #expect(probe.textView.selectedRange() == NSRange(location: 0, length: 7))
}

@MainActor
@Test func shiftTabOutdentsThroughTheEditor() {
    let probe = IMEProbeWindow(text: "  甲")
    let handled = press(probe, backtabKey, at: 3)

    #expect(handled)
    #expect(probe.text == "甲")
}

/// 没东西可反缩进：不接管，也就不会产生一次空编辑。
@MainActor
@Test func shiftTabWithoutIndentFallsThrough() {
    let probe = IMEProbeWindow(text: "甲")
    #expect(!press(probe, backtabKey, at: 1))
}

/// 输入法组合中回车是「确认候选」：这条路径一根手指都不能伸进去。
@MainActor
@Test func returnDuringCompositionIsNotIntercepted() {
    let probe = IMEProbeWindow(text: "- ")
    probe.textView.setSelectedRange(NSRange(location: 2, length: 0))
    probe.textView.setMarkedText(
        "nihao",
        selectedRange: NSRange(location: 5, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )

    let handled = probe.coordinator.textView(probe.textView, doCommandBy: returnKey)

    #expect(!handled)
    #expect(probe.marked, "组合不能被回车打断")
}

/// 撤销是一步：⌘Z 回到回车前，不会退回半截。
@MainActor
@Test func oneUndoRestoresTheLine() {
    let probe = IMEProbeWindow(text: "- 第一项")
    press(probe, returnKey, at: 5)
    #expect(probe.text == "- 第一项\n- ")

    probe.textView.undoManager?.undo()

    #expect(probe.text == "- 第一项")
}

/// 续行之后高亮照常铺上（textDidChange 已经跑过），光标仍在插入点。
@MainActor
@Test func continuationKeepsHighlightAndCaret() {
    let probe = IMEProbeWindow(text: "- 第一项")
    press(probe, returnKey, at: 5)
    // 文本变更通知排在下一拍，高亮随后才重铺
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    let storage = try? #require(probe.textView.textStorage)

    let markerColor = storage?.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor

    #expect(markerColor == NSColor.systemOrange, "新行的 marker 应当被染成列表色")
    #expect(probe.textView.selectedRange().location == 8)
}
