import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 编辑器的位置回填

/// 离屏窗口里的真实 Coordinator：`⌘/` 切回源码时 SwiftUI 会重建它，
/// 这里就用「第二个 Coordinator + 同一份 PositionMemory」模拟那次重建。
@MainActor
private final class EditorPositionProbe {
    let coordinator: EditorTextView.Coordinator
    let window: NSWindow

    init(text: String, memory: PositionMemory, generation: Int) {
        var value = text
        let bindable = Binding(get: { value }, set: { value = $0 })
        let view = EditorTextView(
            text: bindable,
            cursorLine: .constant(0),
            pendingImageInsert: .constant(nil),
            positionMemory: memory,
            generation: generation
        )
        coordinator = view.makeCoordinator()
        // 生产路径是 updateNSView → syncText（设文本、重铺高亮、同步长高 frame）。
        // 走同一条路：自建文本系统的 frame 生长若绕开它，回填滚动会被钳在半截。
        coordinator.syncText(text)

        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = coordinator.scrollView
        window.layoutIfNeeded()
        // 窗口把真实宽度交给编辑器，布局按真宽重排，frame 得按真宽再撑一次——
        // syncText 时视图还没有宽度，那次撑的高度对不上（CI 上滚动正好被钳在半截）。
        // 与生产同一条规则：几何变了，长高排在几何之后。
        coordinator.growToContent()
    }

    var selection: NSRange { coordinator.textView.selectedRange() }
    var scrollY: CGFloat { coordinator.clipView.bounds.origin.y }

