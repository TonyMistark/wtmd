import AppKit
import Foundation
import PDFKit
import Testing
import WTMarkdownKit
@testable import wtmd

// MARK: - 网页 → 纸（端到端）

/// 打印这条线只有真引擎能验：`createPDF` 出来的页面尺寸、切片之后每页装了什么、
/// PDFKit 能不能把正文与页码读回来——字符串断言一个都守不住。
private let printThemeCSS = """
:root{--bg:#ffffff;--fg:#222222;--pre-bg:#f5f5f5;--border:#dddddd;--th-bg:#eeeeee;\
--code-bg:#f5f5f5;--quote-bar:#888888;--font-body:sans-serif;--accent:#07C160;}
"""

private func printMarkdown(paragraphs: Int = 120) -> String {
    "# 纸上的版式\n\n"
        + (1...paragraphs)
        .map { "第 \($0) 段，用来把稿子撑到好几页，好让页边距与字号真的影响分页。" }
        .joined(separator: "\n\n")
}

private func printHTML(
    _ markdown: String,
    layout: PrintLayout,
    layoutCSS: String = "",
    title: String? = nil
) -> String {
    StyleSheet.fullDocument(
        title: "打印测试",
        body: WTMarkdown.render(markdown).html,
        themeCSS: printThemeCSS,
        includeScript: false,
        layoutCSS: layoutCSS,
        printLayout: layout,
        printTitle: title
    )
}

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-print-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// 走一遍完整管线（排版 → 分页 → 切片 → 页码），把成品读回来。
@MainActor private func renderPaper(
    _ html: String,
    layout: PrintLayout,
    folder: URL
) async throws -> PDFDocument {
    let target = folder.appendingPathComponent("paper-\(UUID().uuidString).pdf")
    _ = try await PrintController.render(html: html, baseURL: nil, layout: layout, to: target)
    return try #require(PDFDocument(url: target))
}

@Test @MainActor func aLongDraftBecomesSeveralPages() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let paper = try await renderPaper(
        printHTML(printMarkdown(), layout: .standard),
        layout: .standard,
        folder: folder
    )
    #expect(paper.pageCount >= 2)
    // 正文真的在纸上，而不是一页空白
    #expect((paper.page(at: 0)?.string ?? "").contains("纸上的版式"))
}

/// 每一页都得是 A4：打印机按纸张排版，页大小不对就是裁切或留白。
@Test @MainActor func everyPageIsASheetOfA4() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let paper = try await renderPaper(
        printHTML(printMarkdown(), layout: .standard),
        layout: .standard,
        folder: folder
    )
    let box = try #require(paper.page(at: 0)).bounds(for: .mediaBox)
    #expect(abs(box.width - PaperGeometry.a4.width) < 1)
    #expect(abs(box.height - PaperGeometry.a4.height) < 1)
}

@Test @MainActor func everyPageGetsItsNumber() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let paper = try await renderPaper(
        printHTML(printMarkdown(), layout: .standard),
        layout: .standard,
        folder: folder
    )
    let total = paper.pageCount
    #expect(total >= 2)
    for index in 0..<total {
        let text = paper.page(at: index)?.string ?? ""
        #expect(text.contains("\(index + 1) / \(total)"))
    }
}

/// 页边距必须真的改变每一页装得下多少：同一份稿子，边距大 ⇒ 行更短 ⇒ 页更多。
/// 页数相等说明边距只改了设置、没进版心。
@Test @MainActor func widerMarginsPushContentOntoMorePages() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let html = printHTML(printMarkdown(), layout: .standard)

    let tight = try await renderPaper(
        html,
        layout: PrintLayout(marginMM: 10, pageNumbers: false, showTitle: false),
        folder: folder
    )
    let wide = try await renderPaper(
        html,
        layout: PrintLayout(marginMM: 35, pageNumbers: false, showTitle: false),
        folder: folder
    )
    #expect(wide.pageCount > tight.pageCount)
}

/// 字号跟着屏幕走：同一份稿子，22px 的页数必须多于 14px。
@Test @MainActor func theReadingTextSizeTravelsToPaper() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let markdown = printMarkdown(paragraphs: 60)
    let layout = PrintLayout(marginMM: 18, pageNumbers: false, showTitle: false)

    let small = try await renderPaper(
        printHTML(markdown, layout: layout, layoutCSS: ":root { --wtmd-font-size: 14px; }"),
        layout: layout,
        folder: folder
    )
    let large = try await renderPaper(
        printHTML(markdown, layout: layout, layoutCSS: ":root { --wtmd-font-size: 22px; }"),
        layout: layout,
        folder: folder
    )
    #expect(large.pageCount > small.pageCount)
}

/// 首行标题只在开关打开时出现，且印在第一页最上面。
@Test @MainActor func theTitleIsOptional() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let markdown = printMarkdown(paragraphs: 4)
    let layout = PrintLayout(marginMM: 18, pageNumbers: false, showTitle: true)

    let titled = try await renderPaper(
        printHTML(markdown, layout: layout, title: "季度报告"),
        layout: layout,
        folder: folder
    )
    #expect((titled.page(at: 0)?.string ?? "").contains("季度报告"))

    let untitled = try await renderPaper(
        printHTML(markdown, layout: layout, title: nil),
        layout: layout,
        folder: folder
    )
    #expect((untitled.page(at: 0)?.string ?? "").contains("季度报告") == false)
}

/// 正文老实待在正文框里：一个字的边都不该压到页边距上。
///
/// 页码不算——它本来就画在页边距里，所以这条用「关页码」的版式量。
@Test @MainActor func contentStaysInsideTheContentBox() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let layout = PrintLayout(marginMM: 20, pageNumbers: false, showTitle: false)

    let paper = try await renderPaper(
        printHTML(printMarkdown(paragraphs: 40), layout: layout),
        layout: layout,
        folder: folder
    )
    let margin = layout.marginPoints
    for index in 0..<paper.pageCount {
        let page = try #require(paper.page(at: index))
        let box = page.bounds(for: .mediaBox)
        let allowed = CGRect(
            x: box.minX + margin - 3,
            y: box.minY + margin - 3,
            width: box.width - margin * 2 + 6,
            height: box.height - margin * 2 + 6
        )
        let count = page.numberOfCharacters
        guard count > 0 else { continue }
        for step in stride(from: 0, to: count, by: 17) {
            let glyph = page.characterBounds(at: step)
            guard glyph.width > 0, glyph.height > 0 else { continue }
            #expect(allowed.contains(glyph), "第 \(index + 1) 页有字超出了正文框：\(glyph)")
        }
    }
}

/// 块的边界才是切点：每一页都得从**一段的开头**起头。
///
/// 段落被拦腰切开的话，下一页的第一行必然是半句话——不会是「第 N 段，……」。
/// （不去比整句原文：WebKit 字体子集会把部分汉字映成康熙部首，抽出来的字面
/// 和 markdown 源文对不上，`⻚` 与 `页` 就是两个码位。）
@Test @MainActor func everySheetStartsAtABlock() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let layout = PrintLayout(marginMM: 18, pageNumbers: false, showTitle: false)

    let paper = try await renderPaper(
        printHTML(printMarkdown(paragraphs: 60), layout: layout),
        layout: layout,
        folder: folder
    )
    #expect(paper.pageCount >= 2)

    let firstLines = (0..<paper.pageCount).map { index -> String in
        let text = paper.page(at: index)?.string ?? ""
        return text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
    #expect(firstLines[0].contains("纸上的版式"))
    for line in firstLines.dropFirst() {
        #expect(line.hasPrefix("第 "), "这一页是从半句话开始的：\(line)")
    }
}
