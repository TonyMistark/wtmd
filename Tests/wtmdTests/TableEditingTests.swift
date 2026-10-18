import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 表格里回车补行

private let header = "| 姓名 | 年龄 |"

@MainActor
@Test func returnAppendsARowWithTheSameColumnCount() {
    let edit = MarkdownEditing.newline(
        in: header,
        selection: NSRange(location: (header as NSString).length, length: 0)
    )

    #expect(edit?.text == "\n|  |  |")
    #expect(edit?.range == NSRange(location: 11, length: 0))
    // 光标落在第一格：`|` 后隔一个空格
    #expect(edit?.selectionAfter == NSRange(location: 14, length: 0))
}

/// 光标停在行中间也补在行尾：表格是按行读的，不能把一行拆成两行。
@MainActor
@Test func returnMidRowStillAppendsBelowTheLine() {
    let edit = MarkdownEditing.newline(in: header, selection: NSRange(location: 3, length: 0))

    #expect(edit?.text == "\n|  |  |")
    #expect(edit?.range == NSRange(location: 11, length: 0))
}

/// 有选区时交回系统：读者显然是在选东西，不是在填表。
@MainActor
@Test func returnWithSelectionLeavesTheTableAlone() {
    #expect(MarkdownEditing.newline(in: header, selection: NSRange(location: 2, length: 3)) == nil)
}

/// 在表体最后一行回车：接在它后面，不是接在表头后面。
@MainActor
@Test func returnOnABodyRowAppendsAfterThatRow() {
    let text = "| a | b |\n| --- | --- |\n| 1 | 2 |"
    let edit = MarkdownEditing.newline(
        in: text,
        selection: NSRange(location: (text as NSString).length, length: 0)
    )

    #expect(edit?.range == NSRange(location: (text as NSString).length, length: 0))
    #expect(edit?.text == "\n|  |  |")
}

/// 分隔行上回车也补一行（列数按分隔行算），不把 `| --- |` 当内容。
@MainActor
@Test func returnOnTheSeparatorRowKeepsTheWidth() {
    let text = "| a | b | c |\n| --- | --- | --- |"
    let edit = MarkdownEditing.newline(
        in: text,
        selection: NSRange(location: (text as NSString).length, length: 0)
    )

    #expect(edit?.text == "\n|  |  |  |")
}

/// `\|` 是单元格里的竖线，不是列分隔符。
@MainActor
@Test func escapedPipesDoNotAddColumns() {
    let text = #"| a \| b | c |"#
    let edit = MarkdownEditing.newline(
        in: text,
        selection: NSRange(location: (text as NSString).length, length: 0)
    )

    #expect(edit?.text == "\n|  |  |")
}

/// 只有一列也是表格。
@MainActor
@Test func singleColumnTableStillGetsARow() {
    let edit = MarkdownEditing.newline(in: "| 只有一列 |", selection: NSRange(location: 6, length: 0))
    #expect(edit?.text == "\n|  |")
}

/// 围栏里的 `|` 不是表格——那是代码。
@MainActor
@Test func pipesInsideAFenceAreNotATable() {
    let text = "```\n| a | b |"
    #expect(MarkdownEditing.newline(in: text, selection: NSRange(location: 13, length: 0)) == nil)
}

// MARK: - Tab 在单元格之间跳

@MainActor
private func tab(_ text: String, at caret: Int, outdent: Bool = false) -> MarkdownEdit? {
    MarkdownEditing.tab(in: text, selection: NSRange(location: caret, length: 0), outdent: outdent)
}

@MainActor
@Test func tabMovesToTheNextCell() {
    let edit = tab("| ab | cd |", at: 2)

    #expect(edit?.text == "")
    #expect(edit?.selectionAfter == NSRange(location: 7, length: 0))
}

@MainActor
@Test func shiftTabMovesBackACell() {
    let edit = tab("| ab | cd |", at: 7, outdent: true)

    #expect(edit?.selectionAfter == NSRange(location: 2, length: 0))
}

