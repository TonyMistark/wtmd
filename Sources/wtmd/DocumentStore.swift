import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit
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
        case .edit: return "思绪"
        case .preview: return "成文"
        case .split: return "对照"
        }
    }
}

struct JumpRequest: Equatable {
    let id: String
    let line: Int
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

    /// Single source of truth for the welcome screen. Kept on the store (instead
    /// of inline in the view body) so the condition is unit-testable.
    var showsWelcome: Bool {
        text.isEmpty && fileURL == nil && !hasStartedWriting
    }

    let recentFiles = RecentFiles()
    let themeManager = ThemeManager()
    /// 跨视图重建的位置账本：`⌘/` 会销毁并重建编辑器/预览，位置得存在视图之外。
    let positionMemory = PositionMemory()
    /// 文档内查找。状态跟着窗口走，不落盘——关掉应用再打开，没人期待搜索框还在。
    let find = FindController()
    /// 待执行的替换（编辑器消费后保留 id，避免重复执行）。
    @Published var replaceRequest: ReplaceRequest?

    private let draftDirectory: URL
    /// Debounce before an edit is persisted. Injectable so tests do not have to
    /// sit through the production 1.2s interval for every case.
    private let autoSaveDelay: UInt64
    /// What survived the last launch. `nil` means "this instance keeps nothing":
    /// the default for tests, which must never touch the user's real session.
    private let session: Session?
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
        session: Session? = nil
    ) {
        let directory = draftDirectory ?? Self.defaultDraftDirectory
        self.draftDirectory = directory
        self.autoSaveDelay = autoSaveDelay
        self.session = session

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
    }

    // MARK: - 状态

    var isDirty: Bool { text != savedSnapshot }
    var displayName: String { fileURL?.lastPathComponent ?? "未命名.md" }
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
        let outline: [OutlineItem]
        let statistics: TextStatistics
    }

    /// 解析 + 渲染 + 统计：纯函数，不触碰任何状态，可在后台线程执行。
    nonisolated private static func build(_ markdown: String) -> RenderOutput {
        let result = WTMarkdown.render(markdown)
        return RenderOutput(
            html: result.html,
            blocks: result.blocks,
            outline: result.outline,
            statistics: TextStatistics.count(markdown)
        )
    }

    /// 全量重渲染：打开文件 / 切换模式 / 新建等低频场景（同步，保证首帧即有内容）。
    private func recomputeNow() {
        let output = Self.build(text)
        outline = output.outline
        previewHTML = output.html
        statistics = output.statistics
        // DOM 基准与即将注入的全文一致，后续编辑可直接走增量
        renderedBlocks = output.blocks
        pendingDiff = nil
    }

    /// 增量应用：块级 diff 在主线程完成（O(块数) 比较，与文档长度基本无关），
    /// 未变化块的 DOM 节点保持原位（图片已解码结果不重画）。
    private func applyIncremental(_ output: RenderOutput) {
        outline = output.outline
        statistics = output.statistics
        previewHTML = output.html

        let diff = BlockDiff.compute(old: renderedBlocks, new: output.blocks)
        renderedBlocks = output.blocks
        // 块数组完全一致时没有可发的增量，显式清空避免上一轮的 diff 被重复套用
        pendingDiff = diff.isEmpty ? nil : diff
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
        externalChange = nil
        text = ""
        fileURL = nil
        savedSnapshot = ""
        knownModificationDate = nil
        // The user explicitly asked for a blank document, so the welcome screen
        // must step aside — otherwise the empty text immediately brings it back
        // and the button looks dead.
        hasStartedWriting = true
        renderGeneration += 1
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

    func open(url: URL) {
        // Clicking the file that is already open (in the workspace tree, say)
        // must not reload the preview and throw away the scroll position.
        guard url != fileURL else { return }
        guard let document = Self.readDocument(at: url) else { return }
        // Flush only after the read succeeded: a failed open must not discard
        // unsaved work.
        flushPendingSave()
        // 切走之前把这一篇停在哪里记下来，否则「在文件树里点来点去」的轨迹全丢
        recordSessionPosition()
        // 横幅跟着文档走：换了一篇，上一篇的冲突与这一篇无关
        externalChange = nil
        text = document.content
        fileURL = url
        savedSnapshot = document.content
        knownModificationDate = document.modifiedAt
        recentFiles.add(url)
        hasStartedWriting = true
        renderGeneration += 1
        // 这一篇之前被读过（本次运行或上次启动）就回到当时的位置
        if let recorded = session?.position(for: url) {
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
        if let change = detectExternalChange() {
            externalChange = change
            return
        }
        let targetURL: URL
        if let existing = fileURL {
            targetURL = existing
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "未命名.md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            targetURL = url
            fileURL = url
        }
        do {
            try text.write(to: targetURL, atomically: true, encoding: .utf8)
            savedSnapshot = text
            knownModificationDate = Self.modificationDate(of: targetURL)
            recentFiles.add(targetURL)
            session?.setOpenFile(targetURL)
            clearDraft()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// 冲突未解决就要退出/关窗：磁盘上那份是别人的版本，不去动它；自己的改动
    /// 留在草稿里，下次启动以未命名文档出现——总比一声不响地丢掉好。
    private func preserveLocalVersionIfConflicted() {
        guard externalChange != nil, isDirty else { return }
        Self.writeDraft(text, at: draftDirectory)
        session?.setOpenFile(nil)
    }

    // MARK: - 导出

    /// 导出 HTML：独立文件，排版骨架 + 主题变量层全部内联。
    func exportHTML() {
        let result = WTMarkdown.render(text)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = displayName.replacingOccurrences(of: "\\.md$", with: "", options: .regularExpression) + ".html"
        panel.allowedContentTypes = [.html]

        // 附件选项：使用当前主题（不勾则导出默认主题）
        let useCurrent = NSButton(checkboxWithTitle: "使用当前主题样式", target: nil, action: nil)
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

    func exportPDF() {
        let result = WTMarkdown.render(text)
        let html = StyleSheet.fullDocument(
            title: fileURL?.deletingPathExtension().lastPathComponent ?? "wtmd",
            body: result.html,
            themeCSS: themeManager.currentThemeCSS,
            includeScript: false
        )
        PrintController.print(html: html, baseURL: fileURL?.deletingLastPathComponent())
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
    private static var defaultDraftDirectory: URL {
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
    private func persist(_ content: String) {
        if let fileURL {
            // 只在真正要写盘的那一刻确认磁盘版本：早一点查（比如每次按键）会
            // 在读者犹豫的时候反复报同一个冲突。
            if let change = detectExternalChange() {
                externalChange = change
                return
            }
            writeFile(content, to: fileURL)
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

    /// 读者选定了冲突的处理方式。决定与副作用都在这里，横幅只管把按钮接过来。
    func resolveExternalChange(_ resolution: ExternalChangeResolution) {
        switch resolution {
        case .keepLocal:
            guard let fileURL else { return }
            externalChange = nil
            // `writeFile` 成功后会顺手把基线刷成本次写入的 mtime；失败就说明
            // 磁盘那边还是别的版本（只读卷、路径被占），冲突得重新亮出来。
            if !writeFile(text, to: fileURL) {
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
    private func writeFile(_ content: String, to url: URL) -> Bool {
        guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        savedSnapshot = content
        knownModificationDate = Self.modificationDate(of: url)
        return true
    }

    /// Persists pending edits immediately, cancelling the debounce. Called
    /// before switching documents, and on the way out of the app: an edit made
    /// less than one debounce interval before either would otherwise be dropped.
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty else { return }
        persist(text)
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

// MARK: - 最近文件

final class RecentFiles: ObservableObject {
    private static let key = "wtmd.recentFiles"
    @Published var urls: [URL] = []

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        urls = paths.compactMap { URL(string: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        var next = urls.filter { $0 != url }
        next.insert(url, at: 0)
        if next.count > 8 { next = Array(next.prefix(8)) }
        urls = next
        UserDefaults.standard.set(next.map(\.absoluteString), forKey: Self.key)
    }
}

// MARK: - 打印 / 存为 PDF

@MainActor
final class PrintController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var continuation: CheckedContinuation<Void, Never>?
    private var retained: [Any] = []
    /// 页面是否已报告「图表渲染完成」。
    private var diagramsReady = false

    /// 等待图表就绪的上限；超时按兜底处理，不阻塞导出。
    private static let diagramWaitLimit = 5.0

    static func print(html: String, baseURL: URL?) {
        let controller = PrintController()
        controller.run(html: html, baseURL: baseURL)
    }

    private func run(html: String, baseURL: URL?) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "wtmd")
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 780, height: 1000),
            configuration: config
        )
        webView.navigationDelegate = self
        retained = [webView]
        webView.loadHTMLString(html, baseURL: baseURL)

        Task {
            await withCheckedContinuation { c in
                continuation = c
            }
            // 有图表：等待 mermaid 异步渲染完成的就绪信号（固定等待会丢图）；
            // 无图表：维持原有的短暂排版稳定等待。
            if html.contains("language-mermaid") {
                await waitForDiagrams()
            } else {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            let info = NSPrintInfo.shared
            info.topMargin = 36
            info.bottomMargin = 36
            info.leftMargin = 40
            info.rightMargin = 40
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            let operation = webView.printOperation(with: info)
            operation.jobTitle = "wtmd"
            if let window = NSApp.keyWindow {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            }
            retained = []
        }
    }

    /// 轮询就绪标记：就绪即返回，超时兜底（避免单张图失败时卡住导出）。
    private func waitForDiagrams() async {
        let deadline = Date().addingTimeInterval(Self.diagramWaitLimit)
        while !diagramsReady, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // 渲染完成后再留一小段排版稳定时间
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: WKScriptMessageHandler

    /// 页面脚本回报「图表已渲染完成」（无图表时也会立即回报）。
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            guard message.name == "wtmd",
                  let body = message.body as? [String: Any],
                  body["event"] as? String == "mermaid-ready"
            else { return }
            diagramsReady = true
        }
    }
}
