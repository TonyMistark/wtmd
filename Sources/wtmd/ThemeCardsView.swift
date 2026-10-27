import AppKit
import SwiftUI

// MARK: - 筛选

/// 顶部的明暗筛选 chips：按主题自带哪一侧变量分。
/// 浅色/深色 chip 收的是「只带那一侧」的主题，两侧都有的归「浅 · 深」。
enum ThemeCardFilter: CaseIterable, Identifiable {
    case all, light, dark, both

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return t("All")
        case .light: return t("Light", context: "appearance")
        case .dark: return t("Dark", context: "appearance")
        case .both: return t("Light · Dark")
        }
    }

    func matches(_ theme: Theme) -> Bool {
        switch self {
        case .all: return true
        case .light: return theme.hasLight && !theme.hasDark
        case .dark: return theme.hasDark && !theme.hasLight
        case .both: return theme.hasLight && theme.hasDark
        }
    }
}

/// 卡片信息栏里的外观徽章文案：浅色 / 深色 / 浅 · 深。
func themeAppearanceLabel(_ theme: Theme) -> String {
    switch (theme.hasLight, theme.hasDark) {
    case (true, true): return t("Light · Dark")
    case (true, false): return t("Light", context: "appearance")
    case (false, true): return t("Dark", context: "appearance")
    case (false, false): return "—"
    }
}

// MARK: - 卡片样张

/// 卡片上半的迷你样张：SwiftUI 直绘，不进 WebView——十几张卡同屏滚动，
/// 每张起一个 WKWebView 是灾难。变量解析复用 `Theme.parseVariables`，
/// 颜色认不出就回落系统语义色（与 `ThemeDraftPreview` 同一约定）。
struct ThemeCardPreview: View {
    let vars: [String: String]

    private func color(_ key: String, fallback: NSColor) -> Color {
        Color(nsColor: Theme.color(hex: vars[key] ?? "") ?? fallback)
    }

