import Foundation
import Testing
@testable import wtmd

/// 「打开文件夹」暂时不对外时的守卫（见 `WorkspaceFeature`）。
///
/// 产品收回到「打开一篇 → 编辑 / 阅读」：工作区的实现与菜单结构都留着，
/// 只要开关一关，界面上就不该还有哪条路能走进工作区。
@MainActor
struct WorkspaceHiddenTests {
    @Test("目录里不再给出工作区的三条命令")
    func workspaceCommandsAreNotOffered() {
        #expect(!WorkspaceFeature.isAvailable)
        #expect(CommandCatalog.command(for: .openFolder) == nil)
        #expect(CommandCatalog.command(for: .searchWorkspace) == nil)
        #expect(CommandCatalog.command(for: .closeWorkspace) == nil)
        // 收起的是工作区，不是整个 File 菜单：单文件那两条仍在。
        #expect(CommandCatalog.command(for: .openDocument) != nil)
        #expect(CommandCatalog.command(for: .newDocument) != nil)
    }

    @Test("菜单结构原样留着，恢复时不用重写")
    func menuStructureIsKeptForLater() throws {
        let app = try source("wtmdApp.swift")
        for kind in ["openFolder", "searchWorkspace", "closeWorkspace"] {
            #expect(
                app.contains("menuItem(.\(kind))"),
                "菜单里的 .\(kind) 被删掉了——恢复工作区要重写菜单结构，而不只是翻开关"
            )
        }
    }

    @Test("界面上的三处入口都受开关控制：侧栏、工具栏、欢迎页")
    func everyVisibleEntranceFollowsTheSwitch() throws {
        let content = try source("ContentView.swift")
        let guards = content.components(separatedBy: "WorkspaceFeature.isAvailable").count - 1
        #expect(
            guards >= 3,
            "ContentView 里只剩 \(guards) 处开关——侧栏文件树、工具栏「打开文件夹」、欢迎页那颗按钮，一处漏了就会重新露出来"
        )
    }

    @Test("启动不扫上次那间书房，但会话里的根留着")
    func launchSkipsTheWorkspaceAndKeepsItsPath() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        try "# 一".write(
            to: harness.folder.appendingPathComponent("一.md"), atomically: true, encoding: .utf8
        )
        harness.session.setWorkspace(harness.folder)

        let store = WorkspaceStore(session: harness.session)
        defer { store.close() }

        #expect(store.root == nil, "隐藏期间不该把书房摆回来")
        #expect(store.tree == nil, "没地方摆树，就不该扫盘")
        #expect(!store.showsTree)
        #expect(
            harness.session.workspaceURL != nil,
            "隐藏不等于删除：以后翻回开关，上次的书房还要能回来"
        )
    }

    @Test("能力本身还在：显式打开照样建树")
    func theCapabilityItselfStillWorks() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        try "# 一".write(
            to: harness.folder.appendingPathComponent("一.md"), atomically: true, encoding: .utf8
        )

        let store = WorkspaceStore(session: harness.session)
        defer { store.close() }
        store.open(harness.folder)

        #expect(store.showsTree)
        #expect(store.tree != nil)
    }

    // MARK: - 帮手

    private struct Harness {
        let session: Session
        let suite: String
        let folder: URL

        func cleanup() {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func makeHarness() throws -> Harness {
        let suite = "wtmd.tests.hidden.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-hidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Harness(session: Session(defaults: defaults), suite: suite, folder: folder)
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/wtmd/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
