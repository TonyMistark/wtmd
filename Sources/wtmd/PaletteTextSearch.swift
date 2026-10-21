import Combine
import Foundation

/// 面板里的正文搜索。
///
/// 与 ⌘⇧F 用的是同一台引擎（`WorkspaceSearch`），但目的不同：那边要「翻遍、
/// 读完」，这边只要「够不够把这一条摆到第三段里」。所以条数少、防抖更长、
/// 取消了就不必知道结果。
/// 面板正文段的条数：摆 5 条，多要一条用来判断「还有没有别的」。
enum PaletteTextLimits {
    static let display = 5
    static let probe = display + 1
}

@MainActor
final class PaletteTextSearch: ObservableObject {
    /// 只摆 5 条；多出来的用「在工作区中查看全部」带过去。
    static let displayLimit = PaletteTextLimits.display

    @Published private(set) var hits: [WorkspaceHit] = []
    @Published private(set) var isSearching = false
    /// 是否还有没摆下的命中。
    @Published private(set) var hasMore = false

    /// 防抖比 ⌘⇧F 长一点：面板里每敲一个字都扫一遍全库，键盘会发涩。
    /// 可注入，测试不必真等。
    var delay: UInt64 = 220_000_000

    /// 可替换的扫描实现，测试用它把「旧结果晚到」变成可复现的。
    var searchFunction: @Sendable (WorkspaceSearchController.SearchInput) -> WorkspaceSearchReport = { input in
        WorkspaceSearch.run(
            root: input.root,
            query: input.query,
            options: input.options,
            limit: PaletteTextLimits.probe,
            overlay: input.overlay,
            ignores: input.ignores,
            shouldContinue: input.shouldContinue
        )
    }

    private var task: Task<Void, Never>?

    func search(root: URL?, query: String, overlay: [URL: String] = [:]) {
        task?.cancel()
        task = nil

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, trimmed.count > 1 else {
            clear()
            return
        }

        isSearching = true
        let delay = delay
        let ignores = WorkspaceIgnore.load(root: root)
        let searchFunction = searchFunction
        task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            let work = Task.detached(priority: .utility) {
                searchFunction(
                    WorkspaceSearchController.SearchInput(
                        root: root,
                        query: trimmed,
                        options: [],
                        overlay: overlay,
                        ignores: ignores,
                        shouldContinue: { !Task.isCancelled }
                    )
                )
            }
            let report = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            // 早先那一次（打字打断的）晚到了：它问的不是现在这个词。
            self.hits = Array(report.hits.prefix(Self.displayLimit))
            self.hasMore = report.truncated || report.hitCount > Self.displayLimit
            self.isSearching = false
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        hits = []
        hasMore = false
        isSearching = false
    }
}