    /// 自建文本系统的 frame 生长分了步：等它长到稳且够高再滚。
    /// 快机器一步到位，慢 CI 多等几拍——「滚动被钳在半截」不该是 flake。
    func waitUntilSettled(minimumHeight: CGFloat = 2000) async {
        var previous: CGFloat = -1
        for _ in 0..<200 {
            coordinator.growToContent()
            let height = coordinator.textView.frame.height
            if height >= minimumHeight, height == previous { return }
            previous = height
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func scroll(toY y: CGFloat) {
        coordinator.clipView.scroll(to: NSPoint(x: 0, y: y))
        coordinator.scrollView.reflectScrolledClipView(coordinator.clipView)
    }
}

private let longDocument = (0..<200).map { "第 \($0) 行，用来撑出可滚动的篇幅。" }.joined(separator: "\n")

/// 让出主线程一拍，等 `restorePositionIfNeeded` 排下的异步回填跑完。
private func drainMainQueue() async {
    try? await Task.sleep(nanoseconds: 120_000_000)
}

@Test @MainActor func editorPositionSurvivesARebuild() async throws {
    let memory = PositionMemory()
    memory.startSession(generation: 1)

    let first = EditorPositionProbe(text: longDocument, memory: memory, generation: 1)
    await first.waitUntilSettled()
    first.coordinator.restorePositionIfNeeded()   // 没有旧位置：只是开启记账
    await drainMainQueue()

    let target = NSRange(location: 450, length: 0)
    first.coordinator.textView.setSelectedRange(target)
    first.scroll(toY: 300)
    await drainMainQueue()

    #expect(memory.editorPosition?.selection == target)
    #expect((memory.editorPosition?.scrollOrigin.y ?? 0) > 250)

    // 重建：新的 Coordinator、同一份记账本、同一代文档
    let second = EditorPositionProbe(text: longDocument, memory: memory, generation: 1)
    await second.waitUntilSettled()
    second.coordinator.restorePositionIfNeeded()
    await drainMainQueue()

    #expect(second.selection == target)
    #expect(abs(second.scrollY - 300) <= 2)
}

/// 换文档时旧位置必须作废：否则新文档会被滚到「上一篇的第 450 个字符」附近，
/// 读者看到的是毫无关系的一段中间内容。
@Test @MainActor func aNewDocumentIgnoresTheOldPosition() async throws {
    let memory = PositionMemory()
    memory.startSession(generation: 1)

    let first = EditorPositionProbe(text: longDocument, memory: memory, generation: 1)
    first.coordinator.restorePositionIfNeeded()
    await drainMainQueue()
    first.coordinator.textView.setSelectedRange(NSRange(location: 450, length: 0))
    first.scroll(toY: 300)
    await drainMainQueue()
    #expect(memory.editorPosition != nil)

    let next = EditorPositionProbe(text: longDocument, memory: memory, generation: 2)
    next.coordinator.restorePositionIfNeeded()
    await drainMainQueue()

    #expect(next.selection.location == 0)
    #expect(next.scrollY == 0)
    #expect(memory.editorPosition == nil)
}

/// 换文档（不是换视图）时，光标要从文首开始：`textView.string` 赋值默认把
/// 插入点送到末尾，读者打开一个文件却要往上翻，是同一类「位置不对」。
@Test @MainActor func switchingDocumentsPutsTheCaretAtTheTop() async throws {
    let memory = PositionMemory()
    let probe = EditorPositionProbe(text: "旧文档", memory: memory, generation: 1)

    probe.coordinator.syncText("新文档的第一行\n第二行")

    #expect(probe.coordinator.textView.string == "新文档的第一行\n第二行")
    #expect(probe.coordinator.textView.selectedRange().location == 0)
}

/// 会话恢复的落点：位置不是「重建时顺手记着」的，而是从上一轮（甚至上一次启动）
/// 预置进来的。种子必须在 `startSession` 的清空之前被认领，否则读者一打开应用
/// 就落在文首——恢复了个寂寞。
@Test @MainActor func aSeededPositionIsRestoredForThatGeneration() async throws {
    let memory = PositionMemory()
    memory.seed(
        editorPosition: PositionMemory.EditorPosition(
            selection: NSRange(location: 700, length: 0),
            scrollOrigin: CGPoint(x: 0, y: 240)
        ),
        previewAnchor: nil,
        for: 2
    )

    let probe = EditorPositionProbe(text: longDocument, memory: memory, generation: 2)
    await probe.waitUntilSettled()
    probe.coordinator.restorePositionIfNeeded()
    await drainMainQueue()

    #expect(probe.selection.location == 700)
    #expect(abs(probe.scrollY - 240) <= 2)
}

/// 同一个视图里换文档（代数变了）：要按新一代的种子回填，而不是「这一辈子只回填过一次」。
@Test @MainActor func changingGenerationRestoresThatDocumentsPosition() async throws {
    let memory = PositionMemory()
    let probe = EditorPositionProbe(text: longDocument, memory: memory, generation: 1)
    await probe.waitUntilSettled()
    probe.coordinator.restorePositionIfNeeded()
    await drainMainQueue()

    probe.coordinator.textView.setSelectedRange(NSRange(location: 30, length: 0))
    probe.scroll(toY: 60)
    await drainMainQueue()

    memory.seed(
        editorPosition: PositionMemory.EditorPosition(
            selection: NSRange(location: 900, length: 0),
            scrollOrigin: CGPoint(x: 0, y: 420)
        ),
        previewAnchor: nil,
        for: 2
    )
    probe.coordinator.parent.generation = 2
    probe.coordinator.syncText(longDocument)
    probe.coordinator.restorePositionIfNeeded()
    await drainMainQueue()

    #expect(probe.selection.location == 900)
    #expect(abs(probe.scrollY - 420) <= 2)
}

/// 打字机模式：滚动交给 recenter 决定（光标行居中），不能把旧的像素偏移
/// 硬塞回去——那会让光标偏离中线，直到下一次按键才被纠正。
@Test @MainActor func typewriterModeRecentersInsteadOfReplayingTheOffset() async throws {
    let memory = PositionMemory()
    memory.startSession(generation: 1)
    memory.recordEditorPosition(
        PositionMemory.EditorPosition(
            selection: NSRange(location: 900, length: 0),
            scrollOrigin: CGPoint(x: 0, y: 12)
        )
    )

    var value = longDocument
    let bindable = Binding(get: { value }, set: { value = $0 })
    let view = EditorTextView(
        text: bindable,
        cursorLine: .constant(0),
        pendingImageInsert: .constant(nil),
        typewriterMode: true,
        positionMemory: memory,
        generation: 1
    )
    let coordinator = view.makeCoordinator()
    coordinator.textView.string = longDocument
    coordinator.rebuildLineStarts()

    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = coordinator.scrollView
    window.layoutIfNeeded()

    coordinator.restorePositionIfNeeded()
    await drainMainQueue()

    #expect(coordinator.textView.selectedRange().location == 900)
    // 居中后绝不会还是那个 12pt 的旧偏移
    #expect(abs(coordinator.clipView.bounds.origin.y - 12) > 1)

    // 离屏窗口显式拆掉，别把视图层级留给测试进程的后续用例
    window.contentView = nil
}
