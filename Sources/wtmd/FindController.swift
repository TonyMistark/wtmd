import Foundation

/// 一次替换请求。范围与替换文本都由查找侧算好，编辑器只负责执行——
/// 撤销栈在 `NSTextView` 里，所以替换必须经过它，不能在 `DocumentStore` 里直接改字符串。
struct ReplaceRequest: Equatable {
    let id: String
    /// 被替换的源码区间。**全部替换时是整篇**：一次 `shouldChangeText` 才算一步撤销。
    let range: NSRange
    let replacement: String
    /// 替换后光标落点（已按新文本长度夹过）。
    let selectionAfter: NSRange
}

/// 文档内查找的状态机。
///
/// 只管「查什么、命中了哪些、当前在哪一条」，不碰视图：高亮由编辑器铺，
/// 输入框由查找条读。这样匹配逻辑可以在没有窗口的情况下测试。
@MainActor
final class FindController: ObservableObject {
    @Published private(set) var isVisible = false
    @Published var query = "" {
        didSet { if query != oldValue { restart() } }
    }
    @Published var options: FindOptions = [] {
        didSet { if options != oldValue { restart() } }
    }
    @Published var replacement = ""
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var patternError: String?

    /// 每次「该跳到当前命中了」就 +1。查询词变化会跳（第一个命中是自然落点），
    /// 文本变化**不跳**——读者正在那儿打字，不能把光标抢走。
    @Published private(set) var seekToken = 0
    /// 每次查找条要抢焦点就 +1；`focusesReplacement` 说明抢给哪个输入框。
    @Published private(set) var focusToken = 0
    @Published private(set) var focusesReplacement = false

    private var text = ""
    /// 替换之后下一次扫描的起点。`nil` 表示「接着当前命中往下看」。
    private var resumeLocation: Int?

    // MARK: - 显现与隐藏

    func present(focusingReplacement: Bool) {
        isVisible = true
        focusesReplacement = focusingReplacement
        focusToken += 1
        // 重新打开时从第一个命中开始：读者刚按下 ⌘F，要的是「它在哪」，
        // 而不是「上次停在第三个」。
        resumeLocation = 0
        rescan(resume: 0)
        seekToken += 1
    }

    func dismiss() {
        isVisible = false
        matches = []
        currentIndex = nil
        patternError = nil
        resumeLocation = nil
    }

    // MARK: - 文本

    /// 文档变了。不可见时只更新文本，不扫——每次按键扫全篇是纯浪费。
    func attach(_ newText: String) {
        let changed = newText != text
        text = newText
        guard isVisible else { return }
        // 替换成同样的文本时（把「甲」换成「甲」）内容没变，但仍要往前走一格，
        // 否则「替换」会一直停在同一处。
        guard changed || resumeLocation != nil else { return }
        let resume = resumeLocation
        resumeLocation = nil
        rescan(resume: resume)
    }

    // MARK: - 导航

    func next() { advance(by: 1) }
    func previous() { advance(by: -1) }

    var currentMatch: NSRange? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    var hasMatches: Bool { !matches.isEmpty }

    var statusText: String {
        guard isVisible else { return "" }
        if let patternError { return patternError }
        if query.isEmpty { return "" }
        guard let currentIndex, !matches.isEmpty else { return t("No results", "无结果") }
        let suffix = matches.count >= FindEngine.matchLimit ? "+" : ""
        return "\(currentIndex + 1) / \(matches.count)\(suffix)"
    }

    // MARK: - 替换记账

    /// 替换了一处之后，下一次扫描从这里往后接——否则重算会把光标送回第一个命中。
    func noteReplacement(at range: NSRange, newLength: Int) {
        resumeLocation = range.location + newLength
    }

    /// 全部替换之后从文首重新开始。
    func noteReplaceAll() {
        resumeLocation = 0
    }

    // MARK: - 内部

    private func restart() {
        guard isVisible else { return }
        rescan(resume: 0)
        seekToken += 1
    }

    private func rescan(resume: Int?) {
        let scan = FindEngine.scan(text as NSString, query: query, options: options)
        matches = scan.matches
        patternError = scan.error

        guard !matches.isEmpty else {
            currentIndex = nil
            return
        }
        if let resume, let index = matches.firstIndex(where: { $0.location >= resume }) {
            currentIndex = index
        } else if resume != nil {
            // 已经到文末：绕回第一个，跟「下一处」的行为一致
            currentIndex = 0
        } else {
            currentIndex = min(currentIndex ?? 0, matches.count - 1)
        }
    }

    private func advance(by step: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        let start = currentIndex ?? (step > 0 ? -1 : 0)
        currentIndex = ((start + step) % count + count) % count
        seekToken += 1
    }
}
