import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 编辑器取用主题

/// 预览吃整份 CSS，编辑器（NSTextView）只能拆出底色/字色/等宽字族喂进去。
/// 这里守三件事：解析是纯函数、应用后视图真的换装、回落路径不崩。
@Suite("编辑器主题取用")
struct EditorThemeTests {

    // MARK: 解析

    @Test func parseVariablesPicksUpVarLinesOnly() {
        let raw = """
        --bg: #faf7f0;
        --fg: #2b2620
        blockquote { border-left: 3px double var(--quote-bar); }
           --font-mono: "SF Mono", ui-monospace, monospace;
        """
        let vars = Theme.parseVariables(raw)
        #expect(vars["bg"] == "#faf7f0")
        #expect(vars["fg"] == "#2b2620")
        #expect(vars["font-mono"] == "\"SF Mono\", ui-monospace, monospace")
        #expect(vars.count == 3)
    }

    @Test func parseVariablesOfNilIsEmpty() {
        #expect(Theme.parseVariables(nil).isEmpty)
    }

    @Test func hexColorCoversAllLengths() {
        func parts(_ c: NSColor?) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let rgb = c?.usingColorSpace(.sRGB)
            return (rgb?.redComponent ?? -1, rgb?.greenComponent ?? -1, rgb?.blueComponent ?? -1, rgb?.alphaComponent ?? -1)
        }
        // #rrggbb
        let six = parts(Theme.color(hex: "#faf7f0"))
        #expect(abs(six.0 - 250/255) < 0.002 && abs(six.1 - 247/255) < 0.002 && abs(six.2 - 240/255) < 0.002)
        #expect(six.3 == 1)
        // #rgb：每一位顶四位
        let three = parts(Theme.color(hex: "#f80"))
        #expect(abs(three.0 - 1.0) < 0.002 && abs(three.1 - 136/255) < 0.01 && abs(three.2) < 0.002)
        // #rrggbbaa
        let eight = parts(Theme.color(hex: "#1e212680"))
        #expect(abs(eight.3 - 128/255) < 0.002)
        // 坏值一律 nil，不许把编辑器弄瞎
        #expect(Theme.color(hex: "faf7f0") == nil)
        #expect(Theme.color(hex: "#") == nil)
        #expect(Theme.color(hex: "#zzzzzz") == nil)
        #expect(Theme.color(hex: "#12345") == nil)
    }

    @Test func fontFamilyTakesFirstRealName() {
        #expect(Theme.firstFontFamily(inCSSStack: "\"SF Mono\", ui-monospace, Menlo, monospace") == "SF Mono")
        #expect(Theme.firstFontFamily(inCSSStack: "ui-monospace, monospace") == nil)
        #expect(Theme.firstFontFamily(inCSSStack: "'Songti SC', Georgia, serif") == "Songti SC")
        #expect(Theme.firstFontFamily(inCSSStack: "") == nil)
    }

    @Test func editorStyleFallsBackAcrossVariants() throws {
        // 只有暗色变体的主题（终端）：明暗两侧都借暗色的值
        let terminal = Theme(
            id: "t", name: "T", author: "", isBuiltIn: true,
            light: nil, dark: "--bg: #0d1117;\n--fg: #c9d1d9;\n--font-mono: Menlo, monospace;"
        )
        let style = try #require(EditorThemeStyle(theme: terminal))
        #expect(style.lightBackground == "#0d1117")
        #expect(style.darkForeground == "#c9d1d9")
        #expect(style.monoFontFamily == "Menlo")

        // 连变量都没有：不参与
        let empty = Theme(id: "e", name: "E", author: "", isBuiltIn: false, light: nil, dark: nil)
        #expect(EditorThemeStyle(theme: empty) == nil)
    }

    // MARK: 真视图应用

    @MainActor
    private func makeProbe(theme: EditorThemeStyle?, text: String = "# 标题\n\n**bold** body") -> (EditorTextView.Coordinator, NSTextView) {
        var value = text
        let bindable = Binding(get: { value }, set: { value = $0 })
        let view = EditorTextView(
            text: bindable,
            cursorLine: .constant(0),
            pendingImageInsert: .constant(nil),
            editorTheme: theme
        )
        let coordinator = view.makeCoordinator()
        coordinator.parent = view
        coordinator.textView.string = text
        coordinator.rebuildLineStarts()
        coordinator.applyTheme(theme)
        return (coordinator, coordinator.textView)
    }

    @MainActor
    @Test func applyingThemeRestylesTheEditor() throws {
        let style = EditorThemeStyle(theme: Theme(
            id: "test.ink", name: "Ink", author: "", isBuiltIn: true,
            light: "--bg: #faf7f0;\n--fg: #2b2620;\n--font-mono: Menlo, monospace;",
            dark: "--bg: #211c16;\n--fg: #e8ddc8;"
        ))

        let (coordinator, textView) = makeProbe(theme: try #require(style))
        // 字体跟着主题字族走
        #expect(textView.font?.familyName == "Menlo")
        // 底色是动态颜色，浅色 appearance 下解析成主题的暖白
        let aqua = NSAppearance(named: .aqua)

        func resolve(_ color: NSColor?) -> NSColor? {
            guard let color else { return nil }
            var resolved: NSColor?
            aqua?.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            return resolved
        }
        let bg = try #require(resolve(textView.backgroundColor))
        #expect(abs(bg.redComponent - 250/255) < 0.004)
        #expect(abs(bg.greenComponent - 247/255) < 0.004)

        // 正文颜色取普通行（第 0 个字符是标题行，令牌色会盖住主题字色）
        let bodyLocation = (textView.string as NSString).range(of: "body").location
        try #require(bodyLocation != NSNotFound)
        let fg = try #require(textView.textStorage?.attribute(.foregroundColor, at: bodyLocation, effectiveRange: nil) as? NSColor)
        let fgRGB = try #require(resolve(fg))
        #expect(abs(fgRGB.redComponent - 43/255) < 0.004)
        #expect(abs(fgRGB.greenComponent - 38/255) < 0.004)

        // 光标颜色解析后与文字同源
        let caretRGB = try #require(resolve(textView.insertionPointColor))
        #expect(abs(caretRGB.redComponent - fgRGB.redComponent) < 0.004)
        #expect(abs(caretRGB.greenComponent - fgRGB.greenComponent) < 0.004)
    }

    @MainActor
    @Test func highlightFollowsTheThemeFont() throws {
        let style = EditorThemeStyle(theme: Theme(
            id: "test.ink", name: "Ink", author: "", isBuiltIn: true,
            light: "--bg: #faf7f0;\n--fg: #2b2620;\n--font-mono: Menlo, monospace;",
            dark: nil
        ))
        let (coordinator, textView) = makeProbe(theme: try #require(style))

        // 标题行用同字族放大加粗；粗体标记用主题加粗体
        let fonts = coordinator.fonts
        let storage = try #require(textView.textStorage)
        let titleFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(titleFont.familyName == "Menlo")
        #expect(titleFont.pointSize > EditorTextView.EditorFonts.baseSize - 0.01)

        let boldRange = (textView.string as NSString).range(of: "**bold**")
        try #require(boldRange.location != NSNotFound)
        let boldFont = try #require(storage.attribute(.font, at: boldRange.location + 2, effectiveRange: nil) as? NSFont)
        #expect(boldFont == fonts.bold)
    }

    @MainActor
    @Test func clearingTheThemeRestoresTheSystemLook() throws {
        let style = EditorThemeStyle(theme: Theme(
            id: "test.ink", name: "Ink", author: "", isBuiltIn: true,
            light: "--bg: #faf7f0;\n--font-mono: Menlo, monospace;", dark: nil
        ))
        let (coordinator, textView) = makeProbe(theme: try #require(style))
        #expect(coordinator.fonts.regular.familyName == "Menlo")

        coordinator.applyTheme(nil)
        #expect(textView.backgroundColor == .textBackgroundColor)
        // ⚠️ `textView.font`/`textColor` 的 getter 跟着选区属性走，断言要看
        // coordinator 的字体对与 textStorage 的正文属性。
        let aqua = NSAppearance(named: .aqua)
        func resolve(_ color: NSColor?) -> NSColor? {
            guard let color else { return nil }
            var resolved: NSColor?
            aqua?.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            return resolved
        }
        let bodyLocation = (textView.string as NSString).range(of: "body").location
        try #require(bodyLocation != NSNotFound)
        let fg = try #require(textView.textStorage?.attribute(.foregroundColor, at: bodyLocation, effectiveRange: nil) as? NSColor)
        let textRGB = try #require(resolve(fg))
        let labelRGB = try #require(resolve(.labelColor))
        #expect(abs(textRGB.redComponent - labelRGB.redComponent) < 0.004)
        #expect(abs(textRGB.greenComponent - labelRGB.greenComponent) < 0.004)
        let system = EditorTextView.EditorFonts.system
        #expect(coordinator.fonts.regular.fontName == system.regular.fontName)
        #expect(coordinator.fonts.regular.pointSize == system.regular.pointSize)
    }

    @MainActor
    @Test func unresolvableFontFamilyFallsBackToSystem() throws {
        let style = EditorThemeStyle(theme: Theme(
            id: "test.ghost", name: "Ghost", author: "", isBuiltIn: true,
            light: "--bg: #faf7f0;\n--font-mono: \"No Such Typeface\", monospace;", dark: nil
        ))
        let (coordinator, _) = makeProbe(theme: try #require(style))
        // 字体没装：回落系统等宽，绝不能让编辑器没字写。
        // NSFont(name:) 对未知字族会悄悄给替代字体，回落必须靠可用字族清单把关。
        let system = EditorTextView.EditorFonts.system
        #expect(coordinator.fonts.regular.fontName == system.regular.fontName)
        #expect(coordinator.fonts.regular.pointSize == system.regular.pointSize)
    }
}
