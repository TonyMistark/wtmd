import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 搜索面板的排版

/// 面板是给人看的东西：「有这几行字」证明不了它读起来像一张结果列表。
/// 这里真的渲染成位图，图留在 `/tmp` 供人眼复核。
@MainActor
@Test func thePanelLaysOutGroupedResults() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-search-shot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

    try "第一章\n这一句里有 needle\n后面还有 needle 一次"
        .write(to: root.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
    try "别处的笔记\n没有关键词\n但这一行有 needle"
        .write(to: notes.appendingPathComponent("ideas.md"), atomically: true, encoding: .utf8)

    let search = WorkspaceSearchController(delay: 0)
    search.present(root: root)
    search.query = "needle"

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, search.isSearching || search.hits.isEmpty {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(search.hits.count == 3)

    // ImageRenderer 会把 TextField / Button 画成占位块，所以走真实的
    // NSHostingView + cacheDisplay（同查找条快照）。
    let panel = WorkspaceSearchPanel(search: search, onOpen: { _ in }, onDismiss: {})
    let hosting = NSHostingView(rootView: panel)
    let size = CGSize(width: 640, height: 320)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    window.layoutIfNeeded()

    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "/tmp/wtmd-search-panel.png"))

    // 只有一种颜色说明什么都没画出来（文字塌成 0，或整块被裁掉）
    #expect(distinctColors(bitmap) > 6)
}

/// 数一数画面里有多少种颜色。像素只用来数颜色，尺寸断言一律按点数。
private func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
    var seen = Set<UInt32>()
    let step = 4
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let packed = UInt32(color.redComponent * 255) << 16
                | UInt32(color.greenComponent * 255) << 8
                | UInt32(color.blueComponent * 255)
            seen.insert(packed)
        }
    }
    return seen.count
}
