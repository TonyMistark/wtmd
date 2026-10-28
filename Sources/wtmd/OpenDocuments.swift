import Foundation

/// The app-wide answer to "which window has this document open".
///
/// 多窗口之后同一篇稿子可以被两扇窗各开一份：两边都在写，谁后落盘谁赢，
/// 另一边刚敲的字无声消失。这张表记的是「哪扇窗以哪种语境开着哪一篇」，
/// 让第二个想打开同一篇的窗口改为「跳过去」，而不是再开一份。
///
/// **语境**：一扇窗以「工作区方式」开着某篇（文件在它的工作区根之下），
/// 语境记工作区根；单独打开的记 `nil`。同语境同文件只许一扇窗——重复打开
/// 一律跳过去；跨语境（工作区窗 vs 单独窗）是两种打开方式，允许各开一扇。
///
/// 比较一律走 `PathKey`：同一份文件可能被拼成 `/var/…` 与 `/private/var/…`。
@MainActor
final class OpenDocuments {
    /// One window's hold on a document: the canonical path plus the context
    /// it was opened in (`nil` = standalone).
    private struct Claim: Equatable {
        let path: String
        let context: String?
    }

    /// 窗口 id → 占位。窗口最多几张，线性查找足够。
    private var open: [UUID: Claim] = [:]

    /// 把一篇已经被别窗占着的稿子亮出来。由 `WindowCoordinator` 接上——
    /// 只有它知道窗口在哪、怎么带到前面。返回 `false` 表示那扇窗已经找不到了
    /// （表里的幽灵记录），调用方应当自己把文件开起来。
    var reveal: ((UUID, URL, JumpRequest?) -> Bool)?

    /// 这扇窗此刻还算不算「开着」。主窗 ⌘W 关掉后模型还在（会话要留给下次
    /// 启动），可它已经占不住这篇稿子了；由协调器按真实的 `NSWindow` 回答。
    /// `nil`（测试默认）表示都算开着。
    var isReachable: ((UUID) -> Bool)?

    /// 登记这扇窗开着哪一篇、以什么语境。`url == nil` 表示未命名稿，不占位。
    func update(_ url: URL?, context: String? = nil, for window: UUID) {
        guard let url else {
            open[window] = nil
            return
        }
        open[window] = Claim(path: PathKey.canonical(url), context: context)
    }

    func release(_ window: UUID) {
        open[window] = nil
    }

    /// 这篇在谁手里（同语境才算）。已经够不着的窗口（关掉的）不算。
    func owner(of url: URL, in context: String? = nil) -> UUID? {
        let key = PathKey.canonical(url)
        return open.first { entry in
            entry.value.path == key
                && entry.value.context == context
                && (isReachable?(entry.key) ?? true)
        }?.key
    }

    /// 这篇在**别的**窗里以同样的语境开着吗？开着就交出去（带到前面，必要时
    /// 落到行列）。跨语境的占主不打扰——工作区窗和单独窗允许各开一份。
    ///
    /// - Returns: `true` 表示已经交给那扇窗，调用方不要再打开。
    @discardableResult
    func handOver(
        _ url: URL, jumpingTo request: JumpRequest?, from window: UUID,
        in context: String? = nil
    ) -> Bool {
        guard let owner = owner(of: url, in: context), owner != window else { return false }
        // 找到了占主却亮不出窗（幽灵记录）：就当没交出去，调用方自己开。
        return reveal?(owner, url, request) ?? true
    }

    /// 这篇在**另一扇**窗里开着吗？
    ///
    /// 与 `owner` 分开写：那个问的是「谁占着」（可能是自己），这个问的是
    /// 「有没有第二个人」。写盘的检查只关心后者，所以不能先取一个 owner 再比——
    /// 两扇窗都登记着同一篇时，`owner` 取到哪一个全看字典顺序。
    func isHeldElsewhere(_ url: URL, than window: UUID) -> Bool {
        let key = PathKey.canonical(url)
        return open.contains { entry in
            entry.key != window
                && entry.value.path == key
                && (isReachable?(entry.key) ?? true)
        }
    }

    /// 排障与测试：此刻登记着哪几扇窗。字典无语序，比较请用集合。
    var registeredWindows: Set<UUID> { Set(open.keys) }
}
