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

    // 全量渲染基准：共享 CI runner 的绝对耗时浮动很大（同一提交在 macOS 15 上 ~0.3s，
    // macOS 26 runner 上曾到 2.5s），所以这里只留一条很宽的「复杂度退化」警报网，
    // 它不是性能口径——性能口径是 V02_PLAN 里那条 <16ms/帧，用 Instruments 实测，不由单测声称
    let start = Date()
    let blocks = WTMarkdown.renderBlocks(doc)
    let fullRender = Date().timeIntervalSince(start)
    #expect(blocks.count > 2500)
    print("基准：10k 行全量渲染 \(String(format: "%.3f", fullRender))s / \(blocks.count) 块")
    #expect(fullRender < 6.0, "10k 行全量渲染耗时 \(fullRender)s——比历史实测高出数倍，疑似复杂度退化")

    // 单段编辑的 diff 计算：应远快于全量
    // lines[0]=章节标题，[1]=空行，[2]=第 0 段，[3]=空行，[4]=第 1 段 ——
    // 改第 4 行即改「第 1 段」（块下标 2），故前缀恰为「标题 + 第 0 段」2 块
    var edited = lines
    edited[4] = "这是被编辑的段落，内容变了。"
    let editedDoc = edited.joined(separator: "\n")

    // 编辑后的解析/渲染不计入 diff 计时：真实链路上它在后台线程，
    // 主线程（帧预算关心的那部分）只剩下面这一次 O(块数) 的块数组比较
    let newBlocks = WTMarkdown.renderBlocks(editedDoc)

    let diffStart = Date()
    let diff = BlockDiff.compute(old: blocks, new: newBlocks)
    let diffTime = Date().timeIntervalSince(diffStart)

    // diff 本身是 O(n) 对比；变化段应只有 1 块，且前缀块保持原位
    #expect(diff.replacement.count == 1)
    #expect(diff.commonPrefix == 2)
    // 变化段只覆盖被改的那一块
    #expect(diff.commonPrefix + diff.replacement.count + diff.commonSuffix == newBlocks.count)

    // 与同一轮、同一台机器的全量渲染比：比值不受负载影响。
    // 块级 diff 是纯字符串比较，正常应比解析+渲染便宜两个数量级；退化成 O(n²)
    // 或整篇重渲染时会立刻超线。留 1/2 的宽松裕度，防慢机器上的抖动
    print("基准：块级 diff \(String(format: "%.4f", diffTime))s｜全量渲染 \(String(format: "%.3f", fullRender))s")
    #expect(diffTime < fullRender * 0.5, "块级 diff 应显著快于全量渲染（\(diffTime)s vs \(fullRender)s）")
}
