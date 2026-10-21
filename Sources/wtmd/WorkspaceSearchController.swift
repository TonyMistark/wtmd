import Combine
import Foundation

/// State machine behind the ⌘⇧F panel: what is being searched, what came back,
/// and which hit is under the cursor.
///
/// The sweep itself is `WorkspaceSearch` (pure, testable without a window); this
/// type owns the parts that cannot be pure — debouncing keystrokes, cancelling a
/// stale sweep, and keeping only the newest answer.
@MainActor
final class WorkspaceSearchController: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    @Published var options: FindOptions = [] {
        didSet { if options != oldValue { schedule() } }
    }
    @Published private(set) var isVisible = false
    @Published private(set) var root: URL?
    @Published private(set) var report = WorkspaceSearchReport()
    /// Flattened hits, kept in step with `report` so the view does not re-flatten
    /// 200 hits on every row it draws.
    @Published private(set) var hits: [WorkspaceHit] = []
    @Published private(set) var isSearching = false
    /// Index into `hits` — across groups, so ↑/↓ moves through the list as one.
    @Published var selectedIndex = 0

    /// The document on screen, if any. Its file on disk can lag one autosave
    /// behind, so searching it from disk would miss the word just typed.
    var liveDocument: (@MainActor () -> (url: URL, text: String)?)?

    /// 一次扫描的输入。打包成值类型是为了让 `searchFunction` 有个像样的签名。
    struct SearchInput: Sendable {
        let root: URL
        let query: String
        let options: FindOptions
        let overlay: [URL: String]
        /// `.wtmdignore`：跟着工作区走的忽略清单。
        var ignores: WorkspaceIgnore = .empty
        let shouldContinue: @Sendable () -> Bool
    }

    /// 可替换的扫描实现。默认就是 `WorkspaceSearch.run`；测试用它把「旧结果晚到」
    /// 这件事变成可复现的——只靠真实的快慢去赌，守不住代际守卫。
    var searchFunction: @Sendable (SearchInput) -> WorkspaceSearchReport = { input in
        WorkspaceSearch.run(
            root: input.root,
            query: input.query,
            options: input.options,
            overlay: input.overlay,
            ignores: input.ignores,
            shouldContinue: input.shouldContinue
        )
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasQuery: Bool { !trimmedQuery.isEmpty }

    var selectedHit: WorkspaceHit? {
        hits.indices.contains(selectedIndex) ? hits[selectedIndex] : nil
    }

    var statusText: String {
        guard hasQuery else { return "" }
        if isSearching, report.isEmpty { return t("Searching…", "搜索中…") }
        guard !report.isEmpty else { return isSearching ? t("Searching…", "搜索中…") : t("No results", "无结果") }
        var parts = [t("\(report.hitCount) matches", "\(report.hitCount) 处")]
        if report.truncated { parts.append(t("truncated", "已截断")) }
        parts.append(t("\(report.scannedFiles) files", "\(report.scannedFiles) 个文件"))
        if report.skippedFiles > 0 { parts.append(t("skipped \(report.skippedFiles)", "跳过 \(report.skippedFiles) 个")) }
        return parts.joined(separator: " · ")
    }

    /// Debounce before a sweep starts. Long enough that typing a word does not
    /// launch five sweeps, short enough to feel immediate. Injectable so tests
    /// do not wait 150 ms per case.
    private let delay: UInt64
    private var searchTask: Task<Void, Never>?

    init(delay: UInt64 = 150_000_000) {
        self.delay = delay
    }

    // MARK: - 显现与关闭

    func present(root: URL?) {
        self.root = root
        isVisible = true
        selectedIndex = 0
        if hasQuery {
            schedule(immediately: true)
        } else {
            clearResults()
        }
    }

    func dismiss() {
        isVisible = false
        searchTask?.cancel()
        searchTask = nil
        clearResults()
        // 下次按下 ⌘⇧F 该是一个干净的搜索，而不是上一个工作区的残留
        query = ""
    }

    // MARK: - 选择

    func moveSelection(by delta: Int) {
        guard !hits.isEmpty else { return }
        selectedIndex = PaletteKeyboard.advance(selectedIndex, by: delta, count: hits.count)
    }

    func select(_ index: Int) {
        guard hits.indices.contains(index) else { return }
        selectedIndex = index
    }

    func relativePath(for url: URL) -> String {
        guard let root else { return url.lastPathComponent }
        return WorkspaceSearch.relativePath(of: url, under: root)
    }

    // MARK: - 内部

    private func clearResults() {
        report = WorkspaceSearchReport()
        hits = []
        isSearching = false
        selectedIndex = 0
    }

    private func schedule(immediately: Bool = false) {
        guard isVisible else { return }
        searchTask?.cancel()
        searchTask = nil

        // 空查询不扫盘：按一下 ⌘⇧F 就把整个文件夹读一遍，是最没必要的 I/O
        guard let root, hasQuery else {
            clearResults()
            return
        }

        let query = trimmedQuery
        let options = options
        let ignores = WorkspaceIgnore.load(root: root)
        var overlay: [URL: String] = [:]
        if let live = liveDocument?() { overlay[live.url] = live.text }

        isSearching = true
        let wait = immediately ? 0 : delay
        let searchFunction = searchFunction
        searchTask = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: wait)
                guard !Task.isCancelled else { return }
            }
            // 遍历放后台：500 个文件的读取与匹配不该占着主线程
            let work = Task.detached(priority: .userInitiated) {
                searchFunction(
                    SearchInput(
                        root: root,
                        query: query,
                        options: options,
                        overlay: overlay,
                        ignores: ignores,
                        shouldContinue: { !Task.isCancelled }
                    )
                )
            }
            // 外层被取消（又敲了一个字）时把工作一起掐掉，否则旧的整轮扫描
            // 会跑完再被丢弃——磁盘白读，键盘也可能被拖慢
            let report = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.report = report
            self.hits = report.hits
            self.isSearching = false
            self.selectedIndex = 0
        }
    }
}
