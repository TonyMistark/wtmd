import AppKit
import Foundation
import PDFKit
import WebKit

/// 把一篇稿子送进纸里。
///
/// 三步：WebKit 在离屏把网页排成**一条很长**的 PDF（`createPDF`，矢量、一次成型）→
/// `PrintPagination` 按块找出每页的切点 → `PDFSlicer` 切成一张张 A4 并叠页码。
///
/// 不用 `NSPrintOperation` 的分页：它让 AppKit 驱动 WebKit 逐页重绘，
/// 在离屏 / 无窗口环境里会卡死在 `displayIfNeeded`（实测 45 秒不动、内存 1.2G）。
/// 自己切的好处是切点可控——只落在块与块之间，表格和代码块永远不会被拦腰截断。
@MainActor
enum PrintController {
    enum Failure: Error {
        case notLoaded
        case noPage
    }

    /// ⌘P：印出来，或者让读者在面板里「存储为 PDF」。
    static func print(html: String, baseURL: URL?, layout: PrintLayout) {
        Task {
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("wtmd-print-\(UUID().uuidString).pdf")
            do {
                _ = try await render(html: html, baseURL: baseURL, layout: layout, to: target)
            } catch {
                NSSound.beep()
                return
            }
            presentPrintPanel(for: target)
        }
    }

    /// 完整管线：排版 → 量块 → 分页 → 逐页出 PDF → 拼 A4 → 叠页码。返回页数。
    ///
    /// 逐页出而不是一次出整篇再裁：`createPDF` 的 `rect` 让每一份只含那一页的内容，
    /// 于是 PDF 里复制出来的文字也是「这一页的」（裁切只是遮住，字还在文件里）。
    ///
    /// - Parameter to: 成品落点
    @discardableResult
    static func render(
        html: String,
        baseURL: URL?,
        layout: PrintLayout,
        to url: URL
    ) async throws -> Int {
        let page = PrintPage(width: PaperGeometry.measure(for: layout))
        await page.load(html, baseURL: baseURL)
        await waitUntilReady(page.web)

        // 先整篇量一次：PDF 的真实宽度（滚动条会让它比网页窄）与总高度都在这
        guard let probeData = await page.pdfData(),
              let probe = PDFDocument(data: probeData),
              let probePage = probe.page(at: 0)
        else { throw Failure.noPage }
        let sourceBounds = probePage.bounds(for: .mediaBox)

        let boxes = await page.blockBoxes()
        let geometry = PaperGeometry(sourceWidth: sourceBounds.width, layout: layout)
        let slices = PrintPagination.pages(blocks: boxes, sliceHeight: geometry.sliceHeight)

        var pieces: [PDFDocument] = []
        for slice in slices where slice.height > 0 {
            let rect = CGRect(
                x: 0, y: slice.top, width: sourceBounds.width, height: slice.height
            )
            guard let data = await page.pdfData(in: rect),
                  let piece = PDFDocument(data: data)
            else { continue }
            pieces.append(piece)
        }

        let composed = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-paper-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: composed) }
        try PDFSlicer.compose(pieces, geometry: geometry, to: composed)
        try PDFPageNumberer.stamp(source: composed, destination: url, layout: layout)
        return pieces.count
    }

    /// 交出发成品：面板里既能打印，也能「存储为 PDF」——存下来的就是这份。
    private static func presentPrintPanel(for url: URL) {
        guard let document = PDFDocument(url: url) else {
            NSSound.beep()
            return
        }
        let info = NSPrintInfo.shared
        // 纸上的页边距已经在切片时留好了，打印时别再套一层
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let operation = document.printOperation(
            for: info, scalingMode: .pageScaleDownToFit, autoRotate: false
        )
        operation?.jobTitle = "wtmd"
        if let window = NSApp.keyWindow {
            operation?.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    /// 等图表、公式、图片都画完。超时按兜底处理——一张图画不出来不该让整篇印不出来。
    private static func waitUntilReady(_ web: WKWebView, timeout: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await evaluate(web, "__wtmdPrintReady()") as? Bool == true { break }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        // 就绪之后再留一帧：字体、图片解码落位
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    static func evaluate(_ web: WKWebView, _ source: String) async -> Any? {
        await withCheckedContinuation { cont in
            web.evaluateJavaScript(source) { value, _ in cont.resume(returning: value) }
        }
    }
}

/// 一次打印用的离屏网页。必须被强引用持有——`navigationDelegate` 是弱引用，
/// 拿它当临时变量会在 `await` 之前就被释放，`didFinish` 永远不来。
@MainActor
final class PrintPage: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var waiter: CheckedContinuation<Void, Never>?

    init(width: Double) {
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1000))
        super.init()
    }

    func load(_ html: String, baseURL: URL?) async {
        web.navigationDelegate = self
        web.loadHTMLString(html, baseURL: baseURL)
        await withCheckedContinuation { waiter = $0 }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            waiter?.resume()
            waiter = nil
        }
    }

    /// 出 PDF。不给 `rect` 就是整篇一条长页；给了就只出那一块（分页用）。
    func pdfData(in rect: CGRect? = nil) async -> Data? {
        let configuration = WKPDFConfiguration()
        if let rect { configuration.rect = rect }
        return await withCheckedContinuation { cont in
            web.createPDF(configuration: configuration) { result in
                cont.resume(returning: try? result.get())
            }
        }
    }

    /// 每个顶层块在连续文档里的上下边界（CSS 像素）。
    ///
    /// 量 `getBoundingClientRect` 而不是 `offsetTop`：前者把外边距塌陷算在内；
    /// 块与块之间的空隙归上一块（下一块的顶边就是上一块占到的位置），
    /// 否则分页时会以为「还放得下」，结果页底多出一行。
    func blockBoxes() async -> [PrintBlockBox] {
        let source = """
        (function () {
          var out = [];
          var title = document.querySelector('.wtmd-print-title');
          if (title) { var r = title.getBoundingClientRect(); out.push([r.top + window.scrollY, r.bottom + window.scrollY]); }
          var root = document.getElementById('wtmd-content');
          if (root) {
            for (var i = 0; i < root.children.length; i++) {
              var b = root.children[i].getBoundingClientRect();
              out.push([b.top + window.scrollY, b.bottom + window.scrollY]);
            }
          }
          return out;
        })()
        """
        let raw = await PrintController.evaluate(web, source) as? [[NSNumber]] ?? []
        var boxes: [PrintBlockBox] = raw.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            let top = pair[0].doubleValue
            let bottom = pair[1].doubleValue
            return bottom > top ? PrintBlockBox(top: top, bottom: bottom) : nil
        }
        // 块间距归上一块：这一块占到的位置一直到下一块开始之前
        for index in 0..<max(0, boxes.count - 1) {
            let next = boxes[index + 1].top
            if next > boxes[index].bottom {
                boxes[index] = PrintBlockBox(top: boxes[index].top, bottom: next)
            }
        }
        return boxes
    }
}
