import AppKit
import Foundation
import Testing

@testable import wtmd

// MARK: - 另存为：落点被别窗占着

/// 另存为落在另一扇窗正在写的那篇上：不写，并且把话说清楚。
///
/// 写下去不会报错，只会让那扇窗的字在下次落盘之前悄悄消失——所以宁可拦住。
@MainActor
@Test func savingOntoAFileAnotherWindowIsWritingIsRefused() throws {
    let rig = try GuardRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 原稿\n")
    let owner = rig.newWindow()
    let other = rig.newWindow()
    owner.store.open(url: file)

    other.store.textDidChange("# 我这一版\n")
    var reported: URL?
    other.store.reportHeldSaveTarget = { reported = $0 }

    let saved = other.store.save(to: file)
    let onDisk = try String(contentsOf: file, encoding: .utf8)

    #expect(saved == false)
    #expect(onDisk == "# 原稿\n", "另一扇窗的稿子不该被盖掉")
    #expect(other.store.fileURL == nil, "没写成功就不该认这个落点")
    #expect(reported.map { PathKey.isSame($0, file) } == true)
}

/// 拦住的是「还有人在写」，不是「这个路径曾经开过」：那扇窗关掉之后就能存。
@MainActor
@Test func savingOntoItIsAllowedOnceThatWindowIsGone() throws {
    let rig = try GuardRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 原稿\n")
    let owner = rig.newWindow()
    let other = rig.newWindow()
    owner.store.open(url: file)
    rig.coordinator.windowDidClose(owner)

    other.store.textDidChange("# 接手\n")
    let saved = other.store.save(to: file)
    let onDisk = try String(contentsOf: file, encoding: .utf8)

    #expect(saved)
    #expect(onDisk == "# 接手\n")
    #expect(other.store.fileURL.map { PathKey.isSame($0, file) } == true)
}

// MARK: - 写盘兜底：两扇窗在写同一篇

/// 同一篇被两扇窗持有（升级前留下的旧账）：自动保存不写盘，本地这一版进副本库。
@MainActor
@Test func autosaveStopsAndArchivesWhenAnotherWindowHoldsTheSameFile() throws {
    let rig = try GuardRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 原稿\n")
    let writer = rig.newWindow()
    let squatter = rig.newWindow()
    writer.store.open(url: file)
    // UI 上到不了这个状态（打开会跳过去），这里直接写登记表，模拟「绕过 UI」。
    rig.shared.openDocuments.update(file, for: squatter.id)
    #expect(writer.store.isHeldElsewhere(file))

    writer.store.textDidChange("# 改过的\n")
    writer.store.flushPendingSave()

    let onDisk = try String(contentsOf: file, encoding: .utf8)
    #expect(writer.store.externalChange == .heldElsewhere)
    #expect(onDisk == "# 原稿\n", "盘上那份是另一扇窗正看着的，不能盖")

    let entries = rig.shared.conflicts.entries()
    #expect(entries.count == 1, "写不下去的字必须有个去处")
    #expect(entries.first.flatMap(rig.shared.conflicts.content(of:)) == "# 改过的\n")
}

/// 读者选了「保留我的修改」之后就不再问：接着写，写盘前的 mtime 核对仍然兜着。
@MainActor
@Test func theHoldIsSaidOnceAndThenTheReaderGetsTheirWay() throws {
    let rig = try GuardRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 原稿\n")
    let writer = rig.newWindow()
    let squatter = rig.newWindow()
    writer.store.open(url: file)
    rig.shared.openDocuments.update(file, for: squatter.id)

    writer.store.textDidChange("# 我的版本\n")
    writer.store.flushPendingSave()
    #expect(writer.store.externalChange == .heldElsewhere)

    writer.store.resolveExternalChange(.keepLocal)
    #expect(writer.store.externalChange == nil)
    #expect(try String(contentsOf: file, encoding: .utf8) == "# 我的版本\n")

    writer.store.textDidChange("# 又改了一次\n")
    writer.store.flushPendingSave()

    #expect(writer.store.externalChange == nil, "同一件事不该每敲一次字问一遍")
    #expect(try String(contentsOf: file, encoding: .utf8) == "# 又改了一次\n")
}

/// ⌘S 也是写盘：同一道核对不能只在自动保存那条路上做。
@MainActor
@Test func commandSaveIsHeldBackToo() throws {
    let rig = try GuardRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 原稿\n")
    let writer = rig.newWindow()
    let squatter = rig.newWindow()
    writer.store.open(url: file)
    rig.shared.openDocuments.update(file, for: squatter.id)

    writer.store.textDidChange("# 我的版本\n")
    // 提示换成记账的口子：真的 `NSAlert` 是模态的，万一这条路径走岔了会把测试挂住。
    writer.store.reportHeldSaveTarget = { _ in }
    writer.store.save()

    let onDisk = try String(contentsOf: file, encoding: .utf8)
    #expect(writer.store.externalChange == .heldElsewhere)
    #expect(onDisk == "# 原稿\n")
}

// MARK: - 辅助

/// 两扇窗、一份临时 defaults、一个临时副本库——绝不碰真实数据。
@MainActor
private struct GuardRig {
    let defaultsName: String
    let defaults: UserDefaults
    let root: URL
    let shared: SharedAppEnvironment
    let coordinator: WindowCoordinator

    init() throws {
        defaultsName = "wtmd.tests.guard.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        shared = SharedAppEnvironment(
            writingStats: WritingStats(defaults: defaults),
            recentFiles: RecentFiles(userDefaults: defaults),
            conflicts: ConflictArchive(directory: root.appendingPathComponent("conflicts")),
            history: DocumentHistory(directory: root.appendingPathComponent("history"))
        )
        coordinator = WindowCoordinator(
            shared: shared,
            primary: WindowModel(
                session: Session(persist: false, defaults: defaults),
                shared: shared,
                draftDirectory: root.appendingPathComponent("primary", isDirectory: true),
                startsBlank: true
            ),
            draftRoot: root,
            defaults: defaults
        )
    }

    func newWindow() -> WindowModel {
        coordinator.makeExtraWindow(inheriting: nil)
    }

    func makeFile(_ name: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
