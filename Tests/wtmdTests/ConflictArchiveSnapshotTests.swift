import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 冲突副本清单的排版

/// 这张表是给人做决定用的：要能一眼看清「哪一篇、什么时候、原文件在哪儿」，
/// 而不是被一排按钮挟持。渲染成位图，图留在 `/tmp` 供人眼复核。
@MainActor
private func render() throws -> (bitmap: NSBitmapImageRep, points: CGSize) {
    let when = Date(timeIntervalSince1970: 1_760_000_000)
    let entries = [
        ConflictArchiveEntry(
            fileURL: URL(fileURLWithPath: "/tmp/conflicts/第三章-20261017-184200.md"),
            originalName: "第三章.md",
            originalPath: "/Users/ice/Documents/书稿/第三章.md",
            savedAt: when
        ),
        ConflictArchiveEntry(
            fileURL: URL(fileURLWithPath: "/tmp/conflicts/读书笔记-20261017-101500.md"),
            originalName: "读书笔记.md",
            originalPath: "/Users/ice/Documents/读书笔记.md",
            savedAt: when.addingTimeInterval(-26_000)
        ),
    ]
    let view = ConflictArchiveView(
        entries: entries,
        folder: nil,
        recover: { _ in },
        discard: { _ in },
        reveal: { _ in },
        close: {}
    )
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 320),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    let fitted = hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: fitted)
    window.setContentSize(fitted)
    window.layoutIfNeeded()

    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "/tmp/wtmd-conflict-archive.png"))
    return (bitmap, fitted)
}

private func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
    var seen = Set<UInt32>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let packed = UInt32(color.redComponent * 255) << 16
                | UInt32(color.greenComponent * 255) << 8
                | UInt32(color.blueComponent * 255)
            seen.insert(packed)
        }
    }
    return seen.count
}

@Test @MainActor func theConflictListIsACompactTable() throws {
    let (bitmap, points) = try render()
    // 宽度固定在 480pt（与查找条一样按点断言，CI 是 1x、本机 2x）
    #expect(points.width == 480)
    // 标题 + 两行 + 页脚：矮了是没画出来，高了是一块面板而不是一张表
    #expect(points.height > 120)
    #expect(points.height < 300)
    #expect(distinctColors(bitmap) > 4)
}
