import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 登记表

/// 两扇窗各记各的；问「这篇在谁手里」要答得出来。
@MainActor
@Test func everyWindowRemembersItsOwnDocument() {
    let documents = OpenDocuments()
    let first = UUID()
    let second = UUID()

    documents.update(URL(fileURLWithPath: "/tmp/a.md"), for: first)
    documents.update(URL(fileURLWithPath: "/tmp/b.md"), for: second)

    #expect(documents.owner(of: URL(fileURLWithPath: "/tmp/a.md")) == first)
    #expect(documents.owner(of: URL(fileURLWithPath: "/tmp/b.md")) == second)
    #expect(documents.registeredWindows == [first, second])
}

/// 同一扇窗换了稿子，旧的那篇就没人占着了。
@MainActor
@Test func switchingDocumentsFreesThePreviousOne() {
    let documents = OpenDocuments()
    let window = UUID()

    documents.update(URL(fileURLWithPath: "/tmp/a.md"), for: window)
    documents.update(URL(fileURLWithPath: "/tmp/b.md"), for: window)

    #expect(documents.owner(of: URL(fileURLWithPath: "/tmp/a.md")) == nil)
    #expect(documents.owner(of: URL(fileURLWithPath: "/tmp/b.md")) == window)
}

/// 未命名稿不占位：它没有路径，谁也不可能「打开同一篇」。
@MainActor
@Test func anUntitledDocumentClaimsNothing() {
    let documents = OpenDocuments()
    let window = UUID()

    documents.update(URL(fileURLWithPath: "/tmp/a.md"), for: window)
    documents.update(nil, for: window)

    #expect(documents.registeredWindows.isEmpty)
}

/// 同一份文件被拼成两种路径（符号链接解析前后）：认作同一篇。
@MainActor
@Test func twoSpellingsOfOnePathCountAsOneDocument() throws {
    let rig = try DocumentRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("real.md", "# 真身")
    let link = rig.root.appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    let documents = OpenDocuments()
    let window = UUID()
    documents.update(file, for: window)

    #expect(documents.owner(of: link) == window)
}

/// 同一扇窗再打开一次自己开着的那篇，不算「交给别人」。
@MainActor
@Test func aWindowDoesNotHandOverToItself() {
    let documents = OpenDocuments()
    let window = UUID()
    var reveals = 0
    documents.reveal = { _, _, _ in reveals += 1 }

    documents.update(URL(fileURLWithPath: "/tmp/a.md"), for: window)
    let handled = documents.handOver(
        URL(fileURLWithPath: "/tmp/a.md"), jumpingTo: nil, from: window
    )

    #expect(handled == false)
    #expect(reveals == 0)
}

/// 关掉的窗不再占位：主窗 ⌘W 之后，副窗打开那篇应该能落到副窗。
@MainActor
@Test func aClosedWindowHoldsNothing() {
    let documents = OpenDocuments()
    let closed = UUID()
    let other = UUID()
    documents.update(URL(fileURLWithPath: "/tmp/a.md"), for: closed)
    documents.isReachable = { $0 != closed }

    #expect(documents.owner(of: URL(fileURLWithPath: "/tmp/a.md")) == nil)
    #expect(
        documents.handOver(
            URL(fileURLWithPath: "/tmp/a.md"), jumpingTo: nil, from: other
        ) == false
    )
}

/// 关窗要把登记一起撤掉：只靠「够不着」过滤，表会越积越长，脏记录也会误导排障。
@MainActor
@Test func closingAWindowClearsItsRegistration() throws {
    let rig = try DocumentRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 关窗清账")
    let window = rig.newWindow()
    window.store.open(url: file)
    #expect(rig.shared.openDocuments.registeredWindows.contains(window.id))

    rig.coordinator.windowDidClose(window)

    #expect(!rig.shared.openDocuments.registeredWindows.contains(window.id))
}

// MARK: - 两扇窗真的去开同一篇

/// 第二扇窗打开一篇已经在别处开着的稿子：它自己不切换，占着的那扇被叫出来。
@MainActor
@Test func theSecondWindowHandsOverInsteadOfOpeningTheSameFile() throws {
    let rig = try DocumentRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 同一篇")
    let first = rig.newWindow()
    let second = rig.newWindow()

    first.store.open(url: file)
    second.store.open(url: file)

    #expect(first.store.fileURL.map { PathKey.isSame($0, file) } == true)
    #expect(second.store.fileURL == nil, "第二扇窗不该也开一份")
    #expect(second.store.text.isEmpty)
}

/// 第二个想打开时带着行列（⌘⇧F 的命中）：占着它的那扇窗要落到那儿。
@MainActor
@Test func aSearchHitLandsInTheWindowThatAlreadyHasIt() throws {
    let rig = try DocumentRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 一\n\n## 二\n\n要找的那句话\n")
    let first = rig.newWindow()
    let second = rig.newWindow()
    first.store.open(url: file)

    second.store.open(
        url: file,
        jumpingTo: JumpRequest(id: "hit", line: 5, column: 3, length: 7, slug: "")
    )

    #expect(second.store.fileURL == nil)
    #expect(first.store.editorJump?.line == 5)
    #expect(first.store.editorJump?.column == 3)
}

/// 关掉占着它的那扇窗，再打开就落在新窗里。
@MainActor
@Test func afterTheOwnerClosesTheNextWindowGetsIt() throws {
    let rig = try DocumentRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 换手")
    let first = rig.newWindow()
    let second = rig.newWindow()
    first.store.open(url: file)

    rig.coordinator.windowDidClose(first)
    second.store.open(url: file)

    #expect(second.store.fileURL.map { PathKey.isSame($0, file) } == true)
}

/// 记账是跟着 `fileURL` 自动走的：新建之后这篇就该腾出来。
@MainActor
@Test func claimingFollowsTheDocumentWithoutManualBookkeeping() throws {
    let rig = try DocumentRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 自动记账")
    let window = rig.newWindow()

    window.store.open(url: file)
    #expect(rig.shared.openDocuments.owner(of: file) == window.id)

    window.store.newDocument()
    #expect(rig.shared.openDocuments.owner(of: file) == nil)
}

/// 主窗 ⌘W 关掉再开回来：登记跟着窗口走，不会一直空着。
@MainActor
@Test func reopeningTheClosedPrimaryWindowClaimsItsDocumentAgain() throws {
    let rig = try DocumentRig()
    defer { rig.cleanup() }

    let file = try rig.makeFile("a.md", "# 关掉再开")
    let primary = rig.coordinator.primary
    primary.store.open(url: file)
    #expect(rig.shared.openDocuments.owner(of: file) == primary.id)

    rig.coordinator.windowDidClose(primary)
    #expect(rig.shared.openDocuments.owner(of: file) == nil, "关掉的窗不再占位")

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    rig.coordinator.register(window: window, for: primary)

    #expect(rig.shared.openDocuments.owner(of: file) == primary.id)
}

// MARK: - 辅助

/// 一套不碰真实数据的两扇窗：临时 defaults、临时草稿目录。
@MainActor
private struct DocumentRig {
    let defaultsName: String
    let defaults: UserDefaults
    let root: URL
    let shared: SharedAppEnvironment
    let coordinator: WindowCoordinator

    init() throws {
        defaultsName = "wtmd.tests.open.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        shared = SharedAppEnvironment(
            writingStats: WritingStats(defaults: defaults),
            recentFiles: RecentFiles(userDefaults: defaults),
            conflicts: ConflictArchive(directory: root.appendingPathComponent("conflicts"))
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
