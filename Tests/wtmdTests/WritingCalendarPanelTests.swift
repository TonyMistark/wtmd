import Foundation
import SwiftUI
import Testing
@testable import wtmd

// MARK: - 写作日历面板

/// 面板本身很薄：摘要、格子、点一下。真正会出错的是两处算术——
/// 点歪一格（差一个 step 就是另一天），和数字的写法（+1,240 与 +1240
/// 在界面上是两种观感）。这两处单独守。

@Suite("写作日历面板")
struct WritingCalendarPanelTests {
    // MARK: 几何

    @Test("格子按列宽逐格右移、逐行下移")
    func originStepsByOneCell() {
        let first = WritingHeatmapLayout.origin(column: 0, row: 0)
        let second = WritingHeatmapLayout.origin(column: 1, row: 0)
        let third = WritingHeatmapLayout.origin(column: 0, row: 2)

        #expect(first == .zero)
        #expect(second.x - first.x == WritingHeatmapLayout.step)
        #expect(second.y == first.y)
        #expect(third.y - first.y == WritingHeatmapLayout.step * 2)
    }

    @Test("画布尺寸：列数 × 步长减掉最后一道缝，高七行")
    func canvasSizeFitsTheColumns() {
        let size = WritingHeatmapLayout.size(columns: 53)
        #expect(size.width == CGFloat(53) * WritingHeatmapLayout.step - WritingHeatmapLayout.gap)
        #expect(size.height == CGFloat(7) * WritingHeatmapLayout.step - WritingHeatmapLayout.gap)
    }

    @Test("点在格子里落在哪一天")
    func hitResolvesToACell() {
        let origin = WritingHeatmapLayout.origin(column: 3, row: 5)
        let hit = WritingHeatmapLayout.hit(
            at: CGPoint(x: origin.x + 2, y: origin.y + 2), columns: 53
        )
        #expect(hit?.column == 3)
        #expect(hit?.row == 5)
    }

    @Test("点在缝里算最近的格子——缝只有三点宽，苛求点准只会点空")
    func hitToleratesGaps() {
        let origin = WritingHeatmapLayout.origin(column: 2, row: 1)
        let hit = WritingHeatmapLayout.hit(
            at: CGPoint(x: origin.x + WritingHeatmapLayout.cell + 1, y: origin.y + 1),
            columns: 53
        )
        #expect(hit?.column == 2 || hit?.column == 3)
        #expect(hit != nil)
    }

    @Test("点在外面：负坐标、越过最后一列、超过第七行都落空")
    func hitRejectsOutside() {
        #expect(WritingHeatmapLayout.hit(at: CGPoint(x: -1, y: 4), columns: 53) == nil)
        #expect(WritingHeatmapLayout.hit(at: CGPoint(x: 4, y: -1), columns: 53) == nil)
        #expect(
            WritingHeatmapLayout.hit(
                at: CGPoint(x: WritingHeatmapLayout.size(columns: 53).width + 20, y: 4),
                columns: 53
            ) == nil
        )
        #expect(
            WritingHeatmapLayout.hit(
                at: CGPoint(x: 4, y: WritingHeatmapLayout.size(columns: 1).height + 20),
                columns: 53
            ) == nil
        )
        #expect(WritingHeatmapLayout.hit(at: .zero, columns: 0) == nil)
    }

    // MARK: 文案

    @Test("千分位：三位一逗号，不留前导零")
    func groupedAddsCommas() {
        #expect(WritingCalendarText.grouped(0) == "0")
        #expect(WritingCalendarText.grouped(999) == "999")
        #expect(WritingCalendarText.grouped(1000) == "1,000")
        #expect(WritingCalendarText.grouped(1240) == "1,240")
        #expect(WritingCalendarText.grouped(89_000) == "89,000")
        #expect(WritingCalendarText.grouped(1_234_567) == "1,234,567")
    }

    @Test("带符号：正数加号、负数用真正的减号、零不挂符号")
    func signedUsesRealMinus() {
        #expect(WritingCalendarText.signed(1240) == "+1,240")
        #expect(WritingCalendarText.signed(-320) == "−320")
        #expect(WritingCalendarText.signed(0) == "0")
    }

    // MARK: 接线

    @Test("命令目录里有它：视图段、⌘⇧Y、挨着版本历史")
    func catalogCarriesTheCalendarCommand() throws {
        let command = try #require(
            CommandCatalog.staticCommands.first { $0.kind == .showCalendar }
        )
        #expect(command.section == .view)
        #expect(command.id == "view.calendar")
        #expect(command.shortcut == KeyboardShortcut("y", modifiers: [.command, .shift]))

        let history = try #require(
            CommandCatalog.staticCommands.first { $0.kind == .showHistory }
        )
        #expect(history.shortcut == KeyboardShortcut("y", modifiers: .command))
    }
}
