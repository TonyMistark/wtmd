import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WTMarkdownKit

enum ViewMode: String, CaseIterable, Identifiable {
    case edit
    case preview
    /// 源码与成文并排。只在窗口够宽时出现，见 `SplitLayout`。
    case split

    var id: String { rawValue }
    /// 中心思想的界面落点：源码是思绪的原貌，预览是思绪的成文。
    var label: String {
        switch self {
        case .edit: return t("Source", "思绪")
        case .preview: return t("Preview", "成文")
        case .split: return t("Split", "对照")
        }
    }

    /// 工具栏那个按钮的图标。三种视图共用一个按钮，图标就是「现在在哪」。
    var symbol: String {
        switch self {
        case .edit: return "character.cursor.ibeam"
        case .preview: return "doc.richtext"
        case .split: return "rectangle.split.2x1"
        }
    }

    /// 三个符号的原始尺寸并不一样（16×16 / 14×16 / 18×14，且随系统版本略有出入——
    /// macOS 15 上分栏符号量出来是 19 宽）：统一收进同一个格子，切换时按钮不会忽宽忽窄，
    /// 旁边的工具栏项也不会跟着挪位置。格子留一点余量，别让新版系统裁掉一笔。
    static let iconSize = CGSize(width: 20, height: 18)

    /// 单击依次经过的下一种视图：思绪 → 成文 → 对照 → 回到思绪。
    ///
    /// The ring is `allCases` own order, so reordering it means moving the
    /// `case` lines — no second list to keep in sync.
    var next: ViewMode {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return .edit }
        return all[(index + 1) % all.count]
    }

    /// 悬停提示：先说现在在哪（这个视图是干什么的），再说点下去去哪。
    ///
    /// Always opens with `label`, so the tooltip answers "where am I" first —
    /// the question a single cycling button makes people ask.
    var cycleHint: String {
        let detail: String
        switch self {
        case .edit:
            detail = t(
                "just you and the text. Click for \(next.label).",
                "只有源码，专心写。点击切到\(next.label)"
            )
        case .preview:
            detail = t(
                "the finished page, no editing. Click for \(next.label).",
                "只读成文。点击切到\(next.label)"
            )
        case .split:
            detail = t(
                "type on the left, the page follows on the right. Click for \(next.label).",
                "左边写，右边跟着成文。点击回到\(next.label)"
            )
        }
        return "\(label) · \(detail)"
    }
}

struct JumpRequest: Equatable {
    let id: String
    let line: Int
    /// UTF-16 offset of the target inside `line`. Zero means "start of line",
    /// which is all an outline heading asks for.
    var column: Int = 0
    /// How much text to select at the target; zero just places the caret.
    var length: Int = 0
    let slug: String
}

/// 磁盘上的文件和编辑器里的版本对不上了。
///
/// 自动保存是「读者没下命令也在写盘」，所以它必须先确认磁盘还是上次看到的那个
/// 版本——否则同步盘、另一个编辑器、`git checkout` 的改动会被一声不响地盖掉。
enum ExternalChange: Equatable {
    /// 文件还在，但内容被别处改过（`mtime` 变了）。
    case modified
    /// 文件已经不在了。
    case deleted
    /// 同一篇也被本应用的另一个窗口开着。
    ///
    /// 正常路径上走不到这里：打开会跳到已有窗口、启动恢复会去重。它是给「两条
    /// 记录绕过了 UI」留的网——升级前就同时开着两扇窗，或有人手工改了 defaults。
    /// 两扇窗都在写同一份文件时，谁后落盘谁赢，先落的那一份不会有人知道。
    case heldElsewhere
}

/// 读者对 `ExternalChange` 的选择。
enum ExternalChangeResolution: Equatable {
    /// 我的版本赢：写回去，把磁盘基线刷成这次写入的 `mtime`。
    case keepLocal
    /// 磁盘的版本赢：重新载入，未保存的修改作废。
    case reloadDisk
    /// 文件已经没了：另存到一个新路径。
    case saveAs
    /// 文件已经没了：内容留在草稿里，文档转为未命名。
    case keepAsDraft
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var text: String
    @Published var fileURL: URL?
    @Published var mode: ViewMode = .edit
    @Published var outline: [OutlineItem] = []
    @Published var previewHTML: String = ""
    /// 每个顶层块的源码起始行（与渲染出的块一一对应，脚注区为 -1）。
    ///
    /// 分栏联动靠它把「预览里的第几块」翻译成「源码里的第几行」。不进块 HTML：
    /// 那样每在文档前面插一行，后面所有块的字符串都会变，增量 diff 全盘失效。
    @Published var blockLines: [Int] = []
    /// 增量渲染：上次已渲染的块数组（diff 基准）。
    private var renderedBlocks: [String] = []
    /// 挂起的增量更新（预览视图消费后清空）。
    @Published var pendingDiff: BlockDiff?
    @Published var currentSlug: String?
    @Published var cursorLine: Int = 0
    @Published var sidebarVisible = true
    @Published var editorJump: JumpRequest?
    @Published var previewJump: JumpRequest?
    /// 待插入编辑器的图片引用（EditorTextView 消费后置 nil）。
    @Published var pendingImageInsert: String?
    /// 当前文档统计（字数/词数/阅读时长）。
    @Published var statistics = TextStatistics(characters: 0, words: 0, readingMinutes: 0)
    /// 强制预览整体重载的代数（打开新文件时递增，重置滚动位置）。
    @Published var renderGeneration = 0
    /// Whether a writing session has been entered in this launch (a document was
    /// created or opened). A blank document the user just asked for must not fall
    /// back to the welcome screen, which is what happened when the condition was
    /// derived from `text.isEmpty` alone.
    @Published private(set) var hasStartedWriting = false
    /// 磁盘与编辑器不一致，等着读者决定用谁的版本。非空期间自动保存**不写盘**。
    @Published private(set) var externalChange: ExternalChange?
    /// 冲突未解决就切走时留下的本地副本（`conflicts/` 目录）。最新的在前。
    @Published private(set) var archivedConflicts: [ConflictArchiveEntry] = []
    /// 刚存下一份副本时的一句提示，几秒后自己消失——存档不能是无声的。
    @Published private(set) var archiveNotice: String?
    /// 当前这篇的旧版，最新的在前。面板读它；换文档、别窗留版、删版都会刷新。
    @Published private(set) var historyEntries: [HistoryEntry] = []
    /// 版本历史面板是否展开。每扇窗口各一份——A 窗翻着旧稿，不该盖在 B 窗上。
    @Published var historyVisible = false
    /// 写作日历面板是否展开。同上，每扇窗口各一份。
    @Published var calendarVisible = false
    /// 崩溃报告面板是否展开。只有主窗会主动打开它（启动时发现上次崩了）。
    @Published var crashVisible = false
    /// 面板当前展示哪一份。`nil` 表示「最新的那份还没看过的」。
    private(set) var crashFocusID: String?

    /// Single source of truth for the welcome screen. Kept on the store (instead
    /// of inline in the view body) so the condition is unit-testable.
    var showsWelcome: Bool {
        text.isEmpty && fileURL == nil && !hasStartedWriting
    }

