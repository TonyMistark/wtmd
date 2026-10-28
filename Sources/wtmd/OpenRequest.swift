import AppKit
import Foundation

/// Finder 的「打开方式」、把文件拖到 Dock 图标、`open -a wtmd note.md`——都从这里进来。
///
/// 系统以前为什么不列 wtmd：`Info.plist` 里没有 `CFBundleDocumentTypes`，
/// LaunchServices 根本不知道它能打开 `.md`，右键菜单自然找不到它。声明类型之后，
/// 文件会交到 `AppDelegate.application(_:open:)`，剩下的问题是「交给哪扇窗」。
@MainActor
enum OpenRequest {
    /// 窗口表。`wtmdApp` 起来时装进来——它活得比任何一扇窗都久。
    static weak var coordinator: WindowCoordinator?

    /// 系统投递来的一批文件（Finder 里多选打开时一次好几个）。
    static func open(_ urls: [URL]) {
        // 文件夹（系统也能把目录投过来）没有可编辑的正文，交给 `readDocument`
        // 只会静默失败；这里先筛掉，别让它占掉一扇窗。
        let files = urls.filter(isEditableFile)
        guard !files.isEmpty, let coordinator else { return }

        // 先把人叫回来：从 Finder 打开文件，窗口得在眼前。
        NSApplication.shared.activate(ignoringOtherApps: true)
        // 这次启动是「带着文件来」的明确意图：上次的桌面别抢戏。
        // 启动时的桌面恢复发生在这之后（窗口视图报到才摆），这里先按住暂停键；
        // 应用本来就在跑的场合账本早就摆完了，置位无副作用。
        coordinator.suppressRestoration = true
        // 一扇看得见的写作窗都没有（⌘W 关光、后台启动、系统还在恢复现场）：
        // 先摆一扇出来，否则文件打开了也没人看得见。
        //
        // 但**存在的窗**不能算没有：刚启动时主窗已经建好、只是还没露脸，
        // 这时候再 `openWindow(id:)` 会多开一个 `WindowGroup` 实例——屏幕上
        // 一扇空欢迎页、一扇有稿子，看起来像「打开一个文件却开了两个窗」。
        let windows = NSApplication.shared.windows
        let keyable = windows.filter { !($0 is NSPanel) && $0.canBecomeKey }
        let raised = AppActivation.raiseFrontWindow()
        CrashBreadcrumbs.note(
            "open files=\(files.count) windows=\(windows.count) keyable=\(keyable.count) raised=\(raised)"
        )
        if !raised, keyable.isEmpty {
            AppActivation.openMain?()
        }

        for (index, url) in files.enumerated() {
            let current = coordinator.activeModel(focused: nil)
            // 语境按前台窗算：同一篇文件，装进工作区窗是工作区语境，装进单独
            // 窗是单独语境。占主查询只认同语境——跨语境允许各开一扇。
            let route = plan(
                index: index,
                sameDocumentAlreadyOpen: current.store.fileURL.map {
                    PathKey.isSame($0, url)
                } ?? false,
                frontWindowHoldsUnnamedWords: current.holdsUnnamedWords,
                owner: coordinator.shared.openDocuments.owner(
                    of: url, in: current.claimContext(for: url)
                )
            )
            CrashBreadcrumbs.note("open route=\(route)")
            switch route {
            case .leaveAsIs:
                break
            case .reveal(let window):
                // 这篇在别的窗里开着：跳过去，不再开第二份（两窗各写一份，
                // 谁后落盘谁赢）。占主已是幽灵（表里有、窗口没了）就开一扇
                // 新的，别让文件落空。
                if !coordinator.revealDocument(window, url: url, jumpingTo: nil) {
                    openInFreshWindowOrCurrent(url, coordinator: coordinator, current: current)
                }
            case .reuseCurrent:
                current.store.open(url: url)
            case .newWindow:
                openInFreshWindowOrCurrent(url, coordinator: coordinator, current: current)
            }
        }
    }

    /// 开一扇新窗装这篇；开窗通道还没装好（启动早期）就装进当前窗，
    /// 总比什么都不做强。
    private static func openInFreshWindowOrCurrent(
        _ url: URL, coordinator: WindowCoordinator, current: WindowModel
    ) {
        if let id = coordinator.openNewWindow(inheriting: nil),
           let model = coordinator.model(for: id) {
            model.store.open(url: url)
        } else {
            current.store.open(url: url)
        }
    }

    /// 一篇文件该往哪儿放。
    enum Plan: Equatable {
        /// 这篇在前台窗里已经开着：什么也不用做。
        case leaveAsIs
        /// 前台窗里装下这篇（Obsidian 式默认：文件进当前窗，不多开）。
        case reuseCurrent
        /// 前台窗还欠着没名字的字：另开一扇，别把没保存的稿子顶掉。
        case newWindow
        /// 这篇在另一扇窗里开着：把那扇窗带到前面。
        case reveal(UUID)
    }

    /// 只收真的能编辑的文件：目录、失效的路径都筛掉。
    static func isEditableFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    /// 抽成纯函数：测试不必真开窗，也不必造一整个 `NSApplication`。
    ///
    /// - Parameters:
    ///   - index: 这一批里的第几篇。只有第一篇配占用现成的前台窗。
    ///   - sameDocumentAlreadyOpen: 前台窗此刻开着的就是这篇。
    ///   - frontWindowHoldsUnnamedWords: 前台窗里欠着一篇没名字的稿——那些字
    ///     只在草稿里，被一个文件顶掉就真没了。
    ///   - owner: 这篇正被哪扇窗以**同一种语境**占着（`OpenDocuments` 的答案；
    ///     跨语境的占主——工作区窗 vs 单独窗——在查询那一步就被排除了）。
    static func plan(
        index: Int,
        sameDocumentAlreadyOpen: Bool,
        frontWindowHoldsUnnamedWords: Bool,
        owner: UUID?
    ) -> Plan {
        if sameDocumentAlreadyOpen { return .leaveAsIs }
        if let owner { return .reveal(owner) }
        // Obsidian 式默认：第一篇装进前台窗，不为它另开一扇。正在写的那篇
        // 已经在盘上，换稿之前会先落盘，字不会丢。
        if index == 0, !frontWindowHoldsUnnamedWords { return .reuseCurrent }
        // 多选打开时第二篇起各开一扇，否则后一篇会把前一篇顶掉。
        return .newWindow
    }
}
