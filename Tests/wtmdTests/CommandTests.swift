import AppKit
import Foundation
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 模糊匹配

/// 空查询按定义顺序列出全部——面板应该可以「浏览」，不必先背出命令名。
@Test func emptyQueryListsEverythingInDefinitionOrder() {
    let commands = [command("甲"), command("乙"), command("丙")]
    let results = CommandSearch.filter("   ", in: commands)
    #expect(results.map(\.command.title) == ["甲", "乙", "丙"])
}

/// 连续命中要压过散落命中：「pdf」先想到「打印 / 存为 PDF…」，
/// 而不是某个长标题里字母恰好按顺序出现。
@Test func contiguousHitsOutrankScatteredOnes() {
    let contiguous = CommandSearch.bestMatch(Array("pdf"), in: "打印 / 存为 PDF…")
    let scattered = CommandSearch.bestMatch(Array("pdf"), in: "please draft figures")
    #expect(contiguous != nil)
    #expect(scattered != nil)
    #expect((contiguous?.score ?? 0) > (scattered?.score ?? 0))
}

/// 部分连续（中间断一下）也要压过全分散——连续片段本身的长度是独立的
/// 相关度信号。这一条和上一条的区别：上一条的 needle 是整段子串，
/// 完整子串加权也在起作用；这里两边都不是子串，只有连续片段长度不同。
@Test func partialContiguityOutranksScattered() {
    let partial = CommandSearch.bestMatch(Array("abc"), in: "abXc")
    let scattered = CommandSearch.bestMatch(Array("abc"), in: "aXbXc")
    #expect((partial?.score ?? 0) > (scattered?.score ?? 0))
}

/// 标题开头的命中优于中段命中。
@Test func titleStartOutranksMiddle() {
    let start = CommandSearch.bestMatch(Array("save"), in: "save as")
    let middle = CommandSearch.bestMatch(Array("save"), in: "quick save")
    #expect((start?.score ?? 0) > (middle?.score ?? 0))
}

@Test func matchingIsCaseInsensitive() {
    #expect(CommandSearch.bestMatch(Array("save"), in: "Save As") != nil)
    #expect(CommandSearch.bestMatch(Array("SAVE"), in: "save as") != nil)
}

/// 中文标题靠英文别名也能搜到，但关键词命中不产生高亮位置
/// （标题里没有可标的字符）。
@Test func keywordFallbackFindsChineseTitles() {
    let typewriter = command("打字机模式", keywords: ["typewriter"])
    let results = CommandSearch.filter("typewriter", in: [typewriter])
    #expect(results.count == 1)
    #expect(results.first?.titleHits.isEmpty == true)
}

/// 标题命中永远排在「只靠关键词命中」之前。
@Test func titleHitsOutrankKeywordOnlyHits() {
    let byKeyword = command("导出", keywords: ["export"])
    let byTitle = command("export", keywords: [])
    let results = CommandSearch.filter("export", in: [byKeyword, byTitle])
    #expect(results.map(\.command.title) == ["export", "导出"])
}

/// 命中下标要指向标题里真正被匹配的字符，面板据此加粗。
@Test func hitsPointAtMatchedCharacters() {
    let match = CommandSearch.bestMatch(Array("ff"), in: "Office File")
    #expect(match?.hits == [1, 2])
}

@Test func nonSubsequenceDoesNotMatch() {
    #expect(CommandSearch.bestMatch(Array("xyz"), in: "新建文档") == nil)
}

/// 同分时保持定义顺序：`sort` 不稳定，靠原始下标兜底。
@Test func tiesKeepDefinitionOrder() {
    let first = command("甲乙", keywords: ["xx"])
    let second = command("丙丁", keywords: ["xx"])
    let results = CommandSearch.filter("xx", in: [first, second])
    #expect(results.map(\.command.title) == ["甲乙", "丙丁"])
}

// MARK: - 结果行

/// 空查询插入分组小标题，结果按分组聚拢。
@Test func emptyQueryInsertsSectionHeaders() {
    let commands = [
        command("甲", section: .file),
        command("乙", section: .file),
        command("丙", section: .view),
    ]
    let rows = CommandSearch.rows(for: "", results: CommandSearch.filter("", in: commands))
    #expect(shape(rows) == ["H:file", "C:甲", "C:乙", "H:view", "C:丙"])
}

