import CoreGraphics
import Foundation
import PDFKit

/// 把「一页一块」的 PDF 片段拼成 A4 的纸。
///
/// 为什么不用 `NSPrintOperation` 分页：它要让 AppKit 驱动 WebKit 逐页重绘，
/// 而 WebKit 的打印格式器在离屏 / 无窗口环境里会卡在 `displayIfNeeded`
/// （实测测试进程里 45 秒不动、内存涨到 1.2G）。
///
/// 这条路是：先整篇出一份 PDF 量尺寸，再按分页切点**一页一页**让 WebKit 出
/// （`WKPDFConfiguration.rect`），每份只含那一页的内容，最后缩放贴进 A4 正文框。
/// 切点由 `PrintPagination` 决定，只落在块与块之间——表格和代码块不会被拦腰截断。
enum PDFSlicer {
    enum Failure: Error {
        case emptySource
        case cannotCreateContext
    }

    /// 把每份片段的第一页贴进 `geometry` 的正文框，顶部对齐。
    static func compose(
        _ pieces: [PDFDocument],
        geometry: PaperGeometry,
        to url: URL
    ) throws {
        guard !pieces.isEmpty else { throw Failure.emptySource }

        var mediaBox = CGRect(origin: .zero, size: geometry.pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw Failure.cannotCreateContext
        }
        let content = CGRect(
            x: geometry.margin,
            y: geometry.margin,
            width: geometry.pageSize.width - geometry.margin * 2,
            height: geometry.pageSize.height - geometry.margin * 2
        )

        for piece in pieces {
            guard let page = piece.page(at: 0), let cgPage = page.pageRef else { continue }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 1, box.height > 1 else { continue }

            context.beginPage(mediaBox: &mediaBox)
            context.saveGState()
            // 内容超出正文框（长表格被硬切时会有几像素）就裁掉，别压到页边距里
            context.clip(to: content)
            // 等比缩放到正文框宽度，顶边对齐——页的高度本来就该正好铺满正文框
            //（几何上 slice.height × scale == content.height，差别只是取整的零头）
            let scale = content.width / box.width
            context.translateBy(x: content.minX, y: content.maxY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.maxY)
            context.drawPDFPage(cgPage)
            context.restoreGState()
            context.endPage()
        }
        context.closePDF()
    }
}