    let recentFiles: RecentFiles
    /// 主题是应用的，不是窗口的：所有窗口共用一份，切主题时一起变。
    let themeManager: ThemeManager
    /// 屏幕上的版式（字号/行距）。App 启动时接上；`nil` 表示用默认值——
    /// 打印要把读者调好的字带进纸里，但 store 自己不该拥有这份设置。
    var typesetting: TypesettingSettings?
    /// 纸上版式（页边距/页码/标题）。同上。
    var printSettings: PrintSettings?
    /// 每日净增字数的账本。`nil`（测试默认）表示不记账，绝不写真实的 preferences。
    let writingStats: WritingStats?
    /// 跨视图重建的位置账本：`⌘/` 会销毁并重建编辑器/预览，位置得存在视图之外。
    let positionMemory = PositionMemory()
    /// 文档内查找。状态跟着窗口走，不落盘——关掉应用再打开，没人期待搜索框还在。
    let find = FindController()
    /// 工作区全文搜索（⌘⇧F）。同样不落盘。
    let workspaceSearch = WorkspaceSearchController()
    /// 待执行的替换（编辑器消费后保留 id，避免重复执行）。
    @Published var replaceRequest: ReplaceRequest?

    /// 未命名文档另存时的默认目录（当前工作区）。由视图在切换工作区时写入；
    /// `nil` 就交给系统记得的上次位置。
    var preferredSaveDirectory: URL?

    private let draftDirectory: URL
    /// Debounce before an edit is persisted. Injectable so tests do not have to
    /// sit through the production 1.2s interval for every case.
    private let autoSaveDelay: UInt64
    /// What survived the last launch. `nil` means "this instance keeps nothing":
    /// the default for tests, which must never touch the user's real session.
    private let session: Session?
    /// 冲突副本的存放处。`nil`（测试默认）表示不存档，绝不污染真实的
    /// `~/Library/Application Support/wtmd/conflicts`。
    private let conflicts: ConflictArchive?
    /// 版本历史的存放处。`nil`（测试默认）表示不留历史，绝不写真实的
    /// `~/Library/Application Support/wtmd/history`。
    private let history: DocumentHistory?
    /// 崩溃报告的账房。`nil`（测试默认）表示不碰真实的
    /// `~/Library/Application Support/wtmd/crashes`。
    private let crashes: CrashStore?
    /// 这扇窗的身份。应用级的「谁开着哪一篇」靠它区分窗口。
    private let windowID: UUID
    /// 应用级的「谁开着哪一篇」。`nil`（测试默认）表示不设防：同一个进程里
    /// 每扇窗都自己开自己的，谁也不问别人。
    private let openDocuments: OpenDocuments?
    /// The file's modification date as of the last read or write. A mismatch
    /// against the disk later means someone else touched the file.
    private(set) var knownModificationDate: Date?
    private var savedSnapshot: String = ""
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Keeps the exit observers alive; removed in `deinit`.
    private var exitObservers: [NSObjectProtocol] = []
    /// 把 `find` 的变化转成 store 的变化——查找条与编辑器都挂在 ContentView 上。
    private var findObservation: AnyCancellable?
    /// 存档提示的自动隐去。
    private var archiveNoticeTask: Task<Void, Never>?
    /// 把账本的变化转成 store 的变化——状态栏挂在 ContentView 上，只认 store。
    private var writingStatsObservation: AnyCancellable?
    /// 副本库是应用级的：订阅它，别的窗口存档时这扇窗也能看见。
    private var conflictsObservation: AnyCancellable?
    /// 版本历史也是应用级的：别的窗口留下一版，这扇窗的面板也要跟上。
    private var historyObservation: AnyCancellable?
    /// 换了文档就换一份历史清单——旧稿的版本不该出现在新稿的面板里。
    private var historyFileObservation: AnyCancellable?
    /// 每打开/新建一篇就 +1：它参与 `documentKey`，让「换了文档」永远能被认出来。
    /// 未命名草稿改成空文档时路径没变，只看路径会把清空算成删了几百字。
    private var documentEpoch = 0
    /// 读者已经见过「这篇也在别窗开着」的提示，决定接着写。之后不再拦——
    /// 写盘前的 mtime 核对仍然在，另一边保存时会看到冲突横幅。
    private var acceptedSharedHold = false
    /// 另存为撞上别窗占着的文件时，怎么告诉读者。测试换成记账的假提示：
    /// 真的 `NSAlert` 是模态的，会把测试挂在那儿。
    var reportHeldSaveTarget: ((URL) -> Void)?

    static let welcomeMarkdown = """
    # 欢迎使用 wtmd

    **Where Thoughts Meet Documents** —— 思绪落下的一刻，成文已然成型。

    ## 快速上手

    - 使用 `⌘/` 在**思绪**（源码）与**成文**（预览）之间切换
    - 左侧大纲随标题自动生成，点击即可跳转
    - `⌘O` 打开文件，`⌘S` 保存 —— 文件永远属于你自己
    - 未命名草稿自动保存，重启不丢

    ## 语法速览

    支持**粗体**、*斜体*、~~删除线~~、`行内代码` 与 [链接](https://example.com)，还有脚注[^1]。

    > 写作工具应当隐形，心流高于一切。

    [^1]: 脚注：补充说明放在文末，正文保持心流。

    ### 代码块

    ```swift
    let greeting = "Hello, wtmd!"
    print(greeting)
    ```

    ### 任务列表

    - [x] 双模式视图
    - [x] 大纲导航
    - [ ] 自定义主题（v0.2）

    ### 表格

    | 操作 | 快捷键 |
    | --- | :---: |
    | 思绪 ⇄ 成文 | ⌘/ |
    | 打开文件 | ⌘O |
    | 保存 | ⌘S |

    ---

    MIT 开源协议 · 数据本地存储 · 标准纯文本
    """

