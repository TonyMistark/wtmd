import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 横幅的排版

/// 横幅是给人看的东西：断言「有这两个按钮」证明不了「看起来像条横幅」。
/// 这里把它真的渲染成位图，检查尺寸、配色层次，并把图留在 `/tmp` 方便人眼复核。
@MainActor
private func render(_ change: ExternalChange) throws -> NSBitmapImageRep {
    let renderer = ImageRenderer(
        content: ConflictBanner(change: change, fileName: "第一章.md") { _ in }
    )
    renderer.scale = 2
    renderer.proposedSize = ProposedViewSize(width: 760, height: nil)
    let image = try #require(renderer.nsImage)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    try bitmap.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "/tmp/wtmd-conflict-banner-\(change).png"))
    return bitmap
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

@Test @MainActor func modifiedBannerRendersAsABand() throws {
    let bitmap = try render(.modified)

    #expect(bitmap.pixelsWide == 1520)   // 760pt @2x
    // 一行标题 + 一行说明 + 内边距：大约 2pt，宽到 3 位像素
    #expect(bitmap.pixelsHigh > 30)
    #expect(bitmap.pixelsHigh < 120)
    // 底色、标题、说明、按钮：至少要有这几层才像一条横幅
    #expect(distinctColors(bitmap) > 4)
}

@Test @MainActor func deletedBannerRendersAsABand() throws {
    let bitmap = try render(.deleted)

    #expect(bitmap.pixelsWide == 1520)
    #expect(bitmap.pixelsHigh > 30)
    #expect(bitmap.pixelsHigh < 120)
    #expect(distinctColors(bitmap) > 4)
}
