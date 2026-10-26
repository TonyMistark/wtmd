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

/// A file's size and modification time — the fingerprint by which a rename
/// made behind our back (in the Finder, say) is recognized. Both survive a
/// rename untouched, and together they are unlikely to collide by accident.
struct FileStat: Equatable {
    let size: Int
    let modified: Date

    init?(url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard
            let size = (attributes?[.size] as? NSNumber)?.intValue,
            let modified = attributes?[.modificationDate] as? Date
        else { return nil }
        self.size = size
        self.modified = modified
    }
}

/// One row of the roster: where the file was and what it looked like when it
/// was last seen. Kept together so the relink matcher can pair the *recorded*
/// canonical key with the URL that produced it.
struct FileRecord {
    let url: URL
    let stat: FileStat
}
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
    /// Whether the whole workspace section in the sidebar is unfolded. Toggled
    /// by double-clicking the workspace header row; held here so tree rebuilds
    /// don't snap it back open.
    @Published var sectionExpanded = true
    /// 刚建出来的那一行，界面收到后立刻把它变成输入框——「新建」的下一步
    /// 永远是「起名字」，不该让读者再去右键一次。
    @Published var pendingRename: URL?

    /// 当前文档跟着磁盘走的那条链路；由 App 装配，测试里为 nil。
    weak var fileEvents: (any WorkspaceFileEvents)?

    private var watcher: DirectoryWatcher?
    /// Where the workspace root and the expanded folders are remembered between
    /// launches. `nil` in tests, which must not read or write the real session.
    private let session: Session?
    /// Every file in the tree, by canonical path: its URL plus its fingerprint.
    /// Rebuilt after each scan; **between** scans it doubles as the roster of
    /// what existed last time — and that is the only stable form of it. A file
    /// that has just vanished can no longer be canonicalized reliably (the
    /// resolver gives up on paths that are gone and hands back the raw input),
    /// so the vanished side of the match is taken from this table, recorded
    /// while the file still existed.
    private var fileRecords: [String: FileRecord] = [:]

    init(session: Session? = nil) {
        self.session = session
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
        panel.prompt = t("Open Workspace")
        panel.message = t("Choose a folder that holds Markdown files")
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    /// Rescans the folder on disk. Called on open and whenever the watcher
    /// reports a change.
    ///
    /// `relinking` is off for reloads that follow an operation wtmd itself just
    /// performed: those already remapped every local path explicitly, and the
    /// matcher would only find the old-new pairs a second time.
    func reload(relinking: Bool = true) {
        guard let root else {
            tree = nil
            return
        }
        let scanned = WorkspaceScanner.scan(root: root)
        tree = scanned
        if relinking {
            relinkExternalChanges(to: scanned)
        }
        refreshFileRecords()
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
            expandedPaths.insert(Self.canonicalPath(directory))
        }
        selection = target
        session?.setExpandedPaths(expandedPaths)
    }

    /// 展开状态一律按归一后的路径记：树里给的是 `/private/var/…`，别处来的可能
    /// 是 `/var/…`，两种拼法在 Set 里是两把不同的钥匙。
    func isExpanded(_ url: URL) -> Bool { expandedPaths.contains(Self.canonicalPath(url)) }

    func setExpanded(_ url: URL, to expanded: Bool) {
        if expanded {
            expandedPaths.insert(Self.canonicalPath(url))
        } else {
            expandedPaths.remove(Self.canonicalPath(url))
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
        reload(relinking: false)
        selection = url
        pendingRename = url
        return url
    }

    @discardableResult
    func createFolder(in directory: URL? = nil) -> URL? {
        guard let parent = directory ?? root else { return nil }
        guard let url = try? WorkspaceFiles.createFolder(in: parent) else { return nil }
        expand(parent)
        reload(relinking: false)
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
            reload(relinking: false)
            return nil
        } catch let error as FileOperationError {
            return error
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 把一个文件或文件夹挪进 `directory`，并让本地记着的路径一起搬过去。
    /// 返回 nil 表示成功（或什么都没发生）。
    @discardableResult
    func move(_ url: URL, into directory: URL) -> FileOperationError? {
        do {
            let newURL = try WorkspaceFiles.move(url, into: directory)
            guard Self.canonicalPath(newURL) != Self.canonicalPath(url) else { return nil }
            remapPaths(from: url, to: newURL)
            // 目标是折叠着的话，东西「移进去了但看不见」和丢了没区别
            expand(directory)
            reload(relinking: false)
            return nil
        } catch let error as FileOperationError {
            return error
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 新建出来的东西可能在折叠着的目录里：一路展开到它，别让「新建了但看不见」。
    private func expand(_ directory: URL) {
        guard let root else { return }
        if !Self.isSameDirectory(directory, root) {
            expandedPaths.insert(Self.canonicalPath(directory))
        }
        for ancestor in ancestors(of: directory, upTo: root) {
            expandedPaths.insert(Self.canonicalPath(ancestor))
        }
        session?.setExpandedPaths(expandedPaths)
    }

    private static func isSameDirectory(_ a: URL, _ b: URL) -> Bool {
        canonicalPath(a) == canonicalPath(b)
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

    // MARK: - Helpers

    // MARK: 外部改动的静默跟随

    /// A file that disappeared while the tree changed elsewhere was most likely
    /// renamed or moved in the Finder. Match it against files the new tree
    /// gained, by size + modification time — if one matches, this **is** the
    /// same file under a new name, and everything recorded about the old path
    /// should follow it instead of dangling. No banner, no reload.
    private func relinkExternalChanges(to current: WorkspaceNode?) {
        guard !fileRecords.isEmpty else { return }
        var newFiles: [String: URL] = [:]
        Self.collectFiles(in: current, into: &newFiles)
        for pair in Self.relinkedPaths(oldRecords: fileRecords, newFiles: newFiles) {
            remapPaths(from: pair.old, to: pair.new)
        }
    }

    /// Every Markdown file in the subtree, by canonical path.
    static func collectFiles(in node: WorkspaceNode?, into result: inout [String: URL]) {
        guard let node else { return }
        if !node.isDirectory {
            result[canonicalPath(node.url)] = node.url
            return
        }
        for child in node.children {
            collectFiles(in: child, into: &result)
        }
    }

    /// Pairs up vanished files with newcomers by fingerprint. The vanished
    /// side comes from the roster recorded by the *previous* scan — the disk
    /// can no longer be asked about a file that is gone — while newcomers are
    /// stat'ed on the spot. Candidates in the file's own directory win: a
    /// rename is the common case, and picking a same-sized twin from another
    /// folder for it would be a coincidence to conjure. Deterministic
    /// otherwise (path order) so tests can pin behavior.
    static func relinkedPaths(
        oldRecords: [String: FileRecord],
        newFiles: [String: URL],
        stat: (URL) -> FileStat? = { FileStat(url: $0) }
    ) -> [(old: URL, new: URL)] {
        let vanished = oldRecords.keys.filter { newFiles[$0] == nil }.sorted()
        var newcomers = newFiles.filter { oldRecords[$0.key] == nil }
        var pairs: [(old: URL, new: URL)] = []
        for oldPath in vanished {
            guard let record = oldRecords[oldPath] else { continue }
            let oldURL = record.url
            let fingerprint = record.stat
            let oldParent = (oldPath as NSString).deletingLastPathComponent
            guard
                let candidate = newcomers
                    .filter({ stat($0.value) == fingerprint })
                    .sorted(by: { a, b in
                        let aSameParent = (a.key as NSString).deletingLastPathComponent == oldParent
                        let bSameParent = (b.key as NSString).deletingLastPathComponent == oldParent
                        if aSameParent != bSameParent { return aSameParent }
                        return a.key < b.key
                    })
                    .first
            else { continue }
            newcomers[candidate.key] = nil
            pairs.append((oldURL, candidate.value))
        }
        return pairs
    }

    /// Rebuilds the roster from the freshly scanned tree.
    private func refreshFileRecords() {
        var files: [String: URL] = [:]
        Self.collectFiles(in: tree, into: &files)
        var records: [String: FileRecord] = [:]
        for (path, url) in files {
            if let stat = FileStat(url: url) {
                // The URL is rebuilt from the canonical key on purpose: once
                // the file is gone, no resolver can be trusted with the raw
                // path again, and the roster is what survives.
                records[path] = FileRecord(url: URL(fileURLWithPath: path), stat: stat)
            }
        }
        fileRecords = records
    }

    /// Folders between `url` and `root`, nearest first. Empty when `url` sits
    /// directly in the root.
    private func ancestors(of url: URL, upTo root: URL) -> [URL] {
        var result: [URL] = []
        var current = url.deletingLastPathComponent()
        // 一路上走到工作区根为止：多走一步就会把根**外面**的目录也塞进展开状态，
        // 下次启动带着一串跟自己无关的路径。
        while PathKey.isDescendant(current, of: root) {
            result.append(current)
            current = current.deletingLastPathComponent()
        }
        return result
    }

    /// 「是不是同一个文件」的判据在 `PathKey` 里——纯函数，不依赖主线程，
    /// 文件操作那一层（`WorkspaceFiles`）也要用同一套。这里留着这个入口，
    /// 是因为调用点已经习惯了从工作区问。
    static func canonicalPath(_ url: URL) -> String { PathKey.canonical(url) }

    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        PathKey.isDescendant(url, of: root)
    }

    static func isDescendantOrSelf(_ url: URL, of root: URL) -> Bool {
        PathKey.isDescendantOrSelf(url, of: root)
    }

    static func contains(_ url: URL, in node: WorkspaceNode?) -> Bool {
        guard let node else { return false }
        if canonicalPath(node.url) == canonicalPath(url) { return true }
        return node.children.contains { contains(url, in: $0) }
    }
}
