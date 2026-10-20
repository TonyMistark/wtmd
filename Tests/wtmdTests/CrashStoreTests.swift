import Foundation
import Testing
@testable import wtmd

// MARK: - 账房

/// 收现场、列清单、标看过了、删掉。全部用临时目录：测试绝不碰真实的
/// `~/Library/Application Support/wtmd/crashes`。

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-crashes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 造一个「上次崩溃留下的」半成品，形状与 `CrashCatcher` 写出来的一致。
@discardableResult
private func writeInflight(
    in directory: URL,
    name: String = ".inflight-999-1790000000.raw",
    signal: String = "SIGSEGV",
    frames: Bool = true
) throws -> URL {
    var text = "WTMDCRASH 1\nbase 0x104000000\nkind signal\nsignal \(signal)\nframes\n"
    if frames {
        text += "0   wtmd   0x0000000104a1b2c3 main + 12\n"
        text += "1   wtmd   0x0000000104a1c001 start + 1\n"
    }
    text += "end\n"
    let url = directory.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func writeBreadcrumbs(_ lines: [String], in directory: URL) throws {
    try (lines.joined(separator: "\n") + "\n")
        .write(to: directory.appendingPathComponent("breadcrumbs.log"), atomically: true, encoding: .utf8)
}

// MARK: - 收

@MainActor
@Test("半成品整理成报告：原件删掉，轨迹与窗口数补进去")
func harvestTurnsInflightIntoReport() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inflight = try writeInflight(in: root)
    try writeBreadcrumbs([
        "15:02:11 launch wtmd 0.13.0",
        "15:02:12 windows 3",
        "15:02:40 doc 第二章.md",
    ], in: root)

    let store = CrashStore(directory: root)
    store.harvest()

    #expect(store.reports.count == 1)
    let report = try #require(store.reports.first)
    #expect(report.kind == .signal)
    #expect(report.signal == "SIGSEGV")
    #expect(report.windowCount == 3)
    #expect(report.documentName == "第二章.md")
    #expect(report.markdown.contains("main + 12"))
    // 半成品不该留在盘上：留下来下次启动会再报一次
    #expect(!FileManager.default.fileExists(atPath: inflight.path))
    #expect(report.fileURL?.pathExtension == "wtmdcrash")
}

@MainActor
@Test("只有头的半成品：报「没正常退出」，不假装抓到了栈")
func harvestHandlesForceQuit() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeInflight(in: root, frames: false)

    let store = CrashStore(directory: root)
    store.harvest()

    let report = try #require(store.reports.first)
    #expect(report.kind == .terminated)
    #expect(report.signal == nil)
    #expect(report.explanation.contains("没抓到现场"))
}

@MainActor
@Test("没有半成品时什么都不做，也不炸")
func harvestOnCleanDirectoryIsQuiet() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = CrashStore(directory: root)
    store.harvest()
    #expect(store.reports.isEmpty)
    #expect(!store.hasPending)
}

// MARK: - 清单

@MainActor
@Test("看过了就不再问，但文件还在")
func markSeenKeepsTheFile() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeInflight(in: root)

    let store = CrashStore(directory: root)
    store.harvest()
    let report = try #require(store.reports.first)
    #expect(store.hasPending)

    store.markSeen(report.id)
    #expect(!store.hasPending)
    // 「忽略」是「别再问我」，不是「删掉证据」：读者还能在访达里找到它
    #expect(FileManager.default.fileExists(atPath: report.fileURL!.path))

    // 重新读目录：.seen 标记要能把「看过」带过来，否则下次启动又问一遍
    let reopened = CrashStore(directory: root)
    reopened.reload()
    #expect(!reopened.hasPending)
}

@MainActor
@Test("删掉一份：文件与标记都不留")
func removeDropsFileAndMarker() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeInflight(in: root)

    let store = CrashStore(directory: root)
    store.harvest()
    let report = try #require(store.reports.first)
    store.markSeen(report.id)
    store.remove(report.id)

    #expect(store.reports.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@MainActor
@Test("只留最近若干份：报告是给人看的，不是日志归档")
func pruneKeepsTheNewest() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = CrashStore(directory: root, clock: { Date(timeIntervalSince1970: 1_790_000_000) })
    for index in 0..<5 {
        let report = CrashReport.make(
            id: "2026101\(index)-120000-aaaa",
            capturedAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(index) * 3600),
            kind: .signal, signal: "SIGSEGV", body: "# \(index)"
        )
        try report.markdown.write(
            to: root.appendingPathComponent("\(report.id).wtmdcrash"),
            atomically: true, encoding: .utf8
        )
    }
    store.reload()
    #expect(store.reports.count == 5)

    let limited = CrashStore(
        directory: root, clock: { Date(timeIntervalSince1970: 1_790_000_000) },
        maxReports: 2, maxAge: .greatestFiniteMagnitude
    )
    limited.reload()
    limited.prune()
    #expect(limited.reports.count == 2)
    #expect(limited.reports.first?.id == "20261010-120000-aaaa")
}

@MainActor
@Test("过期的清掉：三个月前的报告留着没有意义")
func pruneDropsOldReports() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = CrashReport.make(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .signal, signal: "SIGSEGV", body: "# old"
    )
    try old.markdown.write(
        to: root.appendingPathComponent("\(old.id).wtmdcrash"), atomically: true, encoding: .utf8
    )

    let store = CrashStore(
        directory: root, clock: { Date(timeIntervalSince1970: 1_790_000_000) }
    )
    store.reload()
    store.prune()
    #expect(store.reports.isEmpty)
}

// MARK: - 手动反馈

@MainActor
@Test("报告问题：留一份带环境的说明，并且不再弹窗追问")
func feedbackIsRecordedAndSeen() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = CrashStore(directory: root)
    let report = store.recordFeedback(note: "", documentName: "第一章.md")

    #expect(report.kind == .feedback)
    #expect(report.markdown.contains("第一章.md"))
    #expect(store.reports.count == 1)
    // 是读者主动点出来的，不用下次启动再问一遍
    #expect(!store.hasPending)
}

@MainActor
@Test("报告里的 issue 链接指向这个仓库的新建页面")
func issueURLPointsAtThisRepository() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CrashStore(directory: root)
    let report = store.recordFeedback(note: "切到分栏时会顿一下", documentName: nil)

    let url = try #require(store.issueURL(for: report))
    #expect(url.host == "github.com")
    #expect(url.path == "/TonyMistark/wtmd/issues/new")
    #expect(url.absoluteString.contains("title="))
    #expect(url.absoluteString.contains("body="))
}
