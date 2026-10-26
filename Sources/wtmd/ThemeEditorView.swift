import AppKit
import SwiftUI

// MARK: - 编辑器状态

/// 编辑器只管草稿与校验；写盘是 `ThemeStore` 的事，装进列表是 `ThemeManager` 的事。
@MainActor
final class ThemeEditorModel: ObservableObject {
    enum Side: String, CaseIterable, Identifiable {
        case light, dark
        var id: String { rawValue }
        var title: String { self == .light ? t("Light", context: "appearance") : t("Dark", context: "appearance") }
    }

    @Published var draft: ThemeDraft
    @Published var side: Side = .light
    @Published var showHighlights = false
    /// 下拉里显示的「基底」：换它就重载颜色与字体。
    @Published var baseID: String
    /// 非空即「这个文件夹已经有人占了」，界面弹问：覆盖 / 另存 / 取消。
    @Published var conflict: String?
    @Published var errorText: String?

    private let directory: URL

    init(draft: ThemeDraft, baseID: String, directory: URL = ThemeManager.themesDirectory) {
        self.draft = draft
        self.baseID = baseID
        self.directory = directory
    }

    var isEditing: Bool { draft.editingID != nil }

    var appearance: ThemeDraft.Appearance {
        get { side == .light ? draft.light : draft.dark }
        set {
            if side == .light { draft.light = newValue } else { draft.dark = newValue }
        }
    }

    // MARK: 绑定

    func colorBinding(_ key: String) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: Theme.color(hex: self.appearance.colors[key] ?? "") ?? .labelColor) },
            set: { newValue in
                guard let hex = Self.hex(from: newValue) else { return }
                self.appearance.colors[key] = hex
            }
        )
    }

    func hexBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { self.appearance.colors[key] ?? "" },
            set: { newValue in
                // 打一半的 `#f` 不该把颜色打坏：能认出来才写回，认不出留在文本框里。
                if let hex = ThemeDraft.normalizedHex(newValue) {
                    self.appearance.colors[key] = hex
                }
            }
        )
    }

    func fontBinding(_ font: WritableKeyPath<ThemeDraft.Fonts, String>) -> Binding<String> {
        Binding(
            get: { self.appearance.fonts[keyPath: font] },
            set: { self.appearance.fonts[keyPath: font] = $0 }
        )
    }

    // MARK: 动作

    /// 换基底：保留名字与作者，颜色/字体重回那套主题的样子。
    func rebase(on theme: Theme) {
        let fresh = ThemeDraft(basedOn: theme)
        draft.light = fresh.light
        draft.dark = fresh.dark
    }    /// 把当前一侧抄到另一侧。「深色就从浅色调暗一点」是最常见的做法。
    func copyToOtherSide() {
        if side == .light { draft.dark = draft.light } else { draft.light = draft.dark }
    }

    /// 正文与底色的对比度太低时说一句，但不拦着保存。
    var contrastWarning: String? {
        let colors = appearance.colors
        guard let ratio = ThemeDraft.contrastRatio(
            foreground: colors["fg"] ?? "", background: colors["bg"] ?? ""
        ), ratio < ThemeDraft.contrastWarningThreshold else { return nil }
        return t(
            "Text may be hard to read on this background ({}:1).",
            String(format: "%.1f", ratio)
        )
    }

    // MARK: 保存

    func save(overwrite: Bool = false) -> Theme? {
        do {
            let folder = try ThemeStore.write(draft, to: directory, overwrite: overwrite || isEditing)
            return ThemeFormat.loadFolder(folder)
        } catch let error as ThemeSaveError {
            if case .alreadyExists = error {
                conflict = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                errorText = error.localizedDescription
            }
            return nil
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }

    /// 另存为副本：名字加序号，之后它就是一套独立主题。
    func saveAsCopy() -> Theme? {
        draft.name = ThemeStore.copyName(draft.name, in: directory)
        draft.editingID = nil
        return save(overwrite: true)
    }

    static func hex(from color: Color) -> String? {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int {
            Int((Swift.min(Swift.max(value, 0), 1) * 255).rounded())
        }
        return String(
            format: "#%02x%02x%02x",
            byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent)
        )
    }
}

