import AppKit
import Foundation
import SwiftUI

// MARK: - 树节点

/// One entry in the workspace tree: either a Markdown file, or a folder that
/// holds at least one Markdown file somewhere below it.
struct WorkspaceNode: Identifiable, Equatable, Hashable {
    let url: URL
    let isDirectory: Bool
    let children: [WorkspaceNode]

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool, children: [WorkspaceNode] = []) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }
}

// MARK: - 扫描

/// Directory scanning. Kept as pure functions so the tree shape can be tested
/// without a store, a window, or any file watching.
enum WorkspaceScanner {
    /// Extensions treated as documents. Anything else is invisible to wtmd.
    static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// Directories that never belong in a writing workspace: dependencies,
    /// build products, virtualenvs. A tree is not a file-system browser, and a
    /// single `node_modules` would bury every note under it.
    static let ignoredDirectoryNames: Set<String> = [
        "node_modules", "pods", "deriveddata", ".build", "venv", ".venv", "__pycache__",
    ]

    /// Scans `root` into a folder node, or returns nil when `root` is not a
    /// readable directory.
    static func scan(root: URL) -> WorkspaceNode? {
        guard isDirectory(root) else { return nil }
        return WorkspaceNode(url: root, isDirectory: true, children: scanChildren(of: root))
    }

    /// Folders and files directly inside `directory`, folders first and then by
    /// name.
    static func scanChildren(of directory: URL) -> [WorkspaceNode] {
        scanDirectory(directory).children
    }

    /// Whether a directory earns a row in the tree.
    ///
    /// A folder is shown when its subtree holds Markdown — that has not changed
    /// since v0.3, and it is what keeps an `assets/` folder full of images out
    /// of the way. What changed in v0.7: a **completely empty** folder is shown
    /// too. Once the tree can create folders, a folder that vanishes the moment
    /// it is created reads as a failure.
    private static func scanDirectory(_ directory: URL) -> (children: [WorkspaceNode], keep: Bool) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        var folders: [WorkspaceNode] = []
        var files: [WorkspaceNode] = []
        var entryCount = 0
        var hasVisibleContent = false

        for entry in entries {
            entryCount += 1
            if isDirectory(entry) {
                guard !isPackage(entry) else { continue }
                guard !ignoredDirectoryNames.contains(entry.lastPathComponent.lowercased()) else {
                    continue
                }
                let scanned = scanDirectory(entry)
                if scanned.keep {
                    folders.append(
                        WorkspaceNode(url: entry, isDirectory: true, children: scanned.children)
                    )
                    hasVisibleContent = true
                }
            } else if markdownExtensions.contains(entry.pathExtension.lowercased()) {
                files.append(WorkspaceNode(url: entry, isDirectory: false))
                hasVisibleContent = true
            }
        }

        return (
            folders.sorted(by: byName) + files.sorted(by: byName),
            hasVisibleContent || entryCount == 0
        )
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }

    /// Folder first, then Finder-like name order (so `doc2` sorts before `doc10`).
    private static let byName: (WorkspaceNode, WorkspaceNode) -> Bool = {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

// MARK: - 变更监听

/// Watches a folder subtree and reports changes back on the main actor.
///
/// One `DispatchSource` per directory rather than a single FSEvents stream:
/// FSEvents' C callback is awkward to own from Swift, while a writing workspace
/// holds tens of directories at most. Events are debounced — a single save in
/// an editor or the Finder emits a burst (temp file, rename, metadata) — and
/// afterwards the whole source set is rebuilt so folders created in the
/// meantime get watched too.
@MainActor
final class DirectoryWatcher {
    private let root: URL
    private let onChange: @MainActor () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounce: Task<Void, Never>?
    private var isStopped = false

    private static let debounceNanoseconds: UInt64 = 300_000_000

    init(root: URL, onChange: @escaping @MainActor () -> Void) {
        self.root = root
        self.onChange = onChange
        rebuild()
    }

    func stop() {
        isStopped = true
        debounce?.cancel()
        debounce = nil
        for source in sources.values { source.cancel() }
        sources.removeAll()
    }

    /// Adds a source for every directory that is not watched yet, and drops the
    /// ones that vanished.
    private func rebuild() {
        guard !isStopped else { return }
        let current = directories(in: root)
        let paths = Set(current.map(\.path))

        for directory in current where sources[directory.path] == nil {
            watch(directory)
        }
        for (path, source) in sources where !paths.contains(path) {
            source.cancel()
            sources[path] = nil
        }
    }

    private func directories(in root: URL) -> [URL] {
        var result: [URL] = []
        var pending: [URL] = [root]
        while let directory = pending.popLast() {
            result.append(directory)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            for entry in entries where WorkspaceScanner.isDirectory(entry) {
                pending.append(entry)
            }
        }
        return result
    }

    private func watch(_ directory: URL) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // The source is bound to the main queue, so this is safe by construction.
            MainActor.assumeIsolated { self?.scheduleChange() }
        }
        source.setCancelHandler { close(descriptor) }
        sources[directory.path] = source
        source.resume()
    }

    private func scheduleChange() {
        guard !isStopped else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            self.onChange()
            self.rebuild()
        }
    }
}