    init(
        draftDirectory: URL? = nil,
        autoSaveDelay: UInt64 = 1_200_000_000,
        session: Session? = nil,
        conflicts: ConflictArchive? = nil,
        history: DocumentHistory? = nil,
        crashes: CrashStore? = nil,
        writingStats: WritingStats? = nil,
        themeManager: ThemeManager? = nil,
        recentFiles: RecentFiles? = nil,
        windowID: UUID = UUID(),
        openDocuments: OpenDocuments? = nil
    ) {
        let directory = draftDirectory ?? Self.defaultDraftDirectory
        self.draftDirectory = directory
        self.autoSaveDelay = autoSaveDelay
        self.session = session
        self.conflicts = conflicts
        self.history = history
        self.crashes = crashes
        self.writingStats = writingStats
        self.themeManager = themeManager ?? ThemeManager()
        self.recentFiles = recentFiles ?? RecentFiles()
        self.windowID = windowID
        self.openDocuments = openDocuments
        self.archivedConflicts = conflicts?.entries() ?? []

        // 上次打开的那篇优先于草稿：读者按下 ⌘Tab 回来，期待看到的是刚才在写的东西，
        // 而不是「今天早上那份未命名草稿」。
        let storedURL = session?.openFileURL
        let restored = storedURL.flatMap(Self.readDocument(at:))
        var restoredPosition: Session.Position?
        if let restored, let storedURL {
            text = restored.content
            fileURL = storedURL
            savedSnapshot = restored.content
            hasStartedWriting = true
            knownModificationDate = restored.modifiedAt
            renderGeneration = 1
            restoredPosition = session?.position(for: storedURL)
        } else if let draft = Self.readDraft(at: directory), !draft.isEmpty {
            text = draft
        } else {
            text = Self.welcomeMarkdown
            Self.writeDraft(text, at: directory)
        }
        // 文件在两次启动之间被删了：别再指向一个不存在的路径
        if storedURL != nil, restored == nil {
            session?.setOpenFile(nil)
        }
        recomputeNow()
        if let restoredPosition, let storedURL {
            seedPosition(from: restoredPosition, for: storedURL, generation: renderGeneration)
        }
        observeExitForPendingEdits()

        find.attach(text)
        findObservation = find.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        // 正在编辑的这一篇以内存内容参与工作区搜索：磁盘副本可能还停在
        // 上一次自动保存，读者刚敲下的词必须搜得到。
        workspaceSearch.liveDocument = { [weak self] in
            guard let self, let url = self.fileURL else { return nil }
            return (url, self.text)
        }
        writingStatsObservation = writingStats?.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        // 副本库是应用级一份：别的窗口存下/取走副本时，这扇窗的列表也要跟上，
        // 否则「还有一份没取回的字」只在存下它的那扇窗里看得见。
        conflictsObservation = conflicts?.objectWillChange.sink { [weak self] in
            self?.refreshArchivedConflicts()
        }
        // 历史面板跟着两件事走：这篇换了（`fileURL`），或者历史本身变了
        // （本窗刚写下一版、别的窗留下一版、读者删掉一版）。
        refreshHistory()
        historyFileObservation = $fileURL
            .removeDuplicates()
            // `@Published` 在 `willSet` 里发出：闭包里拿到的才是新值，`self.fileURL`
            // 此刻还是旧的。直接用它，否则「换到另一篇」会读到上一篇的历史。
            .sink { [weak self] url in self?.refreshHistory(for: url) }
        historyObservation = history?.objectWillChange.sink { [weak self] in
            self?.refreshHistory()
        }
    }

    // MARK: - 状态

    var isDirty: Bool { text != savedSnapshot }
    var displayName: String { fileURL?.lastPathComponent ?? t("Untitled.md", "未命名.md") }
    var windowTitle: String { (isDirty ? "● " : "") + displayName }

    func textDidChange(_ new: String) {
        text = new
        find.attach(new)
        scheduleRender()
        scheduleSave()
    }

    // MARK: - 查找替换

    /// `⌘F` / `⌥⌘R`。
    ///
    /// 成文模式里没有源码可高亮，按 ⌘F 先切到对照——读者找东西时想看的是
    /// 「它在原文哪儿」，而不是一个找不到落点的计数。
    func showFind(replacing: Bool = false) {
        if mode == .preview { setMode(.split) }
        find.attach(text)
        find.present(focusingReplacement: replacing)
    }

    func hideFind() {
        find.dismiss()
        replaceRequest = nil
    }

    /// 编辑器执行完替换后回调：请求是一次性的，留着会在视图重建时被重放。
    func consumeReplaceRequest() {
        replaceRequest = nil
    }

    /// 换文档时作废查找：上一个文档的命中区间放到新文本里毫无意义。
    private func resetFind() {
        find.dismiss()
        replaceRequest = nil
        find.attach(text)
    }

    /// 替换当前命中，并把「下一处」放到替换文本之后。
    func replaceCurrentMatch() {
        guard let target = find.currentMatch else { return }
        let newLength = (find.replacement as NSString).length
        find.noteReplacement(at: target, newLength: newLength)
        replaceRequest = ReplaceRequest(
            id: UUID().uuidString,
            range: target,
            replacement: find.replacement,
            selectionAfter: NSRange(location: target.location + newLength, length: 0)
        )
    }

    /// 全部替换。整篇一次改完：`⌘Z` 退一步就全回来了。
    func replaceAllMatches() {
        guard let first = find.matches.first else { return }
        guard let updated = FindEngine.replacingAll(
            in: text, query: find.query, options: find.options, template: find.replacement
        ) else { return }
        find.noteReplaceAll()
        replaceRequest = ReplaceRequest(
            id: UUID().uuidString,
            range: NSRange(location: 0, length: (text as NSString).length),
            replacement: updated,
            selectionAfter: NSRange(
                location: min(first.location, (updated as NSString).length), length: 0
            )
        )
    }

    func setMode(_ newMode: ViewMode) {
        guard newMode != mode else { return }
        mode = newMode
        // 预览与对照都要现成的 HTML；切回源码不必重算
        if newMode != .edit { recomputeNow() }
    }

    /// `⌘/`：思绪 ⇄ 成文。从对照按下去回到思绪——单视图里最想回到的是能打字的那一边。
    func toggleMode() {
        setMode(mode == .edit ? .preview : .edit)
    }

    /// `⌘⇧\`：进入 / 离开对照。
    func toggleSplit() {
        setMode(mode == .split ? .edit : .split)
    }

    /// 工具栏上那一个按钮：视图不是三选一，是同一个位置的一圈状态。
    func cycleMode() {
        setMode(mode.next)
    }

    /// 编辑模式下当前光标所在章节 slug（用于大纲高亮）。对照模式下光标在源码里，
    /// 跟着光标走比跟着预览滚动走更贴近「我在哪一段」。
    var currentOutlineSlug: String? {
        if mode == .preview { return currentSlug }
        return outline.last(where: { $0.line <= cursorLine })?.slug
    }

    func jump(to item: OutlineItem) {
        let request = JumpRequest(id: UUID().uuidString, line: item.line, slug: item.slug)
        switch mode {
        case .edit:
            editorJump = request
        case .preview:
            previewJump = request
        case .split:
            // 两侧一起走：左边落到那一行，右边滚到那个标题
            editorJump = request
            previewJump = request
        }
        currentSlug = item.slug
    }

    // MARK: - 图片粘贴落地

    /// 编辑器粘贴回调：图片数据 → assets/ 文件 → 待插入引用。
    /// 返回 true 表示已处理（编辑器跳过默认粘贴）。
    func handleImagePaste(_ pngData: Data) -> Bool {
        guard let saved = ImageAssets.save(pngData: pngData, documentURL: fileURL) else {
            return false // 用户取消选目录 → 不拦截，继续默认粘贴
        }
        pendingImageInsert = saved.relativePath
        return true
    }

    // MARK: - 渲染

    /// 一次编辑所需的全部渲染产物（跨线程传递，全部 Sendable）。
    private struct RenderOutput: Sendable {
        let html: String
        let blocks: [String]
        /// 每个顶层块的源码起始行（与 `blocks` 平行）。分栏联动用。
        let blockLines: [Int]
        let outline: [OutlineItem]
        let statistics: TextStatistics
    }