    /// 样张字体跟随主题字族；字族没装/栈非法就回落系统字体——预览卡片
    /// 不该为一份坏字体栈丢颜色。
    private func font(_ stack: String?, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let family = Theme.firstFontFamily(inCSSStack: stack ?? ""),
              NSFontManager.shared.availableFontFamilies.contains(family)
        else { return .system(size: size, weight: weight) }
        return .custom(family, size: size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t("Sample Heading"))
                .font(font(vars["font-heading"], size: 13, weight: .semibold))
                .foregroundStyle(color("fg", fallback: .labelColor))
                .lineLimit(1)
            HStack(spacing: 3) {
                Text(t("Sample body"))
                Text("code")
                    .font(font(vars["font-mono"], size: 9))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color("code-bg", fallback: .quaternaryLabelColor))
                    )
                Text(t("Sample link"))
                    .foregroundStyle(color("link", fallback: .controlAccentColor))
            }
            .font(font(vars["font-body"], size: 10))
            .foregroundStyle(color("fg", fallback: .labelColor))
            .lineLimit(1)
            Text("let theme = \"wtmd\"")
                .font(font(vars["font-mono"], size: 9))
                .foregroundStyle(color("fg", fallback: .labelColor))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color("pre-bg", fallback: .unemphasizedSelectedContentBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(color("pre-border", fallback: .separatorColor), lineWidth: 0.5)
                )
            swatches
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(color("bg", fallback: .textBackgroundColor))
        .clipped()
    }

    private var swatches: some View {
        HStack(spacing: 4) {
            ForEach(["accent", "fg", "pre-bg", "secondary"], id: \.self) { key in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(key, fallback: .separatorColor))
                    .frame(width: 12, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 主题卡

/// 一张主题卡：上半是主题自身变量渲染的样张（明暗双面主题左右各一半），
/// 下半是名称 + 外观徽章 + 作者。点击整卡即选中。
struct ThemeCard: View {
    let theme: Theme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                preview
                Divider()
                info
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            )
            .overlay(alignment: .topTrailing) { selectionBadge }
            .shadow(color: .black.opacity(isSelected ? 0.10 : 0.05), radius: isSelected ? 6 : 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(theme.name)
    }

    /// 明暗双面主题左右各渲染一半，中间一条分隔线；单侧主题整幅用那一侧。
    @ViewBuilder
    private var preview: some View {
        if theme.hasLight && theme.hasDark {
            HStack(spacing: 0) {
                ThemeCardPreview(vars: Theme.parseVariables(theme.light))
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                ThemeCardPreview(vars: Theme.parseVariables(theme.dark))
            }
            .frame(height: 96)
            .clipped()
        } else {
            let vars = Theme.parseVariables(theme.hasLight ? theme.light : theme.dark)
            ThemeCardPreview(vars: vars)
        }
    }

    private var info: some View {
        HStack(spacing: 6) {
            Text(theme.name)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            badge
            Spacer(minLength: 4)
            Text(theme.author.isEmpty ? "—" : theme.author)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var badge: some View {
        Text(themeAppearanceLabel(theme))
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            ZStack {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
            .padding(6)
        }
    }
}

// MARK: - 添加主题卡

/// 自定义组尾部的虚线卡：点它弹文件夹选择面板，选中 .wttheme 即安装。
struct AddThemeCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .light))
                Text(t("Add Theme…"))
                    .font(.system(size: 12, weight: .medium))
                Text(t("Select a .wttheme folder to install"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 128)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.02)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 主题页

/// 设置 › 主题：卡片式主题库。取代原先的下拉 Picker——名字之外，每套
/// 主题用自己的颜色和字体长出来一张样张，滚轮往下翻完整个库。
struct ThemeSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var filter: ThemeCardFilter = .all
    @State private var editing: EditingDraft?
    @State private var importError: String?

    private let columns = [GridItem(.adaptive(minimum: 224), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    filterChips
                        .padding(.top, 12)
                    group(t("Built-in"), hint: t("Maintained by wtmd"),
                          themes: themeManager.builtInThemes)
                    group(t("base16 Community"), hint: t("From tinted-theming/schemes · MIT"),
                          themes: themeManager.base16Themes)
                    group(t("Custom"), hint: t("From your .wttheme folders"),
                          themes: themeManager.customThemes, addCard: true)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editing) { item in
            ThemeEditorView(
                model: ThemeEditorModel(draft: item.draft, baseID: item.baseID)
            )
            .environmentObject(themeManager)
        }
        .alert(
            t("Couldn't Add Theme"),
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button(t("OK"), role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    /// sheet(item:) 要 Identifiable；草稿本身没有身份，套一层。
    private struct EditingDraft: Identifiable {
        let id = UUID()
        let draft: ThemeDraft
        let baseID: String
    }

    // MARK: 分组

    @ViewBuilder
    private func group(
        _ title: String,
        hint: String,
        themes: [Theme],
        addCard: Bool = false
    ) -> some View {
        let visible = themes.filter { filter.matches($0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(t("{} themes", visible.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(visible) { theme in
                    ThemeCard(
                        theme: theme,
                        isSelected: theme.id == themeManager.currentThemeID
                    ) {
                        themeManager.select(theme.id)
                    }
                }
                if addCard {
                    AddThemeCard { importTheme() }
                }
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(ThemeCardFilter.allCases) { candidate in
                let active = filter == candidate
                Button {
                    filter = candidate
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                active ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)
                            )
                        )
                        .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 底栏

    /// 当前主题的一句话 + 原有动作。卡片页本身管「选」，这排管「建/改/装」。
    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(themeManager.currentTheme.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(currentSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(t("New Theme…")) {
                editing = EditingDraft(
                    draft: ThemeDraft(basedOn: themeManager.currentTheme),
                    baseID: themeManager.currentThemeID
                )
            }
            Button(t("Edit Theme…")) {
                editing = EditingDraft(
                    draft: ThemeDraft(basedOn: themeManager.currentTheme, editing: true),
                    baseID: themeManager.currentThemeID
                )
            }
            .disabled(themeManager.currentTheme.isBuiltIn)
            Button(t("Open Themes Folder…")) { themeManager.openThemesFolder() }
            Button(t("Rescan")) { themeManager.reload() }
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    /// 「内置 · wtmd · 浅 · 深」——来源、作者、外观拼一句话。
    private var currentSummary: String {
        let theme = themeManager.currentTheme
        var parts: [String] = []
        if theme.isBase16 {
            parts.append("base16")
        } else {
            parts.append(theme.isBuiltIn ? t("Built-in") : t("Custom"))
        }
        parts.append(theme.author.isEmpty ? "—" : theme.author)
        parts.append(themeAppearanceLabel(theme))
        return parts.joined(separator: " · ")
    }

    // MARK: 安装

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = t("Choose")
        panel.message = t("Select a .wttheme folder to install")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try themeManager.installTheme(from: url)
            themeManager.select(theme.id)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}
