import Foundation

/// 一次「跟着滚到第几行」的请求。
///
/// 带自增 `id` 而不是直接传行号：同一行可能被连续请求两次（读者先滚开再滚回来），
/// 而视图重建（`⌘/`、窄窗降级）会把旧请求重新交到新视图手上——不带 id 就分不清
/// 「这是一个新请求」还是「上次那个还没处理完」。
struct SplitScrollRequest: Equatable {
    var id: Int
    var line: Int
}

/// 分栏联动里「谁在动」的判权。
///
/// 联动天然会回声：源码把预览滚过去 → 预览的滚动事件回报 → 又想把源码滚回去。
/// 所以一边驱动另一边之后，短暂时间内另一边的回报一律当作回声丢掉；窗口一过，
/// 读者真的去滚另一边了，控制权就归它。
struct SyncScrollState {
    enum Source: Equatable {
        case editor
        case preview
    }

    /// 静默窗口。短到不影响「换个地方读」，长到足够吞掉一次滚动动画的尾巴。
    static let hold: TimeInterval = 0.5

    private(set) var owner: Source?
    private var ownerSince: TimeInterval = 0

    /// 这次来自 `source` 的移动算不算数。算数就把它记为当前控制方。
    mutating func accept(_ source: Source, at now: TimeInterval) -> Bool {
        if let owner, owner != source, now - ownerSince < Self.hold {
            return false
        }
        owner = source
        ownerSince = now
        return true
    }

    mutating func reset() {
        owner = nil
        ownerSince = 0
    }
}

/// 把「哪一侧动了、动到第几行」翻译成两条滚动请求。
///
/// 只在分栏（`⌘⇧\`）里启用：单栏编辑时预览根本不在屏幕上，让它拽着源码走
/// 是纯粹的打扰；单栏预览时同理。
@MainActor
final class SplitSyncController: ObservableObject {
    /// 让预览滚到某一行。
    @Published private(set) var previewScroll: SplitScrollRequest?
    /// 让源码滚到某一行（不改光标、不抢焦点）。
    @Published private(set) var editorReveal: SplitScrollRequest?

    /// 分栏是否在场。退出分栏立刻清空——否则切回来会重放上一个位置。
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            reset()
        }
    }

    private var state = SyncScrollState()
    private var counter = 0
    /// 上次推过去的行号。同一次停留不必反复触发（滚动事件是每帧的）。
    private var lastPreviewLine = -1
    private var lastEditorLine = -1
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// 源码侧动了（光标换行、点击、打字）。
    func editorMoved(to line: Int) {
        guard isActive, line >= 0 else { return }
        guard state.accept(.editor, at: now()) else { return }
        guard line != lastPreviewLine else { return }
        lastPreviewLine = line
        counter += 1
        previewScroll = SplitScrollRequest(id: counter, line: line)
    }

    /// 预览侧动了（读者滚到了别处）。
    func previewMoved(to line: Int) {
        guard isActive, line >= 0 else { return }
        guard state.accept(.preview, at: now()) else { return }
        guard line != lastEditorLine else { return }
        lastEditorLine = line
        counter += 1
        editorReveal = SplitScrollRequest(id: counter, line: line)
    }

    private func reset() {
        state.reset()
        lastPreviewLine = -1
        lastEditorLine = -1
        previewScroll = nil
        editorReveal = nil
    }
}
