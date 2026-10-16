import Foundation

/// 块级 HTML diff：前后缀对齐，只重发中间变化段。
///
/// 渲染器把文档渲染为块 HTML 数组；编辑发生后对比新旧数组，
/// 相同的前缀块与后缀块在 WebView 中保持原位（不重画图片/图表），
/// 只替换中间变化段的 innerHTML。
public struct BlockDiff: Equatable, Sendable {
    /// 前缀相同块数（保留不动）。
    public let commonPrefix: Int
    /// 后缀相同块数（保留不动）。
    public let commonSuffix: Int
    /// 变化段的新块 HTML（旧块数 = 旧总数 - 前后缀）。
    public let replacement: [String]

    /// 是否完全没有变化。
    public var isEmpty: Bool { replacement.isEmpty }

    /// 对比新旧块数组。全同时 replacement 为空。
    public static func compute(old: [String], new: [String]) -> BlockDiff {
        // 前缀对齐
        var prefix = 0
        let maxPrefix = min(old.count, new.count)
        while prefix < maxPrefix, old[prefix] == new[prefix] {
            prefix += 1
        }

        // 后缀对齐（不与前缀重叠）
        var suffix = 0
        let maxSuffix = min(old.count - prefix, new.count - prefix)
        while suffix < maxSuffix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        let replacement = Array(new[prefix ..< new.count - suffix])
        return BlockDiff(
            commonPrefix: prefix,
            commonSuffix: suffix,
            replacement: replacement
        )
    }
}

extension WTMarkdown {
    /// 渲染为顶层块 HTML 数组（供增量更新逐块替换）。
    /// 每个元素是一个顶层块级元素的完整 HTML；脚注区块（如有）为最后一个元素。
    /// 复用 `render` 的单次解析结果，不额外解析。
    public static func renderBlocks(_ markdown: String) -> [String] {
        render(markdown).blocks
    }
}
