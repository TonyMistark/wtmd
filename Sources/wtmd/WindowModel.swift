import AppKit
import SwiftUI

// MARK: - 应用级的那一份

/// What belongs to the application rather than to a window.
///
/// 设置是应用的：换主题、打字机、版式、页边距、快捷键，都是「这个人怎么写字」，
/// 不是「这一篇稿子怎么写字」。多窗口之后这一点必须显式——否则第二扇窗口会带一套
/// 自己的设置，改一处另一处不跟。
///
/// 今日字数账本、最近文件、冲突副本库同理：它们记的是这台机器上这个人，不是某一扇窗。
@MainActor
final class SharedAppEnvironment: ObservableObject {
    let themeManager: ThemeManager
    let writing: WritingSettings
    let typesetting: TypesettingSettings
    let printing: PrintSettings
    let updates: UpdateChecker
    let overrides: ShortcutOverrides
    let writingStats: WritingStats
    let recentFiles: RecentFiles
    let conflicts: ConflictArchive

    /// 参数默认 `nil` 而不是直接给实例：默认实参在非隔离上下文里求值，
    /// 而 `WritingStats` 这类类型的主初始化器是 main-actor 隔离的。
    init(
        themeManager: ThemeManager? = nil,
        writing: WritingSettings? = nil,
        typesetting: TypesettingSettings? = nil,
        printing: PrintSettings? = nil,
        updates: UpdateChecker? = nil,
        overrides: ShortcutOverrides? = nil,
        writingStats: WritingStats? = nil,
        recentFiles: RecentFiles? = nil,
        conflicts: ConflictArchive? = nil
    ) {
        self.themeManager = themeManager ?? ThemeManager()
        self.writing = writing ?? WritingSettings()
        self.typesetting = typesetting ?? TypesettingSettings()
        self.printing = printing ?? PrintSettings()
        self.updates = updates ?? UpdateChecker()
        self.overrides = overrides ?? ShortcutOverrides()
        self.writingStats = writingStats ?? WritingStats()
        self.recentFiles = recentFiles ?? RecentFiles()
        self.conflicts = conflicts ?? ConflictArchive()
    }
}

// MARK: - 一扇窗口

/// One window: its own document, its own folder, its own memory of where you were.
///
/// 这个类型存在的理由只有一条：**窗口之间不能共享会话**。共享了，两扇窗口就会抢
/// 同一份「上次打开的文件」，退出时谁最后写谁赢。
///
/// 反过来，凡是「这个人怎么写字」的东西都从这里拿走，交给 `SharedAppEnvironment`。
@MainActor
final class WindowModel: ObservableObject, Identifiable {
    let id: UUID
    let session: Session
    let store: DocumentStore
    let workspace: WorkspaceStore
    let shared: SharedAppEnvironment
    /// ⌘K 面板：每扇窗口一份。A 窗开着面板，不该盖在 B 窗上。
    @Published var paletteVisible = false

    /// 主窗口沿用上次的会话；其余窗口是一次性的（`session.isPersistent == false`），
    /// 关掉就走，不留记录——按窗口记账是 beta 的事。
    init(
        id: UUID = UUID(),
        session: Session,
        shared: SharedAppEnvironment,
        draftDirectory: URL? = nil,
        workspaceRoot: URL? = nil,
        startsBlank: Bool = false
    ) {
        self.id = id
        self.session = session
        self.shared = shared
        self.store = DocumentStore(
            draftDirectory: draftDirectory,
            session: session,
            conflicts: shared.conflicts,
            writingStats: shared.writingStats,
            themeManager: shared.themeManager,
            recentFiles: shared.recentFiles
        )
        self.workspace = WorkspaceStore(session: session)
        // 树里改名/删除之后，这扇窗口的当前文档跟着磁盘走。每扇窗口一条线，
        // 谁也不许碰别人的文档。
        workspace.fileEvents = store
        store.typesetting = shared.typesetting
        store.printSettings = shared.printing

        // 第二扇窗口从空页开始：不是欢迎页，也不是主窗口那篇。
        if startsBlank {
            store.newDocument()
        }
        // 同一个文件夹、另一张桌子：新窗口接着用这间书房，但打开的是自己的稿子。
        if let workspaceRoot {
            workspace.open(workspaceRoot)
        }
    }
}

// MARK: - 窗口协调

