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

    /// Single source of truth for the welcome screen. Kept on the store (instead
    /// of inline in the view body) so the condition is unit-testable.
    var showsWelcome: Bool {
        text.isEmpty && fileURL == nil && !hasStartedWriting
    }

    let recentFiles = RecentFiles()
    let themeManager = ThemeManager()
    /// 跨视图重建的位置账本：`⌘/` 会销毁并重建编辑器/预览，位置得存在视图之外。
    let positionMemory = PositionMemory()

    private let draftDirectory: URL
    /// Debounce before an edit is persisted. Injectable so tests do not have to
    /// sit through the production 1.2s interval for every case.
    private let autoSaveDelay: UInt64
    private var savedSnapshot: String = ""
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Keeps the exit observers alive; removed in `deinit`.
    private var exitObservers: [NSObjectProtocol] = []

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

    init(draftDirectory: URL? = nil, autoSaveDelay: UInt64 = 1_200_000_000) {
        let directory = draftDirectory ?? Self.defaultDraftDirectory
        self.draftDirectory = directory
        self.autoSaveDelay = autoSaveDelay
        if let draft = Self.readDraft(at: directory), !draft.isEmpty {
            text = draft
        } else {
            text = Self.welcomeMarkdown
            Self.writeDraft(text, at: directory)
        }
        recomputeNow()
        observeExitForPendingEdits()
    }

    // MARK: - 状态

    var isDirty: Bool { text != savedSnapshot }
    var displayName: String { fileURL?.lastPathComponent ?? "未命名.md" }
    var windowTitle: String { (isDirty ? "● " : "") + displayName }

    func textDidChange(_ new: String) {
        text = new
        scheduleRender()
        scheduleSave()
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
        text = ""
        fileURL = nil
        savedSnapshot = ""
        // The user explicitly asked for a blank document, so the welcome screen
        // must step aside — otherwise the empty text immediately brings it back
        // and the button looks dead.
        hasStartedWriting = true
        renderGeneration += 1
        recomputeNow()
        mode = .edit
        clearDraft()
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
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        // Flush only after the read succeeded: a failed open must not discard
        // unsaved work.
        flushPendingSave()
        text = content
        fileURL = url
        savedSnapshot = content
        recentFiles.add(url)
        hasStartedWriting = true
        renderGeneration += 1
        recomputeNow()
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
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
            recentFiles.add(targetURL)
            clearDraft()
        } catch {
            NSAlert(error: error).runModal()
        }
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
            writeFile(content, to: fileURL)
        } else {
            Self.writeDraft(content, at: draftDirectory)
        }
    }

    @discardableResult
    private func writeFile(_ content: String, to url: URL) -> Bool {
        guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        savedSnapshot = content
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
                MainActor.assumeIsolated { box.store?.flushPendingSave() }
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
