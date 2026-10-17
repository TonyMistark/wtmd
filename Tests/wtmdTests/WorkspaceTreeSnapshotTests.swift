import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 文件树的排版

/// 树里多了能动手的东西：空目录也有一行，当前文档高亮。文件树抽成了独立的
/// `WorkspaceTreeView`，可以单独渲染成位图留在 `/tmp` 供人眼复核。
@MainActor
private func renderTree() throws -> (bitmap: NSBitmapImageRep, points: CGSize) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-tree-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let drafts = root.appendingPathComponent("drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
    try "# 第一章".write(
        to: drafts.appendingPathComponent("第一章.md"), atomically: true, encoding: .utf8
    )
    try "# 序".write(
        to: root.appendingPathComponent("序.md"), atomically: true, encoding: .utf8
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("空文件夹", isDirectory: true),
        withIntermediateDirectories: true
    )

    let store = DocumentStore(draftDirectory: root, autoSaveDelay: 60_000_000_000)
    store.open(url: drafts.appendingPathComponent("第一章.md"))
    let workspace = WorkspaceStore()
    workspace.open(root)
    workspace.reveal(drafts.appendingPathComponent("第一章.md"))
    workspace.setExpanded(drafts, to: true)

    let view = List {
        WorkspaceTreeView()
    }
    .listStyle(.sidebar)
    .environmentObject(store)
    .environmentObject(workspace)
    .frame(width: 280, height: 260)

    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 280, height: 260),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: CGSize(width: 280, height: 260))
    window.setContentSize(CGSize(width: 280, height: 260))
    window.layoutIfNeeded()

    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "/tmp/wtmd-workspace-tree.png"))
    return (bitmap, hosting.bounds.size)
}

private func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
    var seen = Set<UInt32>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let packed = UInt32(color.redComponent * 255) << 16
                | UInt32(color.greenComponent * 255) << 8
                | UInt32(color.blueComponent * 255)
            seen.insert(packed)
        }
    }
    return seen.count
}

@MainActor
@Test func theTreeShowsFoldersFilesAndAnEmptyFolder() throws {
    let (bitmap, points) = try renderTree()
    // 按点断言（CI 是 1x、本机 2x）
    #expect(points.width == 280)
    // 根下的两行 + 折叠组里的一行 + 空文件夹一行：矮了是没画出来，高了就是面板
    #expect(points.height == 260)
    #expect(distinctColors(bitmap) > 8)
}
