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
    // 这里守的是面板的**排版**（分组、行文、高亮），不是扫盘——注入即时返回
    // 的假扫描，摘掉真实 I/O 在并行测试挤占 CPU 时的时序运气（CI 上连挂）。
    // 两组命中：draft.md 两条、notes/ideas.md 一条，正好铺出跨文件分组。
    let draftURL = root.appendingPathComponent("draft.md")
    let ideasURL = notes.appendingPathComponent("ideas.md")
    func hit(_ url: URL, line: Int, lineText: String) -> WorkspaceHit {
        let column = (lineText as NSString).range(of: "needle").location
        return WorkspaceHit(
            fileURL: url, line: line, column: column,
            length: 6, lineText: lineText,
            highlightStart: column, highlightLength: 6
        )
    }
    let canned = WorkspaceSearchReport(groups: [
        WorkspaceHitGroup(
            fileURL: draftURL, relativePath: "draft.md",
            hits: [
                hit(draftURL, line: 1, lineText: "这一句里有 needle"),
                hit(draftURL, line: 3, lineText: "后面还有 needle 一次"),
            ]
        ),
        WorkspaceHitGroup(
            fileURL: ideasURL, relativePath: "notes/ideas.md",
            hits: [hit(ideasURL, line: 2, lineText: "但这一行有 needle")]
        ),
    ], hitCount: 3, scannedFiles: 2)
    search.searchFunction = { _ in canned }
    search.present(root: root)
    search.query = "needle"

    // 等那一轮扫描的句柄，而不是按墙钟数秒：主线程被别的重活占住时，墙钟
    // 轮询会把「结果还在路上」误判成「没结果」（CI 上就这样挂过）。
    await search.searchTask?.value
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
