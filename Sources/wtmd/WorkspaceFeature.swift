import Foundation

/// 产品范围开关：文件夹工作区暂时不对外。
///
/// 0.15.48 起产品收回到「打开一篇 → 编辑 / 阅读」这一件事上。工作区的实现
/// （扫描、树、监视、全文搜索、文件操作）一行没删，菜单与侧栏的结构也原样
/// 留着；只是 `CommandCatalog` 不再给出那几条命令，界面于是看不到入口，
/// ⌘⇧O / ⇧⌘F 也没有菜单项可以派发。
///
/// 要恢复：把 `isAvailable` 改回 `true`。所有入口都读这一个值——目录、侧栏、
/// 工具栏、欢迎页、启动恢复——没有第二处需要动。
enum WorkspaceFeature {
    /// 打开文件夹 / 搜索工作区 / 解除工作区：三个入口一起收起来。
    static let isAvailable = false

    /// 目录里藏起来的命令。菜单源码里仍写着它们（`AppMenus` 一字未动）：
    /// `CommandCatalog.command(for:)` 查不到定义，`menuItem` 就渲染成空，
    /// 键位也不会注册；设置里的改派表同样跟着目录走，自动少掉这几条。
    static var hiddenCommands: Set<CommandKind> {
        isAvailable ? [] : [.openFolder, .searchWorkspace, .closeWorkspace]
    }

    /// 启动时要不要把上次那间书房扫回来。
    ///
    /// 隐藏期间不扫：树没有地方摆，白扫一遍还要给每个目录挂一个 watcher。
    /// 会话里的根**不清**——以后重新打开这个开关，上次的书房还在。
    static var restoresOnLaunch: Bool { isAvailable }
}
