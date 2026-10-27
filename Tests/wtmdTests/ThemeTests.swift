import Foundation
import Testing
@testable import wtmd

// MARK: - cssText 拼接

@Test func cssTextWrapping() {
    let both = StyleSheet.cssText(light: "--bg: #fff;", dark: "--bg: #000;")
    #expect(both != nil)
    #expect(both!.contains(":root {\ncolor-scheme: light;\n--bg: #fff;"))
    #expect(both!.contains("@media (prefers-color-scheme: dark)"))
    #expect(both!.contains("--bg: #000;"))

    // 仅深色：常暗，不包 media query
    let darkOnly = StyleSheet.cssText(light: nil, dark: "--bg: #000;")
    #expect(darkOnly != nil)
    #expect(darkOnly!.contains(":root"))
    #expect(!darkOnly!.contains("@media"))

    // 仅浅色
    let lightOnly = StyleSheet.cssText(light: "--bg: #fff;", dark: nil)
    #expect(lightOnly != nil)
    #expect(!lightOnly!.contains("@media"))

    // 非法：两者皆无 / 空白
    #expect(StyleSheet.cssText(light: nil, dark: nil) == nil)
    #expect(StyleSheet.cssText(light: "  \n ", dark: "") == nil)
}

/// 原生滚动条（页面级与 pre/table 的横向滚动槽）的明暗由 `color-scheme`
/// 决定，不声明时 WebKit 一律按浅色画——深色主题下就是一条白底滚动槽。
/// 每个变量块都必须带上与自身明暗匹配的 `color-scheme`。
///
/// 断言带缩进前缀：裸的 "color-scheme: dark" 会在 "prefers-color-scheme:
/// dark" 里误匹配（反向验证踩过——探针删了真声明，守卫照样绿）。
@Test func cssTextDeclaresColorSchemeForNativeScrollbars() {
    let both = StyleSheet.cssText(light: "--bg: #fff;", dark: "--bg: #000;")!
    #expect(both.contains(":root {\ncolor-scheme: light;"), "浅色块缺 color-scheme: light")
    if let mediaRange = both.range(of: "@media") {
        let darkBlock = String(both[mediaRange.lowerBound...])
        #expect(darkBlock.contains("  color-scheme: dark;"), "深色 media 块缺 color-scheme: dark 声明")
    } else {
        Issue.record("双变体输出缺 @media 块")
    }

    #expect(StyleSheet.cssText(light: nil, dark: "--bg: #000;")!.contains(":root {\ncolor-scheme: dark;"))
    #expect(StyleSheet.cssText(light: "--bg: #fff;", dark: nil)!.contains(":root {\ncolor-scheme: light;"))
}

@Test func fullDocumentContainsTwoStyleLayers() {
    let doc = StyleSheet.fullDocument(
        title: "t", body: "<p>hi</p>", themeCSS: ":root{}", includeScript: false
    )
    #expect(doc.contains("<style id=\"wtmd-base\">"))
    #expect(doc.contains("<style id=\"wtmd-theme\">:root{}"))
    // 静态导出不注入交互脚本（滚动同步/消息回传），但仍内嵌高亮资源
    #expect(!doc.contains("__wtmdUpdate"))
    #expect(doc.contains("__wtmdHighlight"))
}

// MARK: - .wttheme 加载

@Test func loadThemeFolderValid() throws {
    let dir = makeThemeFolder(
        name: "夜航",
        author: "测试者",
        light: "--bg: #101014;",
        dark: "--bg: #050507;"
    )
    defer { try? FileManager.default.removeItem(at: dir) }

    let theme = ThemeFormat.loadFolder(dir)
    #expect(theme != nil)
    #expect(theme?.name == "夜航")
    #expect(theme?.author == "测试者")
    #expect(theme?.isBuiltIn == false)
    #expect(theme?.hasLight == true)
    #expect(theme?.hasDark == true)
    #expect(theme?.cssText.contains("--bg: #101014;") == true)
}

