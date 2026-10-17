import CoreGraphics

/// 分栏的排版决策。抽成纯函数，好让「窄窗口降级」这条规则能被测试。
enum SplitLayout {
    /// 内容区（去掉侧栏之后）至少要这么宽才分栏：两栏各 320pt 上下，
    /// 源码不至于每行折成三四段，预览的版心也还立得住。
    static let minimumContentWidth: CGFloat = 640

    static func showsTwoPanes(contentWidth: CGFloat) -> Bool {
        contentWidth >= minimumContentWidth
    }
}