    /// 解析 + 渲染 + 统计：纯函数，不触碰任何状态，可在后台线程执行。
    nonisolated private static func build(_ markdown: String) -> RenderOutput {
        let result = WTMarkdown.render(markdown)
        return RenderOutput(
            html: result.html,
            blocks: result.blocks,
            blockLines: result.blockLines,
            outline: result.outline,
            statistics: TextStatistics.count(markdown)
        )
    }

    /// 全量重渲染：打开文件 / 切换模式 / 新建等低频场景（同步，保证首帧即有内容）。
    private func recomputeNow() {
        let output = Self.build(text)
        outline = output.outline
        previewHTML = output.html
        blockLines = output.blockLines
        statistics = output.statistics
        noteWritingProgress()
        // DOM 基准与即将注入的全文一致，后续编辑可直接走增量
        renderedBlocks = output.blocks
        pendingDiff = nil
    }

    /// 增量应用：块级 diff 在主线程完成（O(块数) 比较，与文档长度基本无关），
    /// 未变化块的 DOM 节点保持原位（图片已解码结果不重画）。
    private func applyIncremental(_ output: RenderOutput) {
        outline = output.outline
        statistics = output.statistics
        noteWritingProgress()
        previewHTML = output.html
        blockLines = output.blockLines

        let diff = BlockDiff.compute(old: renderedBlocks, new: output.blocks)
        renderedBlocks = output.blocks
        // 块数组完全一致时没有可发的增量，显式清空避免上一轮的 diff 被重复套用
        pendingDiff = diff.isEmpty ? nil : diff
    }

    // MARK: - 每日字数

    /// 认「是不是同一篇」用的身份：归一路径 + 代数。
    ///
    /// 路径走 canonical：`/var` 与 `/private/var` 是同一份文件，不该让账本以为换了篇。
    /// 未命名草稿没有路径，新建之后仍是同一串 `-`——只靠路径的话，把一篇
    /// 五百字的草稿换成空文档会被算成「删了五百字」，所以还要带上代数。
    private var documentKey: String {
        let path = fileURL.map { WorkspaceStore.canonicalPath($0) } ?? "-"
        return "\(path)#\(documentEpoch)"
    }

    /// 统计一更新就报给账本：同一篇报两次，差就是净增。
    private func noteWritingProgress() {
        writingStats?.observe(document: documentKey, characters: statistics.characters)
    }

    /// 结算前先按正文**同步**数一遍字数：防抖里最后半秒敲的字还没进
    /// `statistics`，直接结算会把它们漏掉。全篇数一次只发生在切文档与退出。
    private func settleWritingStats() {
        guard let writingStats else { return }
        writingStats.observe(
            document: documentKey,
            characters: TextStatistics.count(text).characters
        )
        writingStats.settle()
    }

