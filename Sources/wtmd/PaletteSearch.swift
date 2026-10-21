import Combine
import Foundation

// MARK: - 搜什么

/// 面板里的一段结果。
///
/// 前缀是语法而不是设置：`>` 只要命令、`@` 只要文件、`#` 只要正文。
/// 不写前缀就是「全都搜」——读者不该先做一次分类再开始找。
enum PaletteScope: String, CaseIterable, Identifiable {
    case all
    case commands
    case files
    case text

    var id: String { rawValue }

    /// 开头那个字符。点胶囊切段，跟直接打前缀是同一条路。
    var prefix: Character? {
        switch self {
        case .all: return nil
        case .commands: return ">"
        case .files: return "@"
        case .text: return "#"
        }
    }

    var title: String {
        switch self {
        case .all: return t("All", "全部")
        case .commands: return t("Commands", "命令")
        case .files: return t("Files", "文件")
        case .text: return t("Text", "正文")
        }
    }

    var symbol: String {
        switch self {
        case .all: return "circle.grid.2x2"
        case .commands: return "command"
        case .files: return "doc.text"
        case .text: return "text.alignleft"
        }
    }

    static func forPrefix(_ character: Character) -> PaletteScope? {
        allCases.first { $0.prefix == character }
    }
}

/// 一次输入拆成「搜什么」与「搜什么词」。
///
/// 前缀只在**第一个非空字符**上生效：`#` 在正文里很正常，一个标题写着
/// `# 第三章` 时读者不会指望它变成「只搜正文」。
struct PaletteQuery: Equatable {
    let scope: PaletteScope
    let needle: String

    var trimmedNeedle: String {
        needle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { trimmedNeedle.isEmpty }

    static func parse(_ raw: String) -> PaletteQuery {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, let scope = PaletteScope.forPrefix(first) else {
            return PaletteQuery(scope: .all, needle: raw)
        }
        return PaletteQuery(scope: scope, needle: String(text.dropFirst()))
    }
}

// MARK: - 文件

/// 一个能跳过去的文件。`relativePath` 已经算好：面板每画一行都要用。
struct PaletteFileHit: Identifiable, Equatable {
    let url: URL
    let name: String
    let relativePath: String

    var id: String { url.path }
}

/// 文件名与相对路径的匹配。
///
/// 复用命令那套子序列评分：几个字母（`d3`、`排版`）就该把文件顶上来，
/// 而不是要求把名字打全。文件名命中永远高于只在路径里命中的。
enum PaletteFileSearch {
    static func filter(_ needle: String, in files: [PaletteFileHit], limit: Int) -> [PaletteFileHit] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(files.prefix(limit))
        }

        let characters = Array(trimmed)
        let scored: [(index: Int, hit: PaletteFileHit, score: Int)] = files.enumerated().compactMap { index, file in
            if let match = CommandSearch.bestMatch(characters, in: file.name) {
                return (index, file, match.score)
            }
            // 路径命中降一等：找 `书稿/第三章.md` 打 `书稿` 也该出得来，
            // 但名字里真有这两个字的文件得排在前面。
            guard let match = CommandSearch.bestMatch(characters, in: file.relativePath) else {
                return nil
            }
            return (index, file, match.score / 2)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.hit.relativePath < rhs.hit.relativePath
            }
            .prefix(limit)
            .map(\.hit)
    }

    /// 把工作区树摊平。目录不进去：命中的永远是文件。
    static func flatten(_ node: WorkspaceNode?, root: URL?) -> [PaletteFileHit] {
        guard let node else { return [] }
        var files: [PaletteFileHit] = []
        walk(node, root: root, into: &files)
        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private static func walk(_ node: WorkspaceNode, root: URL?, into files: inout [PaletteFileHit]) {
        if node.isDirectory {
            for child in node.children { walk(child, root: root, into: &files) }
            return
        }
        let relative: String
        if let root {
            relative = WorkspaceSearch.relativePath(of: node.url, under: root)
        } else {
            relative = node.url.lastPathComponent
        }
        files.append(PaletteFileHit(url: node.url, name: node.name, relativePath: relative))
    }
}

// MARK: - 分组

/// 结果区里的一段。空查询时按命令原本的分组摆，有查询时按「命令 / 文件 /
/// 正文」摆——两种顺序各自都是读者正在做的那件事的形状。
enum PaletteGroup: Equatable {
    case recent
    case searches
    /// 空查询时命令自己的分组（文件、编辑、视图……）。
    case section(CommandSection)
    /// 有查询时的三段。
    case commands
    case files
    case text

    var id: String {
        switch self {
        case .recent: return "recent"
        case .searches: return "searches"
        case .section(let section): return "section.\(section.id)"
        case .commands: return "commands"
        case .files: return "files"
        case .text: return "text"
        }
    }

    var title: String {
        switch self {
        case .recent: return t("Recently Used", "最近使用")
        case .searches: return t("Recent Searches", "最近搜索")
        case .section(let section): return section.title
        case .commands: return t("Commands", "命令")
        case .files: return t("Files", "文件")
        case .text: return t("Text", "正文")
        }
    }
}

// MARK: - 行

/// 一行。小标题不可选，其余都可执行——方向键只在可执行的行上走。
enum PaletteRow: Identifiable {
    case header(PaletteGroup)
    case command(CommandSearch.Result)
    case file(PaletteFileHit)
    case text(WorkspaceHit)
    /// 一条搜过的词：选中它只是把词填回输入框。
    case search(String)
    /// 正文结果太多的出口：把这个词带进 ⌘⇧F 的完整面板。
    case seeAll

