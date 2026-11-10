import AppKit
import Foundation
import Testing

@testable import wtmd

/// 从 Finder 打开第二个文件时，屏幕上多出一扇和主窗一模一样的窗（#299）。
///
/// 用户报的现象：用一个文件启动，一扇窗；再打开另一个文件，又冒出一扇窗，
/// **两扇窗显示的都是第二个文件**。
///
/// 两个成因叠在一起：
/// 1. 系统每投递一次「打开文件」都给主场景（`WindowGroup`）开一个新实例，而主场景
///    渲染的永远是同一个 `coordinator.primary`——于是多出来的窗和主窗内容一致。
///    规矩是：文件落在哪扇窗由 `OpenRequest` 决定，主场景一扇新窗都不开。
/// 2. 欢迎页的文案也是一段真的 `text`，于是刚启动的窗永远算「欠着一篇没名字的
///    稿子」，`plan` 只好另开一扇。欢迎页不是读者写的字。
@Suite("一个文件一扇窗", .serialized)
@MainActor
struct SingleWindowTests {
    private static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // wtmdTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/wtmd")
            .appendingPathComponent(name)
    }

    /// 守卫扫源码前剥掉 `//` 行注释——否则注释里的字样会绊红断言。
    private static func code(of url: URL) -> String {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return raw
            .components(separatedBy: "\n")
            .map { line in
                if let range = line.range(of: "//") { return String(line[..<range.lowerBound]) }
                return line
            }
            .joined(separator: "\n")
    }

    // MARK: - 欢迎页不算读者的字

    @Test("刚启动的窗摆着欢迎页：不欠稿子")
    func theWelcomePageIsNotAnUnnamedDraft() throws {
        let rig = try SingleWindowRig()
        defer { rig.cleanup() }

        #expect(rig.model.store.text == DocumentStore.welcomeMarkdown, "前置：摆的是欢迎页")
        #expect(rig.model.store.fileURL == nil)
        #expect(!rig.model.holdsUnnamedWords, "欢迎页不是读者写的字，别拿它当归宿")
    }

    @Test("空白新稿：也不欠稿子")
    func aBlankSheetIsNotAnUnnamedDraft() throws {
        let rig = try SingleWindowRig(startsBlank: true)
        defer { rig.cleanup() }

        #expect(rig.model.store.text.isEmpty, "前置：一页白纸")
        #expect(!rig.model.holdsUnnamedWords, "白纸上没有字，关窗也不用留一手")
    }

    @Test("在白纸上写了字：这才算欠着")
    func typedWordsCount() throws {
        let rig = try SingleWindowRig(startsBlank: true)
        defer { rig.cleanup() }

        rig.model.store.text = "# 我的字\n\n还没起名字。"
        #expect(rig.model.holdsUnnamedWords, "没名字的字得护着——关窗就再没有入口拿回来")
    }

    @Test("在欢迎页上写了字：同样算欠着")
    func typingOverTheWelcomePageCounts() throws {
        let rig = try SingleWindowRig()
        defer { rig.cleanup() }

        rig.model.store.text = DocumentStore.welcomeMarkdown + "\n\n补一段自己的。"
        #expect(rig.model.holdsUnnamedWords, "欢迎页已经被改过，那就是读者的稿子")
    }

    // MARK: - 打开的文件落在哪扇窗

    @Test("用文件启动：这一篇进当前窗，不再另开一扇")
    func openingAFileReusesTheWelcomeWindow() throws {
        let rig = try SingleWindowRig()
        defer { rig.cleanup() }

        let route = OpenRequest.plan(
            index: 0,
            sameDocumentAlreadyOpen: false,
            frontWindowHoldsUnnamedWords: rig.model.holdsUnnamedWords,
            owner: nil
        )
        #expect(route == .reuseCurrent, "欢迎页挡不住新文件：它不算占着这一窗")
    }

    @Test("前台窗里真有没保存的字：另开一扇，别顶掉")
    func anUnnamedDraftStillGetsItsOwnWindow() throws {
        let rig = try SingleWindowRig(startsBlank: true)
        defer { rig.cleanup() }

        rig.model.store.text = "# 正在写\n\n这段还没落盘。"
        let route = OpenRequest.plan(
            index: 0,
            sameDocumentAlreadyOpen: false,
            frontWindowHoldsUnnamedWords: rig.model.holdsUnnamedWords,
            owner: nil
        )
        #expect(route == .newWindow, "没名字的字被一个文件顶掉就真没了")
    }

    // MARK: - 主场景的替身窗

    /// 系统为「打开文件」给主场景再开一个实例时，屏幕上会出现两扇渲染同一份
    /// 模型的窗（#299）。收口点在 `WindowCoordinator.register`：原来那扇还在场，
    /// 就把后挂上来的关掉。
    ///
    /// `.handlesExternalEvents(matching: [])` 不能再用——实测它让主窗压根不出现、
    /// 事件转给第二个场景，一次启动攒出一排空窗（#302）。
    @Test("主场景被系统再实例化一次：替身关掉，留原来那扇")
    func aTwinMainWindowIsClosed() throws {
        let rig = try SingleWindowRig()
        defer { rig.cleanup() }

        let first = Self.mainWindow(index: 1)
        let twin = Self.mainWindow(index: 2)
        defer {
            first.close()
            twin.close()
        }

        #expect(rig.coordinator.register(window: first, for: rig.model), "第一扇当然要收下")
        #expect(rig.coordinator.window(for: rig.model.id) === first)

        #expect(!rig.coordinator.register(window: twin, for: rig.model), "替身不该被收下")
        #expect(
            rig.coordinator.window(for: rig.model.id) === first,
            "留下的该是读者一直在用的那扇"
        )
        #expect(!twin.isVisible, "替身必须从屏幕上消失")
    }

    /// 一扇带主场景编号的窗。编号是系统给的（`wtmd.main-AppWindow-N`），
    /// 替身判定就认这个。
    private static func mainWindow(index: Int) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(
            "\(WindowScene.main)-AppWindow-\(index)"
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    // MARK: - 源码守卫

    @Test("主场景仍是组窗，且不再声明不接外部事件")
    func theMainSceneKeepsOneWindowPerModel() {
        let app = Self.code(of: Self.sourceURL("wtmdApp.swift"))
        #expect(
            app.contains("WindowGroup(id: WindowScene.main)"),
            "主场景还是那个组窗：改成 `Window` 会让外部打开文件时把主窗关掉"
        )
        #expect(
            !app.contains("handlesExternalEvents"),
            "别再声明它：实测会把主窗挤掉、把事件转给第二个场景，攒出一排空窗"
        )

        let model = Self.code(of: Self.sourceURL("WindowModel.swift"))
        #expect(model.contains("isTwinScene"), "替身窗的判据不见了，两扇一样的窗会回来")
        #expect(
            model.contains("window duplicate"),
            "关替身时该留一行轨迹——这条只在真机上复现，下次复发要能看见"
        )
    }
}

/// 一扇只在测试里存在的窗：临时会话、临时草稿目录、临时冲突库。
@MainActor
private struct SingleWindowRig {
    let defaultsName: String
    let defaults: UserDefaults
    let root: URL
    let session: Session
    let model: WindowModel
    let coordinator: WindowCoordinator

    init(startsBlank: Bool = false) throws {
        defaultsName = "wtmd.tests.single.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-single-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let shared = SharedAppEnvironment(
            writingStats: WritingStats(defaults: defaults),
            recentFiles: RecentFiles(userDefaults: defaults),
            conflicts: ConflictArchive(directory: root.appendingPathComponent("conflicts")),
            history: DocumentHistory(directory: root.appendingPathComponent("history"))
        )
        session = Session(defaults: defaults)
        model = WindowModel(
            session: session,
            shared: shared,
            draftDirectory: root.appendingPathComponent("drafts", isDirectory: true),
            startsBlank: startsBlank
        )
        coordinator = WindowCoordinator(
            shared: shared,
            primary: model,
            draftRoot: root.appendingPathComponent("drafts", isDirectory: true),
            defaults: defaults
        )
    }

    func cleanup() {
        model.workspace.close()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