@Test func loadThemeFolderCustomFileNames() throws {
    let dir = makeThemeFolder(
        name: "自定义文件名",
        lightFile: "day.css",
        darkFile: nil,
        light: "--bg: #fff;"
    )
    defer { try? FileManager.default.removeItem(at: dir) }

    let theme = ThemeFormat.loadFolder(dir)
    #expect(theme != nil)
    #expect(theme?.hasLight == true)
    #expect(theme?.hasDark == false)
}

@Test func loadThemeFolderInvalidCases() throws {
    // 1. 缺 theme.json
    let noMeta = makeTempDir()
    defer { try? FileManager.default.removeItem(at: noMeta) }
    #expect(ThemeFormat.loadFolder(noMeta) == nil)

    // 2. JSON 损坏
    let badJSON = makeTempDir()
    defer { try? FileManager.default.removeItem(at: badJSON) }
    try "{ not json".write(to: badJSON.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
    #expect(ThemeFormat.loadFolder(badJSON) == nil)

    // 3. 有 meta 但无任何 CSS
    let noCSS = makeThemeFolder(name: "空壳", light: nil, dark: nil)
    defer { try? FileManager.default.removeItem(at: noCSS) }
    #expect(ThemeFormat.loadFolder(noCSS) == nil)

    // 4. name 为空
    let emptyName = makeThemeFolder(name: "  ", light: "--bg: #fff;")
    defer { try? FileManager.default.removeItem(at: emptyName) }
    #expect(ThemeFormat.loadFolder(emptyName) == nil)

    // 5. 路径逃逸的文件名
    let escape = makeThemeFolder(name: "逃逸", light: "--bg: #fff;")
    defer { try? FileManager.default.removeItem(at: escape) }
    let meta = """
    {"name": "逃逸", "light": "../../etc/passwd"}
    """
    try meta.write(to: escape.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)
    #expect(ThemeFormat.loadFolder(escape) == nil)
}

// MARK: - 内置主题

@Test func builtInThemesValid() {
    #expect(Theme.builtIns.count == 13)
    for theme in Theme.builtIns {
        #expect(!theme.name.isEmpty)
        #expect(StyleSheet.cssText(light: theme.light, dark: theme.dark) != nil)
    }
    // 终端主题：常暗
    let terminal = Theme.builtIns.first { $0.id == "builtin.terminal" }
    #expect(terminal?.hasLight == false)
    #expect(terminal?.hasDark == true)
    // 默认主题双外观
    let def = Theme.builtIns.first { $0.id == Theme.defaultID }
    #expect(def?.hasLight == true)
    #expect(def?.hasDark == true)
    // 主题名是设置里唯一的辨认依据，撞名等于选不中
    #expect(Set(Theme.builtIns.map(\.name)).count == Theme.builtIns.count)
}

// MARK: - base16 内置主题

/// 色槽 → 变量的映射是整套外部兼容的地基：错了，230 套社区配色全错位。
@Test func base16CSSMapsSlotsToVariables() throws {
    let colors = (0..<16).map { String(format: "#%02x%02x%02x", $0, $0, $0) }
    let css = try #require(Theme.base16CSS(colors))

    #expect(css.contains("--bg: #000000;"), "base00 该是页面底色")
    #expect(css.contains("--fg: #050505;"), "base05 该是正文色")
    #expect(css.contains("--secondary: #040404;"), "base04 该是次级文字")
    #expect(css.contains("--border: #020202;"), "base02 该是边框")
    #expect(css.contains("--accent: #0d0d0d;"), "base0D 该是强调/链接")
    #expect(css.contains("--code-bg: #010101;"), "base01 该是行内代码底")
    #expect(css.contains("--hl-keyword: #0e0e0e;"), "base0E 该是关键字")
    #expect(css.contains("--hl-string: #0b0b0b;"), "base0B 该是字符串")
    #expect(css.contains("--hl-comment: #030303;"), "base03 该是注释")
    // 一行一个变量，不多不少（漏了会静默回落默认色，比报错更难查）
    #expect(css.split(separator: "\n").count == Theme.base16Map.count)
}

@Test func base16CSSRejectsBadInput() {
    #expect(Theme.base16CSS([]) == nil)
    #expect(Theme.base16CSS(Array(repeating: "#000000", count: 15)) == nil)
    #expect(Theme.base16CSS(Array(repeating: "#000000", count: 17)) == nil)

    var bad = Array(repeating: "#000000", count: 16)
    bad[7] = "not-a-color"
    #expect(Theme.base16CSS(bad) == nil, "一个坏色值就该整套拒绝，不出一半颜色的残废主题")

    var shortHex = Array(repeating: "#000000", count: 16)
    shortHex[2] = "#abc" // 三位简写也是合法 CSS 色
    #expect(Theme.base16CSS(shortHex) != nil)
}

@Test func base16BuiltInsAreUsable() {
    #expect(Theme.base16BuiltIns.count == 10)
    #expect(Set(Theme.base16BuiltIns.map(\.id)).count == 10, "id 撞了会选中错主题")

    for theme in Theme.base16BuiltIns {
        #expect(theme.isBuiltIn)
        #expect(theme.isBase16)
        #expect(!theme.name.isEmpty)
        // 一套配色只带一侧，另一侧留空由单变体逻辑兜住
        #expect(theme.hasLight != theme.hasDark)
        #expect(StyleSheet.cssText(light: theme.light, dark: theme.dark) != nil)
        #expect(theme.cssText.contains("--bg:"))
        #expect(theme.cssText.contains("--font-mono:") == false, "base16 不管字体，别覆盖默认栈")
    }

    // 明暗两个方向都得有样本：全暗会让浅色外观的选择失去参照
    #expect(Theme.base16BuiltIns.contains { $0.hasLight })
    #expect(Theme.base16BuiltIns.contains { $0.hasDark })
}

@Test func base16DisplayNamesAreRealNamesNotSlugs() {
    // 编号不是名字：0x96f、3024 这类 slug 只能当身份，不能出现在界面上。
    // 名字是静态表启动时求值的，override 全局——中英两套正名都算过。
    let english: Set<String> = [
        "Night Flight", "Ember", "Apathy", "Apprentice",
        "Arroz con Dulce Dark", "Arroz con Dulce Light", "Ascendancy",
        "Ashes", "Atelier Cave Light", "Atelier Cave Dark",
    ]
    let chinese: Set<String> = [
        "夜航", "炭火", "淡漠", "学徒", "甜米露 · 夜", "甜米露 · 昼",
        "盛世", "余烬", "石窟画室 · 浅", "石窟画室 · 深",
    ]
    let names = Set(Theme.base16BuiltIns.map(\.name))
    #expect(names == english || names == chinese, "显示名必须是正名，编号不出现在界面上")
}

// MARK: - 辅助

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func makeThemeFolder(
    name: String,
    author: String? = nil,
    lightFile: String? = "light.css",
    darkFile: String? = "dark.css",
    light: String?,
    dark: String? = nil
) -> URL {
    let dir = makeTempDir()
    var meta: [String: String] = ["name": name]
    if let author { meta["author"] = author }
    if lightFile != nil { meta["light"] = lightFile }
    if darkFile != nil { meta["dark"] = darkFile }
    let data = try! JSONSerialization.data(withJSONObject: meta)
    try! data.write(to: dir.appendingPathComponent("theme.json"))
    if let light, let lightFile {
        try! light.write(to: dir.appendingPathComponent(lightFile), atomically: true, encoding: .utf8)
    }
    if let dark, let darkFile {
        try! dark.write(to: dir.appendingPathComponent(darkFile), atomically: true, encoding: .utf8)
    }
    return dir
}
