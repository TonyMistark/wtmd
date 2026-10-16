import Foundation
import Testing
@testable import WTMarkdownKit

// MARK: - BlockDiff 前后缀对齐

@Test func diffNoChange() {
    let old = ["<p>a</p>", "<p>b</p>", "<p>c</p>"]
    let d = BlockDiff.compute(old: old, new: old)
    #expect(d.isEmpty)
    #expect(d.replacement.isEmpty)
}

@Test func diffMiddleChange() {
    let old = ["<p>a</p>", "<p>b</p>", "<p>c</p>"]
    let new = ["<p>a</p>", "<p>B!</p>", "<p>c</p>"]
    let d = BlockDiff.compute(old: old, new: new)
    #expect(d.commonPrefix == 1)
    #expect(d.commonSuffix == 1)
    #expect(d.replacement == ["<p>B!</p>"])
}

@Test func diffAppendAndPrepend() {
    // 纯追加
    let d1 = BlockDiff.compute(old: ["<p>a</p>"], new: ["<p>a</p>", "<p>b</p>"])
    #expect(d1.commonPrefix == 1)
    #expect(d1.commonSuffix == 0)
    #expect(d1.replacement == ["<p>b</p>"])

    // 纯前插
    let d2 = BlockDiff.compute(old: ["<p>b</p>"], new: ["<p>a</p>", "<p>b</p>"])
    #expect(d2.commonPrefix == 0)
    #expect(d2.commonSuffix == 1)
    #expect(d2.replacement == ["<p>a</p>"])

    // 全删
    let d3 = BlockDiff.compute(old: ["<p>a</p>", "<p>b</p>"], new: [])
    #expect(d3.commonPrefix == 0)
    #expect(d3.commonSuffix == 0)
    #expect(d3.replacement.isEmpty)
}

@Test func diffFullReplacement() {
    let old = ["<p>a</p>", "<p>a</p>"]
    let new = ["<p>b</p>", "<p>b</p>"]
    let d = BlockDiff.compute(old: old, new: new)
    #expect(d.commonPrefix == 0)
    #expect(d.commonSuffix == 0)
    #expect(d.replacement == ["<p>b</p>", "<p>b</p>"])
}

@Test func diffEmptyToEmpty() {
    let d = BlockDiff.compute(old: [], new: [])
    #expect(d.isEmpty)
}

// MARK: - renderBlocks 与 render 一致性

@Test func renderBlocksJoinEqualsRender() {
    let md = """
    # 标题

    段落一。

    - 甲
    - 乙

    | a | b |
    | -- | -- |

    ```swift
    let x = 1
    ```

    引用[^1]。

    [^1]: 定义
    """
    let blocks = WTMarkdown.renderBlocks(md)
    let joined = blocks.joined()
    let direct = WTMarkdown.html(md)
    #expect(joined == direct)
    // 脚注区块是最后一个元素
    #expect(blocks.last!.contains("footnotes"))
}

@Test func renderResultCarriesBlocks() {
    let md = "# 标题\n\n段落。\n\n```swift\nlet x = 1\n```\n"
    let result = WTMarkdown.render(md)
    // 一次解析同时产出正文与块数组，无需二次解析
    #expect(result.blocks.count == 3)
    #expect(result.blocks.joined() == result.html)
    #expect(WTMarkdown.renderBlocks(md) == result.blocks)
}

// MARK: - 编辑场景 diff

@Test func editingParagraphOnlyChangesThatBlock() {
    let original = "# 标题\n\n第一段。\n\n中间段。\n\n最后段。"
    let edited = "# 标题\n\n第一段。\n\n中间段改了。\n\n最后段。"

    let old = WTMarkdown.renderBlocks(original)
    let new = WTMarkdown.renderBlocks(edited)
    let d = BlockDiff.compute(old: old, new: new)

    #expect(d.commonPrefix == 2) // 标题 + 第一段
    #expect(d.commonSuffix == 1) // 最后段
    #expect(d.replacement.count == 1)
    #expect(d.replacement[0].contains("中间段改了"))
}

@Test func headingEditPropagatesSuffix() {
    // 改标题 → 标题及后续 slug 可能变化，但前面的块保持
    let original = "开头段。\n\n## 章节 A\n\n内容。"
    let edited = "开头段。\n\n## 章节 B\n\n内容。"

    let d = BlockDiff.compute(
        old: WTMarkdown.renderBlocks(original),
        new: WTMarkdown.renderBlocks(edited)
    )
    #expect(d.commonPrefix == 1) // 开头段不动
}

// MARK: - 性能基准

@Test func benchmark10kLines() {
    // 生成 10k+ 行样本（~3000 块）
    var lines: [String] = []
    for section in 0..<300 {
        lines.append("# 第 \(section) 章")
        lines.append("")
        for para in 0..<15 {
            lines.append("这是第 \(section) 章的第 \(para) 段内容，包含**加粗**与 `代码`，还有[链接](https://example.com)点缀。")
            lines.append("")
        }
        if section % 10 == 0 {
            lines.append("- [ ] 任务项")
            lines.append("- [x] 完成项")
            lines.append("")
        }
    }
    let doc = lines.joined(separator: "\n")
    #expect(doc.components(separatedBy: "\n").count >= 9000)

    // 全量渲染基准：CI 机器性能浮动，给宽松上界（防抖 250ms 内须完成）
    let start = Date()
    let blocks = WTMarkdown.renderBlocks(doc)
    let fullRender = Date().timeIntervalSince(start)
    #expect(blocks.count > 2500)
    #expect(fullRender < 1.0, "10k 行全量渲染耗时 \(fullRender)s，超出预算")

    // 单段编辑的 diff 计算：应远快于全量
    // lines[0]=章节标题，[1]=空行，[2]=第 0 段，[3]=空行，[4]=第 1 段 ——
    // 改第 4 行即改「第 1 段」（块下标 2），故前缀恰为「标题 + 第 0 段」2 块
    var edited = lines
    edited[4] = "这是被编辑的段落，内容变了。"
    let editedDoc = edited.joined(separator: "\n")

    let diffStart = Date()
    let newBlocks = WTMarkdown.renderBlocks(editedDoc)
    let diff = BlockDiff.compute(old: blocks, new: newBlocks)
    let diffTime = Date().timeIntervalSince(diffStart)

    // diff 本身是 O(n) 对比；变化段应只有 1 块，且前缀块保持原位
    #expect(diff.replacement.count == 1)
    #expect(diff.commonPrefix == 2)
    #expect(diffTime < 1.0, "10k 行编辑重渲染+diff 耗时 \(diffTime)s")
    // 变化段只覆盖被改的那一块
    #expect(diff.commonPrefix + diff.replacement.count + diff.commonSuffix == newBlocks.count)
}
