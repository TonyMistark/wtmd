import Foundation
import Testing
@testable import wtmd

/// 菜单装配守卫：一条命令写了不等于它在菜单里。
///
/// 0.15.x 的 File 菜单一直是残的——`⌘S` 按下去毫无反应，因为**菜单项根本不存在**：
/// 「打开 / 保存 / 导出」整组都挂在 `CommandGroup(replacing: .saveItem)` 里，而
/// `.saveItem` 这一组只在文档型应用（`DocumentGroup`）里由系统提供；wtmd 不是，
/// 于是 `replacing` 一个不存在的分组，**内容被静默丢弃**，不报错、不警告。
/// 命令面板能搜到「保存」并执行，所以只有键盘和菜单这条路人肉按了才发现。
///
/// 这两条把「命令写进菜单了」钉在源码上：分组必须是真存在的那个，
/// 且每条菜单命令都真的能在目录里查到。
@MainActor
struct MenuPlacementTests {
    @Test("File 菜单挂在存在的分组上，七条命令一个不少")
    func theFileMenuIsPlacedInAGroupThatExists() throws {
        let app = try source("wtmdApp.swift")

        // `.saveItem` 在非文档型应用里不存在：replacing 它 = 整组蒸发。
        #expect(
            !app.contains(".saveItem"),
            "又用 .saveItem 了——wtmd 没有 DocumentGroup，这个分组不存在，里面的命令会被静默丢弃（⌘S 就是这样失效的）"
        )

        let group = try block(startingAt: "CommandGroup(after: .newItem)", in: app)
        for kind in [
            "openDocument", "openFolder", "save", "showHistory",
            "exportHTML", "exportWord", "exportPDF",
        ] {
            #expect(group.contains("menuItem(.\(kind))"), "File 菜单里没有 \(kind)——那条快捷键就是个哑键")
        }
    }

    @Test("菜单点名的每条命令，目录里都查得到")
    func everyMenuCommandExistsInTheCatalog() throws {
        let app = try source("wtmdApp.swift")
        let ids = try commandIdentifiers()

        let regex = try NSRegularExpression(pattern: "menuItem\\(\\.(\\w+)\\)")
        let range = NSRange(app.startIndex..., in: app)
        let kinds = Set(regex.matches(in: app, range: range).compactMap {
            Range($0.range(at: 1), in: app).map { String(app[$0]) }
        })

        #expect(!kinds.isEmpty, "一条菜单命令都没扫到，正则和源码对不上了")
        for kind in kinds.sorted() {
            let id = try #require(ids[kind], "菜单里写了 .\(kind)，但没有这种命令")
            let catalogued = CommandCatalog.staticCommands.contains { $0.kind.id == id }
            #expect(catalogued, "菜单里写了 .\(kind)（\(id)），但目录里没有它——这一项不会出现")
        }
    }

    // MARK: - 从源码里抓事实

    /// 命令的 case 名 → id（`case .save: return "file.save"`）。
    ///
    /// 菜单源码里只留下 `menuItem(.save)` 这样的 case 名，查目录得先换成 id。
    private func commandIdentifiers() throws -> [String: String] {
        let catalog = try source("CommandCatalog.swift")
        let regex = try NSRegularExpression(pattern: "case \\.(\\w+): return \"([^\"]+)\"")
        let range = NSRange(catalog.startIndex..., in: catalog)
        var table: [String: String] = [:]
        for match in regex.matches(in: catalog, range: range) {
            guard let name = Range(match.range(at: 1), in: catalog),
                  let id = Range(match.range(at: 2), in: catalog)
            else { continue }
            table[String(catalog[name])] = String(catalog[id])
        }
        return table
    }

    /// 从锚点往后取，直到下一个命令分组——够圈住那一个分组的内容。
    private func block(startingAt anchor: String, in text: String) throws -> String {
        let start = try #require(text.range(of: anchor), "源码里找不到 \(anchor)")
        let rest = text[start.upperBound...]
        guard let next = rest.range(of: "CommandGroup(") else { return String(rest) }
        return String(rest[..<next.lowerBound])
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/wtmd/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
