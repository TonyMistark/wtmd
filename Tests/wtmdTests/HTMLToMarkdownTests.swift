import AppKit
import Testing
@testable import wtmd

// MARK: - HTML → Markdown

private func markdown(_ html: String) -> String? {
    HTMLToMarkdown.markdown(fromHTML: html)
}

@MainActor
@Test func headingsAndParagraphs() {
    let html = "<h1>标题</h1><p>第一段</p><p>第二段</p>"
    #expect(markdown(html) == "# 标题\n\n第一段\n\n第二段")
}

@MainActor
@Test func headingLevelsSurvive() {
    #expect(markdown("<h2>二级</h2>") == "## 二级")
    #expect(markdown("<h6>六级</h6>") == "###### 六级")
}

@MainActor
@Test func inlineFormatting() {
    let html = "<p>这是 <strong>粗</strong>、<em>斜</em>、<del>删</del> 和 <code>code</code>。</p>"
    #expect(markdown(html) == "这是 **粗**、*斜*、~~删~~ 和 `code`。")
}

@MainActor
@Test func linksAndImages() {
    let html = #"<p>看 <a href="https://example.com">这里</a> 和 <img src="a.png" alt="图"></p>"#
    #expect(markdown(html) == "看 [这里](https://example.com) 和 ![图](a.png)")
}

/// 空链接、页内锚点不值得写成 `[文字]( )`。
@MainActor
@Test func anchorLinksKeepOnlyTheirText() {
    #expect(markdown(##"<p><a href="#top">回到顶部</a></p>"##) == "回到顶部")
}

@MainActor
@Test func unorderedListWithNesting() {
    let html = "<ul><li>一<ul><li>一甲</li><li>一乙</li></ul></li><li>二</li></ul>"
    #expect(markdown(html) == "- 一\n  - 一甲\n  - 一乙\n- 二")
}

@MainActor
@Test func orderedListKeepsItsNumbers() {
    let html = "<ol><li>甲</li><li>乙</li><li>丙</li></ol>"
    #expect(markdown(html) == "1. 甲\n2. 乙\n3. 丙")
}

/// 列表项里包着 `<p>` 的写法（Word、Notion 都这么导出）：并进一行。
@MainActor
@Test func paragraphsInsideAListItemStayOnOneLine() {
    #expect(markdown("<ul><li><p>段一</p><p>段二</p></li></ul>") == "- 段一 段二")
}

@MainActor
@Test func blockquotesGetTheMarker() {
    let html = "<blockquote><p>引用一</p><p>引用二</p></blockquote>"
    #expect(markdown(html) == "> 引用一\n>\n> 引用二")
}

@MainActor
@Test func codeBlockKeepsItsLanguage() {
    let html = "<pre><code class=\"language-swift\">let a = 1\nlet b = 2</code></pre>"
    #expect(markdown(html) == "```swift\nlet a = 1\nlet b = 2\n```")
}

/// 代码里本来就有 ``` 时，围栏要加长，否则块会被提前关掉。
@MainActor
@Test func codeBlockWithBackticksGetsALongerFence() {
    let html = "<pre><code>```\nnested\n```</code></pre>"
    #expect(markdown(html) == "````\n```\nnested\n```\n````")
}

@MainActor
@Test func tableBecomesAGFMTable() {
    let html = """
    <table>
      <thead><tr><th>名</th><th>值</th></tr></thead>
      <tbody><tr><td>甲</td><td>1</td></tr><tr><td>乙</td><td>2</td></tr></tbody>
    </table>
    """
    #expect(markdown(html) == "| 名 | 值 |\n| --- | --- |\n| 甲 | 1 |\n| 乙 | 2 |")
}

/// 单元格里的竖线要转义，否则表格多出一列。
@MainActor
@Test func pipesInsideCellsAreEscaped() {
    let html = "<table><tr><th>a|b</th></tr><tr><td>1</td></tr></table>"
    #expect(markdown(html) == #"| a\|b |"# + "\n| --- |\n| 1 |")
}