// MARK: - 界面

struct ThemeEditorView: View {
    @ObservedObject var model: ThemeEditorModel
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    /// 字体候选：系统的字族清单太长，先给常用的几组，其余在「更多」里。
    private static let curatedFamilies = [
        "Songti SC", "PingFang SC", "Hiragino Sans GB", "STSong", "Kaiti SC",
        "Georgia", "Charter", "Times New Roman", "Helvetica Neue",
        "SF Mono", "Menlo", "Monaco", "Courier New", "PT Mono",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        identity
                        colorsSection
                        fontsSection
                    }
                    .padding(18)
                }
                .frame(width: 400)
                Divider()
                previewPane
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 620)
        .alert(
            t("A theme named “{}” already exists.", model.conflict ?? ""),
            isPresented: Binding(
                get: { model.conflict != nil },
                set: { if !$0 { model.conflict = nil } }
            )
        ) {
            Button(t("Overwrite")) { finish(model.save(overwrite: true)) }
            Button(t("Save as Copy")) { finish(model.saveAsCopy()) }
            Button(t("Cancel"), role: .cancel) { model.conflict = nil }
        } message: {
            Text(t("Overwriting replaces the existing folder in the themes directory."))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.isEditing ? t("Edit Theme") : t("New Theme"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Picker("", selection: $model.side) {
                ForEach(ThemeEditorModel.Side.allCases) { side in
                    Text(side.title).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            Button(t("Copy to the Other")) { model.copyToOtherSide() }
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(t("Name")) {
                TextField("", text: $model.draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent(t("Author")) {
                TextField("", text: $model.draft.author)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent(t("Based On")) {
                Picker("", selection: $model.baseID) {
                    ForEach(themeManager.themes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .labelsHidden()
                .onChange(of: model.baseID) { _, newValue in
                    guard let theme = themeManager.themes.first(where: { $0.id == newValue }) else {
                        return
                    }
                    model.rebase(on: theme)
                }
            }
        }
    }

    private var colorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Colors")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(ThemePalette.primary, id: \.self) { key in
                colorRow(key)
            }
            if let warning = model.contrastWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            DisclosureGroup(t("Code Highlighting"), isExpanded: $model.showHighlights) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ThemePalette.highlights, id: \.self) { key in
                        colorRow(key)
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12))
        }
    }

    private func colorRow(_ key: String) -> some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: model.colorBinding(key), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 38)
            Text(paletteLabel(key))
                .font(.system(size: 12))
                .frame(width: 92, alignment: .leading)
            TextField("", text: model.hexBinding(key))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 96)
            Spacer(minLength: 0)
        }
    }

    private var fontsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Fonts")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            fontRow(t("Body Text"), keyPath: \.body, extra: defaultBodyFamily)
            fontRow(t("Headings"), keyPath: \.heading, extra: defaultBodyFamily)
            fontRow(t("Monospace"), keyPath: \.mono, extra: "SF Mono")
        }
    }

    private func fontRow(
        _ title: String,
        keyPath: WritableKeyPath<ThemeDraft.Fonts, String>,
        extra: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).frame(width: 92, alignment: .leading)
            Picker("", selection: model.fontBinding(keyPath)) {
                Text(t("Theme Default")).tag("")
                ForEach(familyOptions(extra: extra), id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .labelsHidden()
        }
    }

    /// 常用字族打头，其余系统字族补在后面（"更多"就靠菜单滚动）。
    private func familyOptions(extra: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for family in [extra] + Self.curatedFamilies + NSFontManager.shared.availableFontFamilies.sorted() {
            guard !family.isEmpty, seen.insert(family).inserted else { continue }
            result.append(family)
        }
        return result
    }

    private var defaultBodyFamily: String {
        Theme.firstFontFamily(inCSSStack: ThemeDraft.defaultBodyStack) ?? ""
    }

    private var previewPane: some View {
        ScrollView {
            ThemeDraftPreview(appearance: model.appearance)
                .padding(18)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if let error = model.errorText {
                Text(error).font(.callout).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            Button(t("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(t("Save")) { finish(model.save()) }
                .keyboardShortcut(.defaultAction)
                .disabled(model.draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func finish(_ theme: Theme?) {
        guard let theme else { return }
        themeManager.reload()
        themeManager.select(theme.id)
        dismiss()
    }

    private func paletteLabel(_ key: String) -> String {
        switch key {
        case "bg": return t("Background")
        case "fg": return t("Text")
        case "secondary": return t("Secondary Text")
        case "border": return t("Border")
        case "accent": return t("Accent")
        case "link": return t("Link")
        case "code-bg": return t("Inline Code")
        case "pre-bg": return t("Code Block")
        case "quote-bar": return t("Quote Bar")
        case "quote-fg": return t("Quote Text")
        case "hl-keyword": return t("Keyword")
        case "hl-string": return t("String")
        case "hl-number": return t("Number")
        case "hl-comment": return t("Comment")
        case "hl-type": return t("Type")
        case "hl-meta": return t("Meta")
        default: return key
        }
    }
}

// MARK: - 迷你预览

/// 用 SwiftUI 画的样张：不加载 WebView，改一个色立刻就能看到。
struct ThemeDraftPreview: View {
    let appearance: ThemeDraft.Appearance

    private func color(_ key: String, fallback: NSColor = .labelColor) -> Color {
        Color(nsColor: Theme.color(hex: appearance.colors[key] ?? "") ?? fallback)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(color("accent")).frame(width: 6, height: 6)
                Text(t("Quiet Night Thoughts"))
                    .font(.custom(appearance.fonts.heading, size: 16, relativeTo: .title3))
                    .foregroundStyle(color("fg"))
            }
            Text(t("1 · Moonlight"))
                .font(.custom(appearance.fonts.heading, size: 11, relativeTo: .caption))
                .foregroundStyle(color("secondary"))
            Text(t("Moonlight before my bed — I took it for frost on the ground."))
                .font(.custom(appearance.fonts.body, size: 12, relativeTo: .body))
                .foregroundStyle(color("fg"))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(t("I raise my head to the moon, and lower it to home."))
                .font(.custom(appearance.fonts.body, size: 11.5, relativeTo: .body))
                .foregroundStyle(color("quote-fg"))
                .lineSpacing(2)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(color("quote-bar")).frame(width: 2)
                }
            HStack(spacing: 4) {
                Text(t("Run"))
                    .font(.custom(appearance.fonts.body, size: 11.5, relativeTo: .body))
                    .foregroundStyle(color("fg"))
                Text("swift test")
                    .font(.custom(appearance.fonts.mono, size: 10.5, relativeTo: .body))
                    .foregroundStyle(color("fg"))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(color("code-bg")))
            }
            codeBlock
            HStack(spacing: 0) {
                Text(t("Slot")).font(.system(size: 10.5)).frame(maxWidth: .infinity, alignment: .leading)
                Text(t("Use")).font(.system(size: 10.5)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(color("fg"))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color("pre-bg"))
            .overlay(Rectangle().stroke(color("border"), lineWidth: 0.5))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color("bg", fallback: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color("border"), lineWidth: 0.5))
    }

    private var codeBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("// comment")
                .foregroundStyle(color("hl-comment"))
            HStack(spacing: 3) {
                Text("let").foregroundStyle(color("hl-keyword"))
                Text("title").foregroundStyle(color("fg"))
                Text("=").foregroundStyle(color("fg"))
                Text("\"wtmd\"").foregroundStyle(color("hl-string"))
            }
            HStack(spacing: 3) {
                Text("let").foregroundStyle(color("hl-keyword"))
                Text("year").foregroundStyle(color("fg"))
                Text("=").foregroundStyle(color("fg"))
                Text("2026").foregroundStyle(color("hl-number"))
            }
        }
        .font(.custom(appearance.fonts.mono, size: 10.5, relativeTo: .body))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(color("pre-bg")))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(color("border"), lineWidth: 0.5))
    }
}
