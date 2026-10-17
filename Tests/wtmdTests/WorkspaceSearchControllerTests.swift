import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 面板状态机

/// 打开面板、输入、等结果落地——这是读者最常走的一条路。
@MainActor
@Test func searchingFindsHitsAndSelectsTheFirstOne() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "第一行\nneedle 在这里")

    let search = WorkspaceSearchController(delay: 0)
    search.present(root: root)
    search.query = "needle"

    await waitUntil("首轮结果") { !search.isSearching && !search.hits.isEmpty }

    #expect(search.hits.count == 1)
    #expect(search.selectedIndex == 0)
    #expect(search.selectedHit?.line == 1)
    #expect(search.statusText.contains("1 处"))
}

/// **代际守卫**：慢的那一轮后回来，不能盖掉快的那一轮结果。
///
/// 旧查询被故意拖到 300ms——真实的快慢靠不住，这里把「旧结果晚到」做成必然，
/// 摘掉守卫这条用例就会变红（面板会显示上一个词的结果）。
@MainActor
@Test func aLateAnswerFromAnOldQueryIsDiscarded() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("old.md", in: root, content: "旧的那个词")
    try write("new.md", in: root, content: "新的那个词")

    let search = WorkspaceSearchController(delay: 0)
    search.searchFunction = { input in
        if input.query == "旧的" { Thread.sleep(forTimeInterval: 0.3) }
        return WorkspaceSearch.run(
            root: input.root, query: input.query, options: input.options, overlay: input.overlay
        )
    }
    search.present(root: root)
    search.query = "旧的"
    search.query = "新的"

    // 等新的那一轮落地，再留足时间给旧的那一轮回来（它被故意拖了 300ms）
    await waitUntil("新一轮结果落地") { !search.isSearching && !search.hits.isEmpty }
    try await Task.sleep(nanoseconds: 500_000_000)

    #expect(search.hits.map(\.fileURL.lastPathComponent) == ["new.md"])
    #expect(!search.isSearching)
}

/// 空查询（含只有空格）不扫盘：按一下 ⌘⇧F 不该把整个文件夹读一遍。
@MainActor
@Test func blankQueryNeverTouchesTheDisk() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "needle")

    let counter = ScanCounter()
    let search = WorkspaceSearchController(delay: 0)
    search.searchFunction = { input in
        counter.increment()
        return WorkspaceSearch.run(
            root: input.root, query: input.query, options: input.options, overlay: input.overlay
        )
    }
    search.present(root: root)
    search.query = "   "

    try await Task.sleep(nanoseconds: 150_000_000)

    #expect(counter.value == 0)
    #expect(search.hits.isEmpty)
    #expect(!search.isSearching)
}

/// 没有工作区时面板照旧打开，只是没东西可搜——状态里说清楚，别让快捷键像坏了。
@MainActor
@Test func withoutAWorkspaceThePanelStaysEmpty() throws {
    let search = WorkspaceSearchController(delay: 0)
    search.present(root: nil)
    search.query = "needle"

    #expect(search.isVisible)
    #expect(search.root == nil)
    #expect(search.hits.isEmpty)
    #expect(!search.isSearching)
}

/// 关掉面板要清干净：结果、选择、输入都不该留到下一次。
@MainActor
@Test func dismissClearsEverything() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "needle")

    let search = WorkspaceSearchController(delay: 0)
    search.present(root: root)
    search.query = "needle"
    await waitUntil("结果落地") { !search.isSearching && !search.hits.isEmpty }

    search.dismiss()

    #expect(!search.isVisible)
    #expect(search.hits.isEmpty)
    #expect(search.selectedIndex == 0)
    #expect(search.query.isEmpty)
}

/// ↑↓ 绕回：按住下键到底该回到第一条，而不是卡住。
@MainActor
@Test func selectionWrapsAroundTheHitList() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a.md", in: root, content: "needle 一\nneedle 二")

    let search = WorkspaceSearchController(delay: 0)
    search.present(root: root)
    search.query = "needle"
    await waitUntil("两条命中") { !search.isSearching && search.hits.count == 2 }

    search.select(0)
    search.moveSelection(by: -1)
    #expect(search.selectedIndex == 1)
    search.moveSelection(by: 1)
    #expect(search.selectedIndex == 0)
}

/// 正在编辑的那一篇以内存内容参与搜索。
@MainActor
@Test func theOpenDocumentIsSearchedAsItIsInMemory() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a.md", in: root, content: "磁盘上的旧内容")

    let search = WorkspaceSearchController(delay: 0)
    search.liveDocument = { (file, "磁盘上的旧内容\n刚敲下的一句") }
    search.present(root: root)
    search.query = "刚敲下"

    await waitUntil("内存内容参与搜索") { !search.isSearching && !search.hits.isEmpty }
    #expect(search.hits.first?.line == 1)
}

// MARK: - 打开命中

/// 命中带着行列过来，`openSearchHit` 要原样交给编辑器，并且在预览模式下切回源码。
@MainActor
@Test func openingAHitCarriesTheLineAndColumn() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("a.md", in: dir, content: "第一行\n第二行 needle")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.setMode(.preview)
    store.openSearchHit(hit(in: file, line: 1, column: 4, length: 6))

    #expect(store.fileURL == file)
    #expect(store.mode == .edit)
    #expect(store.editorJump?.line == 1)
    #expect(store.editorJump?.column == 4)
    #expect(store.editorJump?.length == 6)
}

/// 命中的就在当前这一篇：不重载文档（会吞掉滚动位置），只把光标送过去。
@MainActor
@Test func aHitInTheOpenDocumentDoesNotReloadIt() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("a.md", in: dir, content: "# 标题\n\n一段话")

    let store = DocumentStore(draftDirectory: dir, autoSaveDelay: 60_000_000_000)
    store.open(url: file)
    let generation = store.renderGeneration

    store.openSearchHit(hit(in: file, line: 2, column: 1, length: 3))

    #expect(store.renderGeneration == generation)
    #expect(store.editorJump?.line == 2)
}

// MARK: - 辅助

private func hit(in file: URL, line: Int, column: Int, length: Int) -> WorkspaceHit {
    WorkspaceHit(
        fileURL: file,
        line: line,
        column: column,
        length: length,
        lineText: "第二行 needle",
        highlightStart: 4,
        highlightLength: 6
    )
}

/// 跨线程计数：注入的扫描实现跑在后台任务上。
private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 15,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("等待超时（\(Int(timeout))s）：\(description)")
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-search-panel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ name: String, in directory: URL, content: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}
