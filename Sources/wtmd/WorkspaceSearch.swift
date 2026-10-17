import Foundation

// MARK: - Results

/// One hit inside one file.
struct WorkspaceHit: Identifiable, Equatable, Sendable {
    let fileURL: URL
    /// Zero-based line number, matching the editor and the outline.
    let line: Int
    /// UTF-16 offset of the hit inside its line.
    let column: Int
    /// UTF-16 length of the hit.
    let length: Int
    /// The line as it should be displayed. Long lines are cut around the hit
    /// and padded with an ellipsis on whichever side was cut, so a hit in a
    /// 4000-character paragraph still reads as a sentence.
    let lineText: String
    /// Where the hit sits inside `lineText` after that cutting.
    let highlightStart: Int
    let highlightLength: Int

    var id: String { "\(fileURL.path)#\(line):\(column)" }
}

/// Hits of one file, in scan order.
struct WorkspaceHitGroup: Identifiable, Equatable, Sendable {
    let fileURL: URL
    let relativePath: String
    let hits: [WorkspaceHit]

    var id: String { fileURL.path }
}

/// The outcome of one sweep over the workspace.
struct WorkspaceSearchReport: Equatable, Sendable {
    var groups: [WorkspaceHitGroup] = []
    var hitCount = 0
    /// Files actually read.
    var scannedFiles = 0
    /// Files left alone — too large, or not decodable as UTF-8. Counted so the
    /// summary can be honest about what was *not* looked at.
    var skippedFiles = 0
    /// More hits existed than `limit` allowed.
    var truncated = false

    var hits: [WorkspaceHit] { groups.flatMap(\.hits) }
    var isEmpty: Bool { hitCount == 0 }
}

// MARK: - Engine

/// Full-text search over a folder workspace.
///
/// No index: a writing workspace holds hundreds of documents, and reading them
/// once per keystroke burst is faster than keeping an index correct — files get
/// renamed, synced and trashed from outside the app all day long, and a stale
/// index answers with the wrong text. Measured against 500 files before
/// deciding; if that ever stops being enough, an index is a v0.7 problem.
enum WorkspaceSearch {
    /// Upper bound on hits across the whole workspace. The count stays honest
    /// ("已截断") instead of pretending the folder holds 200 sentences.
    static let hitLimit = 200
    /// Files above this are skipped: a 2 MB Markdown file is bait, not a draft.
    static let fileSizeLimit = 2 * 1024 * 1024
    /// How much of a line the result row shows.
    static let contextWidth = 160
    /// Folders that never hold the reader's prose. Hidden ones (`.git`) are
    /// already covered by `.skipsHiddenFiles`.
    static let skippedDirectories: Set<String> = ["node_modules", "Pods", "DerivedData", ".build"]

    static func run(
        root: URL,
        query: String,
        options: FindOptions,
        limit: Int = hitLimit,
        sizeLimit: Int = fileSizeLimit,
        overlay: [URL: String] = [:],
        shouldContinue: @Sendable () -> Bool = { true }
    ) -> WorkspaceSearchReport {
        var report = WorkspaceSearchReport()
        guard !query.isEmpty else { return report }

        let rootPath = root.resolvingSymlinksInPath().path
        // 同一个文件可以拼成 `/var/...` 和 `/private/var/...`（枚举器自己就会
        // 把临时目录改写成后者），而 URL 相等是字面比较——不归一到同一个拼法，
        // 「正在编辑的那一篇」就会被当成另一篇，内存覆盖也就落空。
        let liveTexts = Dictionary(
            uniqueKeysWithValues: overlay.map { ($0.key.resolvingSymlinksInPath().path, $0.value) }
        )

        for url in markdownFiles(in: root, shouldContinue: shouldContinue) {
            // Cancelled mid-sweep: hand back what we have; the caller discards
            // it anyway, and stopping here is what keeps typing responsive.
            guard shouldContinue() else { return report }

            let canonicalPath = url.resolvingSymlinksInPath().path
            let text: String
            if let live = liveTexts[canonicalPath] {
                // The open document is searched as it is in memory: its file on
                // disk can lag one autosave behind, and missing the word the
                // reader just typed is the one answer that is plainly wrong.
                text = live
            } else {
                guard byteSize(of: url) <= sizeLimit,
                      let content = try? String(contentsOf: url, encoding: .utf8)
                else {
                    report.skippedFiles += 1
                    continue
                }
                text = content
            }

            let content = text as NSString
            guard content.length > 0 else { continue }
            report.scannedFiles += 1

            let scan = FindEngine.scan(content, query: query, options: options)
            guard !scan.matches.isEmpty else { continue }

            let starts = lineStarts(of: content)
            var hits: [WorkspaceHit] = []
            for match in scan.matches {
                if report.hitCount + hits.count >= limit {
                    report.truncated = true
                    break
                }
                let line = lineIndex(for: match.location, in: starts)
                let lineStart = starts[line]
                let lineEnd = line + 1 < starts.count ? starts[line + 1] - 1 : content.length
                let rawLine = content.substring(
                    with: NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
                )
                let context = context(
                    line: rawLine as NSString,
                    column: match.location - lineStart,
                    length: match.length
                )
                hits.append(
                    WorkspaceHit(
                        fileURL: url,
                        line: line,
                        column: match.location - lineStart,
                        length: match.length,
                        lineText: context.text,
                        highlightStart: context.start,
                        highlightLength: context.length
                    )
                )
            }

            if !hits.isEmpty {
                report.groups.append(
                    WorkspaceHitGroup(
                        fileURL: url,
                        relativePath: relativePath(of: canonicalPath, under: rootPath),
                        hits: hits
                    )
                )
                report.hitCount += hits.count
            }
            if report.truncated { break }
        }
        return report
    }

