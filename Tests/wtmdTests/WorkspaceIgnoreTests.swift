import Foundation
import Testing
@testable import wtmd

// MARK: - 解析

/// `.wtmdignore` 是给人手写的：注释、空行、结尾的 `/` 都得照直觉工作，
/// 否则第一条规则就会写错，然后没人再写第二条。
@Suite("忽略清单")
struct WorkspaceIgnoreTests {
    @Test("注释与空行不进规则")
    func commentsAndBlankLinesAreDropped() {
        let ignore = WorkspaceIgnore.parse("""
        # 素材不算稿子

        assets/
        导出/*.md
        """)
        #expect(ignore.patterns == ["assets/", "导出/*.md"])
    }

    @Test("行尾注释也去掉")
    func trailingCommentsAreStripped() {
        let ignore = WorkspaceIgnore.parse("草稿/** # 临时文件")
        #expect(ignore.patterns == ["草稿/**"])
    }

    @Test("没有文件就是什么都不忽略")
    func missingFileIgnoresNothing() {
        #expect(WorkspaceIgnore.load(root: nil) == .empty)
        #expect(WorkspaceIgnore.load(root: URL(fileURLWithPath: "/tmp/不存在-\(UUID())")) == .empty)
    }
}

// MARK: - 匹配

@Suite("忽略规则怎么匹配")
struct WorkspaceIgnoreMatchTests {
    private func ignore(_ text: String) -> WorkspaceIgnore { WorkspaceIgnore.parse(text) }

    @Test("不带斜杠的规则匹配任意层级：写 `assets` 就够")
    func bareNameMatchesAtAnyDepth() {
        let rules = ignore("assets")
        #expect(rules.excludes(relativePath: "assets/图.md"))
        #expect(rules.excludes(relativePath: "书稿/assets/图.md"))
        #expect(!rules.excludes(relativePath: "书稿/素材.md"))
    }

    @Test("结尾带斜杠只忽略目录")
    func trailingSlashMeansDirectoryOnly() {
        let rules = ignore("草稿/")
        #expect(rules.matches(relativePath: "草稿", isDirectory: true))
        #expect(!rules.matches(relativePath: "草稿", isDirectory: false))
    }

    @Test("`*` 不跨目录，`**` 跨")
    func starsRespectDirectories() {
        let shallow = ignore("导出/*.md")
        #expect(shallow.matches(relativePath: "导出/清单.md"))
        #expect(!shallow.matches(relativePath: "导出/2026/清单.md"))

        let deep = ignore("导出/**/*.md")
        #expect(deep.matches(relativePath: "导出/2026/清单.md"))
        #expect(deep.matches(relativePath: "导出/清单.md"))
    }

    @Test("`?` 只顶一个字符")
    func questionMarkIsOneCharacter() {
        let rules = ignore("第?.md")
        #expect(rules.matches(relativePath: "第1.md"))
        #expect(!rules.matches(relativePath: "第10.md"))
    }

    @Test("父目录被忽略时，里面的文件一起算")
    func parentRulesCoverTheirChildren() {
        let rules = ignore("素材/")
        #expect(rules.excludes(relativePath: "素材/2026/图.md"))
        #expect(!rules.excludes(relativePath: "书稿/素材.md"))
    }

    @Test("没写规则就什么都不排除")
    func emptyIgnoreExcludesNothing() {
        #expect(!WorkspaceIgnore.empty.excludes(relativePath: "草稿/x.md"))
    }
}

// MARK: - 接进搜索

@Suite("搜索真的会跳过被忽略的文件")
struct WorkspaceIgnoreSearchTests {
    @Test("被忽略的文件不读、不出现在结果里")
    func ignoredFilesAreNotScanned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-ignore-\(UUID().uuidString)", isDirectory: true)
        let keep = root.appendingPathComponent("正文", isDirectory: true)
        let skip = root.appendingPathComponent("素材", isDirectory: true)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skip, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "版心宽度决定一行多少字。".write(
            to: keep.appendingPathComponent("排版.md"), atomically: true, encoding: .utf8
        )
        try "版心这个词只出现在素材里。".write(
            to: skip.appendingPathComponent("笔记.md"), atomically: true, encoding: .utf8
        )
        try "素材/\n".write(
            to: root.appendingPathComponent(WorkspaceIgnore.fileName), atomically: true, encoding: .utf8
        )

        let report = WorkspaceSearch.run(
            root: root,
            query: "版心",
            options: [],
            ignores: WorkspaceIgnore.load(root: root)
        )
        #expect(report.hitCount == 1)
        #expect(report.groups.first?.relativePath == "正文/排版.md")
    }

    @Test("没有忽略清单时两个文件都搜得到")
    func withoutRulesBothFilesAreSearched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "版心".write(to: root.appendingPathComponent("甲.md"), atomically: true, encoding: .utf8)
        try "版心".write(to: root.appendingPathComponent("乙.md"), atomically: true, encoding: .utf8)

        let report = WorkspaceSearch.run(root: root, query: "版心", options: [])
        #expect(report.hitCount == 2)
    }
}
