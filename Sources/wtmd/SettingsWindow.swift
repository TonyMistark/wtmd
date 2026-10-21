import AppKit
import Foundation
import SwiftUI

// MARK: - 一页

/// 设置窗口里的页。左侧导航按 `group` 分类，右侧显示选中的那一页。
///
/// `rawValue` 是写进 `UserDefaults` 的东西：改一个字，读者上次停在哪一页就丢了。
/// 新增的 `profile` / `app` 排在末尾——老值照旧读得出来。
enum SettingsTab: String, CaseIterable, Identifiable {
    case profile
    case writing
    case theme
    case layout
    case printing
    case shortcuts
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return t("Profile", "个人信息")
        case .writing: return t("Writing", "写作")
        case .theme: return t("Theme", "主题")
        case .layout: return t("Layout", "版式")
        case .printing: return t("Printing", "打印")
        case .shortcuts: return t("Shortcuts", "快捷键")
        case .app: return t("App", "应用")
        }
    }

    var symbol: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .writing: return "character.cursor.ibeam"
        case .theme: return "paintpalette"
        case .layout: return "text.alignleft"
        case .printing: return "printer"
        case .shortcuts: return "keyboard"
        case .app: return "shippingbox"
        }
    }

    /// 左侧的分组。个人信息不在这三组里——它是顶部那一块账户区。
    var group: SettingsGroup {
        switch self {
        case .profile: return .profile
        case .writing: return .writing
        case .theme, .layout, .printing: return .appearance
        case .shortcuts, .app: return .app
        }
    }

    /// `UserDefaults` 里的键名。第一次打开落在「个人信息」——那是列表的第一行，
    /// 也是唯一一处能改「我是谁」的地方。
    static let storageKey = "wtmd.settings.tab"
    static let fallback: SettingsTab = .profile
}

/// 左侧导航的分类。顺序即界面上从上到下的顺序。
enum SettingsGroup: String, CaseIterable, Identifiable {
    case profile
    case writing
    case appearance
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return t("Profile", "个人")
        case .writing: return t("Writing", "写作")
        case .appearance: return t("Appearance", "外观")
        case .app: return t("App & Help", "应用与帮助")
        }
    }

    /// 这一组里有哪些页。个人信息只有一页，它挂在账户区上，不进列表。
    var tabs: [SettingsTab] {
        SettingsTab.allCases.filter { $0.group == self && self != .profile }
    }
}

// MARK: - 窗口

/// 打开设置窗口，必要时先把它翻到某一页。
///
/// SwiftUI 没有「打开设置并选中第 N 页」的公开 API：`SettingsLink` 只会打开
/// 窗口。能直达的路径只有一条——先把选择写进 `@AppStorage`，再打开窗口。
///
/// 打开的那一下得靠视图环境里的 `openSettings`：AppKit 的
/// `showSettingsWindow:` 在 SwiftUI 生命周期下并不可靠（命令发出去没人接，
/// 点了就是没反应）。可命令层与工具栏都拿不到环境值，所以由根视图出现时把
/// 动作挂在这里，三处共用同一个入口。
@MainActor
enum SettingsWindow {
    /// 由根视图注入。`nil` 时回退到 AppKit 的动作，给没有窗口的环境用。
    private static var opener: (() -> Void)?

    static func install(_ opener: (() -> Void)?) {
        self.opener = opener
    }

    /// 打开上次停留的那一页。
    static func open() {
        guard let raw = UserDefaults.standard.string(forKey: SettingsTab.storageKey),
              let tab = SettingsTab(rawValue: raw)
        else {
            open(SettingsTab.fallback)
            return
        }
        open(tab)
    }

    static func open(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey)
        if let opener {
            opener()
        } else if let app = NSApp {
            // macOS 13 起是 showSettingsWindow:，之前叫 showPreferencesWindow:。
            // 两条都试：点了没反应比多试一次难查得多。
            if !app.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                app.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
        // 测试进程里没有 NSApp（`NSApp` 是隐式解包的可选）——这里不是错，
        // 只是没窗口可激活。
        NSApp?.activate(ignoringOtherApps: true)
    }
}

// MARK: - 窗口内容

/// 设置窗口：左边一列功能，右边是选中的那一页。
///
/// 顶部那块账户区本身就是「个人信息」的入口——头像、昵称、以及一句「只存在
/// 这台 Mac 上」。再往下才是按分类排的页。窗口尺寸固定：切页时窗口不该
/// 跟着变个大小，眼睛得重新找一遍。
struct SettingsShell: View {
    @AppStorage(SettingsTab.storageKey) private var selection = SettingsTab.fallback.rawValue
    @EnvironmentObject var profile: ProfileStore

    private var tab: SettingsTab {
        SettingsTab(rawValue: selection) ?? SettingsTab.fallback
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsLayout.sidebarWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 左

    /// 自绘的侧栏，不用 `List`：macOS 26 的 sidebar 样式会把选中高亮涂到
    /// 分组标题上，而且它的行高、留白都不归我们管。这里的行与账户区用
    /// 同一套按钮样式，视觉上是一体的。
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                account
                ForEach(SettingsGroup.allCases.filter { $0 != .profile }) { group in
                    Text(group.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                        .padding(.bottom, 3)
                    ForEach(group.tabs) { tab in
                        sidebarRow(tab)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 顶部账户区：头像 + 昵称。点它就落在「个人信息」页。
    private var account: some View {
        Button {
            selection = SettingsTab.profile.rawValue
        } label: {
            HStack(spacing: 9) {
                ProfileAvatar(image: profile.avatar, initial: profile.initial, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(profile.hasNickname
                        ? t("Stored on this Mac", "只存在这台 Mac 上")
                        : t("Add a nickname", "设个昵称"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(tab == .profile ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t("Name and picture — kept on this Mac", "昵称与头像——只留在这台 Mac 上"))
        .padding(.top, 10)
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let selected = tab == self.tab
        return Button {
            selection = tab.rawValue
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(selected ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }

    // MARK: 右

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 2)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .profile: ProfileSettingsView()
        case .writing: WritingSettingsView()
        case .theme: ThemeSettingsView()
        case .layout: LayoutSettingsView()
        case .printing: PrintingSettingsView()
        case .shortcuts: ShortcutSettingsView()
        case .app: AppSettingsView()
        }
    }
}

/// 设置窗口的尺寸。左边一列固定宽，右边把剩下的都给它。
enum SettingsLayout {
    static let width: CGFloat = 780
    static let height: CGFloat = 560
    static let sidebarWidth: CGFloat = 208
}

// MARK: - 更新状态的一句话

extension UpdateStatus {
    /// 报告状态给读者看的那句话。闲时不说话——没消息就是好消息。
    var summary: String? {
        switch self {
        case .idle: return nil
        case .checking: return t("Checking…", "正在检查…")
        case .upToDate(let version): return t("v\(version) is up to date", "v\(version) 已是最新")
        case .available(let version, _, _): return t("v\(version) available", "v\(version) 可用")
        case .failed: return t("Last check failed", "上次检查失败")
        }
    }
}
