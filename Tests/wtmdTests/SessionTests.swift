import Foundation
import Testing
@testable import wtmd

// MARK: - 会话记录本身

/// 会话写的是 `UserDefaults`，**必须注入独立的 suite**：测试绝不能碰用户真实的
/// 会话——那会让下一次启动 restoring 到一个临时目录里的文件。
private func makeIsolatedDefaults() -> (defaults: UserDefaults, suite: String) {
    let suite = "wtmd.tests.session.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}

private func makePosition(
    location: Int = 0,
    scrollY: Double = 0,
    blockIndex: Int = 0
) -> Session.Position {
    Session.Position(
        selectionLocation: location,
        selectionLength: 0,
        scrollX: 0,
        scrollY: scrollY,
        blockIndex: blockIndex,
        blockOffset: 0,
        modifiedAt: 1_700_000_000
    )
}

@Test func sessionRoundTripsThroughDefaults() throws {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let workspace = URL(fileURLWithPath: "/tmp/某个工作区")
    let file = URL(fileURLWithPath: "/tmp/某个工作区/第一章.md")

    let first = Session(defaults: defaults)
    first.setWorkspace(workspace)
    first.setOpenFile(file)
    first.setExpandedPaths([workspace.path])
    first.record(makePosition(location: 42, scrollY: 120, blockIndex: 3), for: file)

    // 新实例模拟下一次启动：读到的必须是同一份记录
    let second = Session(defaults: defaults)
    #expect(second.workspaceURL?.path == workspace.path)
    #expect(second.openFileURL?.path == file.path)
    #expect(second.expandedPaths == [workspace.path])
    let position = try #require(second.position(for: file))
    #expect(position.selectionLocation == 42)
    #expect(position.scrollY == 120)
    #expect(position.blockIndex == 3)
}

/// 上限存在的意义：打开过一个几百篇的文件夹之后，记录不能无限长。
@Test func sessionKeepsOnlyTheMostRecentPositions() throws {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var clock: Double = 1_000
    let session = Session(defaults: defaults, now: { Date(timeIntervalSince1970: clock) })
    let files = (0..<(Session.positionLimit + 5)).map {
        URL(fileURLWithPath: "/tmp/doc-\($0).md")
    }
    for file in files {
        session.record(makePosition(), for: file)
        clock += 1
    }

    // 最早的五篇被挤掉，最新的一篇一定还在
    #expect(session.position(for: files[0]) == nil)
    #expect(session.position(for: files[4]) == nil)
    #expect(session.position(for: files[5]) != nil)
    #expect(session.position(for: files[files.count - 1]) != nil)
}

/// LRU 不是 FIFO：重新读过一篇就该把它提到最前，否则「常看的几篇」会先被淘汰。
@Test func readingAnEntryAgainProtectsItFromEviction() throws {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var clock: Double = 1_000
    let session = Session(defaults: defaults, now: { Date(timeIntervalSince1970: clock) })
    let files = (0..<Session.positionLimit).map {
        URL(fileURLWithPath: "/tmp/doc-\($0).md")
    }
    for file in files {
        session.record(makePosition(), for: file)
        clock += 1
    }

    // 再读一次最早那篇，它就成了最新的
    session.record(makePosition(location: 7), for: files[0])
    clock += 1
    let newcomer = URL(fileURLWithPath: "/tmp/doc-new.md")
    session.record(makePosition(), for: newcomer)

    #expect(session.position(for: files[0])?.selectionLocation == 7)
    // 被挤掉的应该是第二早的那篇
    #expect(session.position(for: files[1]) == nil)
}

/// 版本不同的记录一律丢弃：字段含义变了，照读会把读者送到莫名其妙的位置。
@Test func sessionFromAnotherVersionIsIgnored() throws {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let foreign = Data(#"{"version":99,"openFilePath":"/tmp/x.md"}"#.utf8)
    defaults.set(foreign, forKey: "wtmd.session")

    let session = Session(defaults: defaults)
    #expect(session.openFileURL == nil)
    #expect(session.workspaceURL == nil)
}

@Test func sessionFromGarbageIsIgnored() throws {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(Data("不是 JSON".utf8), forKey: "wtmd.session")

    let session = Session(defaults: defaults)
    #expect(session.openFileURL == nil)
    #expect(session.workspaceURL == nil)
}

/// 同一个文件可能被不同写法指到（`/a/./b.md`、软链的父目录）：记录按标准化
/// 路径存，避免同一篇文档攒出两套位置。
@Test func positionIsKeyedByStandardizedPath() throws {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let session = Session(defaults: defaults)
    session.record(
        makePosition(location: 11),
        for: URL(fileURLWithPath: "/tmp/notes/./chapter.md")
    )

    #expect(session.position(for: URL(fileURLWithPath: "/tmp/notes/chapter.md"))?.selectionLocation == 11)
}

@Test func clearingTheSessionDropsEverything() throws {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let file = URL(fileURLWithPath: "/tmp/doc.md")
    let session = Session(defaults: defaults)
    session.setOpenFile(file)
    session.record(makePosition(), for: file)

    session.clear()

    #expect(session.openFileURL == nil)
    #expect(session.position(for: file) == nil)
    // 清空也要落盘，否则重启又把旧记录读回来
    #expect(Session(defaults: defaults).openFileURL == nil)
}

// MARK: - 磁盘改名 / 删除后的路径迁移

/// 目录改名后，会话里以它开头的路径全部要跟着搬——否则下次启动会去开一个
/// 已经不存在的路径，展开状态也会凭空收起来。
@Test func sessionRemapsEverythingUnderARenamedFolder() throws {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let root = URL(fileURLWithPath: "/tmp/书房")
    let drafts = root.appendingPathComponent("drafts")
    let file = drafts.appendingPathComponent("a.md")

    let session = Session(defaults: defaults)
    session.setWorkspace(root)
    session.setOpenFile(file)
    session.setExpandedPaths([drafts.path])
    session.record(makePosition(location: 7, scrollY: 42), for: file)

    let renamed = root.appendingPathComponent("草稿")
    session.remapPaths(from: drafts, to: renamed)

    // 落盘再读回来：要改的是真的存下来的那一份，不只是内存
    let reopened = Session(defaults: defaults)
    let newFile = renamed.appendingPathComponent("a.md")
    #expect(reopened.openFileURL?.path == newFile.path)
    #expect(reopened.expandedPaths == Set([renamed.path]))
    #expect(reopened.position(for: newFile)?.scrollY == 42)
    #expect(reopened.position(for: file) == nil)
    // 工作区本身没改名
    #expect(reopened.workspaceURL?.path == root.path)
}

@Test func sessionForgetsEverythingUnderADeletedFolder() throws {
    let (defaults, suite) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let root = URL(fileURLWithPath: "/tmp/书房")
    let drafts = root.appendingPathComponent("drafts")
    let file = drafts.appendingPathComponent("a.md")

    let session = Session(defaults: defaults)
    session.setWorkspace(root)
    session.setOpenFile(file)
    session.setExpandedPaths([drafts.path, root.path])
    session.record(makePosition(scrollY: 5), for: file)

    session.forgetPaths(at: drafts)

    let reopened = Session(defaults: defaults)
    #expect(reopened.openFileURL == nil)
    #expect(reopened.expandedPaths == Set([root.path]))
    #expect(reopened.position(for: file) == nil)
    #expect(reopened.workspaceURL?.path == root.path)
}