@MainActor
@Test func entitiesAreDecoded() {
    #expect(markdown("<p>a &amp; b &lt;tag&gt; &nbsp; 空格 &#65;&#x42;</p>")
        == "a & b <tag> 空格 AB")
}

/// 源文件里的换行与缩进是排版，不是内容。
@MainActor
@Test func sourceWhitespaceCollapses() {
    let html = """
    <p>
        第一句
        第二句
    </p>
    """
    #expect(markdown(html) == "第一句 第二句")
}

@MainActor
@Test func scriptAndStyleAreDropped() {
    let html = "<style>p{color:red}</style><script>var a = 1</script><p>正文</p>"
    #expect(markdown(html) == "正文")
}

@MainActor
@Test func commentsAreDropped() {
    #expect(markdown("<!-- 注释里有 > 号 --><p>正文</p>") == "正文")
}

/// 整份文档（浏览器复制出来的就是这种）：head 整段不要，正文照常。
@MainActor
@Test func fullDocumentKeepsOnlyTheBody() {
    let html = """
    <html><head><meta charset="utf-8"><title>标题</title></head>
    <body><h1>正文标题</h1><p>一段话。</p></body></html>
    """
    #expect(markdown(html) == "# 正文标题\n\n一段话。")
}

/// Word 的粗体常常只写在 style 里。
@MainActor
@Test func wordStyleBoldIsRecognised() {
    #expect(markdown(#"<p><span style="font-weight:bold">粗</span></p>"#) == "**粗**")
    #expect(markdown(#"<p><span style='font-style: italic'>斜</span></p>"#) == "*斜*")
}

@MainActor
@Test func hardBreakKeepsItsLineBreak() {
    #expect(markdown("<p>一<br>二</p>") == "一  \n二")
}

/// 没有 `<p>` 的片段（有些网页复制出来就是这样）也要能转。
@MainActor
@Test func bareFragmentStillConverts() {
    #expect(markdown("纯文本 <b>加粗</b> 结尾") == "纯文本 **加粗** 结尾")
}

@MainActor
@Test func emptyOrDecorationOnlyReturnsNil() {
    #expect(markdown("") == nil)
    #expect(markdown("   \n  ") == nil)
    #expect(markdown("<div><span></span></div>") == nil)
}

/// 没闭合的标签不该把后面的内容吞掉（网页里的 `<p>` 经常不闭合）。
@MainActor
@Test func unclosedTagsDoNotSwallowTheRest() {
    #expect(markdown("<p>第一段<p>第二段") == "第一段\n\n第二段")
}

/// 表体行比表头多/少一格时补齐，列数由最宽的那行决定。
@MainActor
@Test func tableRowsArePaddedToTheWidestRow() {
    let html = "<table><tr><th>a</th><th>b</th></tr><tr><td>1</td></tr></table>"
    #expect(markdown(html) == "| a | b |\n| --- | --- |\n| 1 |  |")
}

// MARK: - 粘贴板

@MainActor
private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("wtmd-tests-\(UUID().uuidString)"))
}

/// 只有纯文本的粘贴板不归转换器管：交回系统，行为与改动前一致。
@MainActor
@Test func plainTextPasteboardIsLeftAlone() {
    let board = scratchPasteboard()
    board.clearContents()
    board.setString("一段纯文本", forType: .string)
    #expect(HTMLToMarkdown.markdown(from: board) == nil)
}

/// 只有 RTF 的粘贴板（Word、备忘录）也能走到 Markdown。
@MainActor
@Test func rtfOnlyPasteboardConverts() throws {
    let attributed = NSAttributedString(
        string: "备忘录里的一段",
        attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
    )
    let rtf = try attributed.data(
        from: NSRange(location: 0, length: attributed.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    let board = scratchPasteboard()
    board.clearContents()
    board.setData(rtf, forType: .rtf)

    let result = HTMLToMarkdown.markdown(from: board)
    #expect(result?.contains("备忘录里的一段") == true)
}
