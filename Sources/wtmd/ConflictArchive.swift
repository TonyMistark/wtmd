import Foundation

/// 一份冲突发生时留下的本地版本。
struct ConflictArchiveEntry: Identifiable, Equatable {
    /// 副本在 `conflicts/` 目录里的位置（副本本身就是一份普通 `.md`）。
    let fileURL: URL
    /// 它原来叫什么名字。
    let originalName: String
    /// 它原来在哪儿。文件之后可能被删、被改名，这里只是「当时」的事实。
    let originalPath: String?
    let savedAt: Date

    var id: URL { fileURL }
}

/// 冲突没解决就切走时，本地那份的去处。
///
/// 磁盘上的版本是别人的，不能覆盖；编辑器里的版本是读者刚写的，也不能扔。
/// 两边都要留，于是本地版本落到 `conflicts/` 目录，状态栏留一个入口。
///
/// 目录里放的是**普通 Markdown 文件**加一份 `manifest.json`：副本要能被人直接用
/// 别的编辑器打开（所以是纯正文），而「原来叫什么、什么时候存的」这些信息塞进正文
/// 会污染内容，只能另存一本账。账丢了也不至于丢内容——文件还在，只是没人认领。
final class ConflictArchive {
    let directory: URL
    /// 存档时间。注入是为了让「同一秒存两次」这种边界可测。
    private let clock: () -> Date

    private var manifestURL: URL { directory.appendingPathComponent(Self.manifestName) }

    private struct Record: Codable {
        var file: String
        var originalPath: String?
        var savedAt: Date
    }

    static let manifestName = "manifest.json"

    init(directory: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.directory = directory ?? Self.defaultDirectory
        self.clock = clock
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("wtmd/conflicts", isDirectory: true)
    }

    /// 把一份内容存成副本。返回 `nil` 说明连存档都写不进去（磁盘满、目录不可写），
    /// 调用方仍应继续切文档——拦住切换只会让人卡在一个已经坏掉的状态里。
    @discardableResult
    func archive(_ text: String, originalURL: URL?) -> ConflictArchiveEntry? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = clock()
        let name = uniqueName(stem: Self.stem(for: originalURL), at: stamp)
        let target = directory.appendingPathComponent(name)
        guard (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }

        var records = records()
        records.append(Record(file: name, originalPath: originalURL?.path, savedAt: stamp))
        save(records)

        return ConflictArchiveEntry(
            fileURL: target,
            originalName: originalURL?.lastPathComponent ?? "未命名.md",
            originalPath: originalURL?.path,
            savedAt: stamp
        )
    }

    /// 现存副本，最新的在前。已经被别处删掉的文件顺手从账上划掉。
    func entries() -> [ConflictArchiveEntry] {
        var records = records()
        let before = records.count
        records.removeAll { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.file).path) }
        if records.count != before { save(records) }

        return records
            .sorted { $0.savedAt > $1.savedAt }
            .map { record in
                let path = record.originalPath
                return ConflictArchiveEntry(
                    fileURL: directory.appendingPathComponent(record.file),
                    originalName: Self.originalName(of: record),
                    originalPath: (path?.isEmpty == false) ? path : nil,
                    savedAt: record.savedAt
                )
            }
    }

    func content(of entry: ConflictArchiveEntry) -> String? {
        try? String(contentsOf: entry.fileURL, encoding: .utf8)
    }

    func remove(_ entry: ConflictArchiveEntry) {
        try? FileManager.default.removeItem(at: entry.fileURL)
        let name = entry.fileURL.lastPathComponent
        save(records().filter { $0.file != name })
    }

    func removeAll() {
        for record in records() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.file))
        }
        save([])
    }

    // MARK: - 账本

    private func records() -> [Record] {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return decoded
    }

    private func save(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - 命名

    /// `稿.md` → `稿`；`/` 与 `:` 在文件名里不能出现（Finder 会把 `:` 显示成 `/`）。
    static func stem(for url: URL?) -> String {
        let raw = url?.deletingPathExtension().lastPathComponent ?? "未命名"
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : cleaned
    }

    /// 同一秒里存两份同名副本时不能互相覆盖——那正好是「连切两次」会发生的事。
    private func uniqueName(stem: String, at date: Date) -> String {
        let base = "\(stem)-\(Self.stampFormatter.string(from: date))"
        var candidate = base + ".md"
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(index).md"
            index += 1
        }
        return candidate
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// 账上没有原路径时（老账本、手工放进去的文件），从文件名里退一步猜。
    private static func originalName(of record: Record) -> String {
        if let path = record.originalPath, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        // 去掉 `<stem>-<yyyyMMdd-HHmmss>[-n].md` 里的时间戳后缀
        let name = record.file
        guard let range = name.range(of: #"-\d{8}-\d{6}(-\d+)?\.md$"#, options: .regularExpression) else {
            return name
        }
        return name.replacingCharacters(in: range, with: ".md")
    }
}
