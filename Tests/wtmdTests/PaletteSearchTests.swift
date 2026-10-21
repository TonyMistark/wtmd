import Foundation
import Testing
@testable import wtmd

// MARK: - 前缀

/// 前缀是语法，不是设置。解析错一个字符，整个面板就会「只搜命令」而读者
/// 以为自己打错了词。
@Suite("搜索前缀")
struct PaletteQueryTests {
    @Test("不写前缀：全都搜")
    func noPrefixSearchesEverything() {
        let parsed = PaletteQuery.parse("排版")
        #expect(parsed.scope == .all)
        #expect(parsed.needle == "排版")
        #expect(parsed.trimmedNeedle == "排版")
    }

    @Test("三个前缀各归各段，前缀本身不进搜索词")
    func prefixesPickTheirScope() {
        #expect(PaletteQuery.parse(">导出") == PaletteQuery(scope: .commands, needle: "导出"))
        #expect(PaletteQuery.parse("@第三章") == PaletteQuery(scope: .files, needle: "第三章"))
        #expect(PaletteQuery.parse("#版心") == PaletteQuery(scope: .text, needle: "版心"))
    }

    @Test("前缀只在第一个字符上生效：正文里的 # 还是 #")
    func onlyTheFirstCharacterCounts() {
        let parsed = PaletteQuery.parse("第一章 # 开头")
        #expect(parsed.scope == .all)
        #expect(parsed.needle == "第一章 # 开头")
    }

    @Test("前面有空格也认得出前缀")
    func leadingSpacesDoNotHideThePrefix() {
        #expect(PaletteQuery.parse("   @稿子").scope == .files)
        #expect(PaletteQuery.parse("   @稿子").needle == "稿子")
    }

    @Test("只有前缀、没有词：这一段里什么都能浏览")
    func barePrefixIsEmptyButScoped() {
        let parsed = PaletteQuery.parse("@")
        #expect(parsed.scope == .files)
        #expect(parsed.isEmpty)
    }

    @Test("空白查询是空的，但不是「有词」")
    func whitespaceOnlyIsEmpty() {
        #expect(PaletteQuery.parse("   ").isEmpty)
        #expect(!PaletteQuery.parse("  a ").isEmpty)
    }
}

// MARK: - 文件

@Suite("面板里的文件搜索")
struct PaletteFileSearchTests {
    private func file(_ path: String) -> PaletteFileHit {
        PaletteFileHit(
            url: URL(fileURLWithPath: "/tmp/\(path)"),
            name: (path as NSString).lastPathComponent,
            relativePath: path
        )
    }

    @Test("文件名命中排在「只在路径里命中」前面")
    func nameHitsBeatPathHits() {
        let files = [
            file("书稿/第一章.md"),
            file("草稿/书稿清单.md"),
        ]
        let hits = PaletteFileSearch.filter("书稿", in: files, limit: 10)
        #expect(hits.first?.name == "书稿清单.md")
    }

    @Test("几个字母就能找到：子序列匹配")
    func subsequenceFindsTheFile() {
        let files = [file("书稿/chapter-3.md"), file("notes/todo.md")]
        #expect(PaletteFileSearch.filter("c3", in: files, limit: 10).first?.name == "chapter-3.md")
        #expect(PaletteFileSearch.filter("td", in: files, limit: 10).first?.name == "todo.md")
    }

    @Test("空词按顺序取前几个，不返回全部")
    func emptyNeedleTakesTheFirstFew() {
        let files = (1...10).map { file("第\($0)章.md") }
        #expect(PaletteFileSearch.filter("", in: files, limit: 3).count == 3)
    }

    @Test("一个都不匹配就是空：不该拿「差不多」凑数")
    func noMatchMeansNothing() {
        #expect(PaletteFileSearch.filter("zzz", in: [file("第一章.md")], limit: 5).isEmpty)
    }

    @Test("摊平工作区树：目录不进结果，相对路径已经算好")
    func flattenSkipsDirectories() {
        let root = URL(fileURLWithPath: "/tmp/书稿")
        let tree = WorkspaceNode(
            url: root,
            isDirectory: true,
            children: [
                WorkspaceNode(
                    url: root.appendingPathComponent("卷上"),
                    isDirectory: true,
                    children: [
                        WorkspaceNode(url: root.appendingPathComponent("卷上/第一章.md"), isDirectory: false)
                    ]
                ),
                WorkspaceNode(url: root.appendingPathComponent("总纲.md"), isDirectory: false),
            ]
        )
        let files = PaletteFileSearch.flatten(tree, root: root)
        #expect(files.map(\.relativePath) == ["卷上/第一章.md", "总纲.md"])
        #expect(files.allSatisfy { !$0.name.isEmpty })
    }
}

// MARK: - 拼表

