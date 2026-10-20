import AppKit

/// 预览的右键菜单。
///
/// 预览是一块 `WKWebView`，右键菜单由 WebKit 自己弹——它不走 `NSView.menu(for:)`，
/// 所以覆写那个方法拦不住（实测：菜单照弹，覆写根本没被调用）。能挂钩的只有
/// 「菜单开始跟踪」这条通知：`NSMenu` 收到它时项目已经填好，还能改。
///
/// 要拦的是空白处那一种：整份菜单只有一项「重新载入」，点了会把这篇文档的 DOM
/// 整个重建——滚动位置、图表、增量更新的基准一起丢。右键点在没有可操作对象的地方，
/// 本来就不该弹菜单，所以直接撤掉。选中文字、点在链接上时 WebKit 给的是
/// 「查询 / 翻译 / 拷贝 / 共享」那一套，一项不动。
@MainActor
enum PreviewContextMenu {
    private static var observer: NSObjectProtocol?

    /// 装没装过。菜单通知是全应用范围的，装多了等于同一份菜单被撤好几次。
    static var isInstalled: Bool { observer != nil }

    /// 只装一次。
    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                guard isBareReloadMenu(menu) else { return }
                // 这条通知发出来时菜单还没进跟踪循环，当场 cancelTracking 不生效
                //（实测：撤不掉，菜单照旧挡在那儿）。下一拍再撤，那时循环已经转起来了。
                DispatchQueue.main.async { menu.cancelTracking() }
            }
        }
    }

    /// 「空白处那一份」的判据：除分隔线外只剩一项，没有子菜单，动作是 WebKit
    /// 转给网页进程的 `forwardContextMenuAction:`。
    ///
    /// 按 selector 认而不是按标题：标题随系统语言变（英文 Reload、中文「重新载入」），
    /// selector 不变。选中文字时那份菜单同样用这个 selector，但项目多得多，所以
    /// 「只剩一项」这条把它排除在外。
    static func isBareReloadMenu(_ menu: NSMenu) -> Bool {
        let items = menu.items.filter { !$0.isSeparatorItem }
        guard items.count == 1, let item = items.first, item.submenu == nil else { return false }
        guard let action = item.action else { return false }
        return NSStringFromSelector(action) == "forwardContextMenuAction:"
    }
}
