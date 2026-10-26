import AppKit
import Foundation
import Testing
@testable import wtmd


/// 每套主题写到自己的临时目录，互不干扰，也不会碰到真实的 Themes 目录。
private func makeTempThemeDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-theme-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - 草稿与导出

private func makeAppearance(_ overrides: [String: String] = [:]) -> ThemeDraft.Appearance {
    var colors: [String: String] = [:]
    for key in ThemePalette.all { colors[key] = "#123456" }
    colors["bg"] = "#ffffff"
    colors["fg"] = "#111111"
    colors.merge(overrides) { _, new in new }
    return ThemeDraft.Appearance(
        colors: colors,
        fonts: ThemeDraft.Fonts(body: "PingFang SC", heading: "Songti SC", mono: "Menlo")
    )
}

private func makeDraft(
    name: String = "My Theme",
    editingID: String? = nil,
    overrides: [String: String] = [:]
) -> ThemeDraft {
    ThemeDraft(
        name: name,
        author: "ice",
        editingID: editingID,
        light: makeAppearance(overrides),
        dark: makeAppearance(overrides)
    )
}

@Test func draftStartsFromTheChosenTheme() {
    let draft = ThemeDraft(basedOn: Theme.builtIns[0])
    for key in ThemePalette.all {
        #expect(draft.light.colors[key] != nil, "missing light \(key)")
        #expect(draft.dark.colors[key] != nil, "missing dark \(key)")
    }
    // 默认主题的明暗两侧本来就不同，草稿不该把它们抹平。
    #expect(draft.light.colors["bg"] != draft.dark.colors["bg"])
    #expect(!draft.dark.fonts.body.isEmpty)
}

@Test func draftFillsBothSidesFromASingleSidedTheme() throws {
    // base16 主题只带一侧：另一侧没有变量，草稿仍要两侧都完整。
    let terminal = try #require(Theme.builtIns.first { $0.id == "builtin.terminal" })
    let draft = ThemeDraft(basedOn: terminal, editing: true)
    #expect(draft.light.colors["bg"] == "#0d1117")
    #expect(draft.dark.colors["bg"] == "#0d1117")
    // 编辑内置主题算「新建」——内置目录不该被覆盖。
    #expect(draft.editingID == nil)
}

@Test func editingACustomThemeKeepsItsIdentity() {
    let theme = Theme(
        id: "custom.sand.wttheme", name: "Sand", author: "me", isBuiltIn: false,
        light: "--bg: #faf7f0;\n--fg: #2b2620;", dark: "--bg: #211c16;\n--fg: #e8ddc8;"
    )
    let draft = ThemeDraft(basedOn: theme, editing: true)
    #expect(draft.editingID == "custom.sand.wttheme")
    #expect(draft.name == "Sand")
    #expect(draft.author == "me")
}

@Test func cssExportsEveryVariableInAStableOrder() throws {
    let css = makeDraft().css(for: makeAppearance())
    let lines = css.split(separator: "\n").map(String.init)

    // 10 主色 + 6 高亮 + 2 派生（pre-border / th-bg）+ 3 字体
    #expect(lines.count == 21)
    #expect(lines.first == "--bg: #ffffff;")
    // 派生项紧跟源项，编辑「边框」一处就够了。
    let borderIndex = try #require(lines.firstIndex(of: "--border: #123456;"))
    #expect(lines[borderIndex + 1] == "--pre-border: #123456;")
    let preIndex = try #require(lines.firstIndex(of: "--pre-bg: #123456;"))
    #expect(lines[preIndex + 1] == "--th-bg: #123456;")
    #expect(css.contains("--font-body: \"PingFang SC\", -apple-system"))
    #expect(css.contains("--font-mono: Menlo, -apple-system") || css.contains("--font-mono: Menlo,"))
}

@Test func derivedVariablesFollowTheirSource() {
    var appearance = makeAppearance(["border": "#abcdef", "pre-bg": "#fedcba"])
    let css = makeDraft().css(for: appearance)
    #expect(css.contains("--pre-border: #abcdef;"))
    #expect(css.contains("--th-bg: #fedcba;"))
    // 改源色后派生色跟着走。
    appearance.colors["border"] = "#000000"
    #expect(makeDraft().css(for: appearance).contains("--pre-border: #000000;"))
}

@Test func hexNormalizationAcceptsShorthandAndRejectsJunk() {
    #expect(ThemeDraft.normalizedHex("#ABC") == "#aabbcc")
    #expect(ThemeDraft.normalizedHex("abc") == "#aabbcc")
    #expect(ThemeDraft.normalizedHex("#AABBCC") == "#aabbcc")
    #expect(ThemeDraft.normalizedHex("#aabbccdd") == "#aabbccdd")
    #expect(ThemeDraft.normalizedHex("  #fff  ") == "#ffffff")
    #expect(ThemeDraft.normalizedHex("#ff") == nil)
    #expect(ThemeDraft.normalizedHex("rgb(1,2,3)") == nil)
    #expect(ThemeDraft.normalizedHex("#gggggg") == nil)
    #expect(ThemeDraft.normalizedHex("") == nil)
}

@Test func contrastRatioMatchesTheWCAGReference() throws {
    let blackOnWhite = try #require(ThemeDraft.contrastRatio(foreground: "#000000", background: "#ffffff"))
    #expect(abs(blackOnWhite - 21.0) < 0.01)
    #expect(ThemeDraft.contrastRatio(foreground: "#777777", background: "#777777") == 1.0)
    #expect(ThemeDraft.contrastRatio(foreground: "not-a-color", background: "#fff") == nil)
}