@Suite("命令、文件、正文摆在一张表上")
struct PaletteRowsTests {
    private let command = AppCommand(
        kind: .save, title: "保存", section: .file, symbol: "square.and.arrow.down",
        shortcut: nil, keywords: [], subtitle: nil
    )

    private func results(_ commands: [AppCommand], query: String = "") -> [CommandSearch.Result] {
        CommandSearch.filter(query, in: commands)
    }

    private func file(_ name: String) -> PaletteFileHit {
        PaletteFileHit(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, relativePath: name)
    }

    private func hit(_ line: String, file: String = "第一章.md") -> WorkspaceHit {
        WorkspaceHit(
            fileURL: URL(fileURLWithPath: "/tmp/\(file)"),
            line: 0, column: 0, length: 1,
            lineText: line, highlightStart: 0, highlightLength: 1
        )
    }

    private func rows(
        _ query: String,
        files: [PaletteFileHit] = [],
        text: [WorkspaceHit] = [],
        total: Int = 0
    ) -> [PaletteRow] {
        PaletteRows.build(.init(
            query: PaletteQuery.parse(query),
            commands: results([command], query: PaletteQuery.parse(query).trimmedNeedle),
            files: files,
            textHits: text,
            textTotal: total
        ))
    }

    @Test("空查询只摆命令：还没打字，不该先去读一遍整个文件夹")
    func emptyQueryOnlyBrowsesCommands() {
        let rows = rows("", files: [file("第一章.md")], text: [hit("正文")], total: 3)
        #expect(!rows.contains { if case .file = $0 { return true } else { return false } })
        #expect(!rows.contains { if case .text = $0 { return true } else { return false } })
    }

    @Test("有词时三段按命令、文件、正文的顺序摆")
    func sectionsComeInAFixedOrder() {
        let chapterCommand = AppCommand(
            kind: .save, title: "章节对比", section: .file, symbol: "square.and.arrow.down",
            shortcut: nil, keywords: [], subtitle: nil
        )
        let rows = PaletteRows.build(.init(
            query: PaletteQuery.parse("章"),
            commands: CommandSearch.filter("章", in: [chapterCommand]),
            files: [file("第一章.md")],
            textHits: [hit("这一章讲版心")],
            textTotal: 1
        ))
        let headers = rows.compactMap { row -> String? in
            if case .header(let group) = row { return group.id }
            return nil
        }
        #expect(headers == ["commands", "files", "text"])
    }

    @Test("没有命中的段不摆：空小标题只是噪音")
    func emptySectionsAreSkipped() {
        let rows = rows("章", files: [file("第一章.md")], text: [hit("这一章")], total: 1)
        let headers = rows.compactMap { row -> String? in
            if case .header(let group) = row { return group.id }
            return nil
        }
        #expect(headers == ["files", "text"])
    }

    @Test("选中某一段就只出那一段，也不加小标题")
    func scopedQueryDropsTheOtherSections() {
        let rows = rows("@章", files: [file("第一章.md")], text: [hit("这一章")], total: 1)
        #expect(rows.count == 1)
        guard case .file = rows[0] else {
            Issue.record("只搜文件时不该出现别的行")
            return
        }
    }

    @Test("正文还有没摆下的：末尾给一个出口")
    func tooManyMatchesOfferAWayOut() {
        let hits = (1...5).map { hit("第 \($0) 行") }
        let rows = rows("#章", text: hits, total: 9)
        #expect(rows.last?.id == "seeAll")
    }

    @Test("正文全都摆下了就不给出口")
    func everythingShownNeedsNoOutlet() {
        let rows = rows("#章", text: [hit("只有一处")], total: 1)
        #expect(rows.last?.id != "seeAll")
    }

    @Test("最近用过的命令排在最前面，且不重复出现在下面")
    func recentCommandsComeFirstOnce() {
        var input = PaletteRows.Input(
            query: PaletteQuery.parse(""),
            commands: results([command]),
            files: [], textHits: [], textTotal: 0
        )
        input.recentCommands = [command]
        let rows = PaletteRows.build(input)
        #expect(rows.first?.id == "header.recent")
        #expect(rows.filter { $0.id == command.id }.count == 2)  // 最近一条 + 分组里一条
    }

    @Test("最近搜过的词垫底：回车选它只是把词填回去")
    func recentSearchesSitAtTheBottom() {
        var input = PaletteRows.Input(
            query: PaletteQuery.parse(""),
            commands: results([command]),
            files: [], textHits: [], textTotal: 0
        )
        input.recentSearches = ["版心", "排版"]
        let rows = PaletteRows.build(input)
        #expect(rows.suffix(3).map(\.id) == ["header.searches", "search.版心", "search.排版"])
    }