    var id: String {
        switch self {
        case .header(let group): return "header.\(group.id)"
        case .command(let result): return result.id
        case .file(let hit): return "file.\(hit.id)"
        case .text(let hit): return "text.\(hit.id)"
        case .search(let term): return "search.\(term)"
        case .seeAll: return "seeAll"
        }
    }

    /// 方向键能不能停在它上面。
    var isSelectable: Bool {
        if case .header = self { return false }
        return true
    }
}

// MARK: - 拼结果

/// 把命令、文件、正文拼成一张表。
///
/// 顺序是固定的：命令 → 文件 → 正文，最后是出口。空查询时不拼文件与正文
/// ——按一下 ⌘K 就把整个文件夹读一遍，是最没必要的 I/O。
enum PaletteRows {
    /// 每段最多先摆这么多：面板是「挑一条」，不是「翻一页」。
    static let fileLimit = 6
    static let textLimit = 5
    static let commandLimit = 20
    /// 空查询时「最近使用」与「最近搜索」的条数。
    static let recentLimit = 4
    static let searchLimit = 4

    struct Input {
        var query: PaletteQuery
        /// 已按相关度排好的命令。
        var commands: [CommandSearch.Result]
        var files: [PaletteFileHit]
        /// 正文命中，最多 `textLimit` 条。
        var textHits: [WorkspaceHit]
        /// 正文一共多少处——比 `textHits` 多就说明还有没摆下的。
        var textTotal: Int
        var recentCommands: [AppCommand] = []
        var recentSearches: [String] = []
    }

    static func build(_ input: Input) -> [PaletteRow] {
        input.query.isEmpty ? browsing(input) : searching(input)
    }

    /// 空查询：可浏览。最近使用 → 命令分组 → 最近搜索。
    private static func browsing(_ input: Input) -> [PaletteRow] {
        var rows: [PaletteRow] = []

        let recent = input.recentCommands.prefix(recentLimit)
        if !recent.isEmpty {
            rows.append(.header(.recent))
            rows += recent.map {
                .command(CommandSearch.Result(command: $0, score: 0, titleHits: []))
            }
        }

        var current: CommandSection?
        for result in input.commands {
            if result.command.section != current {
                rows.append(.header(.section(result.command.section)))
                current = result.command.section
            }
            rows.append(.command(result))
        }

        let searches = input.recentSearches.prefix(searchLimit)
        if !searches.isEmpty {
            rows.append(.header(.searches))
            rows += searches.map { PaletteRow.search($0) }
        }
        return rows
    }

    /// 有查询：按段拼。选了某一段就只出那一段，也不加小标题。
    private static func searching(_ input: Input) -> [PaletteRow] {
        var rows: [PaletteRow] = []
        let scope = input.query.scope
        let needle = input.query.trimmedNeedle

        if scope == .all || scope == .commands {
            let results = Array(input.commands.prefix(commandLimit))
            if !results.isEmpty {
                if scope == .all { rows.append(.header(.commands)) }
                rows += results.map { PaletteRow.command($0) }
            }
        }

        if scope == .all || scope == .files {
            let files = PaletteFileSearch.filter(needle, in: input.files, limit: fileLimit)
            if !files.isEmpty {
                if scope == .all { rows.append(.header(.files)) }
                rows += files.map { PaletteRow.file($0) }
            }
        }

        if scope == .all || scope == .text {
            let hits = Array(input.textHits.prefix(textLimit))
            if !hits.isEmpty {
                if scope == .all { rows.append(.header(.text)) }
                rows += hits.map { PaletteRow.text($0) }
            }
            if input.textTotal > hits.count && !hits.isEmpty {
                rows.append(.seeAll)
            }
        }

        return rows
    }
}

// MARK: - 用过的

/// 面板自己的记忆：最近搜过什么、哪几条命令用得多。
///
/// 存 `UserDefaults` 而不是内存：这两件事的价值全在「下次打开」。
@MainActor
final class PaletteHistory: ObservableObject {
    @Published private(set) var searches: [String]
    @Published private(set) var recentCommandIDs: [String]

    private let defaults: UserDefaults
    private static let searchesKey = "wtmd.palette.searches"
    private static let commandsKey = "wtmd.palette.recentCommands"
    private static let limit = 8

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searches = defaults.stringArray(forKey: Self.searchesKey) ?? []
        recentCommandIDs = defaults.stringArray(forKey: Self.commandsKey) ?? []
    }

    /// 一条查询被执行过（打开文件、打开命中、跑命令）才记。
    /// 只输入不回车的不算——那是过程，不是结果。
    func rememberSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return }
        searches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        searches.insert(trimmed, at: 0)
        if searches.count > Self.limit { searches.removeLast(searches.count - Self.limit) }
        defaults.set(searches, forKey: Self.searchesKey)
    }

    func rememberCommand(_ id: String) {
        recentCommandIDs.removeAll { $0 == id }
        recentCommandIDs.insert(id, at: 0)
        if recentCommandIDs.count > Self.limit {
            recentCommandIDs.removeLast(recentCommandIDs.count - Self.limit)
        }
        defaults.set(recentCommandIDs, forKey: Self.commandsKey)
    }

    /// 最近用过的命令，按「用得最近」排，已经不在目录里的直接跳过
    /// （主题删了、命令改名了，旧 id 不该占着位置）。
    func recentCommands(from commands: [AppCommand]) -> [AppCommand] {
        recentCommandIDs.compactMap { id in commands.first { $0.id == id } }
    }

    func clearSearches() {
        searches = []
        defaults.removeObject(forKey: Self.searchesKey)
    }
}
