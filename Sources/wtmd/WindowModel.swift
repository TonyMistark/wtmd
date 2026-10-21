import AppKit
import Combine
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
    /// 一键更新：下载 → 挂载 → 装配 → 重启。与 `updates` 同级——
    /// 更新属于这台机器，不属于某一扇窗。
    let installer: UpdateInstaller
    let overrides: ShortcutOverrides
    let writingStats: WritingStats
    let recentFiles: RecentFiles
    let conflicts: ConflictArchive
    /// 版本历史：写过的每一版都留一份。应用级一份——历史目录只有一处，
    /// 哪扇窗写下的版本，别的窗也翻得到（beta 的面板要用）。
    let history: DocumentHistory
    /// 谁开着哪一篇。同一篇稿子只该在一扇窗里打开——见 `OpenDocuments`。
    let openDocuments: OpenDocuments
    /// 崩溃报告的账房：收现场、列清单、交给读者。应用级一份——报告属于这台
    /// 机器，不属于某一扇窗。
    let crashes: CrashStore
    /// 昵称与头像：只存本地，属于这个人而不属于某一扇窗。
    let profile: ProfileStore

    /// 参数默认 `nil` 而不是直接给实例：默认实参在非隔离上下文里求值，
    /// 而 `WritingStats` 这类类型的主初始化器是 main-actor 隔离的。
    init(
        themeManager: ThemeManager? = nil,
        writing: WritingSettings? = nil,
        typesetting: TypesettingSettings? = nil,
        printing: PrintSettings? = nil,
        updates: UpdateChecker? = nil,
        installer: UpdateInstaller? = nil,
        overrides: ShortcutOverrides? = nil,
        writingStats: WritingStats? = nil,
        recentFiles: RecentFiles? = nil,
        conflicts: ConflictArchive? = nil,
        history: DocumentHistory? = nil,
        openDocuments: OpenDocuments? = nil,
        crashes: CrashStore? = nil,
        profile: ProfileStore? = nil
    ) {
        self.themeManager = themeManager ?? ThemeManager()
        self.writing = writing ?? WritingSettings()
        self.typesetting = typesetting ?? TypesettingSettings()
        self.printing = printing ?? PrintSettings()
        self.updates = updates ?? UpdateChecker()
        self.installer = installer ?? UpdateInstaller(steps: UpdateInstaller.productionSteps())
        self.overrides = overrides ?? ShortcutOverrides()
        self.writingStats = writingStats ?? WritingStats()
        self.recentFiles = recentFiles ?? RecentFiles()
        self.conflicts = conflicts ?? ConflictArchive()
        self.history = history ?? DocumentHistory()
        self.openDocuments = openDocuments ?? OpenDocuments()
        self.crashes = crashes ?? CrashStore()
        self.profile = profile ?? ProfileStore()
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
    /// 把 `store.fileURL` 的变化记进应用级的「谁开着哪一篇」。
    private var documentClaim: AnyCancellable?

    /// 每扇窗口带一份自己的会话：主窗口用 `wtmd.session`，其余按窗口 id 各存一条。
    /// 关窗即结束那一条（`WindowCoordinator.finishRecord`），下次启动只摆回还开着的。
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
            history: shared.history,
            crashes: shared.crashes,
            writingStats: shared.writingStats,
            themeManager: shared.themeManager,
            recentFiles: shared.recentFiles,
            windowID: id,
            openDocuments: shared.openDocuments
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

        // 谁开着哪一篇：跟着 `fileURL` 走。打开、新建、另存为、外部改名跟随、
        // 文件消失——凡改 `fileURL` 的路径都自动落账，不靠每个入口记得登记。
        documentClaim = store.$fileURL
            .removeDuplicates()
            .sink { [weak self] url in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.shared.openDocuments.update(url, for: self.id)
                }
            }
    }

    /// 这扇窗里还欠着一篇**没有名字**的字吗？
    ///
    /// 关窗时的判据：草稿已经落盘，可窗口一关就再没有入口把它拿回来。没名字的
    /// 字不会陪窗口一起消失（见 `WindowCoordinator.finishRecord`）。
    var holdsUnnamedWords: Bool {
        guard store.fileURL == nil else { return false }
        return !store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    /// 每扇窗的会话与这本账写在哪儿。测试给它一个临时 suite。
    let defaults: UserDefaults
    /// 退出时开着哪几张桌子。
    let ledger: WindowLedger
    /// 开窗的通道。窗口里的隐藏视图把 `openWindow` 包成闭包交进来——包一层是为了
    /// 测试能注入一个假通道：`OpenWindowAction` 没有公开的构造器。
    var openWindowHandler: ((UUID) -> Void)?
    /// window → model，用来回答「命令落在哪扇窗」。
    private var bindings: [Binding] = []
    /// 还没摆回来的窗：退出时开着的那几扇。
    private var pendingRestorations: [WindowLedger.Entry]
    /// 恢复的窗该站在哪儿。等它挂到真的 `NSWindow` 上才用得上，用掉就删。
    private var pendingFrames: [UUID: CGRect] = [:]
    /// 屏幕的可见区域。「记下的位置还在不在屏幕上」要问它。
    ///
    /// 可注入：测试进程没有显示器，`NSScreen.screens` 会是空的——那会让每一条
    /// 位置记录都被判成「不在屏幕上」，测试就永远测不到「照原样摆回去」。
    var screenFrames: () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) }
    /// 已经关掉、但模型还留着的窗（主窗的会话要留给下次启动）。它们不再占着
    /// 任何一篇稿子——否则副窗打开那篇会被送到一扇看不见的窗口。
    private var closedWindows: Set<UUID> = []

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
        draftRoot: URL? = nil,
        defaults: UserDefaults = .standard,
        ledger: WindowLedger? = nil
    ) {
        self.shared = shared
        self.draftRoot = draftRoot ?? DocumentStore.defaultDraftDirectory
        self.defaults = defaults
        let book = ledger ?? WindowLedger(defaults: defaults)
        self.ledger = book
        let first = primary ?? WindowModel(session: Session(defaults: defaults), shared: shared)
        self.primary = first
        windows[first.id] = first
        // 上次的现场已经在 `harvest()` 里整理好了：开窗就问一句。
        // 只有主窗问——副窗是读者自己开的，不该被一张崩溃说明挡住。
        if shared.crashes.hasPending {
            // 窗口还没挂上去就弹 sheet 会被系统丢掉：等一拍再问。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                first.store.showCrashPrompt()
            }
        }
        // 名单先抄下来，等开窗通道到手再摆——`openWindow` 只在场景里读得到。
        pendingRestorations = book.entries

        // 「谁开着哪一篇」的两个出口：把占着它的窗口带到前面；以及判断那扇窗
        // 还够不够得着（主窗 ⌘W 关掉后模型还在，但已经占不住稿子了）。
        shared.openDocuments.reveal = { [weak self] id, url, request in
            self?.revealDocument(id, url: url, jumpingTo: request)
        }
        shared.openDocuments.isReachable = { [weak self] id in
            guard let self else { return false }
            // 表里记着、但这张窗口表里没有的，是上一次启动留下的旧账（测试进程里
            // 同一个 `SharedAppEnvironment` 会跨「两次启动」复用）。它们不能再算
            // 占着稿子——否则新启动的窗会被一扇已经不存在的窗挡在门外。
            return self.windows[id] != nil && !self.closedWindows.contains(id)
        }
        // 起点也算一次「开着几扇窗」：崩溃时至少知道一开始是几扇。
        noteWindowState("open")
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

    // MARK: - 打开文档

    /// 有窗口想打开一篇已经在别处开着的稿子：把占着它的窗口带到前面。
    ///
    /// 带 `JumpRequest` 时还要在那扇窗里落到行列（`⌘⇧F` 的命中常常指着一篇
    /// 已经开着的文档）。窗口关着/最小化时先弄回眼前——「跳过去」得让人看见。
    private func revealDocument(_ id: UUID, url: URL, jumpingTo request: JumpRequest?) {
        guard let model = windows[id] else { return }
        // 登记可能晚了一步（那扇窗刚换了稿）：让它重新打开一次，顺带走一遍
        // 会话位置与冲突存档。
        let alreadyThere = model.store.fileURL.map { PathKey.isSame($0, url) } ?? false
        if request != nil || !alreadyThere {
            model.store.open(url: url, jumpingTo: request)
        }
        guard let target = window(for: id) else { return }
        // 连带激活应用：只把窗口在自己的层里往前提，人看到的还是别的 app。
        AppActivation.bringToFront(target)
    }

    // MARK: - 开窗

    /// 窗口里的隐藏视图报到：开窗通道到手，顺手把上次的桌子摆回来。
    ///
    /// 每扇窗报到都会走到这里，所以必须幂等——名单抄在 `pendingRestorations`，
    /// 摆完就空，重复报到不会重复开窗。
    func attach(openWindow: @escaping (UUID) -> Void) {
        openWindowHandler = openWindow
        restoreWindows()
    }

    /// 把上次退出时开着的窗摆回来。
    ///
    /// 每个模型都从**自己那条记录**起来：工作区、当前文件、光标位置、展开目录
    /// 都跟着回来。窗口站在它上次站的地方；那个位置若已经不在任何屏幕上
    /// （拔了外接屏、换了分辨率），就退回 alpha 的错开摆法。
    func restoreWindows() {
        guard let openWindowHandler, !pendingRestorations.isEmpty else { return }
        let entries = pendingRestorations
        pendingRestorations = []
        let screens = screenFrames()
        for entry in entries where windows[entry.id] == nil {
            if let frame = entry.frame, frame.fits(in: screens) {
                pendingFrames[entry.id] = frame.rect
            }
            let session = Session(window: entry.id, defaults: defaults)
            // 同一篇被两条记录指着的旧账（升级前就开着两扇、或有人改过 defaults）：
            // 先到先得——主窗在 `init` 里就先登记了，这里是账本里的先后。
            // 后来的那扇把稿子让出去，否则两扇窗各写一份，谁后落盘谁赢。
            if let url = session.openFileURL,
               shared.openDocuments.isHeldElsewhere(url, than: entry.id) {
                session.setOpenFile(nil)
            }
            let model = materialize(
                id: entry.id, session: session, inheriting: nil, startsBlank: false
            )
            openWindowHandler(model.id)
        }
    }

    /// 开一扇新窗口，返回它的 id；没有可用的通道时返回 nil，
    /// 调用方退回「在本窗口新建」。
    @discardableResult
    func openNewWindow(inheriting root: URL?) -> UUID? {
        guard let openWindowHandler else { return nil }
        let model = makeExtraWindow(inheriting: root)
        openWindowHandler(model.id)
        return model.id
    }

    /// 只造窗口模型、不真的开窗——测试用它，`openNewWindow` 也用它。
    @discardableResult
    func makeExtraWindow(inheriting root: URL?) -> WindowModel {
        let id = UUID()
        ledger.add(id)
        return materialize(id: id, inheriting: root, startsBlank: true)
    }

    /// 造一扇窗的模型。
    ///
    /// `startsBlank` 只给 ⌘N 用：恢复的窗要从自己的记录里起来，不能被一张白纸
    /// 盖掉——那样「恢复」就成了「清空」。
    ///
    /// `session` 可由调用方传入：恢复时先读一遍它记的是哪一篇（要确认那篇没有
    /// 被别的窗占着），确认之后再把同一份记录交给窗口，不必读第二遍。
    private func materialize(
        id: UUID,
        session passed: Session? = nil,
        inheriting root: URL?,
        startsBlank: Bool
    ) -> WindowModel {
        let session = passed ?? Session(window: id, defaults: defaults)
        let directory = Self.temporaryDraftDirectory(for: id, root: draftRoot)
        // 恢复一扇什么都没留下的窗，也给白纸：`DocumentStore` 在没有文件也没有
        // 草稿时会摆出欢迎页，而欢迎页只属于「第一次打开这个应用」的那扇主窗。
        let blank = startsBlank || (session.openFileURL == nil && !Self.hasDraft(in: directory))
        let model = WindowModel(
            id: id,
            session: session,
            shared: shared,
            // 每扇窗一份自己的草稿：两份 draft.md 写在一处，谁最后落盘谁赢。
            draftDirectory: directory,
            workspaceRoot: root,
            startsBlank: blank
        )
        windows[id] = model
        noteWindowState("open")
        return model
    }

    /// 崩溃报告里的「当时开着几扇窗」。
    ///
    /// 两行：一行给解析（`windows 3`），一行给人看（开了/关了第几扇）。
    /// 只在窗口生命周期上写——打字不走这里，不会拖慢任何东西。
    private func noteWindowState(_ action: String) {
        let open = windows.values.filter { !closedWindows.contains($0.id) }.count
        CrashBreadcrumbs.note("windows \(open)")
        CrashBreadcrumbs.note("window \(action) · \(open) open")
    }

    /// 这扇窗的草稿家还留着字吗？
    private static func hasDraft(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("draft.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return !text.isEmpty
    }

    // MARK: - 关窗

    /// 窗口关掉了：结束它那一条账，停止监听文件夹，把它从表里划掉。
    ///
    /// 主窗口不在此列——它的会话还要留给下次启动，`workspace.close()` 会把
    /// 「上次打开的文件夹」一并抹掉。
    func windowDidClose(_ model: WindowModel) {
        // 关掉的窗不再占着任何一篇稿子：副窗打开那篇时应该落在副窗，而不是
        // 被送到一扇看不见的窗口。主窗也在此列——它的模型还留着（会话要留给
        // 下次启动），可窗口本身已经不在了。
        closedWindows.insert(model.id)
        shared.openDocuments.release(model.id)
        noteWindowState("close")
        bindings.removeAll { $0.model.id == model.id }
        guard model.id != primary.id else { return }
        model.workspace.close()
        finishRecord(for: model)
        windows[model.id] = nil
        pendingFrames[model.id] = nil
    }

    /// 关掉一扇窗 = 结束它那一条账。
    ///
    /// 例外：这扇窗里还有一篇没有名字的字。草稿已经在盘上，可窗口一关就再没有
    /// 入口把它拿回来——所以第一次只留一条「留一手」记录，下次启动把它放回原处。
    /// 第二次关窗意味着「我已经看见它了」，那就真的关掉。
    private func finishRecord(for model: WindowModel) {
        if model.holdsUnnamedWords, ledger.entry(for: model.id)?.parked != true {
            ledger.setParked(true, for: model.id)
            return
        }
        model.session.endRecord()
        ledger.remove(model.id)
        Self.removeDraftDirectory(for: model.id, root: draftRoot)
    }

    // MARK: - 窗口位置

    /// 恢复的窗该站在哪儿；用掉就删，之后拖到哪儿由读者说了算。
    func takePendingFrame(for id: UUID) -> CGRect? {
        pendingFrames.removeValue(forKey: id)
    }

    func rememberFrame(_ frame: CGRect, for id: UUID) {
        ledger.setFrame(frame, for: id)
    }

    /// 记下这扇窗口与它的 `NSWindow` 的对应关系（用于判断前台是哪扇窗）。
    func register(window: NSWindow?, for model: WindowModel) {
        guard let window else { return }
        bindings.removeAll { $0.window === window }
        bindings.append(Binding(window: window, model: model))
        // 主窗 ⌘W 关掉又重开时，关窗那一刻放掉的登记在这里补回来；副窗则是
        // 每次都幂等地写一遍当前这一篇。
        closedWindows.remove(model.id)
        shared.openDocuments.update(model.store.fileURL, for: model.id)
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

    /// 这扇窗的账结束了，它的草稿家也一并收走：留下的目录没有人会再来打开。
    static func removeDraftDirectory(for id: UUID, root: URL? = nil) {
        try? FileManager.default.removeItem(at: temporaryDraftDirectory(for: id, root: root))
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
