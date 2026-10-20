import AppKit
import Foundation
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 面板

/// 面板本身只做三件事：说清楚、给动作、别挡路。渲染一次确认版式成立，
/// 再确认它接在 `DocumentStore` 上的那几个出口都对。

private func makeTempDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-crash-panel-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func sampleReport(kind: CrashReport.Kind = .signal) -> CrashReport {
    CrashReport.make(
        capturedAt: Date(timeIntervalSince1970: 1_790_000_000),
        kind: kind,
        signal: kind == .terminated ? nil : "SIGSEGV",
        appVersion: "0.13.0",
        system: "macOS 15.5",
        architecture: "arm64",
        windowCount: 3,
        documentName: "第二章.md",
        body: "# wtmd 崩溃报告\n\n- 信号：SIGSEGV\n\n```\n0   wtmd   0x104a1b2c3 main + 12\n```\n"
    )
}

@MainActor
private func render(_ report: CrashReport?, extraCount: Int = 0) throws -> NSBitmapImageRep {
    let view = CrashPanel(
        report: report,
        extraCount: extraCount,
        copy: { _ in },
        reveal: { _ in },
        openIssue: { _ in },
        dismiss: {}
    )
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 560),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    let size = NSSize(width: 760, height: 560)
    hosting.frame = NSRect(origin: .zero, size: size)
    window.setContentSize(size)
    window.layoutIfNeeded()

    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    return bitmap
}

@MainActor
@Test("渲染一份崩溃报告：版式成立，不是一片空白")
func panelRendersACrash() throws {
    let bitmap = try render(sampleReport())
    // 1x/2x 都要能过：只断言「画出了东西」，不锁死像素
    #expect(bitmap.pixelsWide > 0)
    #expect(bitmap.pixelsHigh > 0)

    var distinct = Set<UInt32>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 6) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let packed = UInt32(color.redComponent * 255) << 16
                | UInt32(color.greenComponent * 255) << 8
                | UInt32(color.blueComponent * 255)
            distinct.insert(packed)
        }
    }
    // 有标题、有分隔线、有代码块底：远不止一种颜色
    #expect(distinct.count > 8)
}

@MainActor
@Test("没有报告时也不炸——空态自己说话")
func panelRendersEmpty() throws {
    let bitmap = try render(nil)
    #expect(bitmap.pixelsWide > 0)
}

@Test("还有更早的记录时说一声，没有就不提")
func extraNoteOnlyWhenThereAreExtras() {
    #expect(CrashPanel.extraNote(0) == nil)
    let note = CrashPanel.extraNote(2)
    #expect(note?.contains("2") == true)
}

// MARK: - 接在 store 上

@MainActor
@Test("启动时打开面板：展示最新一份没看过的")
func storeSurfacesTheNewestPendingReport() throws {
    let drafts = try makeTempDirectory("drafts")
    let crashes = try makeTempDirectory("crashes")
    defer {
        try? FileManager.default.removeItem(at: drafts)
        try? FileManager.default.removeItem(at: crashes)
    }
    let store = CrashStore(directory: crashes)
    let older = CrashReport.make(
        capturedAt: Date(timeIntervalSince1970: 1_790_000_000), kind: .signal,
        signal: "SIGABRT", body: "# older"
    )
    // 用 recordFeedback 落盘，再手动把时间拨早——文件名的 id 不参与排序
    let newer = CrashReport.make(
        capturedAt: Date(timeIntervalSince1970: 1_790_003_600), kind: .signal,
        signal: "SIGSEGV", body: "# newer"
    )
    for report in [older, newer] {
        try report.markdown.write(
            to: crashes.appendingPathComponent("\(report.id).wtmdcrash"),
            atomically: true, encoding: .utf8
        )
    }
    store.reload()

    let documentStore = DocumentStore(draftDirectory: drafts, crashes: store)
    documentStore.showCrashPrompt()

    #expect(documentStore.crashVisible)
    #expect(documentStore.crashReport?.signal == "SIGSEGV")
    #expect(documentStore.crashExtraCount == 1)
    #expect(documentStore.crashFolder?.path == crashes.path)
}

@MainActor
@Test("忽略之后再打开面板：没有可展示的报告了")
func dismissingMarksEverythingSeen() throws {
    let drafts = try makeTempDirectory("drafts")
    let crashes = try makeTempDirectory("crashes")
    defer {
        try? FileManager.default.removeItem(at: drafts)
        try? FileManager.default.removeItem(at: crashes)
    }
    let store = CrashStore(directory: crashes)
    let report = CrashReport.make(kind: .signal, signal: "SIGSEGV", body: "# crash")
    try report.markdown.write(
        to: crashes.appendingPathComponent("\(report.id).wtmdcrash"),
        atomically: true, encoding: .utf8
    )
    store.reload()

    let documentStore = DocumentStore(draftDirectory: drafts, crashes: store)
    documentStore.showCrashPrompt()
    #expect(documentStore.crashReport != nil)

    documentStore.dismissCrashPrompt()
    #expect(!documentStore.crashVisible)
    #expect(documentStore.crashReport == nil)
}
