import Foundation
import Testing
@testable import wtmd

/// 记录「工作区通知了文档层什么」。
@MainActor
private final class Recorder: WorkspaceFileEvents {
    var moves: [(from: URL, to: URL)] = []

    func documentDidMove(from old: URL, to new: URL) {
        moves.append((old, new))
    }

    func documentWasTrashed(at url: URL) {
        // not exercised here
    }
}

// MARK: - 纯函数：按「同大小、同修改时间」配对

/// 消失侧的清单必须来自**文件还在的时候**：`resolvingSymlinksInPath` 对已经
/// 不存在的路径会放弃解析、原样返回——同一个文件在消失前后会拿到两种拼法，
/// 现场归一等于拿一把会变的尺子去比。
@MainActor
@Test func relinkMatchesARenameInsideItsOwnDirectory() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = try write("note.md", in: dir, content: "# 原文")
    let roster = [canonical(old): FileRecord(url: old, stat: FileStat(url: old)!)]
    let new = dir.appendingPathComponent("笔记.md")
    try FileManager.default.moveItem(at: old, to: new)

    let pairs = WorkspaceStore.relinkedPaths(
        oldRecords: roster,
        newFiles: [canonical(new): new]
    )

    #expect(pairs.count == 1)
    #expect(pairs.first?.old == old)
    #expect(pairs.first?.new == new)
}

/// 文件被移进了别的文件夹：同目录里没有候选时，别的目录里同指纹的那个也算它。
@MainActor
@Test func relinkMatchesAMoveIntoAnotherFolder() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try makeDirectory("archive", in: dir)
    let old = try write("note.md", in: dir, content: "# 归档之前")
    let roster = [canonical(old): FileRecord(url: old, stat: FileStat(url: old)!)]
    let new = archive.appendingPathComponent("note.md")
    try FileManager.default.moveItem(at: old, to: new)

    let pairs = WorkspaceStore.relinkedPaths(
        oldRecords: roster,
        newFiles: [canonical(new): new]
    )

    #expect(pairs.count == 1)
    #expect(pairs.first?.new == new)
}

/// 两个同指纹候选都在：同目录的优先——改名是常态，跨目录撞指纹是巧合，
/// 巧合不该盖过常态。
@MainActor
@Test func relinkPrefersTheCandidateInTheSameDirectory() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try makeDirectory("archive", in: dir)
    let old = try write("note.md", in: dir, content: "# 同一个指纹")
    let roster = [canonical(old): FileRecord(url: old, stat: FileStat(url: old)!)]
    let twinHere = dir.appendingPathComponent("改名.md")
    let twinThere = archive.appendingPathComponent("far.md")
    try FileManager.default.copyItem(at: old, to: twinHere)
    try FileManager.default.copyItem(at: old, to: twinThere)

    let pairs = WorkspaceStore.relinkedPaths(
        oldRecords: roster,
        newFiles: [canonical(twinHere): twinHere, canonical(twinThere): twinThere]
    )

    #expect(pairs.count == 1)
    #expect(pairs.first?.new == twinHere)
}

/// 没有同指纹的候选（文件真被删了，或换了内容）：配不上就不配，宁可走冲突流程。
@MainActor
@Test func relinkLeavesUnmatchedVanishedFilesAlone() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = try write("note.md", in: dir, content: "# 原文")
    let roster = [canonical(old): FileRecord(url: old, stat: FileStat(url: old)!)]
    let stranger = try write("stranger.md", in: dir, content: "# 别的文件")

    let pairs = WorkspaceStore.relinkedPaths(
        oldRecords: roster,
        newFiles: [canonical(stranger): stranger]
    )

    #expect(pairs.isEmpty)
}

/// 指纹必须两个条件同时成立：大小一样、修改时间不一样的候选不算它——
/// 「改了名又改了内容」和「恰好同大的别的新文件」都不该被认走。
@MainActor
@Test func relinkRejectsSameSizeButDifferentMtimeCandidates() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = try write("note.md", in: dir, content: "# 原文")
    let roster = [canonical(old): FileRecord(url: old, stat: FileStat(url: old)!)]
    let rewritten = dir.appendingPathComponent("笔记.md")
    try "# 完全不同的内容，长度恰好相同！".write(to: rewritten, atomically: true, encoding: .utf8)
    // mtime 挪到昨天：肯定对不上
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: rewritten.path
    )

    let pairs = WorkspaceStore.relinkedPaths(
        oldRecords: roster,
        newFiles: [canonical(rewritten): rewritten]
    )

    #expect(pairs.isEmpty)
}

/// 上一次扫描的清单里没有它（出现又消失，从没被记录过）：没有证据就不认亲。
@MainActor
@Test func relinkLeavesUnrecordedFilesAlone() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = try write("note.md", in: dir, content: "# 原文")
    let new = dir.appendingPathComponent("笔记.md")
    try FileManager.default.moveItem(at: old, to: new)

    let pairs = WorkspaceStore.relinkedPaths(
        oldRecords: [:],
        newFiles: [canonical(new): new]
    )

    #expect(pairs.isEmpty)
}