/// 有查询时保持平铺：小标题会打断按相关度排好的顺序。
@Test func typedQueryStaysFlat() {
    let commands = [command("save", section: .file), command("scope", section: .writing)]
    let rows = CommandSearch.rows(for: "s", results: CommandSearch.filter("s", in: commands))
    #expect(shape(rows).allSatisfy { $0.hasPrefix("C:") })
    #expect(shape(rows).count == 2)
}

// MARK: - 命令清单

/// id 是面板与菜单共用的主键，撞了会让选中态错位。
@Test func commandIdentifiersAreUnique() {
    let commands = CommandCatalog.commands(
        themes: Theme.builtIns,
        recentFiles: [URL(fileURLWithPath: "/tmp/甲.md"), URL(fileURLWithPath: "/tmp/乙.md")]
    )
    let ids = commands.map(\.id)
    #expect(Set(ids).count == ids.count)
}

/// 菜单与面板共用这份定义，所以这些是用户肌肉记忆最深的条目，
/// 改动必须是有意的。
@Test func keyCommandsKeepTheirTitlesAndShortcuts() {
    #expect(CommandCatalog.command(for: .newDocument)?.title == "新建文档")
    #expect(shortcutLabel(.newDocument) == "⌘N")
    #expect(shortcutLabel(.openDocument) == "⌘O")
    #expect(shortcutLabel(.openFolder) == "⇧⌘O")
    #expect(shortcutLabel(.save) == "⌘S")
    #expect(shortcutLabel(.exportHTML) == "⇧⌘E")
    #expect(shortcutLabel(.exportPDF) == "⌘P")
    #expect(shortcutLabel(.toggleMode) == "⌘/")
    #expect(shortcutLabel(.toggleTypewriter) == "⌥⌘T")
    #expect(shortcutLabel(.toggleFocus) == "⌥⌘F")
    #expect(shortcutLabel(.find) == "⌘F")
    // ⌥⌘F 已经归专注模式，替换只能另找一格：R 记 Replace
    #expect(shortcutLabel(.findReplace) == "⌥⌘R")
}

/// 查找与替换在同一个分组里：读者找东西时会想「顺便换掉」，
/// 分成两处反而要多想一次。
@Test func findCommandsLiveInTheEditSection() {
    #expect(CommandCatalog.command(for: .find)?.section == .edit)
    #expect(CommandCatalog.command(for: .findReplace)?.section == .edit)
}

/// 快捷键撞车是静默的：菜单里一条永远打不开，而且没人会发现。
@Test func noTwoCommandsShareAShortcut() {
    let commands = CommandCatalog.commands(themes: Theme.builtIns, recentFiles: [])
    let labels = commands.compactMap { $0.shortcut.map(ShortcutFormatter.label) }
    #expect(Set(labels).count == labels.count, "快捷键重复：\(labels)")
}

/// 图标打错字只会静默变成空白，所以逐个验存在性。
@Test func everyCommandSymbolExists() {
    let commands = CommandCatalog.commands(themes: Theme.builtIns, recentFiles: [])
    for command in commands {
        #expect(
            NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) != nil,
            "缺少图标：\(command.symbol)"
        )
    }
}

/// 每条命令都要能被搜到——没有标题的条目在面板里等于不存在。
@Test func everyCommandHasATitle() {
    let commands = CommandCatalog.commands(themes: Theme.builtIns, recentFiles: [])
    #expect(!commands.isEmpty)
    #expect(commands.allSatisfy { !$0.title.isEmpty })
}

// MARK: - 键盘

@Test func keyCodesMapToPaletteActions() {
    #expect(PaletteKeyboard.action(forKeyCode: PaletteKey.upArrow) == .move(-1))
    #expect(PaletteKeyboard.action(forKeyCode: PaletteKey.downArrow) == .move(1))
    #expect(PaletteKeyboard.action(forKeyCode: PaletteKey.return) == .execute)
    #expect(PaletteKeyboard.action(forKeyCode: PaletteKey.keypadEnter) == .execute)
    #expect(PaletteKeyboard.action(forKeyCode: PaletteKey.escape) == .dismiss)
}

