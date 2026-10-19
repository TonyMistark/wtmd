import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// 给打印出来的 PDF 叠页码。
///
/// 为什么非得后处理：WebKit 不支持 CSS paged media 的 margin box
/// （`@page { @bottom-right { content: counter(page) } }` 写了也不生效），
/// `NSPrintOperation` 也没有页码 API。所以先让 WebKit 把网页打成一份 PDF，
/// 再逐页重绘、在页脚画一行字——打印与导出因此走的是同一份产物。
enum PDFPageNumberer {
    enum Failure: Error {
        case unreadableSource
        case cannotCreateContext
    }

    /// 把 `source` 逐页重绘到 `destination`，每页右下角印 `pageLabel`。
    ///
    /// 关掉页码时仍然重绘一遍：调用方拿到的永远是一份「完整的成品」，
    /// 不必在别处判断要不要再用原文件。
    static func stamp(source: URL, destination: URL, layout: PrintLayout) throws {
        guard let document = PDFDocument(url: source), document.pageCount > 0,
              let first = document.page(at: 0)
        else { throw Failure.unreadableSource }

        var mediaBox = first.bounds(for: .mediaBox)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
            throw Failure.cannotCreateContext
        }

        let total = document.pageCount
        for index in 0..<total {
            guard let page = document.page(at: index) else { continue }
            var pageBox = page.bounds(for: .mediaBox)
            context.beginPage(mediaBox: &pageBox)
            page.draw(with: .mediaBox, to: context)
            if layout.pageNumbers {
                drawFooter(
                    in: context,
                    box: pageBox,
                    label: layout.pageLabel(index: index + 1, total: total),
                    margin: layout.marginPoints
                )
            }
            context.endPage()
        }
        context.closePDF()
    }

    /// 页脚那一行：贴在页边距里，右对齐到右边距。
    ///
    /// 位置写死在 `margin * 0.45`（18mm 页边距 → 基线离纸边约 8mm），
    /// 而不是紧贴页边距下沿——太靠下会被打印机的不可打印区吃掉。
    private static func drawFooter(
        in context: CGContext,
        box: CGRect,
        label: String,
        margin: CGFloat
    ) {
        let attributed = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.black.withAlphaComponent(0.55)
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: box.maxX - margin - width,
            y: box.minY + margin * 0.45
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