    // MARK: - Files

    /// Every Markdown file under `root`, in a stable order.
    ///
    /// Sorted by path rather than by the file system's enumeration order: two
    /// runs over the same folder must produce the same list, or `↑`/`↓` in the
    /// panel would point at different sentences each time.
    static func markdownFiles(in root: URL, shouldContinue: @Sendable () -> Bool = { true }) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if !shouldContinue() { break }
            if isSkippedDirectory(url) {
                enumerator.skipDescendants()
                continue
            }
            guard WorkspaceScanner.markdownExtensions.contains(url.pathExtension.lowercased()),
                  !WorkspaceScanner.isDirectory(url)
            else { continue }
            files.append(url)
        }
        return files.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
    }

    static func isSkippedDirectory(_ url: URL) -> Bool {
        guard skippedDirectories.contains(url.lastPathComponent) else { return false }
        return WorkspaceScanner.isDirectory(url)
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        relativePath(of: url.resolvingSymlinksInPath().path, under: root.resolvingSymlinksInPath().path)
    }

    private static func relativePath(of path: String, under rootPath: String) -> String {
        guard path.hasPrefix(rootPath + "/") else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func byteSize(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? .max
    }

    // MARK: - Lines

    /// UTF-16 offsets where each line starts. Same shape as the editor's own
    /// `lineStarts`, so a hit found here lands on the line the editor scrolls to.
    static func lineStarts(of content: NSString) -> [Int] {
        var starts: [Int] = [0]
        var index = 0
        while index < content.length {
            var cursor = index
            while cursor < content.length, content.character(at: cursor) != 10 { cursor += 1 }
            if cursor >= content.length { break }
            starts.append(cursor + 1)
            index = cursor + 1
        }
        return starts
    }

    /// Index of the last line starting at or before `location`.
    static func lineIndex(for location: Int, in starts: [Int]) -> Int {
        guard !starts.isEmpty else { return 0 }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The slice of a line worth showing, with the hit re-mapped into it.
    ///
    /// The hit is kept in the left third: in prose, what follows a word explains
    /// it far more often than what precedes it.
    static func context(
        line: NSString,
        column: Int,
        length: Int
    ) -> (text: String, start: Int, length: Int) {
        var raw = line as String
        // A CR left over from CRLF would paint a box in the middle of the row.
        if raw.hasSuffix("\r") { raw.removeLast() }
        let text = raw as NSString

        guard text.length > contextWidth else {
            let safeColumn = min(max(0, column), text.length)
            let safeLength = min(max(0, length), text.length - safeColumn)
            return (raw, safeColumn, safeLength)
        }

        let head = max(0, min(column - contextWidth / 3, text.length - contextWidth))
        let leading = head > 0 ? "…" : ""
        let trailing = head + contextWidth < text.length ? "…" : ""
        let piece = text.substring(with: NSRange(location: head, length: contextWidth))
        let start = column - head + leading.utf16.count
        let room = max(0, contextWidth - (column - head))
        let safeLength = min(max(0, length), room)
        return (leading + piece + trailing, start, safeLength)
    }
}
