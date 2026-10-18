import Foundation

/// 读者的版式：一页放多少字、字多大、行多松。
///
/// 这三件事从 v0.1 起就写死在样式表里，主题只能换颜色与字体栈——读者把窗口拉宽，
/// 正文只是两边多出空白。这里把它们提成三个可调的值，经 CSS 变量交给预览层：
/// `--wtmd-measure` / `--wtmd-font-size` / `--wtmd-line-height`。
///
/// A separate `<style id="wtmd-layout">` layer means switching themes can never
/// wipe the reader's layout, and vice versa. Stored in UserDefaults; the store
/// is injectable so tests never touch the real preferences.
@MainActor
final class TypesettingSettings: ObservableObject {
    enum Limits {
        static let measure = 480...1_100
        static let fontSize = 14...22
        static let lineHeight = 1.4...2.2
    }

    /// 立项时预览使用的就是这三个数：恢复默认 = 回到 v0.8 的样子。
    enum Standard {
        static let measure = 760
        static let fontSize = 16
        static let lineHeight = 1.75
    }

    private enum Key {
        static let measure = "wtmd.typeset.measure"
        static let fontSize = "wtmd.typeset.fontSize"
        static let lineHeight = "wtmd.typeset.lineHeight"
    }

    private let defaults: UserDefaults

    /// 版心宽度（px）：正文一行的最大宽度。
    @Published var measure: Int {
        didSet { defaults.set(measure, forKey: Key.measure) }
    }

    /// 正文字号（px）。标题是 em 相对单位，会跟着一起缩放。
    @Published var fontSize: Int {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    /// 行距倍数。
    @Published var lineHeight: Double {
        didSet { defaults.set(lineHeight, forKey: Key.lineHeight) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        measure = defaults.object(forKey: Key.measure) as? Int ?? Standard.measure
        fontSize = defaults.object(forKey: Key.fontSize) as? Int ?? Standard.fontSize
        lineHeight = defaults.object(forKey: Key.lineHeight) as? Double ?? Standard.lineHeight
    }

    /// 注入预览的变量层。越界值在这里收敛——界面只给区间，但记忆里的旧值、
    /// 手改过的 defaults 不该把版面撑坏。
    var css: String {
        """
        :root {
          --wtmd-measure: \(Self.clamp(measure, to: Limits.measure))px;
          --wtmd-font-size: \(Self.clamp(fontSize, to: Limits.fontSize))px;
          --wtmd-line-height: \(String(format: "%.2f", Self.clamp(lineHeight, to: Limits.lineHeight)));
        }
        """
    }

    /// 回到立项时的样子。
    func reset() {
        measure = Standard.measure
        fontSize = Standard.fontSize
        lineHeight = Standard.lineHeight
    }

    nonisolated static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    nonisolated static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
