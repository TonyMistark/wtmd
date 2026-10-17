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
        coordinator.textView.string = text
        coordinator.rebuildLineStarts()
        // 新视图的默认落点就是文首（`string` 赋值会把光标送到末尾，这里还原）
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
