import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 快捷键设置页的排版

/// 这张表要一眼看出「哪条命令、现在是什么键、怎么改」；渲染成位图供人眼复核。
@MainActor
private func render() throws -> (bitmap: NSBitmapImageRep, points: CGSize) {
    let suite = "wtmd.tests.snapshot.shortcuts.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let overrides = ShortcutOverrides(defaults: defaults)
    // 预置一条改派，让「恢复默认」按钮也出现在画面里
    overrides.assign(RecordedShortcut(key: "g", modifiers: ["command"]), for: .exportWord)

    let view = ShortcutSettingsView().environmentObject(overrides)
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 520),
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
        .write(to: URL(fileURLWithPath: "/tmp/wtmd-shortcut-settings.png"))
    return (bitmap, fitted)
}

@Test @MainActor func theShortcutSettingsRenderAsATable() throws {
    let (bitmap, points) = try render()
    #expect(points.width == 480)
    #expect(points.height > 200)
    // 足够多的颜色：正文、辅助文字、按钮、改派后的强调色
    var seen = Set<UInt32>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            seen.insert(
                UInt32(color.redComponent * 255) << 16
                    | UInt32(color.greenComponent * 255) << 8
                    | UInt32(color.blueComponent * 255)
            )
        }
    }
    #expect(seen.count > 4)
}
