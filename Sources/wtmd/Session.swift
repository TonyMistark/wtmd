import CoreGraphics
import Foundation

/// What survives a relaunch: the workspace folder, the file that was open, the
/// folders expanded in the tree, and where the reader stood in each document.
///
/// Stored as **one JSON blob** under a single key rather than a scatter of
/// `UserDefaults` keys: these entries describe one thing (a session), they must
/// stay consistent with each other, and a blob gives "no session yet" and
/// "session written by an older version" a single place to be rejected.
///
/// `defaults` and `now` are injectable because tests must never read or write the
/// user's real session — and because an LRU bound can only be tested with a clock
/// whose ordering is predictable.
final class Session {
    /// Where the reader was in one file.
    ///
    /// Both kinds of position live in one record on purpose: the editor and the
    /// preview are two views of the same document, and a session restore has to
    /// put both of them back in one go.
    struct Position: Codable, Equatable {
        var selectionLocation: Int
        var selectionLength: Int
        var scrollX: Double
        var scrollY: Double
        var blockIndex: Int
        var blockOffset: Double
        /// The file's modification date when this position was recorded, so a
        /// later reader can tell "same file, moved on disk" from "same file,
        /// untouched". Seconds since 1970; `nil` when the file was never stat'ed.
        var modifiedAt: Double?
        /// Last time this entry was touched. Stamped by `Session.record`, so the
        /// caller never has to supply a clock and can leave it at the default.
        var updatedAt: Double = 0
    }

    private struct Snapshot: Codable {
        var version: Int = Session.currentVersion
        var workspacePath: String?
        var openFilePath: String?
        var expandedPaths: [String] = []
        var positions: [String: Position] = [:]
    }

    /// How many documents keep a remembered position. A writing workspace holds
    /// tens of files at most; the bound exists so the blob cannot grow without
    /// limit when someone opens a folder of hundreds of notes once.
    static let positionLimit = 20

    private static let key = "wtmd.session"
    private static let currentVersion = 1

    private let defaults: UserDefaults
    private let now: () -> Date
    private var snapshot: Snapshot

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data),
           decoded.version == Self.currentVersion {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
    }

    // MARK: - 工作区

    var workspaceURL: URL? {
        snapshot.workspacePath.map { URL(fileURLWithPath: $0) }
    }

    func setWorkspace(_ url: URL?) {
        snapshot.workspacePath = url?.standardizedFileURL.path
        flush()
    }

    var expandedPaths: Set<String> {
        Set(snapshot.expandedPaths)
    }

    func setExpandedPaths(_ paths: Set<String>) {
        guard Set(snapshot.expandedPaths) != paths else { return }
        snapshot.expandedPaths = paths.sorted()
        flush()
    }

    // MARK: - 当前文档

    var openFileURL: URL? {
        snapshot.openFilePath.map { URL(fileURLWithPath: $0) }
    }

    func setOpenFile(_ url: URL?) {
        snapshot.openFilePath = url?.standardizedFileURL.path
        flush()
    }

    // MARK: - 每篇文档的位置

    /// Records (or refreshes) the position for `url`, stamping it as the most
    /// recently used entry.
    func record(_ position: Position, for url: URL) {
        var entry = position
        entry.updatedAt = now().timeIntervalSince1970
        snapshot.positions[Self.key(for: url)] = entry
        evictBeyondLimit()
        flush()
    }

    func position(for url: URL) -> Position? {
        snapshot.positions[Self.key(for: url)]
    }

    func forget(_ url: URL) {
        guard snapshot.positions.removeValue(forKey: Self.key(for: url)) != nil else { return }
        flush()
    }

    /// Drops everything. Used when the workspace is gone for good, and by tests.
    func clear() {
        snapshot = Snapshot()
        flush()
    }

    // MARK: - 实现

    /// Keyed by standardized path so `/a/./b.md` and `/a/b.md` are one document,
    /// and so the same file reached through a symlinked parent still matches.
    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Keeps the `positionLimit` most recently used entries, oldest out.
    private func evictBeyondLimit() {
        let overflow = snapshot.positions.count - Self.positionLimit
        guard overflow > 0 else { return }
        let ordered = snapshot.positions.sorted { $0.value.updatedAt < $1.value.updatedAt }
        for (key, _) in ordered.prefix(overflow) {
            snapshot.positions[key] = nil
        }
    }

    private func flush() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
