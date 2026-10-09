import Testing
@testable import WTMarkdownKit

// MARK: - 中英混合统计

@Test func pureChinese() {
    let s = TextStatistics.count("你好世界，wtmd 是一个编辑器。")
    // CJK：你好世界是一个编辑器 = 10 字；西文词：wtmd = 1
    #expect(s.characters == 11)
    #expect(s.words == 1)
    #expect(s.readingMinutes == 1)
}

@Test func pureEnglish() {
    let s = TextStatistics.count("hello brave new world")
    #expect(s.characters == 4)
    #expect(s.words == 4)
    #expect(s.readingMinutes == 1)
}

@Test func mixedCounts() {
    let s = TextStatistics.count("Swift 里 String 是值类型")
    // CJK：里是值类型 = 5；西文：Swift String = 2 词
    #expect(s.characters == 7)
    #expect(s.words == 2)
}

@Test func readingTimeCalculation() {
    // 900 个汉字 → 3 分钟
    let long = String(repeating: "汉", count: 900)
    #expect(TextStatistics.count(long).readingMinutes == 3)
    // 400 词英文 → 2 分钟
    let words = Array(repeating: "word", count: 400).joined(separator: " ")
    #expect(TextStatistics.count(words).readingMinutes == 2)
    // 混合：300 汉字 + 100 词 = 1 + 0.5 → 向上取整 2 分钟
    let mixed = String(repeating: "汉", count: 300) + " " + Array(repeating: "word", count: 100).joined(separator: " ")
    #expect(TextStatistics.count(mixed).readingMinutes == 2)
}

// MARK: - Markdown 剥离

@Test func markdownMarkersStripped() {
    let s = TextStatistics.count("# 标题\n\n**加粗** 与 *斜体*、~~删除~~、`代码`")
    // 计入：标题加粗与斜体删除代码 = 11 字，标记符不重复计数
    #expect(s.characters == 11)
}

@Test func linksAndImagesStripped() {
    let s = TextStatistics.count("看[这个链接](https://example.com/very/long/url)和图![替代文字](img.png)")
    // 链接保留文字：看这个链接和图替代文字 = 11 字；URL 不计
    #expect(s.characters == 11)
    #expect(s.words == 0)
}

@Test func codeBlocksExcluded() {
    let s = TextStatistics.count("""
    正文五个字呀

    ```swift
    let code = "these english words do not count"
    ```
    """)
    // 正文五个字呀 = 6 字；代码块内英文不计
    #expect(s.characters == 6)
    #expect(s.words == 0)
}

@Test func emptyAndBlankDocuments() {
    #expect(TextStatistics.count("").characters == 0)
    #expect(TextStatistics.count("").readingMinutes == 0)
    // 只有标记符与空白 → 0
    let onlyMarkers = TextStatistics.count("# \n\n---\n\n- ")
    #expect(onlyMarkers.characters == 0)
    #expect(onlyMarkers.readingMinutes == 0)
}

@Test func fullwidthPunctuationNotCounted() {
    let s = TextStatistics.count("你好，世界！")
    // 全角标点不计字数：你好世界 = 4
    #expect(s.characters == 4)
}

@Test func listMarkersStripped() {
    let s = TextStatistics.count("- 列表项甲\n- 列表项乙\n\n> 引用内容")
    // 列表项甲列表项乙引用内容 = 12
    #expect(s.characters == 12)
}