/// 行末的 Tab 落到下一行第一格；分隔行不是落脚点。
@MainActor
@Test func tabFromTheHeaderSkipsTheSeparatorRow() {
    let text = "| a | b |\n| --- | --- |\n| 1 | 2 |"
    let edit = tab(text, at: 6)

    #expect(edit?.selectionAfter == NSRange(location: 26, length: 0))
}

/// 表头 ⇧Tab：退到上一行的最后一格，而不是卡在 `| --- |` 上。
@MainActor
@Test func shiftTabFromTheFirstBodyCellLandsInTheHeader() {
    let text = "| a | b |\n| --- | --- |\n| 1 | 2 |"
    let edit = tab(text, at: 26, outdent: true)

    #expect(edit?.selectionAfter == NSRange(location: 6, length: 0))
}

/// 最后一格再按 Tab：与其停在原地，不如把下一行备好。
@MainActor
@Test func tabPastTheLastCellAddsARow() {
    let edit = tab("| a | b |", at: 7)

    #expect(edit?.text == "\n|  |  |")
    // 新行落在当前行之后：`|` 之后隔一个空格
    #expect(edit?.selectionAfter == NSRange(location: 12, length: 0))
}

/// 表格第一格 ⇧Tab：没有上一格，交回系统（不硬塞空格）。
@MainActor
@Test func shiftTabAtTheVeryFirstCellFallsThrough() {
    #expect(tab("| a | b |", at: 2, outdent: true) == nil)
}

/// 空单元格也要有个好落点：空格中间，而不是贴在竖线上。
@MainActor
@Test func tabLandsInsideAnEmptyCell() {
    let edit = tab("|  |  |\n|  |  |", at: 2)
    #expect(edit?.selectionAfter == NSRange(location: 5, length: 0))
}

/// 不在表格里，Tab 还是缩进（alpha 的行为不变）。
@MainActor
@Test func tabOutsideATableStillIndents() {
    // 缩进是整行改写：行首补两格
    #expect(tab("甲", at: 1)?.text == "  甲")
}

/// 代码块里的 Tab 是缩进，不是单元格导航。
@MainActor
@Test func tabInsideAFenceIndents() {
    let text = "```\n| a | b |"
    let edit = tab(text, at: 13)
    #expect(edit?.text == "  | a | b |")
}

/// 分隔行不是写字的地方：Tab 原地不动，别把 `---` 推成缩进行。
@MainActor
@Test func tabOnTheSeparatorRowIsANoOp() {
    let text = "| a | b |\n| --- | --- |"
    let edit = tab(text, at: 16)
    #expect(edit?.text == "")
    #expect(edit?.selectionAfter == NSRange(location: 16, length: 0))
}

// MARK: - 真实编辑器里的表格按键

@MainActor
@Test func returnInATableAddsARowInTheEditor() {
    let probe = IMEProbeWindow(text: "| a | b |")
    probe.textView.setSelectedRange(NSRange(location: 9, length: 0))

    let handled = probe.coordinator.textView(
        probe.textView,
        doCommandBy: #selector(NSResponder.insertNewline(_:))
    )

    #expect(handled)
    #expect(probe.text == "| a | b |\n|  |  |")
    #expect(probe.textView.selectedRange() == NSRange(location: 12, length: 0))
}

/// 跳格只挪光标，一个字都不改——所以撤销栈里也不该多出东西。
@MainActor
@Test func tabJumpsBetweenCellsInTheEditor() {
    let probe = IMEProbeWindow(text: "| ab | cd |")
    probe.textView.setSelectedRange(NSRange(location: 2, length: 0))

    let handled = probe.coordinator.textView(
        probe.textView,
        doCommandBy: #selector(NSResponder.insertTab(_:))
    )

    #expect(handled)
    #expect(probe.text == "| ab | cd |")
    #expect(probe.textView.selectedRange() == NSRange(location: 7, length: 0))
}
