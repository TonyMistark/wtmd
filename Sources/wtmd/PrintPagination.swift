import CoreGraphics
import Foundation

/// 连续文档里的一块（CSS 像素，自上而下）。
///
/// 打印时文档先按版心宽度排成**一条很长**的流，再按页切开。
/// 切点必须落在块与块之间——把一行字劈成两半比多留半页空白难看得多。
struct PrintBlockBox: Equatable {
    let top: Double
    let bottom: Double

    init(top: Double, bottom: Double) {
        self.top = top
        self.bottom = bottom
    }
}

/// 一页纸装下的那一段连续文档（CSS 像素，自上而下）。
struct PageSlice: Equatable {
    let top: Double
    let height: Double

    var bottom: Double { top + height }
}

/// 纸的几何：把「按纸宽排出来的 CSS 像素」换算到「A4 上的点」。
///
/// 字号不随页边距缩放。屏幕 96dpi 的像素换算到 72dpi 的纸面正好 ×0.75——
/// 屏幕上 16px 的字，纸上就是 12pt，这是排版软件都会给出的同一个数。
/// 页边距因此只改变**一页能装多少字**（版心变窄、行变多、页变多），
/// 而不是把字越缩越小——读者把边距调大，不该得到更小的字。
struct PaperGeometry: Equatable {
    /// A4（1 pt = 1/72 英寸）。
    static let a4 = CGSize(width: 595.28, height: 841.89)

    /// CSS 像素 → 点。96dpi → 72dpi。
    static let cssToPoint = 0.75

    let pageSize: CGSize
    let margin: CGFloat
    /// 实际的 CSS 像素 → 点（按 PDF 的真实宽度算，滚动条那 17px 也在里面）。
    let scale: Double
    /// 一页正文区的宽度（CSS 像素）。
    let measure: Double
    /// 一页正文区的高度（CSS 像素）。
    let sliceHeight: Double

    /// 给定版式，算出这份稿子该按多宽排版（喂给网页的宽度）。
    static func measure(for layout: PrintLayout, pageSize: CGSize = PaperGeometry.a4) -> Double {
        let usable = Double(pageSize.width - layout.marginPoints * 2)
        return max(usable, 1) / cssToPoint
    }

    init(sourceWidth: Double, layout: PrintLayout, pageSize: CGSize = PaperGeometry.a4) {
        let usableWidth = Double(pageSize.width - layout.marginPoints * 2)
        let usableHeight = Double(pageSize.height - layout.marginPoints * 2)
        self.pageSize = pageSize
        margin = layout.marginPoints
        // 宽度为零只可能是量错了（空文档还没排版）：退回 CSS 的 0.75，至少别除出个 inf
        let width = sourceWidth > 1 ? sourceWidth : max(usableWidth, 1) / Self.cssToPoint
        let ratio = max(usableWidth, 1) / width
        scale = ratio
        measure = width
        sliceHeight = max(usableHeight, 1) / ratio
    }
}

enum PrintPagination {
    /// 贪心分页：块尽量整块留在同一页，放不下就在块前面断开。
    ///
    /// 只有一种例外：单块本身比一整页还高（长表格、长代码块、一张竖图）。
    /// 那时无论怎么断都会切到内容，只能按页硬切——少切几刀比丢内容强。
    static func pages(blocks: [PrintBlockBox], sliceHeight: Double) -> [PageSlice] {
        guard sliceHeight > 1 else { return [] }
        let boxes = blocks.filter { $0.bottom > $0.top }
        guard let first = boxes.first else {
            // 空文档也要出一张纸：打印面板里「0 页」看着像出错了
            return [PageSlice(top: 0, height: sliceHeight)]
        }

        let epsilon = 0.5
        var slices: [PageSlice] = []
        var start = max(0, first.top)

        for block in boxes {
            // 这块整块放不进当前页剩下的地方
            guard block.bottom - start > sliceHeight + epsilon else { continue }

            if block.top > start + epsilon {
                // 在块前断开：当前页到此为止
                let end = min(block.top, start + sliceHeight)
                slices.append(PageSlice(top: start, height: end - start))
                start = end
            }
            // 块自己就比一页高：按整页硬切，直到剩下的部分能放下
            while block.bottom - start > sliceHeight + epsilon {
                slices.append(PageSlice(top: start, height: sliceHeight))
                start += sliceHeight
            }
        }

        if let last = boxes.last, last.bottom - start > epsilon {
            slices.append(PageSlice(top: start, height: min(sliceHeight, last.bottom - start)))
        }
        if slices.isEmpty {
            slices.append(PageSlice(top: start, height: sliceHeight))
        }
        return slices
    }
}