    @Test("小标题不可选：方向键只在能执行的行上走")
    func headersAreNotSelectable() {
        let rows = rows("章", files: [file("第一章.md")])
        #expect(rows.filter(\.isSelectable).count == rows.count - 1)
        #expect(rows.first?.isSelectable == false)
    }
}

// MARK: - 记忆

@Suite("面板自己的记忆")
@MainActor
struct PaletteHistoryTests {
    private func makeHistory() throws -> (PaletteHistory, UserDefaults, String) {
        let name = "wtmd.tests.palette.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (PaletteHistory(defaults: defaults), defaults, name)
    }

    @Test("搜过的词记在最前，重复的挪上来而不是攒两份")
    func searchesMoveToTheFront() throws {
        let (history, defaults, name) = try makeHistory()
        defer { defaults.removePersistentDomain(forName: name) }

        history.rememberSearch("版心")
        history.rememberSearch("排版")
        history.rememberSearch("版心")

        #expect(history.searches == ["版心", "排版"])
    }

    @Test("一个字的查询不记：那多半是打字的过程")
    func singleCharacterQueriesAreNotRemembered() throws {
        let (history, defaults, name) = try makeHistory()
        defer { defaults.removePersistentDomain(forName: name) }

        history.rememberSearch("排")
        #expect(history.searches.isEmpty)
    }

    @Test("最多留八条，旧的往后挤掉")
    func searchesAreCapped() throws {
        let (history, defaults, name) = try makeHistory()
        defer { defaults.removePersistentDomain(forName: name) }

        for index in 1...12 { history.rememberSearch("词\(index)") }
        #expect(history.searches.count == 8)
        #expect(history.searches.first == "词12")
    }

    @Test("最近用过的命令跳过已经不在目录里的 id")
    func staleCommandIDsAreSkipped() throws {
        let (history, defaults, name) = try makeHistory()
        defer { defaults.removePersistentDomain(forName: name) }

        let command = AppCommand(
            kind: .save, title: "保存", section: .file, symbol: "square.and.arrow.down",
            shortcut: nil, keywords: [], subtitle: nil
        )
        history.rememberCommand("file.save")
        history.rememberCommand("theme.gone")

        #expect(history.recentCommands(from: [command]).map(\.id) == ["file.save"])
    }

    @Test("记忆写进 defaults：关掉面板、关掉应用都还在")
    func memorySurvivesAFreshInstance() throws {
        let name = "wtmd.tests.palette.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        PaletteHistory(defaults: defaults).rememberSearch("版心")
        #expect(PaletteHistory(defaults: defaults).searches == ["版心"])
    }
}

// MARK: - 正文那一段

/// 面板里的正文搜索与 ⌘⇧F 同一台引擎，但只取前几条：它的任务不是「翻完」，
/// 是「够不够摆第三段」。
@Suite("面板里的正文搜索")
@MainActor
struct PaletteTextSearchTests {
    private func workspace(with texts: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in texts {
            try text.write(
                to: root.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }
        return root
    }

    private func waitForHits(_ search: PaletteTextSearch) async {
        for _ in 0..<150 where search.hits.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("命中会落到 hits 上，并且带上行号")
    func findsMatches() async throws {
        let root = try workspace(with: ["第一章.md": "第一行\n版心宽度决定一行多少字。\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let search = PaletteTextSearch()
        search.delay = 0
        search.search(root: root, query: "版心")
        await waitForHits(search)

        #expect(search.hits.count == 1)
        #expect(search.hits.first?.line == 1)
        #expect(search.hits.first?.lineText.contains("版心") == true)
    }

    @Test("一个字不搜：那个词还没成形，扫盘只是白读")
    func singleCharacterDoesNotSweep() async throws {
        let root = try workspace(with: ["第一章.md": "版心"])
        defer { try? FileManager.default.removeItem(at: root) }

        let search = PaletteTextSearch()
        search.delay = 0
        search.search(root: root, query: "版")
        try? await Task.sleep(nanoseconds: 120_000_000)

        #expect(search.hits.isEmpty)
        #expect(!search.isSearching)
    }

    @Test("没有工作区就是空，不是错")
    func noWorkspaceMeansNoHits() async {
        let search = PaletteTextSearch()
        search.delay = 0
        search.search(root: nil, query: "版心")
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(search.hits.isEmpty)
    }

    @Test("换一个词：旧结果不会盖住新结果")
    func staleResultsAreDropped() async throws {
        let root = try workspace(with: [
            "第一章.md": "版心宽度决定一行多少字。",
            "第二章.md": "排版是另一件事。",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let search = PaletteTextSearch()
        search.delay = 0
        search.search(root: root, query: "版心")
        search.search(root: root, query: "排版")
        await waitForHits(search)
        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(search.hits.allSatisfy { $0.lineText.contains("排版") })
    }
}