    private func scheduleRender() {
        renderTask?.cancel()
        let snapshot = text
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            // 重活（解析/渲染/统计）放后台线程，主线程只负责 diff 与状态赋值
            let output = await Task.detached(priority: .userInitiated) {
                Self.build(snapshot)
            }.value
            // 期间又发生编辑或本任务已被取消 → 丢弃，交给下一次防抖
            guard !Task.isCancelled, let self, self.text == snapshot else { return }
            self.applyIncremental(output)
        }
    }

    // MARK: - 文件

    func newDocument() {
        flushPendingSave()
        recordSessionPosition()
        // 换一篇之前先把上一位读者的处境收好：冲突没解决的本地版本进副本
        archiveLocalVersionIfConflicted()
        text = ""
        fileURL = nil
        savedSnapshot = ""
        knownModificationDate = nil
        acceptedSharedHold = false
        // The user explicitly asked for a blank document, so the welcome screen
        // must step aside — otherwise the empty text immediately brings it back
        // and the button looks dead.
        hasStartedWriting = true
        renderGeneration += 1
        documentEpoch += 1
        recomputeNow()
        mode = .edit
        clearDraft()
        session?.setOpenFile(nil)
        resetFind()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) { open(url: url, jumpingTo: nil) }

    /// 工作区搜索的一条命中：打开那篇，并把光标放到命中词上。
    func openSearchHit(_ hit: WorkspaceHit) {
        open(
            url: hit.fileURL,
            jumpingTo: JumpRequest(
                id: UUID().uuidString,
                line: hit.line,
                column: hit.column,
                length: hit.length,
                slug: ""
            )
        )
    }

    /// Opens a document, optionally landing on a specific character range.
    ///
    /// With a target, the remembered position is **not** restored: the reader
    /// just said which sentence they are looking for, and putting them back
    /// where they last stopped would quietly undo that.
    func open(url: URL, jumpingTo request: JumpRequest?) {
        // Clicking the file that is already open (in the workspace tree, say)
        // must not reload the preview and throw away the scroll position.
        if url == fileURL {
            guard let request else { return }
            // 同一篇：不重载，只把光标送到命中处
            if mode == .preview { mode = .edit }
            editorJump = request
            return
        }
        // 这篇已经在另一扇窗里开着：跳过去，而不是在这里再开一份。两份各写各的，
        // 谁后落盘谁赢，另一边刚敲的字就没了。读盘之前就拦，连预览都不重建。
        if openDocuments?.handOver(url, jumpingTo: request, from: windowID) == true {
            return
        }
        guard let document = Self.readDocument(at: url) else { return }
        // Flush only after the read succeeded: a failed open must not discard
        // unsaved work.
        flushPendingSave()
        // 切走之前把这一篇停在哪里记下来，否则「在文件树里点来点去」的轨迹全丢
        recordSessionPosition()
        // 横幅跟着文档走：换了一篇，上一篇的冲突与这一篇无关。但本地那份不能跟着
        // 一起消失——没解决的冲突先存档。
        archiveLocalVersionIfConflicted()
        text = document.content
        fileURL = url
        savedSnapshot = document.content
        knownModificationDate = document.modifiedAt
        // 崩溃报告里的「手上是哪一篇」：只记文件名，不记内容。
        CrashBreadcrumbs.note("doc \(url.lastPathComponent)")
        // 「打开时的样子」本身就是一版：今天的删改通常是相对它而言的。
        // 内容与最新一版相同就什么也不做（`capture` 自己去重）。
        history?.capture(document.content, for: url, force: true)
        acceptedSharedHold = false
        recentFiles.add(url)
        hasStartedWriting = true
        renderGeneration += 1
        documentEpoch += 1
        if let request {
            // 行列只存在于源码里：预览没有行号可落
            if mode == .preview { mode = .edit }
            editorJump = request
        } else if let recorded = session?.position(for: url) {
            // 这一篇之前被读过（本次运行或上次启动）就回到当时的位置
            seedPosition(from: recorded, for: url, generation: renderGeneration)
        }
        session?.setOpenFile(url)
        recomputeNow()
        resetFind()
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        // ⌘S 也是「写盘」，同样不能盖掉别处刚改过的版本：交给横幅让读者选。
        if let change = detectExternalChange() ?? detectSharedHold() {
            externalChange = change
            archiveIfHeldElsewhere(change)
            return
        }
        let targetURL: URL
        if let existing = fileURL {
            targetURL = existing
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = t("Untitled.md", "未命名.md")
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            // 工作区打开着就以它为默认落点：读者已经在那个文件夹里了，
            // 再让他从「文稿」一路导航过去是多出来的一步。
            if let preferredSaveDirectory {
                panel.directoryURL = preferredSaveDirectory
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            targetURL = url
        }
        save(to: targetURL)
    }

    /// 把这一份写到 `url`。单独成一步是因为 `NSSavePanel` 在测试里开不出来，
    /// 而「落点被另一扇窗占着就不写」这条规矩必须能被验证。
    ///
    /// - Returns: 落盘成功为 `true`；落点被占或写入失败为 `false`。
    @discardableResult
    func save(to url: URL) -> Bool {
        guard !isHeldElsewhere(url) else {
            reportHeldTarget(url)
            return false
        }
        // 落盘只有 `writeFile` 一条路：正文、基线、版本历史都在那里一次做完。
        // 两条路各写一遍，迟早有一条忘了顺手做的事。
        if let error = writeFile(text, to: url) {
            NSAlert(error: error).runModal()
            return false
        }
        if fileURL == nil { fileURL = url }
        recentFiles.add(url)
        session?.setOpenFile(url)
        clearDraft()
        return true
    }

    /// 这篇在**另一扇**窗里开着吗？
    func isHeldElsewhere(_ url: URL) -> Bool {
        openDocuments?.isHeldElsewhere(url, than: windowID) ?? false
    }

    private func reportHeldTarget(_ url: URL) {
        if let reportHeldSaveTarget {
            reportHeldSaveTarget(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = t(
            "That file is open in another window",
            "这个文件正在另一扇窗口里打开"
        )
        alert.informativeText = t(
            "Saving here would overwrite what is being written there. Close it in that window first, or choose another name.",
            "存到这里会盖掉那扇窗里正在写的内容。请先在那里关掉它，或者换一个文件名。"
        )
        alert.runModal()
    }

    /// 冲突未解决就要退出/关窗：磁盘上那份是别人的版本，不去动它；自己的改动
    /// 留在草稿里，下次启动以未命名文档出现——总比一声不响地丢掉好。
    private func preserveLocalVersionIfConflicted() {
        guard externalChange != nil, isDirty else { return }
        Self.writeDraft(text, at: draftDirectory)
        session?.setOpenFile(nil)
    }

    // MARK: - 冲突副本

    /// 冲突没解决就要切走：磁盘那份是别人的，不去动它；编辑器里这份是读者写的，
    /// 也不能一声不响地扔掉。折中是存成副本留在 `conflicts/`，状态栏留个入口。
    ///
    /// **不拦切换**：写作工具不该为了保住一段话先开一场对话。存下副本本身就是
    /// 「已经保住了」的证据，取不取回是之后的事。
    private func archiveLocalVersionIfConflicted() {
        let change = externalChange
        if change != nil { externalChange = nil }
        // 「另一扇窗也开着」在发现的那一刻就已经存过一份了（`archiveIfHeldElsewhere`），
        // 切走时再存一份只会让副本库里多一份一模一样的字。
        guard let change, change != .heldElsewhere, isDirty, let conflicts else { return }
        guard let entry = conflicts.archive(text, originalURL: fileURL) else { return }
        refreshArchivedConflicts()
        showArchiveNotice(t("Saved a local copy of \(entry.originalName) to the conflict archive", "已把「\(entry.originalName)」的本地版本存入冲突副本"))
    }

    private func refreshArchivedConflicts() {
        archivedConflicts = conflicts?.entries() ?? []
    }

    /// 副本所在的文件夹，供界面「在访达中打开」用。
    var conflictFolder: URL? { conflicts?.directory }

    private func showArchiveNotice(_ message: String) {
        archiveNotice = message
        archiveNoticeTask?.cancel()
        archiveNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.archiveNotice = nil
        }
    }

    /// 把副本取回编辑器：作为**未命名文档**打开，而不是直接写回原文件。
    /// 原文件此刻是别人的版本，要不要盖掉得读者拿主意；他要做的只是先救回自己的字。
    func recoverArchivedConflict(_ entry: ConflictArchiveEntry) {
        guard let conflicts, let content = conflicts.content(of: entry) else { return }
        flushPendingSave()
        archiveLocalVersionIfConflicted()
        recordSessionPosition()
        conflicts.remove(entry)
        refreshArchivedConflicts()
        text = content
        fileURL = nil
        savedSnapshot = ""
        knownModificationDate = nil
        hasStartedWriting = true
        renderGeneration += 1
        documentEpoch += 1
        mode = .edit
        session?.setOpenFile(nil)
        recomputeNow()
        resetFind()
    }

    func discardArchivedConflict(_ entry: ConflictArchiveEntry) {
        conflicts?.remove(entry)
        refreshArchivedConflicts()
    }

    // MARK: - 版本历史

    /// 历史所在的文件夹，供面板「在访达中打开」用。
    var historyFolder: URL? { history?.directory }

    /// 这篇有没有历史可翻。菜单与命令面板据此决定是不是灰着。
    var canBrowseHistory: Bool { fileURL != nil && !historyEntries.isEmpty }

    /// 打开面板。先刷新一次：读者可能刚在 Finder 里删过历史文件。
    func showHistory() {
        refreshHistory()
        historyVisible = true
    }

    /// 打开写作日历。账本是应用级的，窗口只负责把它摊开——
    /// 没设目标、甚至一天没写，也让它打开：空态会自己解释。
    func showCalendar() {
        calendarVisible = true
    }

    /// 把某一版装回编辑器。
    ///
    /// **先留当前这一版**（`force`）：否则「取回旧版」这个动作本身就会把读者
    /// 刚写的那一段变成唯一没存过的内容——想反悔时已经没得翻了。
    ///
    /// `fileURL` 不动：这是「回到这篇的某一版」，不是另存为一篇。写盘交给自动
    /// 保存（和普通编辑一样，走磁盘版本核对与多窗占用那三道口），所以恢复之后
    /// 编辑器立刻是脏的，标题上那个点也在。
    ///
    /// `documentEpoch` 前进一代：字数账本按文档记账，一次恢复不是「今天删了几千字」，
    /// 而应当重新起算。
    func restoreHistory(_ entry: HistoryEntry) {
        guard let history, let content = history.content(of: entry) else {
            historyVisible = false
            return
        }
        if let fileURL {
            history.capture(text, for: fileURL, force: true)
        }
        cancelScheduledSave()
        text = content
        hasStartedWriting = true
        renderGeneration += 1
        documentEpoch += 1
        mode = .edit
        recomputeNow()
        resetFind()
        // 装回去的内容要落盘，走的是平时那条自动保存
        scheduleSave()
        historyVisible = false
    }

    /// 删掉某一版。内容没了就没了——面板上问过一次才点得到这里。
    func discardHistory(_ entry: HistoryEntry) {
        history?.remove(entry)
        refreshHistory()
    }

    /// 忘掉这篇的全部历史（连目录）。
    func clearHistory() {
        guard let history, let fileURL else { return }
        history.removeAll(for: fileURL)
        refreshHistory()
        showArchiveNotice(t("Cleared the version history of \(displayName)", "已清除「\(displayName)」的版本历史"))
    }

    // MARK: - 崩溃报告

    /// 上次崩了：把面板打开。启动时由窗口协调器调用，其余入口是菜单里的
    /// 「报告问题」。
    func showCrashPrompt(id: String? = nil) {
        crashFocusID = id
        crashVisible = true
    }

    /// 面板展示的那一份：优先当前聚焦的，否则最新一份没看过的。
    var crashReport: CrashReport? {
        guard let crashes else { return nil }
        if let crashFocusID, let focused = crashes.report(id: crashFocusID) { return focused }
        return crashes.pending.first
    }

    /// 同一个文件夹里还有几份没处理。连着崩的时候只展示最新的那份。
    var crashExtraCount: Int {
        guard let crashes else { return 0 }
        let pending = crashes.pending
        guard let shown = crashReport, pending.contains(where: { $0.id == shown.id }) else {
            return pending.count
        }
        return pending.count - 1
    }

    var crashFolder: URL? { crashes?.directory }

    func copyCrashReport(_ report: CrashReport) {
        crashes?.copyToPasteboard(report)
    }

    func revealCrashReport(_ report: CrashReport) {
        crashes?.reveal(report)
    }

    /// 「在 GitHub 上报告」：打开预填页面，然后翻到下一份（没有就关掉面板）。
    /// 浏览器没打开就**不关**——报告还在，读者可以复制了自己贴。
    func openCrashIssue(_ report: CrashReport) {
        guard let crashes, crashes.openIssue(for: report) else { return }
        // 连着崩过几次的话，这一份说完还有下一份——一扇窗里挨个说完，不用重开。
        if let next = crashes.pending.first(where: { $0.id != report.id }) {
            crashFocusID = next.id
        } else {
            crashVisible = false
            crashFocusID = nil
        }
    }

    /// 「忽略」：记成看过了，下次启动不再问。文件仍留在磁盘上。
    func dismissCrashPrompt() {
        crashes?.markAllSeen()
        crashVisible = false
        crashFocusID = nil
    }

    /// 菜单里的「报告问题…」：不带崩溃现场，只有版本、系统与当前文档名。
    ///
    /// 先摊开面板、不直接拉浏览器：让人看一眼要发出去的是什么，再按那个按钮。
    /// 「发不发」这件事，不该由一个菜单项替他决定。
    func reportProblem() {
        guard let crashes else { return }
        let report = crashes.recordFeedback(
            note: "", documentName: fileURL == nil ? nil : displayName
        )
        showCrashPrompt(id: report.id)
    }

    private func refreshHistory() {
        refreshHistory(for: fileURL)
    }

    private func refreshHistory(for url: URL?) {
        guard let history, let url else {
            if !historyEntries.isEmpty { historyEntries = [] }
            return
        }
        let entries = history.entries(for: url)
        if entries != historyEntries { historyEntries = entries }
    }

    // MARK: - 导出

    /// 导出 HTML：独立文件，排版骨架 + 主题变量层全部内联。
    func exportHTML() {
        let result = WTMarkdown.render(text)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = displayName.replacingOccurrences(of: "\\.md$", with: "", options: .regularExpression) + ".html"
        panel.allowedContentTypes = [.html]

        // 附件选项：使用当前主题（不勾则导出默认主题）
        let useCurrent = NSButton(checkboxWithTitle: t("Style with current theme", "使用当前主题样式"), target: nil, action: nil)
        useCurrent.state = .on
        useCurrent.controlSize = .small
        panel.accessoryView = useCurrent

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let themeCSS = useCurrent.state == .on
            ? themeManager.currentThemeCSS
            : StyleSheet.cssText(light: Theme.defaultLight, dark: Theme.defaultDark)!
        let html = StyleSheet.fullDocument(
            title: fileURL?.deletingPathExtension().lastPathComponent ?? "wtmd",
            body: result.html,
            themeCSS: themeCSS,
            includeScript: false
        )
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// 导出 Word：自研 OOXML 打包（`DocxExporter`），零依赖。
    ///
    /// 版式取文档自身的结构，不套主题——Word 的样式体系与预览的 CSS 变量是两套语言，
    /// 硬映射只会做出四不像；要「和预览一模一样」应该导出 PDF。
    func exportWord() {
        let baseName = displayName.replacingOccurrences(of: "\\.md$", with: "", options: .regularExpression)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = baseName + ".docx"
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data = DocxExporter.document(
            markdown: text,
            title: baseName,
            baseURL: fileURL?.deletingLastPathComponent()
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// 打印 / 存为 PDF：屏幕上调好的字号与行距跟着进纸，版心按页宽归一。
    ///
    /// 纸上那一条连续文档按**读者自己的版心宽度**排版（屏幕上多宽，纸上就多宽），
    /// 再由 `PrintPagination` 按块切开、整条按比例缩到 A4 的正文框里。
    func exportPDF() {
        let result = WTMarkdown.render(text)
        let layout = printSettings?.layout ?? .standard
        let html = StyleSheet.fullDocument(
            title: fileURL?.deletingPathExtension().lastPathComponent ?? "wtmd",
            body: result.html,
            themeCSS: themeManager.currentThemeCSS,
            includeScript: false,
            // 字号与行距要跟屏幕一致——同一份稿子，不该换个介质就换一身字
            layoutCSS: typesetting?.css ?? "",
            printLayout: layout,
            printTitle: displayName.replacingOccurrences(
                of: "\\.md$", with: "", options: .regularExpression
            )
        )
        PrintController.print(
            html: html,
            baseURL: fileURL?.deletingLastPathComponent(),
            layout: layout
        )
    }

    // MARK: - 会话

    /// 读文件内容，连同它的修改时间。一次 stat 拿到两样东西，省得打开文件
    /// 与建立「磁盘基线」之间被人插进一次写入。
    private static func readDocument(at url: URL) -> (content: String, modifiedAt: Date?)? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (content, modificationDate(of: url))
    }

    /// 文件修改时间。
    ///
    /// **不能用 `URL.resourceValues`**：`NSURL` 会缓存资源值，写完再 stat 拿到的
    /// 还是上一次的 mtime，于是「自己刚写的」和「被别人改过」永远分不清
    /// （实测同一路径两次读到相同值，差 6ms 的那种漂移也会随机出现）。
    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 把会话里记下的位置交给账本，等视图建起来时回填。
    private func seedPosition(from recorded: Session.Position, for url: URL, generation: Int) {
        positionMemory.seed(
            editorPosition: PositionMemory.EditorPosition(
                selection: NSRange(
                    location: recorded.selectionLocation,
                    length: recorded.selectionLength
                ),
                scrollOrigin: CGPoint(x: recorded.scrollX, y: recorded.scrollY)
            ),
            previewAnchor: PositionMemory.PreviewAnchor(
                blockIndex: recorded.blockIndex,
                offset: CGFloat(recorded.blockOffset)
            ),
            for: generation
        )
    }

    /// 把当前文档的位置写进会话：切文档、关窗、退出各调一次。
    ///
    /// 位置在内存里是每帧都在更新的（滚动回调），但落盘只走这几条路径——
    /// 把 `UserDefaults` 写进滚动回调既没必要，长文档里还会拖慢滚轮。
    func recordSessionPosition() {
        guard let session, let fileURL else { return }
        let editor = positionMemory.editorPosition
        let anchor = positionMemory.previewAnchor
        // 账本还是空的（视图没建 / 回填没完成）：记下去等于把旧位置抹成文首
        guard editor != nil || anchor != nil else { return }
        session.record(
            Session.Position(
                selectionLocation: editor?.selection.location ?? 0,
                selectionLength: editor?.selection.length ?? 0,
                scrollX: Double(editor?.scrollOrigin.x ?? 0),
                scrollY: Double(editor?.scrollOrigin.y ?? 0),
                blockIndex: anchor?.blockIndex ?? 0,
                blockOffset: Double(anchor?.offset ?? 0),
                modifiedAt: knownModificationDate?.timeIntervalSince1970
            ),
            for: fileURL
        )
    }

    // MARK: - 草稿

    /// Draft storage root. Defaults to Application Support; injectable so tests
    /// can run against a temp directory instead of the user's real draft.
    /// 默认草稿目录，也是「未命名文档」脚本的家。窗口层要在这里给第二扇窗口
    /// 划一个子目录——两份 `draft.md` 写在一起，谁最后落盘谁赢。
    static var defaultDraftDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("wtmd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func draftURL(in directory: URL) -> URL {
        directory.appendingPathComponent("draft.md")
    }

    private static func readDraft(at directory: URL) -> String? {
        try? String(contentsOf: draftURL(in: directory), encoding: .utf8)
    }

    private static func writeDraft(_ content: String, at directory: URL) {
        // 目录可能还不存在：第二扇窗口的草稿有自己的子目录，第一次落盘时它还在
        // 半路上。写不进去的后果是这份草稿根本不存在——静默丢字，最难发现。
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? content.write(to: draftURL(in: directory), atomically: true, encoding: .utf8)
    }

    private func clearDraft() {
        try? FileManager.default.removeItem(at: Self.draftURL(in: draftDirectory))
    }

    /// Persist an edit after a short pause. An untitled document goes to the
    /// draft file; a document with a path is written straight back to disk —
    /// inside a folder workspace the user clicks between files constantly, so
    /// waiting for a manual ⌘S would drop edits.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = text
        let delay = autoSaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.text == snapshot else { return }
            self.persist(snapshot)
        }
    }

    /// Writes content to wherever this document belongs: its file on disk, or
    /// the draft file while it has no path.
    private func persist(_ content: String, forceHistory: Bool = false) {
        if let fileURL {
            // 已经举过「两扇窗在写同一篇」的牌子：字已存进副本库，别再一遍遍存。
            if externalChange == .heldElsewhere { return }
            // 只在真正要写盘的那一刻确认磁盘版本：早一点查（比如每次按键）会
            // 在读者犹豫的时候反复报同一个冲突。
            if let change = detectExternalChange() ?? detectSharedHold() {
                externalChange = change
                archiveIfHeldElsewhere(change)
                return
            }
            writeFile(content, to: fileURL, forceHistory: forceHistory)
        } else {
            Self.writeDraft(content, at: draftDirectory)
        }
    }

    /// 磁盘还是我们上次看到的那个版本吗？
    ///
    /// 未命名文档没有基线（`knownModificationDate == nil`），也就谈不上冲突；
    /// 文件不在了算删除——两者都要在写之前判断，写下去就晚了。
    private func detectExternalChange() -> ExternalChange? {
        guard let fileURL, let known = knownModificationDate else { return nil }
        guard let disk = Self.modificationDate(of: fileURL) else { return .deleted }
        return disk == known ? nil : .modified
    }

    /// 这一篇是不是也在本应用的**另一扇**窗里开着？
    ///
    /// 写盘前的第二道核对。mtime 那一道只看得见「磁盘变过」，两扇窗各自拿着
    /// 同一版基线时它一声不响——第一扇写完，第二扇的旧基线就永远对不上了，
    /// 可那时字已经写完一遍。这一道直接问登记表：同一篇有没有第二个人在写。
    ///
    /// 读者已经做过选择（`acceptedSharedHold`）就不再拦，只在第一次把话说明白。
    private func detectSharedHold() -> ExternalChange? {
        guard !acceptedSharedHold, let fileURL else { return nil }
        return isHeldElsewhere(fileURL) ? .heldElsewhere : nil
    }

    /// 发现「两扇窗在写同一篇」时先把本地这一版存进副本库。
    ///
    /// 不写盘是对的（盘上那份是另一扇窗正看着的），但也不能只举一块牌子：
    /// 读者此刻的字必须有个去处，否则关掉窗口就没了。
    private func archiveIfHeldElsewhere(_ change: ExternalChange) {
        guard change == .heldElsewhere, isDirty, let conflicts, let fileURL else { return }
        guard let entry = conflicts.archive(text, originalURL: fileURL) else { return }
        refreshArchivedConflicts()
        showArchiveNotice(t(
            "Also open in another window — this version was saved to the conflict archive",
            "「\(entry.originalName)」也在另一扇窗口里开着，这一版已存入冲突副本"
        ))
    }

    /// 读者选定了冲突的处理方式。决定与副作用都在这里，横幅只管把按钮接过来。
    func resolveExternalChange(_ resolution: ExternalChangeResolution) {
        // 「也在另一扇窗开着」是问过就算的：读者选了哪一边，都别再拿同一件事
        // 每敲一次字问一遍。之后由写盘前的 mtime 核对继续兜着。
        if externalChange == .heldElsewhere { acceptedSharedHold = true }
        switch resolution {
        case .keepLocal:
            guard let fileURL else { return }
            externalChange = nil
            // `writeFile` 成功后会顺手把基线刷成本次写入的 mtime；失败就说明
            // 磁盘那边还是别的版本（只读卷、路径被占），冲突得重新亮出来。
            if writeFile(text, to: fileURL) != nil {
                externalChange = detectExternalChange() ?? .modified
            }
        case .reloadDisk:
            guard let fileURL, let document = Self.readDocument(at: fileURL) else {
                // 读取失败通常就是文件已经没了：退化为删除，而不是清空编辑器
                externalChange = .deleted
                return
            }
            // 排队中的那次自动保存握的是旧内容，先撤掉再换文本
            cancelScheduledSave()
            externalChange = nil
            text = document.content
            savedSnapshot = document.content
            knownModificationDate = document.modifiedAt
            renderGeneration += 1
            recomputeNow()
        case .saveAs:
            // 文件已经没了：转成未命名再走「存为新文件」这条既有路径。
            // 面板被取消时文档就留在未命名状态，内容随之进草稿——不丢东西。
            fileURL = nil
            knownModificationDate = nil
            externalChange = nil
            save()
        case .keepAsDraft:
            fileURL = nil
            knownModificationDate = nil
            externalChange = nil
            session?.setOpenFile(nil)
            Self.writeDraft(text, at: draftDirectory)
        }
    }

    /// 撤掉排队中的自动保存（不写盘）。用于「读者刚决定用磁盘版本」这类
    /// 必须让旧内容彻底失效的时刻。
    private func cancelScheduledSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    @discardableResult
    private func writeFile(_ content: String, to url: URL, forceHistory: Bool = false) -> Error? {
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return error
        }
        savedSnapshot = content
        knownModificationDate = Self.modificationDate(of: url)
        // 写进去的这一版顺手留个历史。按间隔去重，所以「每 1.2 秒自动保存」
        // 不会把五十版的窗口在十分钟内填满；`forceHistory` 留给「离开这一篇」。
        history?.capture(content, for: url, force: forceHistory)
        return nil
    }

    /// Persists pending edits immediately, cancelling the debounce. Called
    /// before switching documents, and on the way out of the app: an edit made
    /// less than one debounce interval before either would otherwise be dropped.
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        // 结算不依赖「有没有脏改动」：没保存但改过又改回去，净增也该落账
        settleWritingStats()
        guard isDirty else { return }
        // 离开这一篇（切文档 / 关窗 / 退出）时把最后的样子留一版：间隔是给
        // 「一直开着写」用的，不该把「这次写到哪儿」也一起吃掉的。
        persist(text, forceHistory: true)
    }

    /// A weak, `Sendable` handle to the store for notification callbacks: the
    /// observer blocks are `@Sendable`, so they cannot capture the store itself,
    /// and holding it weakly keeps the observer from retaining it.
    private final class WeakStore: @unchecked Sendable {
        weak var store: DocumentStore?
        init(_ store: DocumentStore) { self.store = store }
    }

    /// Persist any pending edit when the app quits or a window closes. Without
    /// this the debounce task simply dies with the process, so the last second
    /// of typing is lost — exactly the case where "autosave" is expected to
    /// have covered you.
    private func observeExitForPendingEdits() {
        let box = WeakStore(self)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.willTerminateNotification,
            NSWindow.willCloseNotification,
        ]
        exitObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Delivered on the main queue, possibly while the process is
                // already tearing down — so flush inline rather than hopping.
                MainActor.assumeIsolated {
                    box.store?.flushPendingSave()
                    // 位置也在这里落盘：写文件刚刚刷新了 mtime，先写完再记才对得上
                    box.store?.recordSessionPosition()
                    // 冲突没解决就走人：本地版本进草稿，别让它随窗口一起消失
                    box.store?.preserveLocalVersionIfConflicted()
                }
            }
        }
    }

    deinit {
        let center = NotificationCenter.default
        for observer in exitObservers {
            center.removeObserver(observer)
        }
    }
}

