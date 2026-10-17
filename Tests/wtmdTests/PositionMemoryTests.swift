import AppKit
import Testing
@testable import wtmd

// MARK: - 位置账本

private func editorPosition(_ location: Int, _ scrollY: CGFloat = 0) -> PositionMemory.EditorPosition {
    PositionMemory.EditorPosition(selection: NSRange(location: location, length: 0), scrollOrigin: CGPoint(x: 0, y: scrollY))
}

@Test func positionMemoryRecordsBothSides() {
    let memory = PositionMemory()
    memory.startSession(generation: 1)

    memory.recordEditorPosition(editorPosition(42, 300))
    memory.recordPreviewAnchor(PositionMemory.PreviewAnchor(blockIndex: 7, offset: -12))

    #expect(memory.editorPosition == editorPosition(42, 300))
    #expect(memory.previewAnchor == PositionMemory.PreviewAnchor(blockIndex: 7, offset: -12))
}

/// `⌘/` 切换只是换视图，不是换文档：同一个 generation 下位置必须留着，
/// 否则「无损切换」在自己的第一道关上就失效了。
@Test func theSameDocumentKeepsItsPositions() {
    let memory = PositionMemory()
    memory.startSession(generation: 3)
    memory.recordEditorPosition(editorPosition(100))
    memory.recordPreviewAnchor(PositionMemory.PreviewAnchor(blockIndex: 2, offset: -5))

    memory.startSession(generation: 3)

    #expect(memory.editorPosition != nil)
    #expect(memory.previewAnchor != nil)
}

/// 换文档（打开文件 / 新建）时两边的位置都必须作废：块下标在新文档里指向
/// 完全无关的内容，照搬会把读者扔到随机一段。
@Test func aNewDocumentDropsPositionsFromTheOldOne() {
    let memory = PositionMemory()
    memory.startSession(generation: 1)
    memory.recordEditorPosition(editorPosition(100))
    memory.recordPreviewAnchor(PositionMemory.PreviewAnchor(blockIndex: 2, offset: -5))

    memory.startSession(generation: 2)

    #expect(memory.generation == 2)
    #expect(memory.editorPosition == nil)
    #expect(memory.previewAnchor == nil)
}

@Test func clearForgetsEverythingWithoutChangingTheGeneration() {
    let memory = PositionMemory()
    memory.startSession(generation: 5)
    memory.recordPreviewAnchor(PositionMemory.PreviewAnchor(blockIndex: 1, offset: 0))

    memory.clear()

    #expect(memory.generation == 5)
    #expect(memory.previewAnchor == nil)
}
