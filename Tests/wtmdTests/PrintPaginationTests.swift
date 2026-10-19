import CoreGraphics
import Testing
@testable import wtmd

// MARK: - 分页（纯逻辑）

@MainActor
struct PrintPaginationTests {
    private func box(_ top: Double, _ bottom: Double) -> PrintBlockBox {
        PrintBlockBox(top: top, bottom: bottom)
    }

    @Test func everythingFitsOnOneSheet() {
        let pages = PrintPagination.pages(
            blocks: [box(0, 100), box(100, 300), box(300, 500)],
            sliceHeight: 800
        )
        #expect(pages == [PageSlice(top: 0, height: 500)])
    }

    /// 放不下就在块**前面**断开：块不跨页，页底留白比劈开一段话好。
    @Test func aBlockThatDoesNotFitMovesToTheNextSheet() {
        let pages = PrintPagination.pages(
            blocks: [box(0, 400), box(400, 700), box(700, 900)],
            sliceHeight: 600
        )
        #expect(pages == [
            PageSlice(top: 0, height: 400),
            PageSlice(top: 400, height: 500)
        ])
    }

    /// 页与页首尾相接：既不能漏内容（重叠），也不能凭空多出一段（跳空）。
    @Test func slicesAreContinuous() {
        let blocks = (0..<20).map { box(Double($0) * 130, Double($0) * 130 + 120) }
        let pages = PrintPagination.pages(blocks: blocks, sliceHeight: 500)
        #expect(pages.count > 1)
        for (previous, next) in zip(pages, pages.dropFirst()) {
            #expect(abs(previous.bottom - next.top) < 0.001)
        }
        #expect(abs((pages.first?.top ?? -1) - 0) < 0.001)
        #expect(abs((pages.last?.bottom ?? -1) - 2590) < 0.001)
    }

    /// 单块比一页还高（长表格、长代码块）：只能硬切，但一页都不能超过纸高。
    @Test func anOversizedBlockIsCutByThePage() {
        let pages = PrintPagination.pages(blocks: [box(0, 1450)], sliceHeight: 500)
        #expect(pages.count == 3)
        #expect(pages.allSatisfy { $0.height <= 500.0001 })
        #expect(abs((pages.last?.bottom ?? -1) - 1450) < 0.001)
    }

    @Test func emptyDocumentStillGivesOneSheet() {
        let pages = PrintPagination.pages(blocks: [], sliceHeight: 800)
        #expect(pages == [PageSlice(top: 0, height: 800)])
    }

    /// 误差容忍：排版量出来多半个像素不算「放不下」，否则页底会莫名空出一整页。
    @Test func halfAPixelOfOverflowIsForgiven() {
        let pages = PrintPagination.pages(blocks: [box(0, 800.4)], sliceHeight: 800)
        #expect(pages.count == 1)
    }
}

// MARK: - 纸的几何

struct PaperGeometryTests {
    /// 96dpi 的像素到 72dpi 的点：18mm 边距时 A4 正文宽 493pt ⇒ 657 CSS px。
    @Test func measureFollowsThePaperNotTheScreen() {
        let layout = PrintLayout(marginMM: 18, pageNumbers: true, showTitle: false)
        let measure = PaperGeometry.measure(for: layout)
        let usable = 595.28 - layout.marginPoints * 2
        #expect(abs(measure - usable / 0.75) < 0.5)
    }

    @Test func widerMarginsNarrowTheMeasure() {
        let tight = PrintLayout(marginMM: 10, pageNumbers: true, showTitle: false)
        let wide = PrintLayout(marginMM: 35, pageNumbers: true, showTitle: false)
        #expect(PaperGeometry.measure(for: wide) < PaperGeometry.measure(for: tight))
    }

    /// 字号不随边距变：边距只改变一页装多少字。同一段高度在纸上的点值因此不变。
    @Test func marginDoesNotShrinkTheType() {
        let tight = PrintLayout(marginMM: 10, pageNumbers: true, showTitle: false)
        let wide = PrintLayout(marginMM: 35, pageNumbers: true, showTitle: false)
        let a = PaperGeometry(sourceWidth: PaperGeometry.measure(for: tight), layout: tight)
        let b = PaperGeometry(sourceWidth: PaperGeometry.measure(for: wide), layout: wide)
        // 1000 CSS px 的内容在两种边距下印出来一样高
        #expect(abs(1000 * a.scale - 1000 * b.scale) < 1)
        // 但一页装得下的内容变少了
        #expect(b.sliceHeight < a.sliceHeight)
    }

    /// 滚动条会让 PDF 比网页窄 17px：缩放按真实宽度算，内容才不会右移出界。
    @Test func scaleUsesTheRealWidth() {
        let layout = PrintLayout(marginMM: 18, pageNumbers: true, showTitle: false)
        let geometry = PaperGeometry(sourceWidth: 640, layout: layout)
        let usable = 595.28 - layout.marginPoints * 2
        #expect(abs(geometry.scale - usable / 640) < 0.0001)
    }
}
