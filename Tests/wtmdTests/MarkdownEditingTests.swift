import Foundation
import Testing
@testable import wtmd

// MARK: - 回车续行

/// 光标放在 `text` 末尾，模拟在行尾按回车。
@MainActor
private func newlineAtEnd(of text: String) -> MarkdownEdit? {
    let length = (text as NSString).length
    return MarkdownEditing.newline(in: text, selection: NSRange(location: length, length: 0))
}

/// 光标放在文档末尾的「上一行行尾」（文本以换行结尾时，末尾其实是空行）。
@MainActor
private func newlineAtLastContentLine(of text: String) -> MarkdownEdit? {
    let ns = text as NSString
    var caret = ns.length
    while caret > 0, ns.character(at: caret - 1) == 0x0A { caret -= 1 }
    return MarkdownEditing.newline(in: text, selection: NSRange(location: caret, length: 0))
}

@MainActor
@Test func unorderedListContinuesWithTheSameMarker() {
    #expect(newlineAtEnd(of: "- 第一项")?.text == "\n- ")
    #expect(newlineAtEnd(of: "* 第一项")?.text == "\n* ")
    #expect(newlineAtEnd(of: "+ 第一项")?.text == "\n+ ")
}

/// marker 后写了几格空白，续行就接几格：对齐是作者自己定的。
@MainActor
@Test func unorderedListKeepsTheGapAfterTheMarker() {
    #expect(newlineAtEnd(of: "-   宽松对齐")?.text == "\n-   ")
}

/// 嵌套列表的缩进原样带过去，否则回车就把这一项从父项底下拎了出来。
@MainActor
@Test func nestedListKeepsItsIndent() {
    #expect(newlineAtEnd(of: "  - 子项")?.text == "\n  - ")
    #expect(newlineAtEnd(of: "\t- 制表符缩进")?.text == "\n\t- ")
}

@MainActor
@Test func orderedListAdvancesTheNumber() {
    #expect(newlineAtEnd(of: "1. 第一项")?.text == "\n2. ")
    #expect(newlineAtEnd(of: "9) 第九项")?.text == "\n10) ")
    #expect(newlineAtEnd(of: "  12. 第十二项")?.text == "\n  13. ")
}

/// 任务的续行回到未勾选：新的一项还没做完。
@MainActor
@Test func taskListContinuesUnchecked() {
    #expect(newlineAtEnd(of: "- [ ] 待办")?.text == "\n- [ ] ")
    #expect(newlineAtEnd(of: "- [x] 已完成")?.text == "\n- [ ] ")
    #expect(newlineAtEnd(of: "* [X] 大写勾选")?.text == "\n* [ ] ")
}

@MainActor
@Test func quoteContinuesWithTheSameDepth() {
    #expect(newlineAtEnd(of: "> 引用")?.text == "\n> ")
    #expect(newlineAtEnd(of: "> > 两层")?.text == "\n> > ")
}

/// 引用里套列表：两层前缀都要接上。
@MainActor
@Test func listInsideAQuoteKeepsBothPrefixes() {
    #expect(newlineAtEnd(of: "> - 引用里的项")?.text == "\n> - ")
}

// MARK: - 空项退出

/// 空项的 marker 被清掉，不再多出一行空列表——这是「写完列表接着写段落」的路。
@MainActor
@Test func emptyItemsDropTheirMarker() {
    let bullet = MarkdownEditing.newline(in: "- ", selection: NSRange(location: 2, length: 0))
    #expect(bullet?.text == "")
    #expect(bullet?.range == NSRange(location: 0, length: 2))

    let ordered = MarkdownEditing.newline(in: "1. ", selection: NSRange(location: 3, length: 0))
    #expect(ordered?.text == "")

    let quote = MarkdownEditing.newline(in: "> ", selection: NSRange(location: 2, length: 0))
    #expect(quote?.text == "")

    let task = MarkdownEditing.newline(in: "- [ ] ", selection: NSRange(location: 6, length: 0))
    #expect(task?.text == "")
}

/// 缩进空项退出后仍属于父项：缩进留着。
@MainActor
@Test func emptyNestedItemKeepsItsIndent() {
    let edit = MarkdownEditing.newline(in: "  - ", selection: NSRange(location: 4, length: 0))
    #expect(edit?.text == "  ")
}

// MARK: - 不续的地方

/// 普通段落、行首、纯空白行都交回系统。
@MainActor
@Test func plainLinesGetTheDefaultNewline() {
    #expect(newlineAtEnd(of: "就是一句话") == nil)
    #expect(newlineAtEnd(of: "") == nil)
    #expect(newlineAtEnd(of: "   ") == nil)
    #expect(newlineAtEnd(of: "-abc 没有空格不是列表") == nil)
}

