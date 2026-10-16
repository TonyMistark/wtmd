import Testing
@testable import WTMarkdownKit

// MARK: - 占位识别

@Test func tocPlaceholderOnItsOwnLine() {
    let blocks = MarkdownParser().parse("正文一段。\n\n[TOC]\n\n# 标题")
    #expect(blocks == [.paragraph("正文一段。"), .toc, .heading(level: 1, text: "标题")])
}

@Test func tocNotRecognizedWhenNotOnItsOwnLine() {
    // 混在段落里只是普通文本
    let r = WTMarkdown.render("这一行 [TOC] 不是占位。")
    #expect(r.html.contains("<p>这一行 [TOC] 不是占位。</p>"))
    #expect(!r.html.contains("wtmd-toc"))

    // 小写不是占位
    let r2 = WTMarkdown.render("[toc]")
    #expect(r2.html.contains("<p>[toc]</p>"))
}

@Test func tocNotRecognizedInsideQuoteListOrCode() {
    // 引用内的 [TOC] 是普通文本
    let r = WTMarkdown.render("> [TOC]")
    #expect(r.html.contains("<blockquote>"))
    #expect(!r.html.contains("wtmd-toc"))

    // 围栏代码内的 [TOC] 是代码
    let r2 = WTMarkdown.render("```\n[TOC]\n```")
    #expect(r2.html.contains("<pre><code>[TOC]</code></pre>"))
}

// MARK: - 目录渲染

@Test func tocRendersAnchoredOutline() {
    let r = WTMarkdown.render("""
    # 入门

    ## 安装

    正文。

    [TOC]
    """)
    #expect(r.html.contains("<nav class=\"wtmd-toc\""))
    #expect(r.html.contains("<a href=\"#入门\">入门</a>"))
    #expect(r.html.contains("<a href=\"#安装\">安装</a>"))
    // 锚点与标题 id 一致，层级缩进类正确
    #expect(r.html.contains("<h1 id=\"入门\">"))
    #expect(r.html.contains("<h2 id=\"安装\">"))
    #expect(r.html.contains("wtmd-toc-l1"))
    #expect(r.html.contains("wtmd-toc-l2"))
}

@Test func tocBeforeHeadingsAlsoFilled() {
    // 占位在标题之前同样能拿到全文大纲（两阶段回填）
    let r = WTMarkdown.render("[TOC]\n\n# 第一章\n\n## 小节")
    #expect(r.html.contains("<a href=\"#第一章\">第一章</a>"))
    #expect(r.html.contains("<a href=\"#小节\">小节</a>"))
    #expect(r.outline.count == 2)
}

@Test func tocEmptyWhenNoHeadings() {
    let r = WTMarkdown.render("[TOC]\n\n只有一段话。")
    #expect(r.html.contains("<nav class=\"wtmd-toc\" data-wtmd-toc></nav>"))
    #expect(!r.html.contains("<a href="))
}

@Test func tocDuplicateHeadingSlugsAligned() {
    let r = WTMarkdown.render("[TOC]\n\n# 重复\n\n# 重复")
    #expect(r.html.contains("<a href=\"#重复\">重复</a>"))
    #expect(r.html.contains("<a href=\"#重复-1\">重复</a>"))
}

@Test func tocMultiplePlaceholdersEachGetFullOutline() {
    let r = WTMarkdown.render("[TOC]\n\n# 章\n\n[TOC]")
    let count = r.html.components(separatedBy: "wtmd-toc-list").count - 1
    #expect(count == 2)
    #expect(r.blocks.filter { $0.contains("wtmd-toc-list") }.count == 2)
}

@Test func tocRenderIsDeterministicForDiff() {
    let source = "[TOC]\n\n# 标题\n\n## 小节\n\n段落。"
    let a = WTMarkdown.render(source)
    let b = WTMarkdown.render(source)
    #expect(a.blocks == b.blocks)
}

@Test func tocEscapesHeadingTextInLinks() {
    let r = WTMarkdown.render("[TOC]\n\n# 含 <b> 标签的标题")
    // 目录条目转义，锚点仍指向标题生成的 slug
    #expect(r.html.contains("&lt;b&gt; 标签"))
    #expect(!r.html.contains("<b> 标签的标题</a>"))
}

// MARK: - 增量渲染

@Test func editingHeadingChangesTOCBlock() {
    let before = WTMarkdown.render("[TOC]\n\n# 旧标题\n\n正文。")
    let after = WTMarkdown.render("[TOC]\n\n# 新标题\n\n正文。")
    // TOC 块（第 0 块）内容不同 → 前缀对齐在它处断开，会进入 diff 重渲染
    #expect(before.blocks[0] != after.blocks[0])
    let diff = BlockDiff.compute(old: before.blocks, new: after.blocks)
    #expect(diff.commonPrefix == 0)
    #expect(!diff.isEmpty)
}

@Test func editingBodyKeepsTOCStable() {
    let before = WTMarkdown.render("[TOC]\n\n# 标题\n\n旧段落。")
    let after = WTMarkdown.render("[TOC]\n\n# 标题\n\n新段落。")
    // 非标题编辑：TOC 块字符串完全一致，diff 只落在段落块（前缀跨过 TOC 与标题）
    #expect(before.blocks[0] == after.blocks[0])
    let diff = BlockDiff.compute(old: before.blocks, new: after.blocks)
    #expect(diff.commonPrefix == 2)
    #expect(diff.replacement.count == 1)
}