// MARK: - 跟着磁盘走

extension DocumentStore: WorkspaceFileEvents {
    /// 当前这一篇（或它所在的目录）改了名、换了位置：路径跟着走，内容一个字不动。
    ///
    /// **不重载、不递增 `renderGeneration`**：改名没有改变任何字符，重渲染只会把
    /// 读者的滚动位置和光标一起吞掉。`savedSnapshot` 也留在原处——它记的是
    /// 「编辑器里这段字与磁盘一致」，与文件叫什么名字无关。
    func documentDidMove(from old: URL, to new: URL) {
        guard let current = fileURL,
              WorkspaceStore.isDescendantOrSelf(current, of: old)
        else { return }

        // 路径一律按归一后的拼法算：树里枚举出来的是 `/private/var/…`，
        // 而从面板/会话来的可能是 `/var/…`，字面比较会把同一份文件当成两份。
        let currentPath = WorkspaceStore.canonicalPath(current)
        let oldPath = WorkspaceStore.canonicalPath(old)
        let suffix = String(currentPath.dropFirst(oldPath.count))
        let newCurrent = URL(fileURLWithPath: WorkspaceStore.canonicalPath(new) + suffix)

        fileURL = newCurrent
        // mtime 刷新到新路径：否则下一次自动保存会把它判成「被别处改过」
        knownModificationDate = Self.modificationDate(of: newCurrent)
        recentFiles.remove(old)
        recentFiles.add(newCurrent)
        session?.setOpenFile(newCurrent)
    }

