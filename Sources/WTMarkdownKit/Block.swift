import Foundation

/// 表格列对齐方式。
public enum TableAlignment: String, Equatable, Sendable {
    case none, left, center, right
}

/// 任务列表项勾选状态。
public enum TaskState: String, Equatable, Sendable {
    case checked, unchecked
}

/// 列表项。
public struct ListItem: Equatable, Sendable {
    public var blocks: [Block]
    public var taskState: TaskState?

    public init(blocks: [Block], taskState: TaskState? = nil) {
        self.blocks = blocks
        self.taskState = taskState
    }
}

/// 脚注定义：id 与原文（渲染时统一编号）。
public struct Footnote: Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// 文档块级结构（轻量 AST）。
public indirect enum Block: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case quote([Block])
    case list(ordered: Bool, start: Int, items: [ListItem])
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    case divider
}

/// 大纲条目：与渲染后的标题锚点一一对应。
public struct OutlineItem: Equatable, Identifiable, Sendable {
    public var id: String { slug }
    public let level: Int
    public let text: String
    public let slug: String
    /// 标题在源码中的行号（0-based）。
    public let line: Int

    public init(level: Int, text: String, slug: String, line: Int) {
        self.level = level
        self.text = text
        self.slug = slug
        self.line = line
    }
}

/// 渲染结果：HTML 正文（含脚注区块，如有）+ 大纲。
public struct RenderResult: Sendable {
    public let html: String
    public let outline: [OutlineItem]
}