/// 不关心的键要放行，否则在搜索框里打字全被吃掉。
@Test func unknownKeysPassThrough() {
    #expect(PaletteKeyboard.action(forKeyCode: 0) == nil)
    #expect(PaletteKeyboard.action(forKeyCode: 49) == nil)
}

@Test func selectionWrapsAtBothEnds() {
    #expect(PaletteKeyboard.advance(0, by: -1, count: 3) == 2)
    #expect(PaletteKeyboard.advance(2, by: 1, count: 3) == 0)
    #expect(PaletteKeyboard.advance(1, by: 1, count: 3) == 2)
}

@Test func selectionOnAnEmptyListStaysAtZero() {
    #expect(PaletteKeyboard.advance(5, by: 1, count: 0) == 0)
    #expect(PaletteKeyboard.advance(5, by: -1, count: 0) == 0)
}

// MARK: - 执行与状态

/// 开关类命令报状态，普通动作报 nil——菜单据此决定用 Toggle 还是 Button。
@MainActor
@Test func switchCommandsReportTheirState() throws {
    let harness = try CommandHarness()
    defer { harness.cleanup() }
    let runtime = harness.runtime

    let typewriter = try #require(CommandCatalog.command(for: .toggleTypewriter))
    #expect(runtime.isOn(typewriter) == false)
    runtime.run(typewriter)
    #expect(runtime.isOn(typewriter) == true)
    #expect(harness.writing.typewriter)

    let sidebar = try #require(CommandCatalog.command(for: .toggleSidebar))
    #expect(runtime.isOn(sidebar) == true)
    runtime.run(sidebar)
    #expect(runtime.isOn(sidebar) == false)

    let newDocument = try #require(CommandCatalog.command(for: .newDocument))
    #expect(runtime.isOn(newDocument) == nil)
}

/// 切主题：命令里执行一次，当前主题就换过去，勾选态跟上。
@MainActor
@Test func runningAThemeCommandSwitchesTheTheme() throws {
    let harness = try CommandHarness()
    defer { harness.cleanup() }
    let themeManager = harness.store.themeManager
    let original = UserDefaults.standard.string(forKey: "wtmd.themeID")
    defer {
        if let original {
            UserDefaults.standard.set(original, forKey: "wtmd.themeID")
        } else {
            UserDefaults.standard.removeObject(forKey: "wtmd.themeID")
        }
    }

    let target = try #require(themeManager.themes.first { $0.id != themeManager.currentThemeID })
    let runtime = harness.runtime
    let command = try #require(
        CommandCatalog.command(for: .selectTheme(target.id), themes: themeManager.themes)
    )

    #expect(runtime.isOn(command) == false)
    runtime.run(command)
    #expect(themeManager.currentThemeID == target.id)
    #expect(runtime.isOn(command) == true)
}

/// 与工具栏一致：欢迎页没有可存的东西；未命名文档要能「保存」（走另存为）；
/// 只有干净的已命名文档才灰掉。
@MainActor
@Test func saveIsEnabledOnlyWhenThereIsSomethingToSave() throws {
    try preservingRecentFiles {
        let harness = try CommandHarness()
        defer { harness.cleanup() }
        let save = try #require(CommandCatalog.command(for: .save))

        harness.store.textDidChange("")               // 走到欢迎页
        #expect(harness.store.showsWelcome)
        #expect(!harness.runtime.isEnabled(save))

        harness.store.newDocument()
        #expect(harness.runtime.isEnabled(save))      // 未命名文档要能另存为

        let file = try write("草稿.md", in: harness.directory, content: "# 初稿")
        harness.store.open(url: file)
        #expect(!harness.runtime.isEnabled(save))     // 刚打开、不脏

        harness.store.textDidChange("# 初稿\n改了一行")
        #expect(harness.runtime.isEnabled(save))      // 脏了
    }
}

/// 没有工作区时「关闭工作区」不该可点。
@MainActor
@Test func closingAWorkspaceIsDisabledWithoutOne() throws {
    let harness = try CommandHarness()
    defer { harness.cleanup() }
    let command = try #require(CommandCatalog.command(for: .closeWorkspace))

    #expect(!harness.runtime.isEnabled(command))

    harness.workspace.open(harness.directory)
    #expect(harness.runtime.isEnabled(command))

    harness.runtime.run(command)
    #expect(!harness.workspace.isOpen)
}

