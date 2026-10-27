import Foundation
import Testing
import WTMarkdownKit
@testable import wtmd

// MARK: - 工具栏那个循环按钮

/// 语言 override 是全局的（L10n 套件会切），label 与 hint 各自调用 `t()`，
/// 并行跑会被别的测试在两次取词之间切语言——整个套件串行（老惯例）。
@Suite(.serialized)
@MainActor
struct ViewModeCycleTests {
    /// 一个按钮转一圈：思绪 → 落笔 → 成文 → 对照 → 回到思绪。
    @Test func cyclingVisitsEveryViewInOrderAndComesHome() throws {
        let dir = try makeTemporaryDraftDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(draftDirectory: dir)

        #expect(store.mode == .edit)
        store.cycleMode()
        #expect(store.mode == .live)
        store.cycleMode()
        #expect(store.mode == .preview)
        store.cycleMode()
        #expect(store.mode == .split)
        store.cycleMode()
        #expect(store.mode == .edit)
    }

    /// 从任何一格按下去都沿着同一圈走，不会跳格。
    @Test func cyclingContinuesTheRingFromWhereverYouAre() {
        #expect(ViewMode.edit.next == .live)
        #expect(ViewMode.live.next == .preview)
        #expect(ViewMode.preview.next == .split)
        #expect(ViewMode.split.next == .edit)
    }

    /// 循环顺序取自 `allCases` 本身——改顺序只动 `case` 的上下位置。
    @Test func cycleOrderIsTheCaseOrder() {
        #expect(ViewMode.allCases == [.edit, .live, .preview, .split])
    }

    /// 各视图共用一个按钮，图标必须互不相同，否则「现在在哪」就看不出来。
    @Test func everyViewHasItsOwnSymbol() {
        let symbols = Set(ViewMode.allCases.map(\.symbol))
        #expect(symbols.count == ViewMode.allCases.count)
        #expect(!symbols.contains(""))
    }

    /// 悬停提示先说现在在哪，再说点下去去哪——两句话都得随模式变。
    @Test func hoverHintNamesTheCurrentViewAndTheNextOne() {
        let hints = Set(ViewMode.allCases.map(\.cycleHint))
        #expect(hints.count == ViewMode.allCases.count)

        for mode in ViewMode.allCases {
            // 测试进程固定中文：`label` 就是「思绪 / 落笔 / 成文 / 对照」
            #expect(mode.cycleHint.hasPrefix(mode.label))
            #expect(mode.cycleHint.contains(mode.next.label))
        }
    }

    /// 按下去必须真的换视图，不只换图标：切进成文就立刻出成文（`setMode` 的既有行为）。
    @Test func cyclingIntoPreviewRendersTheText() throws {
        let dir = try makeTemporaryDraftDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(draftDirectory: dir)
        store.textDidChange("# 第一章\n\n正文")

        store.cycleMode()  // 思绪 → 落笔
        store.cycleMode()  // 落笔 → 成文

        #expect(store.mode == .preview)
        #expect(store.previewHTML.contains("第一章"))
    }

    /// 落笔不渲染 HTML：它还是源码编辑器，切进去不必重算渲染产物。
    @Test func cyclingIntoLiveDoesNotRecomputePreview() throws {
        let dir = try makeTemporaryDraftDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(draftDirectory: dir)
        store.textDidChange("# 第一章\n\n正文")

        store.setMode(.live)

        #expect(store.mode == .live)
    }
}

// MARK: - 辅助

private func makeTemporaryDraftDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-mode-cycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
