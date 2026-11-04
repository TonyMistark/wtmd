import AppKit
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 编辑器画笔与底色的对比度（#280）

/// #280 的教训：`highlight()` 曾直接用系统语义色，它们跟随**系统**外观，
/// 而底色跟随**主题**。单变体主题（base16 浅色方案等）撞上相反的系统外观
/// 时，浅色的语义色铺在浅底上，代码块、引用、落笔标记全部隐形。
///
/// 这里守两件事：所有内置主题在明暗两种 appearance 下，正文与各语法角色
/// 对底色都要有足够的亮度差；`EditorPalette.system` 退回系统语义色的旧世界。
@Suite("编辑器画笔对比度")
struct EditorThemeContrastTests {

    @MainActor
    private func makeProbe(theme: EditorThemeStyle?, text: String = "plain body text") -> (EditorTextView.Coordinator, NSTextView) {
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

    private func luminance(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    }

    /// 在指定 appearance 下解析动态颜色（编辑器绘制时就走这一步）。
    private func resolved(_ color: NSColor, under name: NSAppearance.Name) -> (CGFloat, CGFloat, CGFloat) {
        let appearance = NSAppearance(named: name)
        var out: NSColor?
        appearance?.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) }
        let c = out ?? NSColor.black
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    @MainActor
    @Test func everyBuiltinThemeKeepsEveryRoleReadableInBothAppearances() throws {
        for theme in Theme.builtIns {
            let style = try #require(EditorThemeStyle(theme: theme), "主题 \(theme.id) 连变量都没有")
            let (_, textView) = makeProbe(theme: style)
            let palette = try #require(textView.layoutManager as? LiveDecorationLayoutManager)
                .palette

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let bg = luminance(resolved(textView.backgroundColor, under: appearance))
                // 落笔的标记本来就设计成「退后」，不参与可读性断言。
                let roles: [(String, NSColor)] = [
                    ("text", palette.text),
                    ("heading", palette.heading),
                    ("codeText", palette.codeText),
                    ("quoteText", palette.quoteText),
                    ("listMarker", palette.listMarker),
                    ("inlineCodeText", palette.inlineCodeText),
                    ("strikethrough", palette.strikethrough),
                    ("link", palette.link),
                ]
                for (role, color) in roles {
                    let delta = abs(luminance(resolved(color, under: appearance)) - bg)
                    #expect(
                        delta > 0.2,
                        "\(theme.id) 在 \(appearance.rawValue) 下 \(role) 与底色的亮度差只有 \(delta)"
                    )
                }
            }
        }
    }

    @MainActor
    @Test func lightThemeUnderDarkSystemIsTheRegression() throws {
        // #280 的原始现场：浅色单变体主题 + 系统深色。修复前代码块内容
        // （secondaryLabelColor）解析成浅色，亮度差 ~0.1，肉眼即隐形。
        let style = try #require(EditorThemeStyle(theme: Theme(
            id: "probe.light", name: "Light", author: "", isBuiltIn: true,
            light: "--bg: #efecf4;\n--fg: #585260;\n--secondary: #7E7887;\n--font-mono: Menlo, monospace;",
            dark: nil
        )))
        let (coordinator, textView) = makeProbe(theme: style)
        let bg = luminance(resolved(textView.backgroundColor, under: .darkAqua))
        let code = luminance(resolved(coordinator.palette.codeText, under: .darkAqua))
        #expect(abs(code - bg) > 0.2)
        // 底色必须是主题的浅底，而不是被系统深色接管
        #expect(bg > 0.5)
    }

    @MainActor
    @Test func systemPaletteKeepsTheOldWorld() {
        let system = EditorTextView.EditorPalette.system
        // 无主题时全部回落系统语义色——与 #280 之前的行为逐字段一致。
        #expect(system.text == NSColor.labelColor)
        #expect(system.codeText == NSColor.secondaryLabelColor)
        #expect(system.quoteText == NSColor.systemGreen)
        #expect(system.marker == NSColor.tertiaryLabelColor)
        #expect(system.link == NSColor.linkColor)
    }
}
