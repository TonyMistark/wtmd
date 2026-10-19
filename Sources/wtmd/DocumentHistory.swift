import CryptoKit
import Foundation

/// 一版旧稿。
struct HistoryEntry: Identifiable, Equatable {
    /// 这一版在历史目录里的位置——它就是一份普通 `.md`，用任何编辑器都打得开。
    let fileURL: URL
    let savedAt: Date
    let bytes: Int

    var id: URL { fileURL }
}

/// 本地版本历史：写过的每一版都留一份。
///
/// 自动保存保证「此刻不丢」，却只保此刻——误删一段、整篇替换、外部工具覆盖之后，
/// 盘上只剩最后一版。这里把旧的那几版收在一边，翻得回去。
///
/// 三条设计约束：
///
/// - **不写进读者的文件夹**。稿子旁边多出 `.history/` 会把「拷给别人」「丢进 Git」
///   这两件事弄脏。历史放在 `~/Library/Application Support/wtmd/history/`。
/// - **目录本身就是账本**。每个版本一个 `<时间戳>-<内容哈希>.md`，列表从目录推导，
///   不另存索引：账本会和文件走散（`ConflictArchive` 的 manifest 是无奈之举，
///   那里要记原路径；这里连这个都不必——目录名就是路径哈希，`meta.json` 只给人看）。
/// - **同一篇只认一份**。目录名取 `PathKey.canonical` 的哈希，`/var` 与
///   `/private/var`、符号链接前后两种拼法都落进同一个目录。
final class DocumentHistory {
    /// 根目录：其下每个子目录是一篇稿子的历史。
    let directory: URL
    /// 留存时间。注入是为了测「间隔到了没有」与「三十天之外」这类边界。
    private let clock: () -> Date
    /// 两次自动留存至少隔这么久。打开与离开是「有意义的时刻」，不受它限制。
    let minimumInterval: TimeInterval
    /// 每篇最多留几版。
    let maxCount: Int
    /// 每版最多留多久。
    let maxAge: TimeInterval
    /// 本进程内每篇最近一次留存的时刻。自动保存每 1.2 秒就可能写一次盘，
    /// 每次都去列目录、读上一版内容只为确认「还不到时候」，纯属白花。
    /// 它只用来**提前跳过**——跳过的这些，间隔那道关本来也会挡。
    private var lastCapture: [String: Date] = [:]

    init(
        directory: URL? = nil,
        clock: @escaping () -> Date = Date.init,
        minimumInterval: TimeInterval = 300,
        maxCount: Int = 50,
        maxAge: TimeInterval = 30 * 86_400
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.clock = clock
        self.minimumInterval = minimumInterval
        self.maxCount = maxCount
        self.maxAge = maxAge
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("wtmd/history", isDirectory: true)
    }

    // MARK: - 留存