/// The app's window table: who exists, and which one a menu command should act on.
///
/// `openWindow` can only be read from the environment inside a scene, while menu
/// commands live outside every window. The bridge view in each window hands the
/// action here once; commands then open windows through the coordinator.
@MainActor
final class WindowCoordinator: ObservableObject {
    let shared: SharedAppEnvironment
    let primary: WindowModel
    private(set) var windows: [UUID: WindowModel] = [:]
    /// 临时窗口的草稿落在哪儿。默认是 `…/wtmd/windows`，测试给它一个临时目录——
    /// 谁都不该把测试写进真实的应用支持目录。
    let draftRoot: URL
    /// 由窗口里的隐藏视图捕获。
    var openWindowAction: OpenWindowAction?
    /// window → model，用来回答「命令落在哪扇窗」。
    private var bindings: [Binding] = []

    private final class Binding {
        weak var window: NSWindow?
        let model: WindowModel

        init(window: NSWindow?, model: WindowModel) {
            self.window = window
            self.model = model
        }
    }

    init(
        shared: SharedAppEnvironment,
        primary: WindowModel? = nil,
        draftRoot: URL? = nil
    ) {
        self.shared = shared
        self.draftRoot = draftRoot ?? DocumentStore.defaultDraftDirectory
        let first = primary ?? WindowModel(session: Session(), shared: shared)
        self.primary = first
        windows[first.id] = first
    }

    func model(for id: UUID) -> WindowModel? { windows[id] }

    /// 菜单 / 快捷键作用于前台窗口；没有前台窗口（欢迎页、失焦）时回退主窗口。
    ///
    /// 用 `NSApplication.shared` 而不是 `NSApp`：后者是隐式解包的全局变量，
    /// 在没有 `NSApplication` 的进程（测试）里是 nil，取一下就崩。
    func activeModel(focused: WindowModel?) -> WindowModel {
        if let focused { return focused }
        if let key = model(for: NSApplication.shared.keyWindow) { return key }
        return primary
    }

    /// 开一扇新窗口，返回它的 id；没有可用的 `openWindow` 时返回 nil，
    /// 调用方退回「在本窗口新建」。
    @discardableResult
    func openNewWindow(inheriting root: URL?) -> UUID? {
        guard let openWindowAction else { return nil }
        let model = makeExtraWindow(inheriting: root)
        openWindowAction(id: WindowScene.extra, value: model.id)
        return model.id
    }

    /// 只造窗口模型、不真的开窗——测试用它，`openNewWindow` 也用它。
    @discardableResult
    func makeExtraWindow(inheriting root: URL?) -> WindowModel {
        let id = UUID()
        let model = WindowModel(
            id: id,
            session: Session(persist: false),
            shared: shared,
            // 每个临时窗口一份自己的草稿：两份 draft.md 写在一处，谁最后落盘谁赢。
            draftDirectory: Self.temporaryDraftDirectory(for: id, root: draftRoot),
            workspaceRoot: root,
            startsBlank: true
        )
        windows[id] = model
        return model
    }

    /// 窗口关掉了：停止监听文件夹，把它从表里划掉。
    ///
    /// 主窗口不在此列——它的会话还要留给下次启动，`workspace.close()` 会把
    /// 「上次打开的文件夹」一并抹掉。
    func windowDidClose(_ model: WindowModel) {
        guard model.id != primary.id else { return }
        model.workspace.close()
        windows[model.id] = nil
        bindings.removeAll { $0.model.id == model.id }
    }

    /// 记下这扇窗口与它的 `NSWindow` 的对应关系（用于判断前台是哪扇窗）。
    func register(window: NSWindow?, for model: WindowModel) {
        guard let window else { return }
        bindings.removeAll { $0.window === window }
        bindings.append(Binding(window: window, model: model))
    }

    func model(for window: NSWindow?) -> WindowModel? {
        guard let window else { return nil }
        return bindings.first { $0.window === window }?.model
    }

    func window(for id: UUID) -> NSWindow? {
        bindings.first { $0.model.id == id }?.window
    }

    /// 第二扇窗口的草稿家：`…/wtmd/windows/<id>/draft.md`。
    static func temporaryDraftDirectory(
        for id: UUID,
        root: URL? = nil
    ) -> URL {
        (root ?? DocumentStore.defaultDraftDirectory)
            .appendingPathComponent("windows", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

// MARK: - 场景标识

enum WindowScene {
    static let main = "wtmd.main"
    static let extra = "wtmd.extra"
}

// MARK: - 前台窗口

extension FocusedValues {
    /// 前台窗口的模型。菜单命令靠它找到该对谁下手。
    var windowModel: WindowModel? {
        get { self[WindowModelKey.self] }
        set { self[WindowModelKey.self] = newValue }
    }

    private struct WindowModelKey: FocusedValueKey {
        typealias Value = WindowModel
    }
}
