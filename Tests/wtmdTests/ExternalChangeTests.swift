import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 磁盘与编辑器不一致

/// 自动保存是「读者没下命令也在写盘」，所以它必须先在写之前确认磁盘还是上次看到的
/// 那个版本。这组用例守的就是这条：**别人的改动不会被一声不响地盖掉**。
private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-conflict-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeIsolatedSession() -> (session: Session, suite: String) {
    let suite = "wtmd.tests.conflict.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (Session(defaults: defaults), suite)
}

/// `open(url:)` 会写「最近文件」，用完把原值放回去。
private func preserveRecentFiles() -> () -> Void {
    let key = "wtmd.recentFiles"
    let original = UserDefaults.standard.stringArray(forKey: key)
    return {
        if let original { UserDefaults.standard.set(original, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 15,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("等待超时（\(Int(timeout))s）：\(description)")
}

private func write(_ content: String, to url: URL) throws {
    try content.write(to: url, atomically: true, encoding: .utf8)
}

private func contents(of url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

/// 在别处（同步盘、另一个编辑器、`git checkout`）改了这个文件。
///
/// 这条是整组用例的基准：改动进来之后，自动保存必须停下来，磁盘保持别人的版本。
@MainActor
@Test func autosaveRefusesToOverwriteAnExternalEdit() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 0)
    store.open(url: file)
    try write("别人的版本", to: file)

    store.textDidChange("我的改动")
    await waitUntil("识别出外部修改") { store.externalChange == .modified }

    #expect(contents(of: file) == "别人的版本")
    #expect(store.isDirty)
}

/// ⌘S 也是写盘，同样不能盖掉别人刚写的版本；但它不该弹窗——横幅与自动保存共用
/// 同一个待决状态，读者在哪里看到都一样。
@MainActor
@Test func explicitSaveAlsoRefusesToOverwriteAnExternalEdit() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 600_000_000_000)
    store.open(url: file)
    try write("别人的版本", to: file)
    store.textDidChange("我的改动")

    store.save()

    #expect(store.externalChange == .modified)
    #expect(contents(of: file) == "别人的版本")
}

@MainActor
@Test func keepingTheLocalVersionOverwritesTheDisk() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 600_000_000_000)
    store.open(url: file)
    try write("别人的版本", to: file)
    store.textDidChange("我的改动")
    // 冲突是在「要写盘」的那一刻判定的，这里用 flush 触发，不必等防抖
    store.flushPendingSave()
    #expect(store.externalChange == .modified)

    store.resolveExternalChange(.keepLocal)

    #expect(contents(of: file) == "我的改动")
    #expect(store.externalChange == nil)
    #expect(!store.isDirty)
}

/// 选「载入磁盘版本」之后，排队中的那次自动保存不能又把旧内容写回去——
/// 撤销动作要覆盖到已经排队的东西，而不只是屏幕上的字。
@MainActor
@Test func reloadingTakesTheDiskVersionAndCancelsPendingSaves() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 200_000_000)
    store.open(url: file)
    try write("别人的版本", to: file)
    store.textDidChange("我的改动")
    await waitUntil("识别出外部修改") { store.externalChange == .modified }

    store.resolveExternalChange(.reloadDisk)

    #expect(store.text == "别人的版本")
    #expect(!store.isDirty)
    #expect(store.externalChange == nil)

    // 等过两次防抖窗口：旧内容不该悄悄再写回磁盘
    try? await Task.sleep(nanoseconds: 500_000_000)
    #expect(contents(of: file) == "别人的版本")
}

@MainActor
@Test func aDeletedFileIsReportedAsDeleted() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 0)
    store.open(url: file)
    try FileManager.default.removeItem(at: file)

    store.textDidChange("我的改动")
    await waitUntil("识别出文件被删") { store.externalChange == .deleted }

    // 自动保存不该把一个刚被删掉的文件又「复活」出来
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@MainActor
@Test func keepingAsDraftDetachesTheDocument() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (session, suite) = makeIsolatedSession()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let store = DocumentStore(
        draftDirectory: dir, autoSaveDelay: 600_000_000_000, session: session
    )
    store.open(url: file)
    try FileManager.default.removeItem(at: file)
    store.textDidChange("我的改动")
    store.flushPendingSave()
    #expect(store.externalChange == .deleted)

    store.resolveExternalChange(.keepAsDraft)

    #expect(store.fileURL == nil)
    #expect(store.externalChange == nil)
    #expect(session.openFileURL == nil)
    #expect(contents(of: dir.appendingPathComponent("draft.md")) == "我的改动")
}

/// 反向的守门用例：自己写盘之后基线要跟着刷新。忘了刷新的话，**每一次**自动保存
/// 都会被判成冲突，横幅再也关不掉——那比不检测还糟。
@MainActor
@Test func anOrdinaryAutosaveRaisesNoConflict() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 0)
    store.open(url: file)

    store.textDidChange("第一次改")
    await waitUntil("第一次落盘") { contents(of: file) == "第一次改" }

    store.textDidChange("第二次改")
    await waitUntil("第二次落盘") { contents(of: file) == "第二次改" }

    #expect(store.externalChange == nil)
    #expect(!store.isDirty)
}

/// 冲突没解决就关窗口：磁盘那份不动，自己的改动进草稿——下次启动还能看到，
/// 而不是随窗口一起蒸发。
@MainActor
@Test func quittingWithAnUnresolvedConflictPreservesTheLocalCopy() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (session, suite) = makeIsolatedSession()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let restoreRecent = preserveRecentFiles()
    defer { restoreRecent() }

    let file = dir.appendingPathComponent("稿.md")
    try write("初稿", to: file)

    let store = DocumentStore(
        draftDirectory: dir, autoSaveDelay: 600_000_000_000, session: session
    )
    store.open(url: file)
    try write("别人的版本", to: file)
    store.textDidChange("我的改动")
    store.flushPendingSave()
    #expect(store.externalChange == .modified)

    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

    #expect(contents(of: file) == "别人的版本")
    #expect(contents(of: dir.appendingPathComponent("draft.md")) == "我的改动")
    #expect(session.openFileURL == nil)
}
