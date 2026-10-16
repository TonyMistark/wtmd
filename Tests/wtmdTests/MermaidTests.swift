import Foundation
import Testing
@testable import wtmd

// MARK: - 内嵌 mermaid 资源

@Test func mermaidAssetIsBundled() {
    // 本地内嵌而非 CDN：离线可用、内容不外泄
    #expect(!WebAssets.mermaidJS.isEmpty)
    #expect(WebAssets.mermaidJS.contains("mermaid v11"))
    #expect(WebAssets.mermaidJS.contains("MIT License"))
}

@Test func mermaidScriptCarriesHooksAndReadySignal() {
    let script = StyleSheet.mermaidScript
    #expect(script.contains("__wtmdMermaidRenderAll"))
    #expect(script.contains("__wtmdMermaidThemeVariables"))
    // 打印/存 PDF 的花式时序依赖这个就绪信号
    #expect(script.contains("'mermaid-ready'"))
    // 失败降级：保留源码块 + 错误提示，不白屏
    #expect(script.contains("mermaid-failed"))
    #expect(script.contains("图表渲染失败"))
}

@Test func mermaidFailurePathCleansUpStrayNodes() {
    let script = StyleSheet.mermaidScript
    // mermaid 解析失败会往 document.body 追加 <div id="d{id}"> 的错误 SVG，
    // 落在 #wtmd-content 之外就是文末一个可见脏块 —— 成功/失败两条路径都要清理
    #expect(script.contains("function __wtmdMermaidPurge(id)"))
    #expect(script.components(separatedBy: "__wtmdMermaidPurge(id);").count - 1 == 2)
    // 失败且源码未变的块不再重试（否则每次切主题都会再失败一次、再漏一份）
    #expect(script.contains("data-wtmd-src"))
    #expect(script.contains("mermaid-failed') &&"))
    // 多行的解析诊断压成单行，完整内容挂 title
    #expect(script.contains("note.title = full"))
}

// MARK: - 装配：按需注入

@Test func mermaidInjectedOnlyWhenDocumentHasGraphs() {
    let plain = StyleSheet.fullDocument(
        title: "t",
        body: "<pre><code class=\"language-swift\">let x = 1</code></pre>",
        themeCSS: ":root{}",
        includeScript: true
    )
    let withGraph = StyleSheet.fullDocument(
        title: "t",
        body: "<pre><code class=\"language-mermaid\">graph TD;A-->B;</code></pre>",
        themeCSS: ":root{}",
        includeScript: true
    )

    // 无图表：不携带 2.7MB 的库（懒加载）——交互脚本里只有受 typeof 保护的钩子，没有库本体
    #expect(!plain.contains("mermaid v11"))
    #expect(!plain.contains("__wtmdMermaidThemeVariables"))
    #expect(plain.count < 400_000)

    // 有图表：库与初始化一并注入
    #expect(withGraph.contains("mermaid v11"))
    #expect(withGraph.contains("__wtmdMermaidThemeVariables"))
    #expect(withGraph.contains("language-mermaid"))
    #expect(withGraph.contains("mermaid-wrap"))
}

@Test func mermaidInlinedInStaticExportToo() {
    // 导出的独立 HTML 也要能出图（不含交互脚本）
    for includeScript in [true, false] {
        let doc = StyleSheet.fullDocument(
            title: "t",
            body: "<pre><code class=\"language-mermaid\">graph TD;A-->B;</code></pre>",
            themeCSS: ":root{}",
            includeScript: includeScript
        )
        #expect(doc.contains("__wtmdMermaidRenderAll"))
        // 库本体 + 初始化都在（仅此一处），且脚本标签成对闭合
        #expect(doc.components(separatedBy: "mermaid v11").count == 2)
        #expect(doc.components(separatedBy: "<script>").count == doc.components(separatedBy: "</script>").count)
        #expect(doc.contains("</script>\n</head>"))
    }
}

@Test func baseCSSDefinesGraphStates() {
    for rule in [".mermaid-wrap", ".mermaid-rendered", ".mermaid-failed", ".mermaid-error"] {
        #expect(StyleSheet.baseCSS.contains(rule), "基础样式缺少规则：\(rule)")
    }
}
