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

    /// Scans `root` into a folder node, or returns nil when `root` is not a
    /// readable directory.
    static func scan(root: URL) -> WorkspaceNode? {
        guard isDirectory(root) else { return nil }
        return WorkspaceNode(url: root, isDirectory: true, children: scanChildren(of: root))
    }

    /// Folders and files directly inside `directory`, folders first and then by
    /// name. Folders with no Markdown anywhere below them are dropped: they
    /// would only add noise to a writing workspace.
    static func scanChildren(of directory: URL) -> [WorkspaceNode] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        var folders: [WorkspaceNode] = []
        var files: [WorkspaceNode] = []

        for entry in entries {
            if isDirectory(entry) {
                let children = scanChildren(of: entry)
                guard !children.isEmpty else { continue }
                folders.append(WorkspaceNode(url: entry, isDirectory: true, children: children))
            } else if markdownExtensions.contains(entry.pathExtension.lowercased()) {
                files.append(WorkspaceNode(url: entry, isDirectory: false))
            }
        }

        return folders.sorted(by: byName) + files.sorted(by: byName)
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

    private var watcher: DirectoryWatcher?

    var isOpen: Bool { root != nil }
    var rootName: String { root?.lastPathComponent ?? "" }

    /// Opens `url` as the workspace root, replacing any previous workspace.
    func open(_ url: URL) {
        close()
        root = url
        reload()
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
        selection = url
    }

    /// Highlights `url` and expands its ancestors when it lives inside the
    /// workspace. Used when a document is opened from elsewhere (⌘O, recent
    /// files, the window title bar).
    func reveal(_ url: URL) {
        guard let root, Self.isDescendant(url, of: root) else { return }
        for directory in ancestors(of: url, upTo: root) {
            expandedPaths.insert(directory.path)
        }
        selection = url
    }

    func isExpanded(_ url: URL) -> Bool { expandedPaths.contains(url.path) }

    func setExpanded(_ url: URL, to expanded: Bool) {
        if expanded {
            expandedPaths.insert(url.path)
        } else {
            expandedPaths.remove(url.path)
        }
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

    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    static func contains(_ url: URL, in node: WorkspaceNode?) -> Bool {
        guard let node else { return false }
        if node.url == url { return true }
        return node.children.contains { contains(url, in: $0) }
    }
}
