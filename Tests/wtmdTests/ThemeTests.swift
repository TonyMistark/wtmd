import Foundation
import Testing
@testable import wtmd

// MARK: - cssText 拼接

@Test func cssTextWrapping() {
    let both = StyleSheet.cssText(light: "--bg: #fff;", dark: "--bg: #000;")
    #expect(both != nil)
    #expect(both!.contains(":root {\n--bg: #fff;"))
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

@Test func fullDocumentContainsTwoStyleLayers() {
    let doc = StyleSheet.fullDocument(
        title: "t", body: "<p>hi</p>", themeCSS: ":root{}", includeScript: false
    )
    #expect(doc.contains("<style id=\"wtmd-base\">"))
    #expect(doc.contains("<style id=\"wtmd-theme\">:root{}"))
    #expect(!doc.contains("<script>"))
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
    #expect(Theme.builtIns.count == 3)
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
