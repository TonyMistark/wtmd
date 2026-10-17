import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 离屏编辑器上的查找

/// 真实 `Coordinator` + 离屏窗口：高亮落在哪个属性层、撤销是不是一步，
/// 只有真的 `NSTextView` 能回答。
@MainActor
private final class FindProbe {
    let coordinator: EditorTextView.Coordinator
    let window: NSWindow

    init(text: String, onReplaceApplied: (() -> Void)? = nil) {
        var value = text
        let bindable = Binding(get: { value }, set: { value = $0 })
        let view = EditorTextView(
            text: bindable,
            cursorLine: .constant(0),
            pendingImageInsert: .constant(nil),
            onReplaceApplied: onReplaceApplied
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

    func showFind(_ query: String, options: FindOptions = []) {
        let scan = FindEngine.scan(textView.string as NSString, query: query, options: options)
        coordinator.parent.findMatches = scan.matches
        coordinator.parent.findCurrent = scan.matches.first
        coordinator.applyFindHighlights()
    }
}

/// **红线**：高亮只能盖在 layout manager 的临时属性上。写进 textStorage 的话，
/// 下一次按键的 `highlight()` 会把它整串重建掉，命中就消失了。
@Test @MainActor func findHighlightIsTemporaryAndSurvivesARebuild() throws {
    let probe = FindProbe(text: "alpha beta alpha")
    probe.showFind("alpha")

    let layoutManager = try #require(probe.textView.layoutManager)
    #expect(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
    #expect(probe.textView.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)

    // 模拟一次按键：语法高亮重建整串属性
    EditorTextView.highlight(probe.textView)

    #expect(
        layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil,
        "重建高亮不该带走查找底色"
    )
    #expect(probe.textView.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
}

@Test @MainActor func onlyTheCurrentMatchGetsTheStrongerColour() throws {
    let probe = FindProbe(text: "alpha beta alpha")
    probe.showFind("alpha")

    let layoutManager = try #require(probe.textView.layoutManager)
    let first = try #require(
        layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
    )
    let second = try #require(
        layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 11, effectiveRange: nil) as? NSColor
    )
    #expect(first != second)
}

@Test @MainActor func seekingPutsTheSelectionOnTheMatch() {
    let probe = FindProbe(text: "alpha beta alpha")
    probe.showFind("alpha")
    probe.coordinator.parent.findCurrent = NSRange(location: 11, length: 5)
    probe.coordinator.seekToCurrentMatch()
    #expect(probe.textView.selectedRange() == NSRange(location: 11, length: 5))
}

/// 替换走 `shouldChangeText` / `didChangeText` 成对调用，一步撤销。
@Test @MainActor func replacingOneMatchIsASingleUndoStep() throws {
    let probe = FindProbe(text: "hello world")
    let request = ReplaceRequest(
        id: "1",
        range: NSRange(location: 0, length: 5),
        replacement: "Hello",
        selectionAfter: NSRange(location: 5, length: 0)
    )
    probe.coordinator.applyReplace(request)
    #expect(probe.textView.string == "Hello world")

    let undoManager = try #require(probe.textView.undoManager)
    undoManager.undo()
    #expect(probe.textView.string == "hello world")
}

/// 全部替换整篇一次改完：`⌘Z` 退一步就全回来，而不是退四十次。
@Test @MainActor func replacingEverythingIsAlsoASingleUndoStep() throws {
    let original = "cat cat cat"
    let probe = FindProbe(text: original)
    let updated = try #require(
        FindEngine.replacingAll(in: original, query: "cat", options: [], template: "dog")
    )
    let request = ReplaceRequest(
        id: "all",
        range: NSRange(location: 0, length: (original as NSString).length),
        replacement: updated,
        selectionAfter: NSRange(location: 0, length: 0)
    )
    probe.coordinator.applyReplace(request)
    #expect(probe.textView.string == "dog dog dog")

    let undoManager = try #require(probe.textView.undoManager)
    undoManager.undo()
    #expect(probe.textView.string == original)
}

/// 关掉查找后不能再有底色残留：临时属性不清，读者会以为那是语法高亮。
@Test @MainActor func clearingTheMatchesRemovesTheHighlight() throws {    let probe = FindProbe(text: "alpha beta")
    probe.showFind("alpha")
    probe.coordinator.parent.findMatches = []
    probe.coordinator.parent.findCurrent = nil
    probe.coordinator.applyFindHighlights()

    let layoutManager = try #require(probe.textView.layoutManager)
    #expect(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
}

/// 替换请求是一次性的：执行完必须回报，让 store 清掉它。
/// 留着的话，`⌘/` 重建编辑器会拿同一个区间再改一次——那时它指向的是别的字。
@Test @MainActor func applyingAReplaceIsReportedOnce() async throws {
    var reported = 0
    let probe = FindProbe(text: "hello world") { reported += 1 }
    probe.coordinator.applyReplace(
        ReplaceRequest(
            id: "once",
            range: NSRange(location: 0, length: 5),
            replacement: "Hello",
            selectionAfter: NSRange(location: 5, length: 0)
        )
    )
    try await Task.sleep(nanoseconds: 80_000_000)
    #expect(reported == 1)
    #expect(probe.textView.string == "Hello world")
}
