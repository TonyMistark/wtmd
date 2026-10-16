import Foundation

/// 本地内嵌的前端渲染资源。
///
/// 这些资源随源码仓库分发、运行时从构建产物内读取——不是 CDN、不联网，
/// 因而离线可用且不外泄任何内容。「零第三方依赖」指的是不引入 Swift 包依赖，
/// 前端渲染资源本地内嵌不违反该原则（见 docs/V02_PLAN.md P0-4 的同一决策）。
enum WebAssets {
    /// highlight.js v11.11.1 常用语言子集（36 种：swift/kotlin/ts/go/rust/cpp/sql/yaml…）。
    /// 许可：BSD-3-Clause，版权声明保留在文件头。
    static let highlightJS: String = load(name: "highlight.min", ext: "js")

    /// mermaid v11.12.0（流程图/时序图等）。
    /// 许可：MIT，版本与许可声明写在文件头。
    /// 体积较大（~2.7MB），仅在文档确实含 mermaid 围栏时才注入。
    static let mermaidJS: String = load(name: "mermaid.min", ext: "js")

    /// 读取资源；缺失时返回空串（预览退化为无高亮，不影响正文渲染）。
    private static func load(name: String, ext: String) -> String {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Resources"
        ) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
