import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 查找条的排版

/// 查找条是给人看的东西：断言「有这几个按钮」证明不了它读起来像一条工具条。
/// 这里真的渲染成位图，检查高度与配色层次，图留在 `/tmp` 供人眼复核。
///
/// 返回点尺寸：CI 机器是 1x，本机是 2x，**像素断言会被显示倍率绊倒**，
/// 一律换算回点数再比。
@MainActor
private func render(replacing: Bool) throws -> (bitmap: NSBitmapImageRep, points: CGSize) {
    let find = FindController()
    find.attach("alpha beta alpha gamma alpha")
    find.present(focusingReplacement: replacing)
    find.query = "alpha"
    find.replacement = "omega"

    // ImageRenderer 会把 TextField / Button 画成占位块（离屏没有 AppKit 上下文），
    // 所以这里走真实的 NSHostingView + cacheDisplay。
    let bar = FindBar(
        find: find,
        onReplaceCurrent: {},
        onReplaceAll: {},
        onClose: {}
    )
    .frame(width: 760)
    let hosting = NSHostingView(rootView: bar)
    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 120),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    // 画布贴合查找条的固有高度：窗口给的 120pt 会带一截空边，高度断言就失去意义了
    let fitted = hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: fitted)
    window.setContentSize(fitted)
    window.layoutIfNeeded()

    let bitmap = try #require(
        hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
    )
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "/tmp/wtmd-find-bar-\(replacing ? "replace" : "find").png"))
    return (bitmap, fitted)
}

/// 数一数画面里有多少种颜色：只有一种说明什么都没画出来（比如文字尺寸塌成 0）。
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

@Test @MainActor func theFindBarIsOneSlimRow() throws {
    let (bitmap, points) = try render(replacing: false)
    #expect(points.width == 760)
    // 一行查找（34pt）+ 分隔线：矮了是没画出来，高了是面板而不是条
    #expect(points.height > 20)
    #expect(points.height < 55)
    #expect(distinctColors(bitmap) > 4)     // 底色、输入框、计数、三个选项、按钮
}

/// ⌥⌘R 打开时要多出替换那一行——但整体仍是一条，不是一块面板。
@Test @MainActor func theReplaceRowAddsExactlyOneLine() throws {
    let findOnly = try render(replacing: false)
    let withReplace = try render(replacing: true)
    let extra = withReplace.points.height - findOnly.points.height
    #expect(extra > 15)
    #expect(extra < 50)
    #expect(distinctColors(withReplace.bitmap) > 4)
}
