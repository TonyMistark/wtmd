import Foundation
import Testing
@testable import wtmd

// MARK: - 内嵌高亮资源（离线可用）

@Test func highlightAssetIsBundled() {
    // 本地内嵌而非 CDN：资源必须随构建产物分发，打开即用、不联网
    #expect(!WebAssets.highlightJS.isEmpty)
    // 版权与许可声明随文件保留（BSD-3-Clause）
    #expect(WebAssets.highlightJS.contains("Highlight.js"))
    #expect(WebAssets.highlightJS.contains("BSD-3-Clause"))
}

@Test func highlightScriptCoversRequestedLanguages() {
    let script = StyleSheet.highlightScript
    #expect(script.contains("__wtmdHighlight"))
    // issue #7 点名的语言子集须在库内可解析
    for language in ["swift", "kotlin", "typescript", "python", "go", "rust",
                     "cpp", "java", "json", "yaml", "bash", "sql"] {
        #expect(script.contains(language), "高亮库缺少语言：\(language)")
    }
}

// MARK: - 文档装配

@Test func highlightScriptInlinedOnceForBothModes() {
    for includeScript in [true, false] {
        let doc = StyleSheet.fullDocument(
            title: "t",
            body: "<pre><code class=\"language-swift\">let x = 1</code></pre>",
            themeCSS: ":root{}",
            includeScript: includeScript
        )
        // 预览与导出都自带高亮，正文与语言标记原样保留
        #expect(doc.contains("__wtmdHighlight"))
        #expect(doc.contains("language-swift"))
        #expect(doc.components(separatedBy: "BSD-3-Clause").count == 2)
    }
}

@Test func baseCSSDefinesTokenColors() {
    // 配色走主题变量派生，不引入额外主题文件
    for rule in [".hljs-keyword", ".hljs-string", ".hljs-comment", ".hljs-number", ".hljs-type"] {
        #expect(StyleSheet.baseCSS.contains(rule), "基础样式缺少规则：\(rule)")
    }
    #expect(StyleSheet.baseCSS.contains("--hl-keyword"))
}
