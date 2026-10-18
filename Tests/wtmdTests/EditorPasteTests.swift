import AppKit
import Testing
@testable import wtmd

// MARK: - 真实编辑器里的粘贴链路

@MainActor
private func board(html: String) -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("wtmd-paste-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString(html, forType: .html)
    return pasteboard
}

@MainActor
private func board(text: String) -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("wtmd-paste-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return pasteboard
}

/// 从浏览器复制一段带标题的内容粘进来：落地的是 Markdown，不是一坨硬换行。
@MainActor
@Test func pastedHTMLBecomesMarkdown() {
    let probe = IMEProbeWindow(text: "")
    probe.coordinator.pasteboard = board(html: "<h1>标题</h1><p>一段 <strong>粗</strong>。</p>")

    probe.textView.paste(nil)

    #expect(probe.text == "# 标题\n\n一段 **粗**。")
}

/// 粘贴落在光标处，并且替换掉选中的内容（与系统粘贴的语义一致）。
@MainActor
@Test func pasteLandsAtTheCaretAndReplacesTheSelection() {
    let probe = IMEProbeWindow(text: "前文后文")
    probe.textView.setSelectedRange(NSRange(location: 2, length: 2))
    probe.coordinator.pasteboard = board(html: "<p>替换</p>")

    probe.textView.paste(nil)

    #expect(probe.text == "前文替换")
}

/// 一次粘贴一步撤销：退回的是粘贴前，不会留下半截 Markdown。
@MainActor
@Test func oneUndoRemovesTheWholePaste() {
    let probe = IMEProbeWindow(text: "abc")
    probe.textView.setSelectedRange(NSRange(location: 3, length: 0))
    probe.coordinator.pasteboard = board(html: "<p>一段</p>")

    probe.textView.paste(nil)
    #expect(probe.text == "abc一段")

    probe.textView.undoManager?.undo()
    #expect(probe.text == "abc")
}

/// 纯文本粘贴不归转换器管：交回系统，行为与改动前一致。
@MainActor
@Test func plainTextPasteIsNotIntercepted() {
    let probe = IMEProbeWindow(text: "原文")
    probe.coordinator.pasteboard = board(text: "一段纯文本")

    #expect(!probe.coordinator.handleRichPasteIfNeeded())
    #expect(probe.text == "原文")
}

/// 组合中粘贴：先把拼音落定，再插入转换结果，别替换掉 marked range。
@MainActor
@Test func pasteDuringCompositionCommitsFirst() {
    let probe = IMEProbeWindow(text: "abc")
    probe.textView.setSelectedRange(NSRange(location: 3, length: 0))
    probe.textView.setMarkedText(
        "ni",
        selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    probe.coordinator.pasteboard = board(html: "<p>词</p>")

    probe.textView.paste(nil)

    #expect(!probe.marked, "粘贴不能把组合段留在编辑器里")
    #expect(probe.text.hasSuffix("词"))
}

/// 粘贴进来的多行内容，高亮照常铺上（块级结构在源码里仍然是一行行）。
@MainActor
@Test func pastedMarkdownGetsHighlighted() {
    let probe = IMEProbeWindow(text: "")
    probe.coordinator.pasteboard = board(html: "<ul><li>一项</li></ul>")
    probe.textView.paste(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    let storage = try? #require(probe.textView.textStorage)
    let color = storage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(color == NSColor.systemOrange)
}
