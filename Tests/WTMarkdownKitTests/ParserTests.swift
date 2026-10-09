import Testing
@testable import WTMarkdownKit

// MARK: - 标题与大纲

@Test func headingsAndOutline() {
    let r = WTMarkdown.render("""
    # 项目标题

    正文段落。

    ## 第二章 *强调*

    ### 三级

    ##第二章无效
    """)
    #expect(r.html.contains("<h1 id=\"项目标题\">项目标题</h1>"))
    #expect(r.html.contains("<h2 id=\"第二章-强调\">"))
    #expect(r.html.contains("<h3 id=\"三级\">"))
    #expect(!r.html.contains("<h2 id=\"第二章无效\">"))
    #expect(r.outline.count == 3)
    #expect(r.outline[0].level == 1)
    #expect(r.outline[0].text == "项目标题")
    #expect(r.outline[0].line == 0)
    #expect(r.outline[1].text == "第二章 强调")
    #expect(r.outline[1].line == 4)
    #expect(r.outline[2].level == 3)
}

@Test func slugDeduplication() {
    let r = WTMarkdown.render("# 重复\n\n# 重复\n\n# 重复")
    #expect(r.html.contains("id=\"重复\""))
    #expect(r.html.contains("id=\"重复-1\""))
    #expect(r.html.contains("id=\"重复-2\""))
    #expect(r.outline.map(\.slug) == ["重复", "重复-1", "重复-2"])
}

// MARK: - 内联

@Test func inlineStyles() {
    let r = WTMarkdown.render("这是**粗体**、*斜体*、~~删除~~、`代码`、[链接](https://a.b/c) 和 ![图](img.png \"标题\")")
    #expect(r.html.contains("<strong>粗体</strong>"))
    #expect(r.html.contains("<em>斜体</em>"))
    #expect(r.html.contains("<del>删除</del>"))
    #expect(r.html.contains("<code>代码</code>"))
    #expect(r.html.contains("<a href=\"https://a.b/c\">链接</a>"))
    #expect(r.html.contains("<img src=\"img.png\" alt=\"图\" title=\"标题\" />"))
}

@Test func underscoreEmphasisDoesNotBreakSnakeCase() {
    let r = WTMarkdown.render("snake_case_name 不应该 *被* 强调")
    #expect(!r.html.contains("<em>case</em>"))
    #expect(r.html.contains("snake_case_name"))
}

@Test func codeSpanProtectsMarkers() {
    let r = WTMarkdown.render("行内 `**不粗**` 保持原样")
    #expect(r.html.contains("<code>**不粗**</code>"))
    #expect(!r.html.contains("<strong>"))
}

@Test func htmlEscaping() {
    let r = WTMarkdown.render("文本 <script>alert(1)</script> 与 & 符号")
    #expect(!r.html.contains("<script>"))
    #expect(r.html.contains("&lt;script&gt;"))
    #expect(r.html.contains("&amp;"))
}

@Test func autolinks() {
    let r = WTMarkdown.render("访问 https://example.com/a?b=1 或 <https://example.com> 看看")
    #expect(r.html.contains("<a href=\"https://example.com/a?b=1\">https://example.com/a?b=1</a>"))
    #expect(r.html.contains("<a href=\"https://example.com\">https://example.com</a>"))
}

@Test func hardLineBreak() {
    let r = WTMarkdown.render("第一行  \n第二行")
    #expect(r.html.contains("<br />"))
}

// MARK: - 块级

@Test func fencedCode() {
    let r = WTMarkdown.render("```swift\nlet a = 1\nlet b = \"<b>\"\n```\n")
    #expect(r.html.contains("<pre><code class=\"language-swift\">let a = 1"))
    #expect(r.html.contains("&lt;b&gt;"))
}

@Test func lists() {
    let r = WTMarkdown.render("""
    - 甲
    - 乙
        - 乙一
    1. 第一
    2. 第二
    """)
    #expect(r.html.contains("<ul>"))
    #expect(r.html.contains("<li>甲</li>"))
    #expect(r.html.contains("<ul>"))
    #expect(r.html.contains("<li>乙一</li>"))
    #expect(r.html.contains("<ol>"))
    #expect(r.html.contains("<li>第一</li>"))
}

@Test func taskList() {
    let r = WTMarkdown.render("- [x] 完成\n- [ ] 待办")
    #expect(r.html.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked>"))
    #expect(r.html.contains("<li class=\"task\"><input type=\"checkbox\" disabled>"))
}

@Test func blockquote() {
    let r = WTMarkdown.render("> 引用文本\n> **加粗**")
    #expect(r.html.contains("<blockquote>"))
    #expect(r.html.contains("<strong>加粗</strong>"))
}

@Test func divider() {
    let r = WTMarkdown.render("上文\n\n---\n\n下文")
    #expect(r.html.contains("<hr />"))
}

@Test func table() {
    let r = WTMarkdown.render("""
    | 左 | 中 | 右 |
    | :-- | :-: | --: |
    | a | b | c |
    """)
    #expect(r.html.contains("<table>"))
    #expect(r.html.contains("<th style=\"text-align:left\">左</th>"))
    #expect(r.html.contains("<th style=\"text-align:center\">中</th>"))
    #expect(r.html.contains("<th style=\"text-align:right\">右</th>"))
    #expect(r.html.contains("<td style=\"text-align:left\">a</td>"))
}

@Test func looseListsRemainLists() {
    let r = WTMarkdown.render("- 甲\n\n- 乙")
    #expect(r.html.contains("<li>甲</li>"))
    #expect(r.html.contains("<li>乙</li>"))
}

@Test func orderedListStart() {
    let r = WTMarkdown.render("3. 三\n4. 四")
    #expect(r.html.contains("<ol start=\"3\">"))
}

// MARK: - 大纲纯文本

@Test func outlinePlainText() {
    let r = WTMarkdown.render("## [标题链接](https://a.b) 与 `代码`")
    #expect(r.outline.first?.text == "标题链接 与 代码")
}