// MARK: - store 层：访达里发生的事

/// 访达里改名当前文档：一次 reload 就该静默跟上——高亮、树、文档层全走既有的
/// remap 链路，不弹横幅。
@MainActor
@Test func externalRenameFollowsSilentlyThroughTheStore() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("note.md", in: dir, content: "# 原文")

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    let recorder = Recorder()
    workspace.fileEvents = recorder
    workspace.open(dir)
    workspace.select(file)

    let renamed = dir.appendingPathComponent("笔记.md")
    try FileManager.default.moveItem(at: file, to: renamed)
    // The watcher's callback is a plain reload() — simulated here.
    workspace.reload()

    #expect(PathKey.isSame(workspace.selection ?? URL(fileURLWithPath: "/"), renamed))
    #expect(workspace.tree?.children.map(\.name) == ["笔记.md"])
    #expect(recorder.moves.count == 1)
    #expect(PathKey.isSame(recorder.moves.first?.from ?? URL(fileURLWithPath: "/"), file))
    #expect(PathKey.isSame(recorder.moves.first?.to ?? URL(fileURLWithPath: "/"), renamed))
}

/// 全链路：工作区发现外部改名 → 文档层路径跟着走，内容、脏标记一个字不动。
@MainActor
@Test func externalRenameReachesTheDocumentStore() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("a.md", in: dir, content: "# 原文")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: file)
    store.textDidChange("# 原文\n\n还在写")

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    workspace.fileEvents = store
    workspace.open(dir)
    workspace.select(file)

    let renamed = dir.appendingPathComponent("b.md")
    try FileManager.default.moveItem(at: file, to: renamed)
    workspace.reload()

    #expect(PathKey.isSame(store.fileURL ?? URL(fileURLWithPath: "/"), renamed))
    #expect(store.text == "# 原文\n\n还在写")
    #expect(store.isDirty)
    #expect(store.externalChange == nil)
    // 基线跟到了新路径：下一次自动保存不该被误判成「文件已被删除」
    store.flushPendingSave()
    #expect(try String(contentsOf: renamed, encoding: .utf8) == "# 原文\n\n还在写")
}

/// 访达里删掉当前文档：没有同指纹的文件可认，维持原判——
/// 下一次写盘时按既有冲突流程处理。
@MainActor
@Test func externalDeleteDoesNotRelink() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("note.md", in: dir, content: "# 原文")

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    let recorder = Recorder()
    workspace.fileEvents = recorder
    workspace.open(dir)
    workspace.select(file)

    try FileManager.default.removeItem(at: file)
    workspace.reload()

    #expect(workspace.selection == nil)
    #expect(recorder.moves.isEmpty)
}

/// 树内改名（自己发起）：显式 remap 之后再 reload 不得把同一对路径再报一遍。
@MainActor
@Test func internalRenameIsNotRelinkedTwice() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("note.md", in: dir, content: "# 原文")

    let workspace = WorkspaceStore()
    defer { workspace.close() }
    let recorder = Recorder()
    workspace.fileEvents = recorder
    workspace.open(dir)
    workspace.select(file)

    #expect(workspace.rename(file, to: " renamed ") == nil)

    #expect(recorder.moves.count == 1)
    #expect(workspace.selection?.lastPathComponent == "renamed.md")
}

// MARK: - 最近文件：启动清理

/// 启动时把不存在的路径清出列表，而且**写回 defaults**——
/// 只过滤不落盘的话，每次启动都会从同一份旧账开始。
@Test func recentFilesPruneMissingEntriesAtLaunchAndPersist() throws {
    let suiteName = "wtmd-recent-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let alive = try write("alive.md", in: dir)
    let gone = dir.appendingPathComponent("gone.md")
    let gone2 = dir.appendingPathComponent("gone 2.md") // 带空格：路径编码也要过得去

    defaults.set([gone.absoluteString, alive.absoluteString, gone2.absoluteString],
                 forKey: "wtmd.recentFiles")

    let recents = RecentFiles(userDefaults: defaults)

    #expect(recents.urls == [alive])
    // 旧账已经被清掉，再启动一次也不会回来
    #expect(defaults.stringArray(forKey: "wtmd.recentFiles") == [alive.absoluteString])
    let second = RecentFiles(userDefaults: defaults)
    #expect(second.urls == [alive])
}

/// 运行中也可以主动清一次：全部健在时不落盘、不惊动任何人。
@Test func recentFilesPruneMissingIsANoOpWhenEverythingExists() throws {
    let suiteName = "wtmd-recent-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let alive = try write("alive.md", in: dir)

    let recents = RecentFiles(userDefaults: defaults)
    recents.add(alive)
    let before = defaults.stringArray(forKey: "wtmd.recentFiles")

    #expect(!recents.pruneMissing())
    #expect(defaults.stringArray(forKey: "wtmd.recentFiles") == before)
}

// MARK: - 辅助

private func canonical(_ url: URL) -> String {
    PathKey.canonical(url)
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-relink-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeDirectory(_ name: String, in parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ name: String, in directory: URL, content: String = "# 文档") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}