// MARK: - 写盘与往返

@Test func writeThenLoadRoundTrips() throws {
    let dir = try makeTempThemeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let draft = makeDraft(name: "Sand & Sea")
    let folder = try ThemeStore.write(draft, to: dir, overwrite: false)
    #expect(folder.lastPathComponent == "sand-sea.wttheme")

    let theme = try #require(ThemeFormat.loadFolder(folder))
    #expect(theme.name == "Sand & Sea")
    #expect(theme.author == "ice")
    #expect(theme.isBuiltIn == false)

    // 往返之后颜色一个不差——编辑器存出来的东西必须能被加载器读回。
    let light = Theme.parseVariables(theme.light)
    for key in ThemePalette.all {
        #expect(light[key] == draft.light.colors[key], "mismatch on \(key)")
    }
    #expect(theme.hasLight && theme.hasDark)
}

@Test func slugIsUsableForNamesInAnyScript() {
    #expect(ThemeStore.slug(for: "Sand & Sea") == "sand-sea")
    #expect(ThemeStore.slug(for: "  Trail Mix  ") == "trail-mix")
    // 中文名整段折掉后为空 → 退回时间戳（id 只需要唯一，显示名存在 theme.json 里）。
    #expect(ThemeStore.slug(for: "暖砂").hasPrefix("theme-"))
    #expect(ThemeStore.slug(for: "a/b:c*d") == "a-b-c-d")
}

@Test func existingFolderIsReportedInsteadOfSilentlyReplaced() throws {
    let dir = try makeTempThemeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    try ThemeStore.write(makeDraft(name: "Sand"), to: dir, overwrite: false)
    #expect(throws: ThemeSaveError.alreadyExists("Sand")) {
        try ThemeStore.write(makeDraft(name: "Sand"), to: dir, overwrite: false)
    }
    // 覆盖是显式选择：同名再写一次并换掉颜色，读出来就该是新颜色。
    try ThemeStore.write(
        makeDraft(name: "Sand", overrides: ["bg": "#010203"]), to: dir, overwrite: true
    )
    let theme = try #require(ThemeFormat.loadFolder(dir.appendingPathComponent("sand.wttheme")))
    #expect(Theme.parseVariables(theme.light)["bg"] == "#010203")
}

@Test func editingKeepsTheFolderNameWhenTheNameChanges() throws {
    let dir = try makeTempThemeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let folder = try ThemeStore.write(makeDraft(name: "Sand"), to: dir, overwrite: false)
    let id = "custom.\(folder.lastPathComponent)"

    var draft = makeDraft(name: "Sand at Night", editingID: id)
    draft.author = "ice"
    let again = try ThemeStore.write(draft, to: dir, overwrite: true)
    #expect(again == folder, "editing must not fork a new folder")
    #expect(ThemeFormat.loadFolder(again)?.name == "Sand at Night")
}

@Test func copyNameCountsUp() throws {
    let dir = try makeTempThemeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(ThemeStore.copyName("Sand", in: dir) == "Sand 2")
    // 只避开真的占了的名字：写了「Sand 2」之后才轮到「Sand 3」。
    try ThemeStore.write(makeDraft(name: "Sand 2"), to: dir, overwrite: false)
    #expect(ThemeStore.copyName("Sand", in: dir) == "Sand 3")
}

@Test func emptyNameIsRejected() throws {
    let dir = try makeTempThemeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ThemeSaveError.emptyName) {
        try ThemeStore.write(makeDraft(name: "   "), to: dir, overwrite: false)
    }
}

// MARK: - 编辑器状态

@MainActor
@Test func rebaseKeepsTheNameAndSwapsThePalette() throws {
    let dir = try makeTempThemeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let model = ThemeEditorModel(
        draft: ThemeDraft(basedOn: Theme.builtIns[0]),
        baseID: Theme.defaultID,
        directory: dir
    )
    model.draft.name = "Mine"
    let paper = try #require(Theme.builtIns.first { $0.id == "builtin.paperInk" })
    model.baseID = paper.id
    model.rebase(on: paper)

    #expect(model.draft.name == "Mine")
    #expect(model.draft.light.colors["bg"] == "#faf7f0")
}

@MainActor
@Test func copyToTheOtherSideMirrorsTheColors() throws {
    let dir = try makeTempThemeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    var draft = makeDraft()
    draft.light = makeAppearance(["bg": "#ffffff"])
    draft.dark = makeAppearance(["bg": "#000000"])
    let model = ThemeEditorModel(draft: draft, baseID: Theme.defaultID, directory: dir)

    model.side = .light
    model.copyToOtherSide()
    #expect(model.draft.dark.colors["bg"] == "#ffffff")

    model.side = .dark
    model.draft.dark.colors["bg"] = "#123456"
    model.copyToOtherSide()
    #expect(model.draft.light.colors["bg"] == "#123456")
}

@MainActor
@Test func lowContrastIsWarnedButNotBlocked() throws {
    let dir = try makeTempThemeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let model = ThemeEditorModel(
        draft: makeDraft(overrides: ["bg": "#ffffff", "fg": "#fafafa"]),
        baseID: Theme.defaultID,
        directory: dir
    )
    #expect(model.contrastWarning != nil)

    model.draft.light.colors["fg"] = "#111111"
    #expect(model.contrastWarning == nil)
}
