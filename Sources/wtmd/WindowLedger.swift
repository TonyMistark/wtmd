import CoreGraphics
import Foundation

/// What was on the desk when the app last quit: one entry per window beyond the
/// first, with where it stood and whether it is holding an unnamed draft.
///
/// 系统的窗口恢复只认「上一次那一扇」：多窗口要自己记账。没有这本账，第二扇窗
/// 退出即消失——稿子还在 `windows/<id>/draft.md` 里，却再没有入口打开它。
///
/// 存在一个键下的 JSON 数组而不是散装的 defaults 键：这本账要么整本读对，
/// 要么当它不存在（版本不合、文件损坏都走这一条），不会读出半本。
final class WindowLedger {
    struct Entry: Codable, Equatable {
        let id: UUID
        /// 上一次退出时窗口的外框。`nil` 表示还没量过（刚开就退）。
        var frame: Frame?
        /// 关窗时留下的一篇无名稿：下次启动把它放回原处，再关一次才真的关掉。
        var parked = false
    }

    struct Frame: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

        /// 这块地方现在还在屏幕上吗？
        ///
        /// 拔掉外接屏以后，记下来的坐标会落在不复存在的区域里——照原样摆回去，
        /// 那扇窗就永远待在看不见的地方。判定要求**足够大的一块重叠**，不是
        /// 擦到个边就算：只露出两三个像素的窗口和丢失没有区别。
        func fits(in screens: [CGRect]) -> Bool {
            guard width >= Self.minimumSize.width, height >= Self.minimumSize.height else {
                return false
            }
            return screens.contains { screen in
                let overlap = screen.intersection(rect)
                return !overlap.isNull
                    && overlap.width >= Self.minimumOverlap.width
                    && overlap.height >= Self.minimumOverlap.height
            }
        }

        static let minimumSize = CGSize(width: 400, height: 300)
        static let minimumOverlap = CGSize(width: 120, height: 80)
    }

    static let key = "wtmd.windows.v1"

    private let defaults: UserDefaults
    private(set) var entries: [Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            // 同一扇窗只该有一条：重复的 id 会让它开两次、关两次。
            var seen = Set<UUID>()
            entries = decoded.filter { seen.insert($0.id).inserted }
        } else {
            entries = []
        }
    }

    var ids: [UUID] { entries.map(\.id) }

    func entry(for id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// 记下一扇新窗。已经记过的保留原样（位置、留一手）。
    func add(_ id: UUID, frame: CGRect? = nil) {
        if let index = index(of: id) {
            if let frame { entries[index].frame = Frame(frame) }
        } else {
            entries.append(Entry(id: id, frame: frame.map(Frame.init)))
        }
        flush()
    }

    func remove(_ id: UUID) {
        guard let index = index(of: id) else { return }
        entries.remove(at: index)
        flush()
    }

    func setFrame(_ frame: CGRect, for id: UUID) {
        guard let index = index(of: id) else { return }
        let record = Frame(frame)
        guard entries[index].frame != record else { return }
        entries[index].frame = record
        flush()
    }

    func setParked(_ parked: Bool, for id: UUID) {
        guard let index = index(of: id) else { return }
        guard entries[index].parked != parked else { return }
        entries[index].parked = parked
        flush()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        flush()
    }

    private func index(of id: UUID) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    private func flush() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