/// 代码块里的回车就是回车：缩进与标记都不该被当成 Markdown。
@MainActor
@Test func codeFencesAreLeftAlone() {
    let document = "```swift\n- 这不是列表\n"
    // 光标必须落在围栏里那一行上——落在文末空行会走「空前缀」提前退出，测不到围栏判断
    #expect(newlineAtLastContentLine(of: document) == nil)

    // 围栏行本身也一样
    #expect(newlineAtEnd(of: "```") == nil)
}

/// 表格行留给表格辅助，这一阶段不动。
@MainActor
@Test func tableRowsAreLeftAlone() {
    #expect(newlineAtEnd(of: "| a | b |") == nil)
}

/// 在行中间回车：marker 认得出，续行照旧。
@MainActor
@Test func newlineMidLineStillContinues() {
    let text = "- 第一项后面的字"
    let edit = MarkdownEditing.newline(in: text, selection: NSRange(location: 6, length: 0))
    #expect(edit?.range == NSRange(location: 6, length: 0))
    #expect(edit?.text == "\n- ")
}

/// 有选区时先替换掉选区，再续行——⌘Z 一步回到原样。
@MainActor
@Test func newlineReplacesTheSelection() {
    let edit = MarkdownEditing.newline(in: "- 甲乙丙", selection: NSRange(location: 2, length: 2))
    #expect(edit?.range == NSRange(location: 2, length: 2))
    #expect(edit?.text == "\n- ")
}

// MARK: - 缩进

@MainActor
@Test func tabIndentsTheCurrentLine() {
    let edit = MarkdownEditing.indent(
        in: "一道题", selection: NSRange(location: 2, length: 0), outdent: false
    )
    #expect(edit?.text == "  一道题")
    #expect(edit?.selectionAfter == NSRange(location: 4, length: 0))
}

@MainActor
@Test func tabIndentsEverySelectedLine() {
    let text = "甲\n乙\n丙"
    let edit = MarkdownEditing.indent(
        in: text, selection: NSRange(location: 0, length: (text as NSString).length), outdent: false
    )
    #expect(edit?.text == "  甲\n  乙\n  丙")
    // 整块保持选中，连续 Tab 能一层层往里推
    #expect(edit?.selectionAfter == NSRange(location: 0, length: (edit!.text as NSString).length))
}

/// 空行不产生尾随空白：缩进整段时不该在空行上留下两个空格。
@MainActor
@Test func blankLinesAreNotIndented() {
    let text = "甲\n\n乙"
    let edit = MarkdownEditing.indent(
        in: text, selection: NSRange(location: 0, length: (text as NSString).length), outdent: false
    )
    #expect(edit?.text == "  甲\n\n  乙")
}

@MainActor
@Test func tabOnAnEmptyLineInsertsTheIndentUnit() {
    let edit = MarkdownEditing.indent(in: "", selection: NSRange(location: 0, length: 0), outdent: false)
    #expect(edit?.text == "  ")
    #expect(edit?.selectionAfter == NSRange(location: 2, length: 0))
}

@MainActor
@Test func shiftTabRemovesOneIndentUnit() {
    let edit = MarkdownEditing.indent(
        in: "    五格缩进", selection: NSRange(location: 0, length: 0), outdent: true
    )
    #expect(edit?.text == "  五格缩进")
    #expect(edit?.selectionAfter?.location == 0)
}

/// 只有一格空格也去掉一格——反缩进不是「宁可不做」。
@MainActor
@Test func shiftTabHandlesPartialIndent() {
    let edit = MarkdownEditing.indent(in: " 甲", selection: NSRange(location: 0, length: 0), outdent: true)
    #expect(edit?.text == "甲")
}

@MainActor
@Test func shiftTabHandlesTabs() {
    let edit = MarkdownEditing.indent(in: "\t甲", selection: NSRange(location: 0, length: 0), outdent: true)
    #expect(edit?.text == "甲")
}

/// 没有缩进可去：返回 nil，让系统按键落空，而不是制造一次空编辑。
@MainActor
@Test func shiftTabOnUnindentedLineDoesNothing() {
    #expect(MarkdownEditing.indent(in: "甲", selection: NSRange(location: 0, length: 0), outdent: true) == nil)
}

@MainActor
@Test func shiftTabOutdentsEverySelectedLine() {
    let text = "  甲\n  乙"
    let edit = MarkdownEditing.indent(
        in: text, selection: NSRange(location: 0, length: (text as NSString).length), outdent: true
    )
    #expect(edit?.text == "甲\n乙")
}

/// 选区只碰到某一行的一个字，也只缩进那一行（替换内容就只有那一行）。
@MainActor
@Test func tabOnlyTouchesTheTouchedLines() {
    let text = "甲\n乙\n丙"
    let edit = MarkdownEditing.indent(in: text, selection: NSRange(location: 2, length: 1), outdent: false)
    #expect(edit?.text == "  乙")
    #expect(edit?.range == NSRange(location: 2, length: 1))
}
