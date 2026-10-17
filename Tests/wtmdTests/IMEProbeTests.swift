import AppKit
import Testing
import SwiftUI
@testable import wtmd

// MARK: - 探针：拼音输入法（IME）在源码编辑器里能否落字

/// 离屏窗口 + 真实 NSTextInputClient 调用，复现「拼音候选窗在角落、确认后文字进不去」。
/// setMarkedText → insertText 是输入法 commit 的真实调用序列，不需要真的装输入法。
@MainActor
final class IMEProbeWindow {
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: NSTextView
    let coordinator: EditorTextView.Coordinator
    private let bound: () -> String

    init(text: String = "") {
        var value = text
        let bindable = Binding(get: { value }, set: { value = $0 })
        bound = { value }
        let view = EditorTextView(
            text: bindable,
            cursorLine: .constant(0),
            pendingImageInsert: .constant(nil)
        )
        coordinator = view.makeCoordinator()
        scrollView = coordinator.scrollView
        textView = coordinator.textView
        textView.string = text

        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    /// 输入法：先落 marked text（拼音串），再 commit 候选字
    func imeType(pinyin: String, commit: String) {
        textView.setMarkedText(
            pinyin,
            selectedRange: NSRange(location: (pinyin as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    var text: String { textView.string }
    /// 绑定值：只有 Coordinator.textDidChange 会写它，用来确认 delegate 真的跑了
    var boundText: String { bound() }
    var marked: Bool { textView.hasMarkedText() }
}

@Test @MainActor func imeCommitLandsInEditor() async throws {
    let probe = IMEProbeWindow()
    probe.imeType(pinyin: "nihao", commit: "你好")
    #expect(probe.text == "你好")
}

@Test @MainActor func imeCommitLandsAfterExistingText() async throws {
    let probe = IMEProbeWindow(text: "abc ")
    probe.textView.setSelectedRange(NSRange(location: 4, length: 0))
    probe.imeType(pinyin: "zhongwen", commit: "中文")
    #expect(probe.text == "abc 中文")
}

/// 候选窗定位依赖 firstRect：为零则输入法把候选窗贴到屏幕角落（用户看到的左下角）
@Test @MainActor func imeCaretRectIsUsable() async throws {
    let probe = IMEProbeWindow(text: "第一行\n第二行")
    probe.textView.setSelectedRange(NSRange(location: 3, length: 0))
    var actual = NSRange()
    let rect = probe.textView.firstRect(
        forCharacterRange: NSRange(location: 3, length: 0),
        actualRange: &actual
    )
    #expect(rect.width > 0 || rect.height > 0)
    #expect(rect.origin.x.isFinite && rect.origin.y.isFinite)
}

/// 组合期间 markedRange 必须存活：高亮重建（每次 textDidChange 都会跑）不得让它失效。
/// 失效即真实输入法的症状——候选窗失去锚点贴到屏幕角落，确认时 commit 找不到替换区间被丢弃。
@Test @MainActor func markedRangeSurvivesHighlightRebuild() async throws {
    let probe = IMEProbeWindow(text: "abc ")
    probe.textView.setSelectedRange(NSRange(location: 4, length: 0))
    probe.textView.setMarkedText(
        "nihao",
        selectedRange: NSRange(location: 5, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(probe.marked)
    let marked = probe.textView.markedRange()
    #expect(marked.location != NSNotFound)
    #expect(marked.length == 5)
    #expect(marked.location == 4)
}

/// 这个 bug 的地基事实：组合（setMarkedText）**不触发** textDidChange，
/// 所以绑定值在组合期间必然落后于 textStorage。任何拿绑定值覆盖整串的代码
/// 都会打断组合——这正是中文打不进去、英文却正常的原因。
@Test @MainActor func compositionDoesNotUpdateBinding() async throws {
    let probe = IMEProbeWindow(text: "")
    probe.textView.setMarkedText(
        "ni",
        selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(probe.text == "ni")        // textStorage 已有组合串
    #expect(probe.boundText == "")     // 绑定值仍是旧的（delegate 没跑）
}

/// 真实应用路径：拼音组合中（textStorage 有 marked text、绑定值仍为空），
/// 光标移动引发 SwiftUI 更新 → updateNSView 调 syncText("")。
/// 这必须不能覆盖编辑器内容——否则输入法组合被销毁，中文永远打不进去。
@Test @MainActor func compositionSurvivesSwiftUISync() async throws {
    let probe = IMEProbeWindow(text: "")
    probe.textView.setMarkedText(
        "nihao",
        selectedRange: NSRange(location: 5, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(probe.marked)
    #expect(probe.boundText == "")   // 组合不触发 textDidChange，绑定值必然落后

    // SwiftUI 的一次普通更新（光标行变化等）会把落后的绑定值推回来
    probe.coordinator.syncText("")

    #expect(probe.marked)
    #expect(probe.text == "nihao")

    // 确认候选字：commit 必须落进文档
    probe.textView.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(probe.text == "你好")
}

/// 组合中切换文档不能被守卫挡住：外部真的换了内容（忽略组合段仍不相等）时，
/// 先结束组合再同步。
@Test @MainActor func documentSwitchWinsOverComposition() async throws {
    let probe = IMEProbeWindow(text: "旧文档")
    probe.textView.setSelectedRange(NSRange(location: 3, length: 0))
    probe.textView.setMarkedText(
        "pin",
        selectedRange: NSRange(location: 3, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(probe.text == "旧文档pin")

    probe.coordinator.syncText("另一篇文档")
    #expect(probe.text == "另一篇文档")
    #expect(!probe.marked)
}