/// 顺带守住 #19：从欢迎页执行「新建文档」之后，不能再滑回欢迎页。
@MainActor
@Test func runningNewDocumentLeavesTheWelcomeScreen() throws {
    let harness = try CommandHarness()
    defer { harness.cleanup() }
    harness.store.textDidChange("")               // 走到欢迎页
    #expect(harness.store.showsWelcome)

    let command = try #require(CommandCatalog.command(for: .newDocument))
    harness.runtime.run(command)

    #expect(!harness.store.showsWelcome)
}

/// 最近文件命令要真的打开那个文件；文件被移走后应灰掉而不是点了没反应。
@MainActor
@Test func recentFileCommandsOpenThatFile() throws {
    try preservingRecentFiles {
        let harness = try CommandHarness()
        defer { harness.cleanup() }
        let file = try write("想法.md", in: harness.directory, content: "# 想法\n")
        let command = try #require(CommandCatalog.recentCommands(for: [file]).first)
        let runtime = harness.runtime

        #expect(runtime.isEnabled(command))
        runtime.run(command)
        #expect(harness.store.fileURL == file)
        #expect(harness.store.text == "# 想法\n")

        let missing = harness.directory.appendingPathComponent("没了.md")
        let moved = try #require(CommandCatalog.recentCommands(for: [missing]).first)
        #expect(!runtime.isEnabled(moved))
    }
}

// MARK: - 辅助

/// 造一条只用于搜索测试的命令。用标题当主题 id，这样每条命令的 id 唯一。
private func command(
    _ title: String,
    keywords: [String] = [],
    section: CommandSection = .file
) -> AppCommand {
    AppCommand(
        kind: .selectTheme(title),
        title: title,
        section: section,
        symbol: "circle",
        shortcut: nil,
        keywords: keywords,
        subtitle: nil
    )
}

private func shortcutLabel(_ kind: CommandKind) -> String? {
    CommandCatalog.command(for: kind)?.shortcut.map(ShortcutFormatter.label)
}

/// 把结果行压成可断言的形状：`H:file` 是分组标题，`C:标题` 是命令行。
private func shape(_ rows: [PaletteRow]) -> [String] {
    rows.map { row in
        switch row {
        case .header(let section): return "H:\(section.rawValue)"
        case .command(let result): return "C:\(result.command.title)"
        }
    }
}

/// 一个不碰用户真实数据的命令运行时。
@MainActor
private final class CommandHarness {
    let directory: URL
    let store: DocumentStore
    let workspace: WorkspaceStore
    let writing: WritingSettings

    private let suiteName = "wtmd.tests.commands"
    private let defaults: UserDefaults

    init() throws {
        directory = try makeTempDirectory()
        defaults = try #require(UserDefaults(suiteName: suiteName))
        store = DocumentStore(draftDirectory: directory, autoSaveDelay: 60_000_000_000)
        workspace = WorkspaceStore()
        writing = WritingSettings(defaults: defaults)
    }

    var runtime: CommandRuntime {
        CommandRuntime(
            store: store,
            workspace: workspace,
            writing: writing,
            updates: UpdateChecker(
                configuration: UpdateChecker.Configuration(
                    currentVersion: "0.0.0",
                    endpoint: URL(string: "https://example.invalid/latest")!,
                    interval: 0,
                    retryInterval: 0
                ),
                defaults: defaults,
                fetch: { throw URLError(.notConnectedToInternet) }
            )
        )
    }

    func cleanup() {
        workspace.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-commands-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ name: String, in directory: URL, content: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// 命令注册表是菜单与面板的单一来源：导出 Word 必须注册在文件分组，
/// 否则只有菜单有、面板搜不到（或反过来）。
@Test func wordExportCommandIsRegisteredInTheFileSection() throws {
    let command = try #require(CommandCatalog.command(for: .exportWord))

    #expect(command.section == .file)
    #expect(command.kind.id == "file.exportWord")
    #expect(CommandSearch.filter("docx", in: [command]).count == 1)
}

/// `open(url:)` 会写 UserDefaults 里的最近文件列表——测试不该留下痕迹。
private func preservingRecentFiles<T>(_ body: () throws -> T) rethrows -> T {
    let key = "wtmd.recentFiles"
    let original = UserDefaults.standard.object(forKey: key)
    defer {
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    return try body()
}
