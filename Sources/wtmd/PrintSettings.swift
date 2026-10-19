import CoreGraphics
import Foundation

/// 纸上的版式：页边距、页码、首行标题。
///
/// 抽成值类型而不是只留一个 `ObservableObject`：打印这件事发生在后台，
/// 拿到一份快照就够了，也让 CSS 生成与页码编号可以直接被测试。
struct PrintLayout: Equatable {
    /// 页边距（毫米）。四周一样宽——写作者的稿纸就是这样，不需要四个方向各调一次。
    var marginMM: Double
    /// 右下角印 `3 / 12`。
    var pageNumbers: Bool
    /// 第一页顶部印文档名。
    var showTitle: Bool

    static let marginRange: ClosedRange<Double> = 10...35
    static let defaultMarginMM: Double = 18
    static let standard = PrintLayout(
        marginMM: defaultMarginMM,
        pageNumbers: true,
        showTitle: false
    )

    init(marginMM: Double, pageNumbers: Bool, showTitle: Bool) {
        self.marginMM = Self.clamp(marginMM)
        self.pageNumbers = pageNumbers
        self.showTitle = showTitle
    }

    /// 越界值收敛回区间：手改过的 defaults、旧版本遗留值都不该把版面撑坏。
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMarginMM }
        return min(max(value, marginRange.lowerBound), marginRange.upperBound)
    }

    /// 毫米 → PostScript 点（1 pt = 1/72 英寸）。NSPrintInfo 与 PDF 都用点。
    var marginPoints: CGFloat {
        CGFloat(Self.clamp(marginMM) * 72.0 / 25.4)
    }

    /// 页码文本。`3 / 12`——只给「第 3 页」读者不知道自己还有多远。
    func pageLabel(index: Int, total: Int) -> String {
        "\(max(1, index)) / \(max(1, total))"
    }
}

/// 打印设置（持久化）。与写作/版式设置同一套写法：defaults 可注入，测试不碰真实偏好。
@MainActor
final class PrintSettings: ObservableObject {
    private enum Key {
        static let margin = "wtmd.print.marginMM"
        static let pageNumbers = "wtmd.print.pageNumbers"
        static let title = "wtmd.print.showTitle"
    }

    private let defaults: UserDefaults

    @Published var marginMM: Double {
        didSet { defaults.set(marginMM, forKey: Key.margin) }
    }

    @Published var pageNumbers: Bool {
        didSet { defaults.set(pageNumbers, forKey: Key.pageNumbers) }
    }

    @Published var showTitle: Bool {
        didSet { defaults.set(showTitle, forKey: Key.title) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 0 表示「没存过」——默认 18mm，不是 0mm
        let stored = defaults.double(forKey: Key.margin)
        marginMM = PrintLayout.clamp(stored == 0 ? PrintLayout.defaultMarginMM : stored)
        // 布尔值要用 object(forKey:) 才分得清「没存过」和「存了 false」
        pageNumbers = defaults.object(forKey: Key.pageNumbers) as? Bool ?? true
        showTitle = defaults.object(forKey: Key.title) as? Bool ?? false
    }

    var layout: PrintLayout {
        PrintLayout(marginMM: marginMM, pageNumbers: pageNumbers, showTitle: showTitle)
    }

    func reset() {
        marginMM = PrintLayout.defaultMarginMM
        pageNumbers = true
        showTitle = false
    }
}
