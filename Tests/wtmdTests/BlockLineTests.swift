import Testing
import WTMarkdownKit

/// 顶层块 ↔ 源码行：分栏联动的地基。
///
/// 行号错一位，联动就把读者带到隔壁段落——这种错在界面上极难发现（滚过去
/// 看起来也挺像那么回事），所以每一类块都单独钉一条，脚注那种会整体位移的
/// 情形更是必须钉死。
struct BlockLineTests {
    @Test func headingsAndParagraphs() {
        let result = WTMarkdown.render("# 标题\n\n第一段\n第二段\n\n第三段")
        #expect(result.blockLines == [0, 2, 5])
    }

    /// 段落跨行时记的是**首行**，不是最后一行：光标在段中任意一行，看的都是这一块。
    @Test func paragraphKeepsItsFirstLine() {
        let result = WTMarkdown.render("甲\n乙\n丙\n\n丁")
        #expect(result.blockLines == [0, 4])
    }

    @Test func fencedCodeTakesTheFenceLine() {
        let markdown = "# 标题\n\n```swift\nlet a = 1\n```\n\n结尾"
        #expect(WTMarkdown.render(markdown).blockLines == [0, 2, 6])
    }

    @Test func quoteStartsAtItsFirstLine() {
        #expect(WTMarkdown.render("> 一\n> 二\n\n后文").blockLines == [0, 3])
    }

    @Test func listsStartWhereTheMarkerIs() {
        #expect(WTMarkdown.render("- 甲\n- 乙\n\n1. 一\n2. 二").blockLines == [0, 3])
    }

    @Test func table() {
        let markdown = "前文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |"
        #expect(WTMarkdown.render(markdown).blockLines == [0, 2])
    }

    @Test func divider() {
        #expect(WTMarkdown.render("上\n\n---\n\n下").blockLines == [0, 2, 4])
    }

    @Test func toc() {
        #expect(WTMarkdown.render("[TOC]\n\n# 章").blockLines == [0, 2])
    }

    /// 脚注定义行在解析前被剥掉，行号必须按**原文**算。
    /// 拿过滤后的下标充数，后面每一块都会整体上移——这是这次最容易写错的一处。
    @Test func footnoteDefinitionDoesNotShiftLaterBlocks() {
        let markdown = "正文[^a]\n\n[^a]: 定义\n\n后文"
        let result = WTMarkdown.render(markdown)
        // 末位是脚注区（-1），正文两块才是要验的
        #expect(Array(result.blockLines.prefix(2)) == [0, 4])
    }

    /// 脚注区是渲染时追加的块，正文里没有对应的一行。
    @Test func footnoteSectionHasNoLine() {
        let result = WTMarkdown.render("正文[^a]\n\n[^a]: 定义")
        #expect(result.blockLines.count == result.blocks.count)
        #expect(result.blockLines.last == -1)
    }

    /// 与块数组一一对应、单调递增、除脚注区外都不是负数。
    @Test func everyBlockGetsALine() {
        let markdown = """
        # 一

        段落

        - 列表

        > 引用

        ```
        code
        ```

        | a |
        | --- |
        | 1 |

        ---

        末段
        """
        let result = WTMarkdown.render(markdown)
        #expect(result.blockLines.count == result.blocks.count)
        #expect(result.blockLines.allSatisfy { $0 >= 0 })
        #expect(result.blockLines == result.blockLines.sorted())
    }

    /// 行号不进块 HTML：块字符串是增量 diff 的比较基准，嵌进去就会让
    /// 「在文首插一行」变成整篇都变了。
    @Test func linesAreNotBakedIntoBlockHTML() {
        let result = WTMarkdown.render("甲\n\n乙")
        #expect(!result.html.contains("data-wtmd-line"))
        #expect(result.blockLines == [0, 2])
    }

    /// 同一份文本渲染两次，块数组必须逐字相同——否则每敲一个字都会整篇重画。
    /// 前面插一行时，后面块的内容没变，字符串也不该变（变的只有 blockLines）。
    @Test func insertingAtTheTopKeepsLaterBlocksIdentical() {
        let before = WTMarkdown.render("甲\n\n乙\n\n丙")
        let after = WTMarkdown.render("新的一行\n\n甲\n\n乙\n\n丙")
        #expect(before.blocks == Array(after.blocks.dropFirst()))
        #expect(before.blockLines == [0, 2, 4])
        #expect(after.blockLines == [0, 2, 4, 6])
    }
}
