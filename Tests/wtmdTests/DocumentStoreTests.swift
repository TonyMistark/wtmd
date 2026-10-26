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

/// 从 Finder 打开文件时靠它判断「能不能占用这扇窗」。
///
/// 欢迎页的文案就存在 `text` 里，所以「有没有字」必须靠 `hasStartedWriting`
/// 说话；只看 `text.isEmpty` 会把刚起来的窗当成「有未保存的稿子」，
/// 于是每打开一个文件都多开一扇空窗。
@MainActor
@Test func isUntouchedMeansTheWelcomePageIsStillUntouched() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)

    #expect(store.text == DocumentStore.welcomeMarkdown)
    #expect(store.isUntouched)

    store.textDidChange("# 我的稿子")
    #expect(!store.isUntouched)

    // 打开过文件的窗也不算空窗——哪怕那篇是空的。
    let other = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: other) }
    let opened = DocumentStore(draftDirectory: other)
    let file = other.appendingPathComponent("a.md")
    try "# a".write(to: file, atomically: true, encoding: .utf8)
    opened.open(url: file)
    #expect(!opened.isUntouched)
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

// MARK: - 打开/新建的默认视图（#241）

/// recentFiles 备份恢复的公共小抄：open(url:) 会写「最近文件」。
@MainActor
private func withRecentFilesBackup(_ body: () throws -> Void) rethrows {
    let key = "wtmd.recentFiles"
    let original = UserDefaults.standard.stringArray(forKey: key)
    defer {
        if let original { UserDefaults.standard.set(original, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    try body()
}

/// 打开一篇有字的稿子，最常见的意图是读：默认先进成文（阅读）。
@MainActor
@Test func openingANonEmptyFileDefaultsToPreview() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("doc.md")
    try "# 已写好的稿子\n\n正文一段".write(to: file, atomically: true, encoding: .utf8)

    let store = DocumentStore(draftDirectory: dir)
    try withRecentFilesBackup {
        store.open(url: file)
    }

    #expect(store.fileURL == file)
    #expect(store.mode == .preview)
}

/// 空文件没有可读的预览：留在思绪（源码），等人来写。
@MainActor
@Test func openingAnEmptyFileStaysInSourceMode() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("empty.md")
    try "  \n\n  ".write(to: file, atomically: true, encoding: .utf8)

    let store = DocumentStore(draftDirectory: dir)
    try withRecentFilesBackup {
        store.open(url: file)
    }

    #expect(store.mode == .edit)
}

/// 带行列跳转的打开（⌘⇧F 命中）必须落源码——预览没有行号可落。
@MainActor
@Test func openingWithAJumpRequestStaysInSourceMode() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("doc.md")
    try "第一行\n第二行 needle".write(to: file, atomically: true, encoding: .utf8)

    let store = DocumentStore(draftDirectory: dir)
    try withRecentFilesBackup {
        store.open(
            url: file,
            jumpingTo: JumpRequest(id: "j", line: 1, column: 4, length: 6, slug: "")
        )
    }

    #expect(store.mode == .edit)
    #expect(store.editorJump?.line == 1)
}

/// 读者已经在分栏/预览里：默认不抢当前的选择。
@MainActor
@Test func previewDefaultDoesNotFightAnExplicitChoice() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("doc.md")
    try "# 有字的稿子".write(to: file, atomically: true, encoding: .utf8)

    let store = DocumentStore(draftDirectory: dir)
    store.setMode(.split)
    try withRecentFilesBackup {
        store.open(url: file)
    }
    #expect(store.mode == .split)

    store.setMode(.preview)
    let other = dir.appendingPathComponent("other.md")
    try "# 另一篇".write(to: other, atomically: true, encoding: .utf8)
    try withRecentFilesBackup {
        store.open(url: other)
    }
    #expect(store.mode == .preview)
}

/// 启动恢复上次打开的稿子 = 同样是「打开一篇非空的文件」：先进成文。
@MainActor
@Test func launchRestoreOfANonEmptyFileOpensInPreview() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("last.md")
    try "# 上次的稿子\n\n还有正文".write(to: file, atomically: true, encoding: .utf8)

    let suite = "wtmd.tests.mode-defaults.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = Session(persist: true, defaults: defaults)
    session.setOpenFile(file)

    let store = DocumentStore(draftDirectory: dir, session: session)
    #expect(store.fileURL == file)
    #expect(store.mode == .preview)
}

/// 欢迎页不算「打开了一篇稿子」：它是要写的说明书，留在思绪。
@MainActor
@Test func welcomeScreenStaysInSourceMode() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)
    #expect(store.text == DocumentStore.welcomeMarkdown)
    #expect(store.mode == .edit)
}

/// 新建文档 = 要写了：专注模式点亮（应用级开关，store 只借来按一下）。
@MainActor
@Test func newDocumentTurnsOnFocusMode() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let suite = "wtmd.tests.mode-defaults.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let writing = WritingSettings(defaults: defaults)
    #expect(writing.focusMode == false)

    let store = DocumentStore(draftDirectory: dir)
    store.writing = writing
    store.newDocument()

    #expect(store.mode == .edit)
    #expect(writing.focusMode == true)

    // 读者手动关掉之后，新建仍然要点亮——「新建」本身就是进入写作的意图。
    writing.focusMode = false
    store.newDocument()
    #expect(writing.focusMode == true)
}

/// 没接 writing 设置的 store（测试默认）新建时不会碰真实的偏好设置。
@MainActor
@Test func newDocumentWithoutWritingSettingsStaysHarmless() throws {
    let dir = try makeTempDraftDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DocumentStore(draftDirectory: dir)
    store.writing = nil
    store.newDocument()
    #expect(store.mode == .edit)
}

// MARK: - 辅助

private func makeTempDraftDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
