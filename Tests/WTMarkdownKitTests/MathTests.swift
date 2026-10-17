import Testing
@testable import WTMarkdownKit

/// KaTeX 数学公式：`$…$` 行内、`$$…$$` 块级、边界与增量行为。
@Suite("Math (KaTeX)")
struct MathTests {

    // MARK: - 占位输出

    @Test func inlineMathBecomesPlaceholderSpan() {
        let html = WTMarkdown.render("能量 $E=mc^2$ 守恒").html
        #expect(html.contains(#"<span class="wtmd-math" data-display="0">E=mc^2</span>"#))
    }

    @Test func displayMathAcrossLines() {
        let md = "$$\n\\frac{a}{b} + c\n$$\n后续"
        let html = WTMarkdown.render(md).html
        #expect(html.contains(#"class="wtmd-math wtmd-math-display" data-display="1""#))
        #expect(html.contains("\\frac{a}{b} + c"))
    }

    @Test func mathSourceIsHTMLEscaped() {
        let html = WTMarkdown.render("$a < b > c$").html
        #expect(html.contains("a &lt; b &gt; c"))
        #expect(!html.contains("a < b"))
    }

    @Test func mathShieldsInlineMarkup() {
        // 数学里的 *、_ 不能被行内标记吃掉
        let html = WTMarkdown.render("$a*b*c$ 与 $x_i^2$").html
        #expect(html.contains(#">a*b*c</span>"#))
        #expect(html.contains(#">x_i^2</span>"#))
        #expect(!html.contains("<em>a*b*c</em>"))
    }

    // MARK: - 边界（不该成公式的情形）

    @Test func currencyAmountsStayLiteral() {
        let html = WTMarkdown.render("花了 $5 and $10，共 $15。").html
        #expect(!html.contains("wtmd-math"))
        #expect(html.contains("$5 and $10"))
    }

    @Test func mathInInlineCodeStaysLiteral() {
        let html = WTMarkdown.render("写法 `$x^2$` 是源码").html
        #expect(!html.contains("wtmd-math"))
        #expect(html.contains("<code>$x^2$</code>"))
    }

    @Test func bareDollarSignsStayLiteral() {
        // 开头/结尾贴空白不构成公式
        let html = WTMarkdown.render("价格是 $ 100 与 $ 200").html
        #expect(!html.contains("wtmd-math"))
    }

    @Test func mermaidFenceUnaffected() {
        let md = "```math\nE=mc^2\n```"
        let html = WTMarkdown.render(md).html
        // ```math 是普通围栏，不是数学语法
        #expect(!html.contains("wtmd-math"))
        #expect(html.contains("language-math"))
    }

    // MARK: - 确定性与增量

    @Test func renderingIsDeterministic() {
        let md = "标题 $a_1$ 前言\n\n$$\\int_0^1 x\\,dx$$"
        let a = WTMarkdown.render(md)
        let b = WTMarkdown.render(md)
        #expect(a.blocks == b.blocks)
        #expect(a.html == b.html)
    }

    @Test func bodyEditLeavesMathBlockUntouched() {
        // 公式所在块与正文块独立：改正文不惊动公式块的 HTML
        let before = WTMarkdown.render("$x^2$ 公式块\n\n第一段")
        let after = WTMarkdown.render("$x^2$ 公式块\n\n第一段改了")
        let diff = BlockDiff.compute(old: before.blocks, new: after.blocks)
        #expect(before.blocks[0] == after.blocks[0])
        #expect(diff.commonPrefix == 1)
        #expect(diff.replacement.count == 1)
    }

    @Test func editingFormulaRerendersOnlyItsBlock() {
        let before = WTMarkdown.render("前言\n\n$\\alpha$ 与 $\\beta$")
        let after = WTMarkdown.render("前言\n\n$\\alpha$ 与 $\\gamma$")
        let diff = BlockDiff.compute(old: before.blocks, new: after.blocks)
        #expect(diff.commonPrefix == 1)
        #expect(before.blocks[1] != after.blocks[1])
    }

    @Test func multipleFormulasInOneParagraph() {
        let html = WTMarkdown.render("若 $a>0$ 且 $b>0$，则 $a+b>0$。").html
        let count = html.components(separatedBy: #"class="wtmd-math""#).count - 1
        #expect(count == 3)
    }

    @Test func mathInHeadingAndQuote() {
        let r = WTMarkdown.render("# 关于 $\\pi$\n\n> 半径 $r$ 的圆")
        #expect(r.html.contains("<h1 id=\"关于-pi\">关于 <span class=\"wtmd-math\""))
        #expect(r.html.contains(">半径 <span class=\"wtmd-math\""))
    }

    @Test func escapedDollarStaysLiteral() {
        let html = WTMarkdown.render("转义的 \\$100 不成公式").html
        #expect(!html.contains("wtmd-math"))
    }
}
