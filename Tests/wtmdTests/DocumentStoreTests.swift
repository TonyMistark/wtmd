import Foundation
import Testing
@testable import wtmd

// MARK: - 欢迎页与新建文档

/// 回归用例：欢迎页上的「记下思绪」点下去曾经毫无反应。
///
/// 原因是欢迎页的显示条件写成 `text.isEmpty && fileURL == nil`，而 `newDocument()`
/// 恰好把正文清空、文件置 nil —— 条件依然成立，欢迎页原地不动，看起来就像按钮坏了。
/// 判据收进 `store.showsWelcome`（多了显式的会话状态）之后，按钮才会让位给编辑器。
///
/// 全部用例都注入临时草稿目录，绝不读写用户的真实草稿。
@MainActor
@Test func newDocumentLeavesWelcomeScreen() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)

    // 走到欢迎页的前置状态：正文被清空、没有文件、尚未开始写作
    store.textDidChange("")
    #expect(store.showsWelcome)

    // 点击「记下思绪」
    store.newDocument()

    #expect(!store.showsWelcome)
    #expect(store.text.isEmpty)
    #expect(store.fileURL == nil)
    #expect(store.mode == .edit)
}

@MainActor
@Test func draftIsRestoredOnLaunch() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "# 未保存的思绪".write(
        to: dir.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8
    )

    let store = DocumentStore(draftDirectory: dir)
    #expect(store.text == "# 未保存的思绪")
    #expect(!store.showsWelcome)
}

/// 欢迎页没有被本次修复弄丢：清空正文且从未开始写作时，它仍然可见。
@MainActor
@Test func clearingAllTextFallsBackToWelcome() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)

    #expect(!store.showsWelcome)
    store.textDidChange("")
    #expect(store.showsWelcome)
}

/// 新建文档清掉的是「未保存的草稿」——既有设计（也是草稿文件会消失的原因），
/// 顺带守住注入的目录边界：清理只发生在自己的目录里。
@MainActor
@Test func newDocumentClearsDraftInItsOwnDirectory() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let draft = dir.appendingPathComponent("draft.md")
    try "尚未保存的思绪".write(to: draft, atomically: true, encoding: .utf8)

    let store = DocumentStore(draftDirectory: dir)
    #expect(store.text == "尚未保存的思绪")

    store.newDocument()
    #expect(!FileManager.default.fileExists(atPath: draft.path))
    #expect(store.text.isEmpty)
}

@MainActor
@Test func openingAFileStartsWritingSession() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("doc.md")
    try "# 打开的文件".write(to: file, atomically: true, encoding: .utf8)

    // open(url:) 会写「最近文件」，用完把原值放回去，避免测试污染真实偏好设置
    let key = "wtmd.recentFiles"
    let original = UserDefaults.standard.stringArray(forKey: key)
    defer {
        if let original { UserDefaults.standard.set(original, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    let store = DocumentStore(draftDirectory: dir)
    store.open(url: file)

    #expect(store.text == "# 打开的文件")
    #expect(store.fileURL == file)
    #expect(!store.showsWelcome)
}

// MARK: - 辅助

private func makeTempDraftDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