    /// 给 `url` 留一版。
    ///
    /// - Parameters:
    ///   - text: 这一版的内容。
    ///   - url: 它属于哪一篇。
    ///   - force: 越过最小间隔。给「打开时」与「离开时」用——那两个时刻各有意义，
    ///     不该被「五分钟还没到」吃掉。
    /// - Returns: 真的写下了才返回这一版；内容与最新一版相同、在间隔内、或内容为空
    ///   都返回 `nil`（调用方不需要区分，也不该据此做别的事）。
    @discardableResult
    func capture(_ text: String, for url: URL, force: Bool = false) -> HistoryEntry? {
        // 空文档没有可回的东西。留一版空白只会把有用的旧版往前挤，最后把它们挤出保留窗口。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let key = Self.key(for: url)
        let now = clock()
        if !force, let last = lastCapture[key], now.timeIntervalSince(last) < minimumInterval {
            return nil
        }

        let folder = self.folder(for: url)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if let newest = entries(for: url).first {
            // 内容没变就不留：打开同一篇十次不是十版。
            if content(of: newest) == text { return nil }
            // 间隔是给「一直开着写」用的：自动保存每 1.2 秒就可能写一次盘，
            // 每次都留一版，五十版会在十分钟内被填满。
            if !force, now.timeIntervalSince(newest.savedAt) < minimumInterval { return nil }
        }

        let stamp = now
        let name = uniqueName(at: stamp, hash: Self.contentKey(text), in: folder)
        let target = folder.appendingPathComponent(name)
        guard (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        lastCapture[key] = stamp
        writeMeta(for: url, in: folder)
        prune(for: url)
        return HistoryEntry(fileURL: target, savedAt: stamp, bytes: Data(text.utf8).count)
    }

    // MARK: - 翻阅

    /// 这一篇的旧版，最新的在前。
    ///
    /// 从目录本身推导：文件名里就有时间戳，目录列表就是账本。排序在时间相同时
    /// 再看文件名，保证同一秒里的两版顺序稳定（`capture` 的 `-2` 后缀会排在前面）。
    func entries(for url: URL) -> [HistoryEntry] {
        let folder = self.folder(for: url)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        return names
            .compactMap { name -> HistoryEntry? in
                guard let savedAt = Self.date(fromName: name) else { return nil }
                let fileURL = folder.appendingPathComponent(name)
                let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int
                return HistoryEntry(fileURL: fileURL, savedAt: savedAt, bytes: size ?? 0)
            }
            .sorted {
                $0.savedAt == $1.savedAt
                    ? $0.fileURL.lastPathComponent > $1.fileURL.lastPathComponent
                    : $0.savedAt > $1.savedAt
            }
    }

    func content(of entry: HistoryEntry) -> String? {
        try? String(contentsOf: entry.fileURL, encoding: .utf8)
    }

    /// 这一篇有没有历史。面板与菜单用它决定是不是灰着。
    func hasHistory(for url: URL) -> Bool {
        !entries(for: url).isEmpty
    }

    func remove(_ entry: HistoryEntry) {
        try? FileManager.default.removeItem(at: entry.fileURL)
    }

    /// 忘掉这一篇的全部历史（连同目录）。
    func removeAll(for url: URL) {
        try? FileManager.default.removeItem(at: folder(for: url))
        lastCapture[Self.key(for: url)] = nil
    }

    // MARK: - 位置

    /// 这篇稿子的历史目录。名字是路径的哈希：路径里有 `/`、空格、中文，
    /// 直接当目录名会处处转义，换台机器还可能撞上文件名长度上限。
    func folder(for url: URL) -> URL {
        directory.appendingPathComponent(Self.key(for: url), isDirectory: true)
    }

    static func key(for url: URL) -> String {
        hexDigest(PathKey.canonical(url), length: 8)
    }

    /// `meta.json` 只为人看：直接用 Finder 打开历史目录时，得知道这一屋子
    /// 旧稿原来是哪一篇。程序不依赖它——目录名已经回答了「是哪一篇」。
    struct Meta: Codable, Equatable {
        var path: String
        var name: String
    }

    func meta(for url: URL) -> Meta? {
        let target = folder(for: url).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: target) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    // MARK: - 保留策略

    /// 留完之后顺手清：新的在外，超出版数或岁数的从尾巴上删。
    private func prune(for url: URL) {
        let now = clock()
        var kept = 0
        for entry in entries(for: url) {
            let expired = now.timeIntervalSince(entry.savedAt) > maxAge
            if expired || kept >= maxCount {
                try? FileManager.default.removeItem(at: entry.fileURL)
            } else {
                kept += 1
            }
        }
    }

    // MARK: - 命名

    private func writeMeta(for url: URL, in folder: URL) {
        let meta = Meta(path: PathKey.canonical(url), name: url.lastPathComponent)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    private func uniqueName(at date: Date, hash: String, in folder: URL) -> String {
        let base = "\(Self.stampFormatter.string(from: date))-\(hash.prefix(8))"
        var candidate = base + ".md"
        var index = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(index).md"
            index += 1
        }
        return candidate
    }

    /// 文件名 → 时间。认不出的文件（读者自己放进去的）直接忽略，不当成历史。
    private static func date(fromName name: String) -> Date? {
        guard name.range(of: #"^\d{8}-\d{6}-[0-9a-f]{8}(-\d+)?\.md$"#, options: .regularExpression) != nil
        else { return nil }
        return stampFormatter.date(from: String(name.prefix(15)))
    }

    private static func contentKey(_ text: String) -> String {
        hexDigest(text, length: 4)
    }

    private static func hexDigest(_ string: String, length: Int) -> String {
        SHA256.hash(data: Data(string.utf8))
            .prefix(length)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 本地时区、固定格式：文件名要能排序，也要能用眼睛读。
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