    /// 当前这一篇进了废纸篓：字留在编辑器里，文档转成未命名草稿。
    ///
    /// **绝不先 flush**：那会把内容写回一个刚被丢掉的文件，等于在废纸篓里复活一份，
    /// 而读者已经明确说了不要它。内容改走草稿盘——下次启动它还在。
    func documentWasTrashed(at url: URL) {
        guard let current = fileURL,
              WorkspaceStore.isDescendantOrSelf(current, of: url)
        else { return }

        saveTask?.cancel()
        saveTask = nil
        fileURL = nil
        knownModificationDate = nil
        // 相对「空文档」是脏的：退出时才会把草稿再写一遍，而不是当成已保存的空文档
        savedSnapshot = ""
        externalChange = nil
        hasStartedWriting = true
        recentFiles.remove(current)
        session?.setOpenFile(nil)
        if !text.isEmpty {
            Self.writeDraft(text, at: draftDirectory)
        }
    }
}

// MARK: - 最近文件

final class RecentFiles: ObservableObject {
    private static let key = "wtmd.recentFiles"
    @Published var urls: [URL] = []
    /// Injectable so tests do not read or write the user's real defaults.
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let paths = userDefaults.stringArray(forKey: Self.key) ?? []
        // A file that was renamed keeps its old path in the list — it no longer
        // exists, so it is dropped here, and the pruning is persisted too: a
        // list that is re-filtered at every launch without ever being written
        // back never actually shrinks.
        urls = paths.compactMap { URL(string: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.count != paths.count {
            persist()
        }
    }

    func add(_ url: URL) {
        var next = urls.filter { !Self.isSameFile($0, url) }
        next.insert(url, at: 0)
        if next.count > 8 { next = Array(next.prefix(8)) }
        urls = next
        persist()
    }

    /// 文件被删掉或改名之后，旧路径不能还留在列表里等着被点。
    func remove(_ url: URL) {
        let next = urls.filter { !Self.isSameFile($0, url) }
        guard next.count != urls.count else { return }
        urls = next
        persist()
    }

    /// Drops entries whose file no longer exists on disk, and reports whether
    /// anything was dropped.
    @discardableResult
    func pruneMissing() -> Bool {
        let next = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard next.count != urls.count else { return false }
        urls = next
        persist()
        return true
    }

    private func persist() {
        userDefaults.set(urls.map(\.absoluteString), forKey: Self.key)
    }

    /// `/var/…` 与 `/private/var/…` 是同一份文件，比较前先归一。
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        PathKey.isSame(a, b)
    }
}
