import AppKit
import Foundation
import Testing

@testable import wtmd

/// 关掉的主窗不能再占主（#290）。
///
/// 用户报的现象：右键打开文件之后，工作区树显示着之前保留的文件夹，点树里的
/// 文件却毫无反应。根因有两层，都是老雷：
///
/// 1. 主窗从不挂 `willCloseNotification`（#106 起），⌘W 掉的主窗在窗口表里
///    永远「开着」，它占过的那篇成了幽灵占主——别的窗点那篇会被 `handOver`
///    交出去；
/// 2. `revealDocument` 把稿子塞进幽灵模型之后**照样返回 true**，调用方于是
///    什么都不做。文件进了看不见的窗，人看到的只有「点了没有用」。
///
/// 这里的测试守住：关掉的主窗不再可及、不再占主；`revealDocument` 对够不着
/// 的窗拒收；命令回退到还活着的那扇窗；主窗开回来之后一切恢复。测试进程里
/// 没有 `WindowBridge` 的观察者，关窗的效果用显式 `windowDidClose` 模拟——
/// 生产路径的观察者已对主窗同样挂上（WindowRoot.swift）。
@Suite("关掉的主窗不再占主", .serialized)
@MainActor
struct ClosedPrimaryTests {
    private func makeWindow(alive: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: alive
                ? NSRect(x: 0, y: 0, width: 400, height: 300)
                : NSRect(x: -20000, y: -20000, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // 「活着」的窗要真的上过屏：没 orderFront 的窗 isVisible 恒为 false。
        if alive { window.orderFront(nil) }
        return window
    }

    private func write(_ name: String, in root: URL, content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("主窗关掉后不再可及、不再占主：别的窗点它的稿子该自己开")
    func aClosedPrimaryStopsHoldingItsDocument() throws {
        let rig = try ClosedPrimaryRig()
        defer { rig.cleanup() }

        let root = try rig.makeFolder(named: "书房")
        let aa = try write("aa.md", in: root, content: "# 甲")
        let window = makeWindow(alive: true)
        defer { window.close() }
        rig.coordinator.register(window: window, for: rig.primary)
        rig.primary.store.open(url: aa)
        #expect(rig.shared.openDocuments.isReachable?(rig.primary.id) ?? true)

        // 生产路径由主窗的 willCloseNotification 触发；测试直接模拟它的效果。
        window.close()
        rig.coordinator.windowDidClose(rig.primary)

        #expect(rig.shared.openDocuments.isReachable?(rig.primary.id) != true, "关掉的主窗不该再算「开着」")
        #expect(rig.coordinator.revealDocument(rig.primary.id, url: aa, jumpingTo: nil) == false,
                "对关掉的主窗拒收交接，让调用方自己开")

        let extra = rig.coordinator.makeExtraWindow(inheriting: root)
        // 模拟副窗树里点 aa：handOver 找不到活占主，返回 false，文件就地打开。
        let handed = rig.shared.openDocuments.handOver(aa, jumpingTo: nil, from: extra.id, in: nil)
        #expect(!handed)
        extra.store.open(url: aa)
        #expect(PathKey.isSame(try #require(extra.store.fileURL), aa), "点击的文件必须真的开出来")
    }

    @Test("占主没有在场的桌子：revealDocument 拒收，不谎报成功")
    func revealRefusesAnOwnerWithoutAWindow() throws {
        let rig = try ClosedPrimaryRig()
        defer { rig.cleanup() }

        let root = try rig.makeFolder(named: "书房")
        let bb = try write("bb.md", in: root, content: "# 乙")
        rig.primary.store.open(url: bb)

        // 从没挂上真窗的模型：window(for:) 为 nil。
        #expect(rig.coordinator.window(for: rig.primary.id) == nil)
        #expect(rig.coordinator.revealDocument(rig.primary.id, url: bb, jumpingTo: nil) == false)
    }

    @Test("占主在场：revealDocument 接手，跳过去成功")
    func revealAcceptsAPresentOwner() throws {
        let rig = try ClosedPrimaryRig()
        defer { rig.cleanup() }

        let root = try rig.makeFolder(named: "书房")
        let cc = try write("cc.md", in: root, content: "# 丙")
        let window = makeWindow(alive: true)
        defer { window.close() }
        rig.coordinator.register(window: window, for: rig.primary)

        #expect(rig.coordinator.revealDocument(rig.primary.id, url: cc, jumpingTo: nil),
                "占主在场（缩在 Dock 里的也算，#175）：跳过去该成功")
        #expect(rig.coordinator.revealDocument(rig.primary.id, url: cc, jumpingTo: nil),
                "同一篇已开着：leaveAsIs 也算交接成功")
    }

    @Test("主窗关掉后，命令回退到还活着的那扇，而不是看不见的主窗")
    func commandsFallBackToALivingWindow() throws {
        let rig = try ClosedPrimaryRig()
        defer { rig.cleanup() }

        let window = makeWindow(alive: true)
        defer { window.close() }
        let extra = rig.coordinator.makeExtraWindow(inheriting: nil)
        rig.coordinator.register(window: window, for: extra)

        // 唯一挂了真窗的副窗也关了，主窗从未上屏：没有活窗可退，才轮到主窗模型。
        window.close()
        #expect(rig.coordinator.activeModel(focused: nil) === rig.primary)

        let living = makeWindow(alive: true)
        defer { living.close() }
        rig.coordinator.register(window: living, for: extra)
        rig.coordinator.windowDidClose(rig.primary)
        #expect(rig.coordinator.activeModel(focused: nil) === extra,
                "主窗不在了，命令该落在还活着的那扇上")
    }

    @Test("主窗开回来：绑定换新、可及恢复，旧绑定不再挡路")
    func reopeningThePrimaryRestoresEverything() throws {
        let rig = try ClosedPrimaryRig()
        defer { rig.cleanup() }

        let root = try rig.makeFolder(named: "书房")
        let dd = try write("dd.md", in: root, content: "# 丁")
        let first = makeWindow(alive: true)
        defer { first.close() }
        rig.coordinator.register(window: first, for: rig.primary)
        rig.primary.store.open(url: dd)
        first.close()
        rig.coordinator.windowDidClose(rig.primary)

        #expect(rig.shared.openDocuments.isReachable?(rig.primary.id) != true)

        let second = makeWindow(alive: true)
        defer { second.close() }
        rig.coordinator.register(window: second, for: rig.primary)

        #expect(rig.coordinator.window(for: rig.primary.id) === second, "绑定必须换成新窗")
        #expect(rig.shared.openDocuments.isReachable?(rig.primary.id) ?? true)
        #expect(rig.coordinator.revealDocument(rig.primary.id, url: dd, jumpingTo: nil),
                "开回来的主窗又是合法的跳转目标")
    }
}

/// 一个只在测试里存在的窗口装配：临时会话、临时草稿目录、临时冲突库。
/// 与 `MultiWindowTests` 的装配同构，但独立一份——两个套件互不踩脚。
@MainActor
private struct ClosedPrimaryRig {
    let defaults: UserDefaults
    let defaultsName: String
    let root: URL
    let shared: SharedAppEnvironment
    let coordinator: WindowCoordinator

    var primary: WindowModel { coordinator.primary }

    init() throws {
        defaultsName = "wtmd.tests.closed-primary.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-closed-primary-\(UUID().uuidString)", isDirectory: true)
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

    func makeFolder(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