// MARK: - 工作区

/// 磁盘上的树变了，文档层得知道。
///
/// 协议而不是直接引用 `DocumentStore`：工作区与文档是两件独立的账，
/// 一个不该为了通知另一个先把自己绑死；测试里也可以只验一边。
@MainActor
protocol WorkspaceFileEvents: AnyObject {
    /// 当前文档（或它的上级目录）在磁盘上改了名或换了位置。
    func documentDidMove(from old: URL, to new: URL)
    /// 当前文档（或它的上级目录）进了废纸篓。
    func documentWasTrashed(at url: URL)
}

/// The folder the user opened as a workspace: its tree, the current selection,
/// and the watcher keeping the tree in sync with the Finder.
///
/// Deliberately separate from `DocumentStore`. That one owns exactly one open
/// document; this one owns the folder around it. They meet in the view layer:
/// clicking a tree row calls `DocumentStore.open(url:)`, and a change of
/// `DocumentStore.fileURL` calls `reveal(_:)` here.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var tree: WorkspaceNode?
    /// The file currently open in the editor, highlighted in the tree.
    @Published var selection: URL?
    /// Expanded folders by path. Held here rather than in the view so the state
    /// survives the tree rebuilds that external changes trigger.
    @Published var expandedPaths: Set<String> = []
    /// 刚建出来的那一行，界面收到后立刻把它变成输入框——「新建」的下一步
    /// 永远是「起名字」，不该让读者再去右键一次。
    @Published var pendingRename: URL?

    /// 当前文档跟着磁盘走的那条链路；由 App 装配，测试里为 nil。
    weak var fileEvents: (any WorkspaceFileEvents)?

    private var watcher: DirectoryWatcher?
    /// Where the workspace root and the expanded folders are remembered between
    /// launches. `nil` in tests, which must not read or write the real session.
    private let session: Session?
    /// 删除怎么落地。可注入：测试不能把文件丢进读者的真实废纸篓。
    private let moveToTrash: (URL) throws -> Void

    init(session: Session? = nil, moveToTrash: ((URL) throws -> Void)? = nil) {
        self.session = session
        self.moveToTrash = moveToTrash ?? WorkspaceFiles.defaultMoveToTrash
        restore()
    }

    var isOpen: Bool { root != nil }
    var rootName: String { root?.lastPathComponent ?? "" }

    /// Brings back the folder that was open last time. A path that no longer
    /// exists (unplugged drive, deleted folder) is dropped silently: coming back
    /// to "no workspace" is what a text editor should do, not an error dialog.
    func restore() {
        guard let session, let url = session.workspaceURL else { return }
        guard WorkspaceScanner.isDirectory(url) else {
            session.setWorkspace(nil)
            return
        }
        // 先把展开状态取出来：`open` 会先 `close` 上一个工作区（顺手清空并落盘），
        // 取晚了读到的是刚被清掉的那份。
        let expanded = session.expandedPaths
        open(url)
        expandedPaths = expanded
    }

    /// Opens `url` as the workspace root, replacing any previous workspace.
    func open(_ url: URL) {
        close()
        // 根先归一：目录枚举回来的是解析过符号链接的路径（`/var/…` →
        // `/private/var/…`），根要是原样留着，树里每一行都跟它「不是同一个目录」。
        root = url.resolvingSymlinksInPath()
        reload()
        session?.setWorkspace(root)
        watcher = DirectoryWatcher(root: url) { [weak self] in
            self?.reload()
        }
    }

    func close() {
        watcher?.stop()
        watcher = nil
        root = nil
        tree = nil
        selection = nil
        expandedPaths = []
        session?.setWorkspace(nil)
        session?.setExpandedPaths([])
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "打开工作区"
        panel.message = "选择包含 Markdown 文件的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    /// Rescans the folder on disk. Called on open and whenever the watcher
    /// reports a change.
    func reload() {
        guard let root else {
            tree = nil
            return
        }
        let scanned = WorkspaceScanner.scan(root: root)
        tree = scanned
        // A file that was deleted or moved out must not stay highlighted.
        if let selection, !Self.contains(selection, in: scanned) {
            self.selection = nil
        }
    }

    func select(_ url: URL) {
        selection = url.resolvingSymlinksInPath()
    }

    /// Highlights `url` and expands its ancestors when it lives inside the
    /// workspace. Used when a document is opened from elsewhere (⌘O, recent
    /// files, the window title bar).
    func reveal(_ url: URL) {
        let target = url.resolvingSymlinksInPath()
        guard let root, Self.isDescendant(target, of: root) else { return }
        for directory in ancestors(of: target, upTo: root) {
            expandedPaths.insert(directory.path)
        }
        selection = target
        session?.setExpandedPaths(expandedPaths)
    }

    func isExpanded(_ url: URL) -> Bool { expandedPaths.contains(url.path) }

    func setExpanded(_ url: URL, to expanded: Bool) {
        if expanded {
            expandedPaths.insert(url.path)
        } else {
            expandedPaths.remove(url.path)
        }
        session?.setExpandedPaths(expandedPaths)
    }

    // MARK: - 文件操作

    /// 在 `directory`（nil = 工作区根）下新建一篇空白文档。
    ///
    /// 名字先给「未命名」，然后把 `pendingRename` 亮起来：新建的下一步永远是
    /// 起名字，不该让读者再去右键一次。
    @discardableResult
    func createDocument(in directory: URL? = nil) -> URL? {
        guard let parent = directory ?? root else { return nil }
        guard let url = try? WorkspaceFiles.createDocument(in: parent) else { return nil }
        expand(parent)
        reload()
        selection = url
        pendingRename = url
        return url
    }

    @discardableResult
    func createFolder(in directory: URL? = nil) -> URL? {
        guard let parent = directory ?? root else { return nil }
        guard let url = try? WorkspaceFiles.createFolder(in: parent) else { return nil }
        expand(parent)
        reload()
        selection = url
        pendingRename = url
        return url
    }

    /// 改名并把本地记着的路径一起搬过去。返回 nil 表示成功。
    @discardableResult
    func rename(_ url: URL, to newName: String) -> FileOperationError? {
        do {
            let newURL = try WorkspaceFiles.rename(url, to: newName)
            guard newURL != url else { return nil }
            remapPaths(from: url, to: newURL)
            reload()
            return nil
        } catch let error as FileOperationError {
            return error
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 移到废纸篓。返回 nil 表示成功。
    @discardableResult
    func trash(_ url: URL) -> FileOperationError? {
        do {
            try WorkspaceFiles.trash(url, moveToTrash: moveToTrash)
        } catch let error as FileOperationError {
            return error
        } catch {
            return .failed(error.localizedDescription)
        }
        dropPaths(at: url)
        reload()
        fileEvents?.documentWasTrashed(at: url)
        return nil
    }

    /// 新建出来的东西可能在折叠着的目录里：一路展开到它，别让「新建了但看不见」。
    private func expand(_ directory: URL) {
        guard let root else { return }
        if directory != root {
            expandedPaths.insert(directory.standardizedFileURL.path)
        }
        for ancestor in ancestors(of: directory, upTo: root) {
            expandedPaths.insert(ancestor.standardizedFileURL.path)
        }
        session?.setExpandedPaths(expandedPaths)
    }

    /// 改名/移动之后，本地以旧路径为前缀的东西全部改挂到新路径上。
    ///
    /// 漏掉这一步的后果不是「不好看」：展开状态会凭空收起来、高亮会跳到别的行，
    /// 而会话里存着的旧路径下次启动会去开一个已经不存在的文件。
    private func remapPaths(from old: URL, to new: URL) {
        let oldPath = Self.canonicalPath(old)
        let newPath = Self.canonicalPath(new)

        func remap(_ path: String) -> String {
            if path == oldPath { return newPath }
            guard path.hasPrefix(oldPath + "/") else { return path }
            return newPath + String(path.dropFirst(oldPath.count))
        }

        expandedPaths = Set(expandedPaths.map(remap))
        if let selection {
            self.selection = URL(fileURLWithPath: remap(Self.canonicalPath(selection)))
        }
        session?.setExpandedPaths(expandedPaths)
        session?.remapPaths(from: old, to: new)
        fileEvents?.documentDidMove(from: old, to: new)
    }

    /// 删掉之后，本地不能再留着那条路径。
    private func dropPaths(at url: URL) {
        let path = Self.canonicalPath(url)
        if let selection, Self.isDescendantOrSelf(selection, of: url) {
            self.selection = nil
        }
        expandedPaths = expandedPaths.filter { $0 != path && !$0.hasPrefix(path + "/") }
        session?.setExpandedPaths(expandedPaths)
        session?.forgetPaths(at: url)
    }

    // MARK: - Helpers

    /// Folders between `url` and `root`, nearest first. Empty when `url` sits
    /// directly in the root.
    private func ancestors(of url: URL, upTo root: URL) -> [URL] {
        let rootPath = root.standardizedFileURL.path
        var result: [URL] = []
        var current = url.deletingLastPathComponent()
        while current.standardizedFileURL.path != rootPath,
              current.pathComponents.count > 1 {
            result.append(current)
            current = current.deletingLastPathComponent()
        }
        return result
    }

    /// 同一份文件可以被拼成 `/var/…` 与 `/private/var/…`（macOS 的临时目录、
    /// 部分外接卷都会）。URL 相等是字面比较，两种拼法会被当成两件不同的东西，
    /// 所以「是不是同一个」一律先归一再说。
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        canonicalPath(url).hasPrefix(canonicalPath(root) + "/")
    }

    static func isDescendantOrSelf(_ url: URL, of root: URL) -> Bool {
        canonicalPath(url) == canonicalPath(root) || isDescendant(url, of: root)
    }

    static func contains(_ url: URL, in node: WorkspaceNode?) -> Bool {
        guard let node else { return false }
        if canonicalPath(node.url) == canonicalPath(url) { return true }
        return node.children.contains { contains(url, in: $0) }
    }
}
