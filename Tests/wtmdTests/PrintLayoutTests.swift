import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
import WTMarkdownKit
@testable import wtmd

// MARK: - 纸上的版式

@MainActor
struct PrintLayoutTests {
    @Test func marginIsClampedIntoRange() {
        #expect(PrintLayout(marginMM: 2, pageNumbers: true, showTitle: false).marginMM == 10)
        #expect(PrintLayout(marginMM: 99, pageNumbers: true, showTitle: false).marginMM == 35)
        #expect(PrintLayout(marginMM: 22, pageNumbers: true, showTitle: false).marginMM == 22)
    }

    /// 手改过的 defaults 里可能是 NaN/inf：回默认值，别让版面算不出来。
    @Test func nonFiniteMarginFallsBackToDefault() {
        #expect(PrintLayout.clamp(.nan) == PrintLayout.defaultMarginMM)
        #expect(PrintLayout.clamp(.infinity) == PrintLayout.defaultMarginMM)
    }

    /// 毫米 → 点：18mm = 18/25.4 英寸 = 51.02pt
    @Test func millimetresBecomePoints() {
        let layout = PrintLayout(marginMM: 25.4, pageNumbers: true, showTitle: false)
        #expect(abs(layout.marginPoints - 72) < 0.01)
    }

    @Test func pageLabelCarriesTheTotal() {
        let layout = PrintLayout.standard
        #expect(layout.pageLabel(index: 3, total: 12) == "3 / 12")
        // 越界的页码（理论上不会发生）也不能写出 0 或负数
        #expect(layout.pageLabel(index: 0, total: 0) == "1 / 1")
    }

    @Test func defaultsRoundTrip() {
        let defaults = UserDefaults(suiteName: "wtmd.print.tests.\(UUID().uuidString)")!
        let settings = PrintSettings(defaults: defaults)
        // 没存过：18mm / 有页码 / 无标题
        #expect(settings.marginMM == 18)
        #expect(settings.pageNumbers)
        #expect(settings.showTitle == false)

        settings.marginMM = 24
        settings.pageNumbers = false
        settings.showTitle = true

        let reopened = PrintSettings(defaults: defaults)
        #expect(reopened.marginMM == 24)
        #expect(reopened.pageNumbers == false)
        #expect(reopened.showTitle)
    }

    /// 存过 `false` 与「没存过」必须分开：前者是读者的选择，后者才是默认。
    @Test func storedFalseSurvives() {
        let defaults = UserDefaults(suiteName: "wtmd.print.tests.\(UUID().uuidString)")!
        defaults.set(false, forKey: "wtmd.print.pageNumbers")
        #expect(PrintSettings(defaults: defaults).pageNumbers == false)
    }

    @Test func resetGoesBackToStandard() {
        let defaults = UserDefaults(suiteName: "wtmd.print.tests.\(UUID().uuidString)")!
        let settings = PrintSettings(defaults: defaults)
        settings.marginMM = 30
        settings.pageNumbers = false
        settings.reset()
        #expect(settings.layout == .standard)
    }
}

// MARK: - 打印样式

struct PrintStyleTests {
    /// 纸上不该有屏幕的留白：body 的 padding、版心居中都要归零。
    /// 四周边距交给切片时的 A4 正文框，CSS 里再留一层就成了双层边距。
    @Test func screenMarginsAreWiped() {
        let css = StyleSheet.printCSS(.standard)
        #expect(css.contains("html, body { margin: 0; padding: 0;"))
        #expect(css.contains("#wtmd-content { max-width: none; width: 100%; margin: 0; padding: 0; }"))
    }

    /// 字号行距不在这里重复声明（它们由版式层带进来），页边距也不该写进 CSS。
    @Test func paperMarginsStayOutOfCSS() {
        let css = StyleSheet.printCSS(.standard)
        #expect(!css.contains("--wtmd-font-size"))
        #expect(!css.contains("mm"))
    }

    @Test func titleHasItsOwnRule() {
        #expect(StyleSheet.printCSS(.standard).contains(".wtmd-print-title"))
    }

    @Test func documentCarriesThePrintLayer() throws {
        let html = StyleSheet.fullDocument(
            title: "报告",
            body: "<p>正文</p>\n",
            themeCSS: ":root{}",
            includeScript: false,
            printLayout: .standard,
            printTitle: "报告 <草稿>"
        )
        #expect(html.contains("<style id=\"wtmd-print\">"))
        // 就绪探测只在打印文档里：预览不背这段
        #expect(html.contains("__wtmdPrintReady"))
        // 默认不印标题：div 不该出现
        #expect(!html.contains("wtmd-print-title\">"))

        let titled = StyleSheet.fullDocument(
            title: "报告",
            body: "<p>正文</p>\n",
            themeCSS: ":root{}",
            includeScript: false,
            printLayout: PrintLayout(marginMM: 18, pageNumbers: true, showTitle: true),
            printTitle: "报告 <草稿>"
        )
        #expect(titled.contains("wtmd-print-title\">报告 &lt;草稿&gt;"))
        // 标题在正文容器之外：顶层子节点数 == 块数这条不变式不能破
        let titleAt = try #require(titled.range(of: "wtmd-print-title"))
        let contentAt = try #require(titled.range(of: "<div id=\"wtmd-content\">"))
        #expect(titleAt.lowerBound < contentAt.lowerBound)
    }

    @Test func exportedHTMLStillHasNoPrintLayer() {
        let html = StyleSheet.fullDocument(
            title: "t", body: "<p>x</p>", themeCSS: ":root{}", includeScript: false
        )
        #expect(!html.contains("wtmd-print"))
        #expect(!html.contains("__wtmdPrintReady"))
    }
}

// MARK: - 页码后处理

private func makeBlankPDF(pages: Int, at url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4，单位点
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw PDFPageNumberer.Failure.cannotCreateContext
    }
    for _ in 0..<pages {
        context.beginPage(mediaBox: &box)
        context.endPage()
    }
    context.closePDF()
}

@Test func stampingAddsAPageNumberToEveryPage() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-stamp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let source = folder.appendingPathComponent("raw.pdf")
    let output = folder.appendingPathComponent("stamped.pdf")
    try makeBlankPDF(pages: 3, at: source)

    try PDFPageNumberer.stamp(source: source, destination: output, layout: .standard)

    let document = try #require(PDFDocument(url: output))
    #expect(document.pageCount == 3)
    #expect(document.page(at: 0)?.string?.contains("1 / 3") == true)
    #expect(document.page(at: 2)?.string?.contains("3 / 3") == true)
}

@Test func stampingWithPageNumbersOffLeavesNoText() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-stamp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let source = folder.appendingPathComponent("raw.pdf")
    let output = folder.appendingPathComponent("plain.pdf")
    try makeBlankPDF(pages: 2, at: source)

    let layout = PrintLayout(marginMM: 18, pageNumbers: false, showTitle: false)
    try PDFPageNumberer.stamp(source: source, destination: output, layout: layout)

    let document = try #require(PDFDocument(url: output))
    #expect(document.pageCount == 2)
    #expect((document.page(at: 0)?.string ?? "").isEmpty)
}

@Test func stampingAnUnreadableFileThrows() {
    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-bogus-\(UUID().uuidString).pdf")
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-out-\(UUID().uuidString).pdf")
    #expect(throws: PDFPageNumberer.Failure.self) {
        try PDFPageNumberer.stamp(source: bogus, destination: output, layout: .standard)
    }
}
